// FakeRTCWorld (Plan 4 Task 7 / LNK-33): fakes for every seam of the RTC
// world — peer connection provider, peer connection, audio track, video
// capturer, RTP sender, data channel, camera availability and manual
// audio control — so the engine is exercised without any live WebRTC
// object. RTCVideoTrack itself can only come from a live factory, so the
// video-track fakes render nil by design.

@testable import CallEngine
import Foundation
import Synchronization
import WebRTC
import XCTest

// MARK: - Fake peer connection provider

/// Returns the test's fake peer connection and records the configuration it
/// was handed, so tests assert the ICE servers and policies the engine built
/// from the TURN credentials. The configuration is written once per prepare
/// (before any assertion reads it), so a plain field is race-free here.
final class FakePeerConnectionProvider: PeerConnectionProviding, @unchecked Sendable {
    let connection = FakePeerConnection()
    private var recordedConfiguration: RTCConfiguration?

    func makePeerConnection(
        configuration: RTCConfiguration,
        constraints _: RTCMediaConstraints,
        sink: PeerConnectionSink
    ) -> (any EnginePeerConnection)? {
        recordedConfiguration = configuration
        connection.attachSink(sink)
        return connection
    }

    var configuration: RTCConfiguration? {
        recordedConfiguration
    }
}

// MARK: - Fake peer connection

/// One recorded session description: the SDP string plus its direction.
struct RecordedDescription: Equatable, Sendable {
    let sdp: String
    let isAnswer: Bool
}

/// EnginePeerConnection fake: records every request the engine makes and
/// lets tests fire the callbacks the real WebRTC delegate would produce.
final class FakePeerConnection: EnginePeerConnection, @unchecked Sendable {
    private struct State {
        var audioTracks: [FakeAudioTrack] = []
        var videoBundles: [VideoTrackBundle] = []
        var channels: [FakeDataChannel] = []
        var offerCount = 0
        var answerCount = 0
        var localDescriptions: [RecordedDescription] = []
        var remoteDescriptions: [RecordedDescription] = []
        var addedCandidates: [IceCandidate] = []
        var closeCount = 0
        var statisticsCalls = 0
    }

    /// The sink the provider attached at makePeerConnection time (written
    /// once, before any test fires callbacks).
    private var sink: PeerConnectionSink?

    /// The video sender handed out by `videoSender()` — stored so the test
    /// asserts the parameters the engine applied to the same instance.
    private let storedVideoSender = Mutex<FakeRtpSender?>(nil)

    /// The canned report `statistics()` returns; nil until the test sets it.
    var cannedReport: RawStatsReport?

    private let state = Mutex(State())

    /// Wires the engine's sink so fire* methods reach the engine's streams.
    func attachSink(_ attached: PeerConnectionSink) {
        sink = attached
    }

    // MARK: EnginePeerConnection

    func addLocalAudio() -> any EngineAudioTrack {
        let track = FakeAudioTrack()
        state.withLock { $0.audioTracks.append(track) }
        return track
    }

    func addLocalVideo() -> VideoTrackBundle? {
        let bundle = VideoTrackBundle(capturer: FakeCapturer(), renderable: FakeVideoTrackHandle())
        state.withLock { $0.videoBundles.append(bundle) }
        return bundle
    }

    func makeOffer(_: RTCMediaConstraints) async throws -> String {
        state.withLock { $0.offerCount += 1 }
        return "offer-sdp"
    }

    func makeAnswer(_: RTCMediaConstraints) async throws -> String {
        state.withLock { $0.answerCount += 1 }
        return "answer-sdp"
    }

    func setLocalDescription(_ sdp: String, isAnswer: Bool) async throws {
        state.withLock { $0.localDescriptions.append(RecordedDescription(sdp: sdp, isAnswer: isAnswer)) }
    }

    func setRemoteDescription(_ sdp: String, isAnswer: Bool) async throws {
        state.withLock { $0.remoteDescriptions.append(RecordedDescription(sdp: sdp, isAnswer: isAnswer)) }
    }

    func addIceCandidate(_ candidate: IceCandidate) async {
        state.withLock { $0.addedCandidates.append(candidate) }
    }

    func dataChannel(forLabel _: String, configuration _: RTCDataChannelConfiguration?) -> any EngineDataChannel {
        let pcSink: PeerConnectionSink? = sink
        let ignoreData: @Sendable (Data) -> Void = { _ in }
        let ignoreState: @Sendable (Bool) -> Void = { _ in }
        let sink = DataChannelSink(
            onMessage: pcSink?.onDataChannelMessage ?? ignoreData,
            onStateChange: pcSink?.onDataChannelState ?? ignoreState
        )
        let channel = FakeDataChannel(sink: sink)
        state.withLock { $0.channels.append(channel) }
        return channel
    }

    func videoSender() -> (any RtpSenderControlling)? {
        let hasVideo = !state.withLock { $0.videoBundles }.isEmpty
        guard hasVideo else { return nil }
        return storedVideoSender.withLock { locked in
            if let stored = locked {
                return stored
            }
            let fresh = FakeRtpSender()
            locked = fresh
            return fresh
        }
    }

    func statistics() async -> RawStatsReport? {
        state.withLock { $0.statisticsCalls += 1 }
        return cannedReport
    }

