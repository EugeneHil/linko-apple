// DefaultCallEngine (Plan 4 Task 7): the CallMediaEngine implementation over
// the WebRTC seams. Configuration is spike-proven (ADR-0001): unified plan,
// continuous ICE gathering, all transports with the server's TURN
// credentials as the only servers; VP8 preferred (H.264 stays the Task 13
// cut candidate), Opus is the factory's audio default. The Simulator has no
// camera, so capture starts only when the camera seam detects a real device.
// Logging never carries SDP or ICE credentials — lifecycle words only.

import Foundation
import os
import ServerAPI
import WebRTC

/// Log seam for the engine; implementations never carry SDP, ICE
/// credentials or tokens (spec 6/7).
public protocol CallEngineLogging: Sendable {
    func info(_ message: String)
    func error(_ message: String)
}

struct DefaultCallEngineLogging: CallEngineLogging {
    private let logger = Logger(subsystem: "io.github.eugenehil.linko", category: "call-engine")

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

public actor DefaultCallEngine: CallMediaEngine {
    /// The data channel label both apps agree on (Task 9 control, Task 11
    /// file frames ride it).
    static let dataChannelLabel = "control"

    private let credentials: TurnCredentials
    private let provider: any PeerConnectionProviding
    private let cameraAvailability: any CameraAvailabilityChecking
    // Mutable through the existential (prepare flips useManualAudio).
    private var manualAudio: any ManualAudioControlling
    private let statsInterval: Duration
    private let logging: any CallEngineLogging

    private var peerConnection: (any EnginePeerConnection)?
    private var audioTrack: (any EngineAudioTrack)?
    private var videoBundle: VideoTrackBundle?
    private var videoSender: (any RtpSenderControlling)?
    private var channel: (any EngineDataChannel)?
    private var statsTask: Task<Void, Never>?
    private var localVideo: (any VideoTrackHandle)?
    private var remoteVideo: (any VideoTrackHandle)?

    private let iceCandidatesStream: AsyncStream<IceCandidate>
    private let iceCandidatesContinuation: AsyncStream<IceCandidate>.Continuation
    private let connectionStatesStream: AsyncStream<IceConnectionState>
    private let connectionStatesContinuation: AsyncStream<IceConnectionState>.Continuation
    private let dataChannelMessagesStream: AsyncStream<Data>
    private let dataChannelMessagesContinuation: AsyncStream<Data>.Continuation
    private let dataChannelStatesStream: AsyncStream<Bool>
    private let dataChannelStatesContinuation: AsyncStream<Bool>.Continuation
    private let statisticsStream: AsyncStream<RawStatsReport>
    private let statisticsContinuation: AsyncStream<RawStatsReport>.Continuation

    public init(
        credentials: TurnCredentials,
        peerConnectionProvider: any PeerConnectionProviding = LivePeerConnectionProvider.shared,
        cameraAvailability: any CameraAvailabilityChecking = LiveCameraAvailability(),
        manualAudio: any ManualAudioControlling = LiveManualAudioController.shared,
        statsInterval: Duration = .seconds(1),
        logging: (any CallEngineLogging)? = nil
    ) {
        self.credentials = credentials
        provider = peerConnectionProvider
        self.cameraAvailability = cameraAvailability
        self.manualAudio = manualAudio
        self.statsInterval = statsInterval
        self.logging = logging ?? DefaultCallEngineLogging()
        (iceCandidatesStream, iceCandidatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (connectionStatesStream, connectionStatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (dataChannelMessagesStream, dataChannelMessagesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (dataChannelStatesStream, dataChannelStatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (statisticsStream, statisticsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public nonisolated var iceCandidates: AsyncStream<IceCandidate> {
        iceCandidatesStream
    }

    public nonisolated var connectionStates: AsyncStream<IceConnectionState> {
        connectionStatesStream
    }

    public nonisolated var dataChannelMessages: AsyncStream<Data> {
        dataChannelMessagesStream
    }

    public nonisolated var dataChannelStates: AsyncStream<Bool> {
        dataChannelStatesStream
    }

    public nonisolated var statistics: AsyncStream<RawStatsReport> {
        statisticsStream
    }

    public var localVideoTrack: (any VideoTrackHandle)? {
        localVideo
    }

    public var remoteVideoTrack: (any VideoTrackHandle)? {
        remoteVideo
    }

    // MARK: Prepare

    public func prepare(media: CallMedia) async throws {
        guard peerConnection == nil else {
            throw CallEngineError.alreadyPrepared
        }
        // WebRTC must not activate the audio unit itself: CallKit (Task 10)
        // owns activation through the manual audio controller.
        manualAudio.useManualAudio = true

        let configuration = RTCConfiguration()
        configuration.iceServers = Self.iceServers(from: credentials)
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceTransportPolicy = .all
        guard let connection = provider.makePeerConnection(
            configuration: configuration,
            constraints: Self.mediaConstraints,
            sink: sink
        ) else {
            logging.error("peer connection refused by the WebRTC factory")
            throw CallEngineError.peerConnectionFailed
        }
        peerConnection = connection

        audioTrack = connection.addLocalAudio()
        if media == .video {
            let bundle = connection.addLocalVideo()
            videoBundle = bundle
            localVideo = bundle?.renderable
            videoSender = connection.videoSender()
            if let bundle, cameraAvailability.hasCamera {
                do {
                    try await bundle.capturer.startCapture()
                } catch {
                    // The call continues audio-only; the state surfaces
                    // through the connection stream, never through SDP.
                    logging.error("camera capture failed to start")
                }
            } else if bundle != nil {
                logging.info("no camera detected; capture stays off")
            }
        }
        startStatsPolling()
        logging.info("engine prepared (media: \(media.rawValue))")
    }

    // MARK: Offer and answer

    public func startCall() async throws -> String {
        guard let connection = peerConnection else {
            throw CallEngineError.notPrepared
        }
        // The caller creates the channel before the offer so the answer
        // side discovers it through didOpenDataChannel.
        channel = connection.dataChannel(forLabel: Self.dataChannelLabel, configuration: nil)
        let offer = try await connection.makeOffer(Self.mediaConstraints)
        try await connection.setLocalDescription(offer, isAnswer: false)
        return offer
    }

    public func accept() async throws -> String {
        guard let connection = peerConnection else {
            throw CallEngineError.notPrepared
        }
        let answer = try await connection.makeAnswer(Self.mediaConstraints)
        try await connection.setLocalDescription(answer, isAnswer: true)
        return answer
    }

    public func restartIce() async throws -> String {
        guard let connection = peerConnection else {
            throw CallEngineError.notPrepared
        }
        // The legacy iceRestart mandatory constraint is how a fresh offer
        // requests an ICE restart under the unified plan; the peer answers
        // it through the regular call.offer / call.answer exchange.
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: Self.restartIceMandatory,
            optionalConstraints: nil
        )
        let offer = try await connection.makeOffer(constraints)
        try await connection.setLocalDescription(offer, isAnswer: false)
        return offer
    }

    public func setRemoteSDP(_ sdp: String, isAnswer: Bool) async throws {
        guard let connection = peerConnection else {
            throw CallEngineError.notPrepared
        }
        try await connection.setRemoteDescription(sdp, isAnswer: isAnswer)
    }

    public func addIceCandidate(candidate: String, sdpMid: String?, lineIndex: Int32) async {
        guard let connection = peerConnection else {
            logging.error("candidate dropped: engine not prepared")
            return
        }
        await connection.addIceCandidate(IceCandidate(candidate: candidate, sdpMid: sdpMid, lineIndex: lineIndex))
    }

    // MARK: Data channel

    public func sendOverDataChannel(_ data: Data) async throws {
        guard peerConnection != nil else {
            throw CallEngineError.notPrepared
        }
        guard let channel, channel.isOpen else {
            throw CallEngineError.channelNotOpen
        }
        try channel.send(data)
    }

    // MARK: Bitrate and mute

    public func applyBitratePlan(_ plan: BitratePlan) async {
        guard let videoSender else {
            logging.info("bitrate plan ignored: no video sender")
            return
        }
        videoSender.applyEncodingParameters(plan.encodingParameters)
    }

    public func setMuted(_ muted: Bool) async {
        audioTrack?.setEnabled(!muted)
    }

    public func setVideoEnabled(_ enabled: Bool) async {
        guard videoBundle != nil else {
            logging.info("video toggle ignored: audio-only session")
            return
        }
        localVideo?.renderable?.isEnabled = enabled
        if enabled {
            // Re-arm capture only where a camera exists; a refused restart
            // leaves the call audio-only (the state surfaces through the
            // connection stream, never through SDP).
            if cameraAvailability.hasCamera {
                try? await videoBundle?.capturer.startCapture()
            }
            logging.info("video capture resumed")
        } else {
            videoBundle?.capturer.stopCapture()
            logging.info("video capture stopped")
        }
    }

    // MARK: Hangup

    public func hangup() async {
        guard peerConnection != nil else { return }
        statsTask?.cancel()
        statsTask = nil
        // Anti-goal: capture left running after the call ends.
        videoBundle?.capturer.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        channel = nil
        audioTrack = nil
        videoBundle = nil
        videoSender = nil
        localVideo = nil
        remoteVideo = nil
        logging.info("engine hung up")
    }

    // MARK: Shared configuration

    /// The TURN credentials become exactly one RTCIceServer carrying every
    /// configured URI (the REST credentials apply to the whole URI set —
    /// turn_handler.cpp).
    static func iceServers(from credentials: TurnCredentials) -> [RTCIceServer] {
        guard !credentials.urls.isEmpty else { return [] }
        return [RTCIceServer(
            urlStrings: credentials.urls,
            username: credentials.username,
            credential: credentials.credential
        )]
    }

    /// Offer/answer media constraints: the unified plan needs none — the
    /// added tracks decide what is offered (spike-proven).
    private static var mediaConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    /// The mandatory constraints of a restart offer: the pinned legacy
    /// iceRestart key/value pair (the restart trigger under the unified
    /// plan). Whether WebRTC honors it is device-e2e territory (Task 15).
    static let restartIceMandatory: [String: String] = [
        kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue
    ]
}

// MARK: - Wiring and polling

private extension DefaultCallEngine {
    /// The single wrap point: the production adapter fires these from the
    /// WebRTC delegate threads; the streams carry them. The four pure
    /// streams yield directly from the captured continuations; the two that
    /// mutate engine state hop through a Task onto the actor.
    var sink: PeerConnectionSink {
        PeerConnectionSink(
            onIceCandidate: { [iceCandidatesContinuation] candidate in
                iceCandidatesContinuation.yield(candidate)
            },
            onConnectionState: { [connectionStatesContinuation] state in
                connectionStatesContinuation.yield(state)
            },
            onRemoteVideoTrack: { [weak self] handle in
                Task { await self?.setRemoteVideoTrack(handle) }
            },
            onDataChannelMessage: { [dataChannelMessagesContinuation] data in
                dataChannelMessagesContinuation.yield(data)
            },
            onDataChannelState: { [dataChannelStatesContinuation] open in
                dataChannelStatesContinuation.yield(open)
            },
            onOpenDataChannel: { [weak self] channel in
                Task { await self?.adoptRemoteChannel(channel) }
            }
        )
    }

    func setRemoteVideoTrack(_ handle: any VideoTrackHandle) {
        remoteVideo = handle
    }

    /// The remote-opened channel becomes the send target — the coordinator's
    /// in-call control fallback (spec 4.2) rides it.
    func adoptRemoteChannel(_ incoming: any EngineDataChannel) {
        guard channel == nil else { return }
        channel = incoming
    }

    /// One snapshot per interval; cancelled by hangup (the tests assert the
    /// stop, Task 8 consumes the stream).
    func startStatsPolling() {
        statsTask = Task { [weak self, statsInterval, statisticsContinuation] in
            while !Task.isCancelled {
                try? await Task.sleep(for: statsInterval)
                guard !Task.isCancelled else { return }
                guard let self, let connection = await peerConnection else { continue }
                if let report = await connection.statistics() {
                    statisticsContinuation.yield(report)
                }
            }
        }
    }
}
