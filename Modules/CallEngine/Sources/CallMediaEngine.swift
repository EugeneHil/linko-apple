// CallMediaEngine (Plan 4 Task 7): the protocol the call coordinator
// (Task 9) and the stats poller (Task 8) drive, plus the seams that keep
// every live WebRTC object (factory, peer connection, tracks, capturer,
// data channel) behind interfaces the tests fake. Delegate callbacks are
// wrapped exactly once into AsyncStreams by the production adapters — the
// engine only ever sees the streams and the seam objects.

import Foundation
import WebRTC

/// The call media surface. One instance drives one call: prepare →
/// start/accept → hangup, with streams for everything the wire and the UI
/// need (spec 4.4, spec 7: callback APIs wrapped once).
public protocol CallMediaEngine: Sendable {
    /// Builds the peer connection, tracks and (for video on a real device)
    /// the camera capture. Statistics polling starts here.
    func prepare(media: CallMedia) async throws

    /// Creates the data channel and the offer; returns the offer SDP string.
    func startCall() async throws -> String

    /// Creates the answer to the remote offer; returns the answer SDP string.
    func accept() async throws -> String

    /// Rebuilds the session with an ICE-restart offer and applies it as the
    /// local description; returns the offer SDP string for the coordinator to
    /// ship to the peer as call.offer (the StartIceRestart effect's surface,
    /// Plan 4 Task 9).
    func restartIce() async throws -> String

    /// Applies the remote session description (offer before accept, answer
    /// after startCall).
    func setRemoteSDP(_ sdp: String, isAnswer: Bool) async throws

    /// Feeds a remote ICE candidate to the peer connection.
    func addIceCandidate(candidate: String, sdpMid: String?, lineIndex: Int32) async

    /// Stops capture, closes the peer connection and releases the tracks.
    func hangup() async

    /// Local candidates the wire must carry (call.ice bodies).
    var iceCandidates: AsyncStream<IceCandidate> { get }

    /// ICE connection states, folded by the coordinator into machine events.
    var connectionStates: AsyncStream<IceConnectionState> { get }

    /// Inbound data channel payloads (call control, Task 9; file frames,
    /// Task 11) as opaque binary data.
    var dataChannelMessages: AsyncStream<Data> { get }

    /// Data channel open/closed transitions — the coordinator checks the
    /// in-call control fallback against them (spec 4.2).
    var dataChannelStates: AsyncStream<Bool> { get }

    /// Raw statistics at the 1 s cadence that feeds Task 8.
    var statistics: AsyncStream<RawStatsReport> { get }

    /// Sends an opaque binary payload over the open data channel; throws
    /// while no channel is open.
    func sendOverDataChannel(_ data: Data) async throws

    /// Applies the adaptation policy's plan to the video sender's encoding
    /// parameters.
    func applyBitratePlan(_ plan: BitratePlan) async

    /// Mutes/unmutes the local audio track.
    func setMuted(_ muted: Bool) async

    /// Enables/disables the local camera for the current video call: the
    /// track stops being sent and capture stops (re-enabled on demand).
    /// A no-op for audio-only sessions (Task 13 part 2's tray camera
    /// toggle routes here).
    func setVideoEnabled(_ enabled: Bool) async

    /// The local video track for the UI preview; nil for audio-only calls.
    var localVideoTrack: (any VideoTrackHandle)? { get async }

    /// The remote video track once it arrives; nil until then.
    var remoteVideoTrack: (any VideoTrackHandle)? { get async }
}

/// Typed engine failures. None of the payloads carries SDP or credentials.
public enum CallEngineError: Error, Equatable, Sendable {
    /// prepare was never called.
    case notPrepared
    /// prepare was called on an already-prepared engine.
    case alreadyPrepared
    /// The WebRTC factory refused the peer connection.
    case peerConnectionFailed
    /// No data channel is open (or none exists yet).
    case channelNotOpen
    /// An SDP or candidate operation failed inside WebRTC.
    case negotiationFailed
}

// MARK: - Seams

/// Builds peer connections. The production provider owns the one shared
/// RTCPeerConnectionFactory (expensive to create); tests inject a provider
/// that hands back a fake connection.
public protocol PeerConnectionProviding: Sendable {
    func makePeerConnection(
        configuration: RTCConfiguration,
        constraints: RTCMediaConstraints,
        sink: PeerConnectionSink
    ) -> (any EnginePeerConnection)?
}

/// What the production adapters fire — the single wrap point from the
/// WebRTC delegate callbacks into the engine's streams. Every closure is
/// non-async and Sendable, so the delegate threads never touch actor state
/// (the two that must mutate the engine hop through a Task internally).
public struct PeerConnectionSink: Sendable {
    public let onIceCandidate: @Sendable (IceCandidate) -> Void
    public let onConnectionState: @Sendable (IceConnectionState) -> Void
    public let onRemoteVideoTrack: @Sendable (any VideoTrackHandle) -> Void
    public let onDataChannelMessage: @Sendable (Data) -> Void
    public let onDataChannelState: @Sendable (Bool) -> Void
    public let onOpenDataChannel: @Sendable (any EngineDataChannel) -> Void