    func close() {
        state.withLock { $0.closeCount += 1 }
    }

    // MARK: Test surface

    var audioTracks: [FakeAudioTrack] {
        state.withLock { $0.audioTracks }
    }

    var videoBundles: [VideoTrackBundle] {
        state.withLock { $0.videoBundles }
    }

    var channels: [FakeDataChannel] {
        state.withLock { $0.channels }
    }

    var offerCount: Int {
        state.withLock { $0.offerCount }
    }

    var answerCount: Int {
        state.withLock { $0.answerCount }
    }

    var localDescriptions: [RecordedDescription] {
        state.withLock { $0.localDescriptions }
    }

    var remoteDescriptions: [RecordedDescription] {
        state.withLock { $0.remoteDescriptions }
    }

    var addedCandidates: [IceCandidate] {
        state.withLock { $0.addedCandidates }
    }

    var closeCount: Int {
        state.withLock { $0.closeCount }
    }

    var statisticsCalls: Int {
        state.withLock { $0.statisticsCalls }
    }

    /// The sender instance the engine cached at prepare time (nil when the
    /// connection has no video).
    var videoSenderFake: FakeRtpSender? {
        storedVideoSender.withLock { $0 }
    }

    /// Fires what the real RTCPeerConnectionDelegate would produce.
    func fireIceCandidate(_ candidate: IceCandidate) {
        sink?.onIceCandidate(candidate)
    }

    func fireConnectionState(_ newState: IceConnectionState) {
        sink?.onConnectionState(newState)
    }

    func fireRemoteVideoTrack(_ handle: any VideoTrackHandle) {
        sink?.onRemoteVideoTrack(handle)
    }
}

// MARK: - Fake audio track

final class FakeAudioTrack: EngineAudioTrack, @unchecked Sendable {
    private let enabledState = Mutex(true)

    func setEnabled(_ enabled: Bool) {
        enabledState.withLock { $0 = enabled }
    }

    var isEnabled: Bool {
        enabledState.withLock { $0 }
    }
}

// MARK: - Fake video capturer

final class FakeCapturer: EngineVideoCapturer, @unchecked Sendable {
    private let counts = Mutex<(started: Int, stopped: Int)>((0, 0))

    func startCapture() async {
        counts.withLock { $0.started += 1 }
    }

    func stopCapture() {
        counts.withLock { $0.stopped += 1 }
    }

    var startCount: Int {
        counts.withLock { $0.started }
    }

    var stopCount: Int {
        counts.withLock { $0.stopped }
    }
}

// MARK: - Fake video track handle

/// A VideoTrackHandle without a real WebRTC track (RTCVideoTrack can only be
/// produced by a live factory, so fakes always render nil).
struct FakeVideoTrackHandle: VideoTrackHandle {
    var renderable: RTCVideoTrack? {
        nil
    }
}

// MARK: - Fake RTP sender

final class FakeRtpSender: RtpSenderControlling, @unchecked Sendable {
    private let applied = Mutex<[EncodingParameters]>([])

    func applyEncodingParameters(_ parameters: EncodingParameters) {
        applied.withLock { $0.append(parameters) }
    }

    var appliedParameters: [EncodingParameters] {
        applied.withLock { $0 }
    }
}

// MARK: - Fake data channel

final class FakeDataChannel: EngineDataChannel, @unchecked Sendable {
    private struct State {
        var sent: [Data] = []
        var open = false
    }

    private let sink: DataChannelSink
    private let state = Mutex(State())

    init(sink: DataChannelSink) {
        self.sink = sink
    }

    func send(_ data: Data) throws {
        state.withLock { $0.sent.append(data) }
    }

    var isOpen: Bool {
        state.withLock { $0.open }
    }

    // MARK: Test surface

    var sent: [Data] {
        state.withLock { $0.sent }
    }

    /// Simulates the channel reaching the open state.
    func simulateOpen() {
        state.withLock { $0.open = true }
        sink.onStateChange(true)
    }

    /// Simulates an inbound message from the peer.
    func receive(_ data: Data) {
        sink.onMessage(data)
    }
}

// MARK: - Fake camera availability

struct FakeCameraAvailability: CameraAvailabilityChecking {
    let hasCamera: Bool
}

// MARK: - Fake manual audio control

final class FakeManualAudio: ManualAudioControlling, @unchecked Sendable {
    private let flags = Mutex<(useManual: Bool, audioEnabled: Bool)>((false, false))

    var useManualAudio: Bool {
        get { flags.withLock { $0.useManual } }
        set { flags.withLock { $0.useManual = newValue } }
    }

    var isAudioEnabled: Bool {
        get { flags.withLock { $0.audioEnabled } }
        set { flags.withLock { $0.audioEnabled = newValue } }
    }
}

// MARK: - Recording logger

/// Log seam fake that records every message so tests can assert log hygiene
/// (spec 6/7: no SDP or ICE credentials ever logged).
final class RecordingCallEngineLogger: CallEngineLogging, @unchecked Sendable {
    private let messages = Mutex<[String]>([])

    func info(_ message: String) {
        messages.withLock { $0.append("info: \(message)") }
    }

    func error(_ message: String) {
        messages.withLock { $0.append("error: \(message)") }
    }

    var recorded: [String] {
        messages.withLock { $0 }
    }
}
