// LiveRTC (Plan 4 Task 7): the production adapters — the single place where
// live WebRTC objects exist. RTCPeerConnectionFactory and
// RTCAudioSession are process-wide singletons (the factory is expensive and
// shared, plan Task 7); every delegate callback crosses into the sink
// exactly once, and the Objective-C track classes ride in unchecked-Sendable
// boxes (CallMedia.swift). WebRTC-internal behavior (real capture, DTLS) is
// covered by the device e2e (Task 15), per ADR-0001's spike proof.

import CoreMedia
import Foundation
import Synchronization
import WebRTC

// MARK: - Codec preference

/// VP8 first in the codec lists (plan Task 7; H.264 is the Task 13 cut
/// candidate). Opus stays the audio factory's default — no ordering code.
enum CodecPreference {
    static func vp8First(_ codecs: [RTCVideoCodecInfo]) -> [RTCVideoCodecInfo] {
        let vp8 = codecs.filter { $0.name == "VP8" }
        let rest = codecs.filter { $0.name != "VP8" }
        return vp8 + rest
    }
}

private final class VP8PreferredEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = RTCDefaultVideoEncoderFactory()

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        base.createEncoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        CodecPreference.vp8First(base.supportedCodecs())
    }
}

private final class VP8PreferredDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        base.createDecoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        CodecPreference.vp8First(base.supportedCodecs())
    }
}

// MARK: - Peer connection provider

/// The production provider over the one shared RTCPeerConnectionFactory.
public final class LivePeerConnectionProvider: PeerConnectionProviding, @unchecked Sendable {
    /// The shared provider (the factory is expensive and created once).
    public static let shared = LivePeerConnectionProvider()

    /// Thread-safe after initialization (libwebrtc contract), so a
    /// nonisolated(unsafe) singleton is the honest shape for the expensive
    /// factory every engine instance shares.
    private nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: VP8PreferredEncoderFactory(),
            decoderFactory: VP8PreferredDecoderFactory()
        )
    }()

    public func makePeerConnection(
        configuration: RTCConfiguration,
        constraints: RTCMediaConstraints,
        sink: PeerConnectionSink
    ) -> (any EnginePeerConnection)? {
        let box = LivePeerConnection(sink: sink)
        guard let rtc = Self.factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: box
        ) else {
            return nil
        }
        box.attach(rtc, factory: Self.factory)
        return box
    }
}

// MARK: - Live peer connection