    public init(
        onIceCandidate: @escaping @Sendable (IceCandidate) -> Void,
        onConnectionState: @escaping @Sendable (IceConnectionState) -> Void,
        onRemoteVideoTrack: @escaping @Sendable (any VideoTrackHandle) -> Void,
        onDataChannelMessage: @escaping @Sendable (Data) -> Void,
        onDataChannelState: @escaping @Sendable (Bool) -> Void,
        onOpenDataChannel: @escaping @Sendable (any EngineDataChannel) -> Void
    ) {
        self.onIceCandidate = onIceCandidate
        self.onConnectionState = onConnectionState
        self.onRemoteVideoTrack = onRemoteVideoTrack
        self.onDataChannelMessage = onDataChannelMessage
        self.onDataChannelState = onDataChannelState
        self.onOpenDataChannel = onOpenDataChannel
    }
}

/// The data channel's inbound callbacks; the connection sink forwards both
/// channel kinds (caller-created and remote-opened) into the same pair.
public struct DataChannelSink: Sendable {
    public let onMessage: @Sendable (Data) -> Void
    public let onStateChange: @Sendable (Bool) -> Void

    public init(
        onMessage: @escaping @Sendable (Data) -> Void,
        onStateChange: @escaping @Sendable (Bool) -> Void
    ) {
        self.onMessage = onMessage
        self.onStateChange = onStateChange
    }
}

/// What the engine does with a peer connection. Production wraps one
/// RTCPeerConnection (and is its delegate); tests record the calls.
public protocol EnginePeerConnection: Sendable {
    /// Creates the local audio track and adds it to the connection.
    func addLocalAudio() -> any EngineAudioTrack
    /// Creates the local video track with its capturer and adds it.
    func addLocalVideo() -> VideoTrackBundle?
    /// The video sender for bitrate application; nil without video.
    func videoSender() -> (any RtpSenderControlling)?
    /// The offer SDP string (the RTCSessionDescription objects never cross
    /// this seam: the adapter builds and applies them internally).
    func makeOffer(_ constraints: RTCMediaConstraints) async throws -> String
    /// The answer SDP string.
    func makeAnswer(_ constraints: RTCMediaConstraints) async throws -> String
    func setLocalDescription(_ sdp: String, isAnswer: Bool) async throws
    func setRemoteDescription(_ sdp: String, isAnswer: Bool) async throws
    func addIceCandidate(_ candidate: IceCandidate) async
    /// Creates (caller side) the data channel; its callbacks flow through
    /// the connection's sink like the remote channel's do.
    func dataChannel(forLabel label: String, configuration: RTCDataChannelConfiguration?) -> any EngineDataChannel
    /// One statistics snapshot; nil without a live connection.
    func statistics() async -> RawStatsReport?
    func close()
}

/// The local audio track's control surface (mute).
public protocol EngineAudioTrack: Sendable {
    func setEnabled(_ enabled: Bool)
}

/// The local video capture (device and format selection is production
/// detail); hangup must stop it — the anti-goal test asserts that.
public protocol EngineVideoCapturer: Sendable {
    /// Throws when the capture session fails to start.
    func startCapture() async throws
    func stopCapture()
}

/// The video track bundle addLocalVideo returns: the capturer the engine
/// starts/stops and the renderable handle for the UI.
public struct VideoTrackBundle: Sendable {
    public let capturer: any EngineVideoCapturer
    public let renderable: (any VideoTrackHandle)?

    public init(capturer: any EngineVideoCapturer, renderable: (any VideoTrackHandle)?) {
        self.capturer = capturer
        self.renderable = renderable
    }
}

/// The video sender's encoding surface (the fake RTCRtpSender seam the
/// bitrate tests exercise).
public protocol RtpSenderControlling: Sendable {
    func applyEncodingParameters(_ parameters: EncodingParameters)
}

/// The data channel's send surface. Inbound messages and state changes flow
/// through the connection sink, identically for the caller-created channel
/// and the remote-opened one.
public protocol EngineDataChannel: Sendable {
    /// Sends one opaque binary payload (consumers frame it: Task 9 control,
    /// Task 11 transfer frames).
    func send(_ data: Data) throws
    var isOpen: Bool { get }
}

/// Whether a camera exists on this device — the Simulator has none, so
/// capture starts only when a real device is detected (plan Task 7).
public protocol CameraAvailabilityChecking: Sendable {
    var hasCamera: Bool { get }
}