/// Wraps one RTCPeerConnection, is its delegate, and forwards every consumed
/// callback into the sink exactly once (spec 7). The wrapped objects are
/// written once by attach (before any external call can reach the methods)
/// and read from the engine's actor — the @unchecked Sendable box covers
/// that discipline; the delegate callbacks only ever touch the immutable
/// sink.
final class LivePeerConnection: NSObject, EnginePeerConnection, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let sink: PeerConnectionSink
    private var rtcConnection: RTCPeerConnection?
    private var rtcFactory: RTCPeerConnectionFactory?

    init(sink: PeerConnectionSink) {
        self.sink = sink
    }

    func attach(_ rtc: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
        rtcFactory = factory
        rtcConnection = rtc
    }

    // MARK: Tracks

    func addLocalAudio() -> any EngineAudioTrack {
        guard let factory = rtcFactory, let rtc = rtcConnection else {
            return DetachedAudioTrack()
        }
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "audio-\(UUID().uuidString.prefix(8))")
        rtc.add(track, streamIds: ["linko"])
        return LiveAudioTrack(rtc: track)
    }

    func addLocalVideo() -> VideoTrackBundle? {
        guard let factory = rtcFactory, let rtc = rtcConnection else {
            return nil
        }
        let source = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "video-\(UUID().uuidString.prefix(8))")
        rtc.add(track, streamIds: ["linko"])
        return VideoTrackBundle(
            capturer: LiveVideoCapturer(rtc: capturer),
            renderable: LiveVideoTrack(renderable: track)
        )
    }

    func videoSender() -> (any RtpSenderControlling)? {
        guard let rtc = rtcConnection else { return nil }
        let transceiver = rtc.transceivers.first { $0.mediaType == .video }
        guard let sender = transceiver?.sender else { return nil }
        return LiveRtpSender(rtc: sender)
    }

    // MARK: Negotiation

    func makeOffer(_ constraints: RTCMediaConstraints) async throws -> String {
        let rtc = try currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            rtc.offer(for: constraints) { description, _ in
                if let description {
                    continuation.resume(returning: description.sdp)
                } else {
                    continuation.resume(throwing: CallEngineError.negotiationFailed)
                }
            }
        }
    }

    func makeAnswer(_ constraints: RTCMediaConstraints) async throws -> String {
        let rtc = try currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            rtc.answer(for: constraints) { description, _ in
                if let description {
                    continuation.resume(returning: description.sdp)
                } else {
                    continuation.resume(throwing: CallEngineError.negotiationFailed)
                }
            }
        }
    }

    func setLocalDescription(_ sdp: String, isAnswer: Bool) async throws {
        let rtc = try currentConnection()
        let description = RTCSessionDescription(type: isAnswer ? .answer : .offer, sdp: sdp)
        try await rtc.setLocalDescription(description)
    }

    func setRemoteDescription(_ sdp: String, isAnswer: Bool) async throws {
        let rtc = try currentConnection()
        let description = RTCSessionDescription(type: isAnswer ? .answer : .offer, sdp: sdp)
        try await rtc.setRemoteDescription(description)
    }

    func addIceCandidate(_ candidate: IceCandidate) async {
        guard let rtc = rtcConnection else { return }
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.lineIndex,
            sdpMid: candidate.sdpMid
        )
        // Candidate errors are non-fatal (a late candidate is routine); the
        // connection state stream carries the real transport health.
        try? await rtc.add(rtcCandidate)
    }

    // MARK: Data channel and statistics

    func dataChannel(forLabel label: String, configuration: RTCDataChannelConfiguration?) -> any EngineDataChannel {
        let channelSink = DataChannelSink(
            onMessage: sink.onDataChannelMessage,
            onStateChange: sink.onDataChannelState
        )
        // The factory API expects a configuration object; nil callers get
        // the defaults.
        let channelConfiguration = configuration ?? RTCDataChannelConfiguration()
        guard let rtc = rtcConnection,
              let rtcChannel = rtc.dataChannel(forLabel: label, configuration: channelConfiguration)
        else {
            return DetachedDataChannel(sink: channelSink)
        }
        return LiveDataChannel(rtc: rtcChannel, sink: channelSink)
    }

    func statistics() async -> RawStatsReport? {
        guard let rtc = rtcConnection else { return nil }
        return await withCheckedContinuation { continuation in
            rtc.statistics { report in
                continuation.resume(returning: StatsConversion.convert(report))
            }
        }
    }

    func close() {
        rtcConnection?.close()
        rtcConnection = nil
    }

    private func currentConnection() throws -> RTCPeerConnection {
        guard let rtc = rtcConnection else {
            throw CallEngineError.notPrepared
        }
        return rtc
    }

    // MARK: RTCPeerConnectionDelegate (wrapped once)

    func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sink.onIceCandidate(IceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            lineIndex: candidate.sdpMLineIndex
        ))
    }

    func peerConnection(_: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        sink.onConnectionState(Self.map(state))
    }

    func peerConnection(_: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        sink.onRemoteVideoTrack(LiveVideoTrack(renderable: track))
    }

    func peerConnection(_: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        let channelSink = DataChannelSink(
            onMessage: sink.onDataChannelMessage,
            onStateChange: sink.onDataChannelState
        )
        sink.onOpenDataChannel(LiveDataChannel(rtc: dataChannel, sink: channelSink))
    }

    func peerConnection(_: RTCPeerConnection, didFailToGatherIceCandidate _: RTCIceCandidateErrorEvent) {
        // Gathering failures (e.g. a blocked STUN/TURN URI) are non-fatal:
        // other candidates keep arriving and the connection state stream
        // carries the transport health. Never logged with candidate text.
    }

    /// Required delegate slots the engine does not consume.
    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}

    /// RTCIceConnectionState → the engine's enum, one to one.
    static func map(_ state: RTCIceConnectionState) -> IceConnectionState {
        switch state {
        case .new: .new
        case .checking: .checking
        case .connected: .connected
        case .completed: .completed
        case .failed: .failed
        case .disconnected: .disconnected
        case .closed: .closed
        default: .closed
        }
    }
}
