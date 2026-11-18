// CallCoordinator (Plan 4 Task 9): the one active call's lifecycle, driven
// entirely by the core call state machine through CoreBridge's
// LKCallStateMachine. The coordinator holds no protocol knowledge of its
// own: signaling call.* envelopes map to machine events, engine states and
// network changes map to machine events, and the machine's LKEffect vector
// is the only output — sends, timers, ringing reports and ICE restarts.
// The wire half (consumers of the input streams, envelope mapping and the
// in-call control fallback) lives in CallCoordinator+Wire.swift.

import CallEngine
import CallStats
import CoreBridge
import Foundation
import Signaling

/// The outbound signaling seam (SignalingClient in production; tests record).
public protocol CallSignalingSending: Sendable {
    func send(_ envelope: LKEnvelope) async throws
}

/// The network input seam: NWPathMonitor path changes wrapped as CallStats
/// NetworkState values (Task 13 wiring).
public protocol CallNetworkMonitoring: Sendable {
    var states: AsyncStream<NetworkState> { get }
}

/// Boxes the statistics stream's iterator for the StatsPoller's @Sendable
/// pull closure (the iterator is a mutable value that cannot be captured
/// directly). Single consumer: only the poller's loop calls pull(), so the
/// unsynchronized iterator access is safe.
final class StatisticsPuller: @unchecked Sendable {
    private nonisolated(unsafe) var iterator: AsyncStream<RawStatsReport>.Iterator

    init(stream: AsyncStream<RawStatsReport>) {
        iterator = stream.makeAsyncIterator()
    }

    func pull() async -> RawStatsReport? {
        await iterator.next()
    }
}

@MainActor
public final class CallCoordinator {
    let signaling: any CallSignalingSending
    let signalingEvents: AsyncStream<SignalingEvent>
    let engine: any CallMediaEngine
    let reporting: any CallReporting
    let source: any IncomingCallSource
    let network: any CallNetworkMonitoring
    let uploader: any CallReportUploading
    let adaptation: AdaptationPolicy
    let statsInterval: Duration
    let makeCallId: @Sendable () -> String
    let nowMs: @Sendable () -> Int64

    var machine = LKCallStateMachine(state: .idle())

    /// The clock the machine's timers sleep on; stored so the lazy timer can
    /// pick the injected one up after initialization.
    let clock: any CallClock

    /// The timer actor behind StartTimer/CancelTimer. Lazy because its expiry
    /// closure needs the fully initialized coordinator (Swift forbids self
    /// capture in an initializer body; first access happens after init).
    lazy var timer = CallTimer(clock: clock, onExpiry: { [weak self] kind in
        await self?.handleTimerExpiry(kind)
    })

    /// The UI-facing state stream (buffered; the UI consumes at its own pace).
    public let callState: AsyncStream<CallState>
    let callStateContinuation: AsyncStream<CallState>.Continuation

    /// The UI-facing statistics stream (LNK-39, Task 13 part 1): one derived
    /// sample per poll tick while a session is active, newest-wins buffering
    /// so a slow UI consumer never accumulates backlog. The stream lives as
    /// long as the coordinator — samples stop between calls, the stream
    /// never ends.
    public let stats: AsyncStream<CallStatsSample>
    let statsContinuation: AsyncStream<CallStatsSample>.Continuation

    /// The machine's current call state, readable without consuming the stream.
    public private(set) var currentState: CallState = .idle

    /// Whether the engine's data channel is open (the in-call control
    /// fallback routes sends over it, spec 4.2).
    public internal(set) var isDataChannelOpen = false

    /// The consuming loop tasks start() spawned; stop() cancels them.
    var loops: [Task<Void, Never>] = []
    var running = false

    /// The call id the engine's prepared session belongs to; nil while the
    /// engine holds no session (before the first call and after each end).
    var sessionCallId: String?
    var poller: StatsPoller?
    var muted = false
    var setupStartMs: Int64 = 0

    public init(
        signaling: any CallSignalingSending,
        signalingEvents: AsyncStream<SignalingEvent>,
        engine: any CallMediaEngine,
        reporting: any CallReporting,
        source: any IncomingCallSource,
        network: any CallNetworkMonitoring,
        uploader: any CallReportUploading,
        clock: (any CallClock)? = nil,
        adaptation: AdaptationPolicy = AdaptationPolicy(),
        statsInterval: Duration = .seconds(1),
        makeCallId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.signaling = signaling
        self.signalingEvents = signalingEvents
        self.engine = engine
        self.reporting = reporting
        self.source = source
        self.network = network
        self.uploader = uploader
        self.adaptation = adaptation
        self.statsInterval = statsInterval
        self.makeCallId = makeCallId
        self.nowMs = nowMs
        self.clock = clock ?? SystemCallClock()
        (callState, callStateContinuation) = AsyncStream.makeStream(of: CallState.self, bufferingPolicy: .unbounded)
        (stats, statsContinuation) = AsyncStream.makeStream(of: CallStatsSample.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts the consuming loops (signaling events, incoming calls, engine
    /// streams, network states). Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        loops = [
            Task { await self.consumeSignalingEvents() },
            Task { await self.consumeIncomingCalls() },
            Task { await self.consumeConnectionStates() },
            Task { await self.consumeDataChannelMessages() },
            Task { await self.consumeDataChannelStates() },
            Task { await self.consumeIceCandidates() },
            Task { await self.consumeNetworkStates() }
        ]
    }

    /// Stops the consuming loops.
    public func stop() {
        guard running else { return }
        running = false
        for loop in loops {
            loop.cancel()
        }
        loops = []
        Task {
            await timer.cancelAll()
            await stopStatsCollection()
        }
    }

    // MARK: - Local user actions

    /// Starts an outgoing call. A no-op while any call is active: exactly
    /// one call at a time.
    public func invite(peer: String, media: CallMedia) async {
        guard machine.state.kind == .idle else { return }
        let callId = makeCallId()
        // The engine session exists before the wire invite: the offer ships
        // right behind it, and a refused engine never reaches the wire.
        await ensureEngineSession(callId: callId, video: media == .video)
        guard sessionCallId == callId, let offer = try? await engine.startCall() else { return }
        await apply(LKCallEvent(kind: .localInvite, callId: callId, peer: peer, video: media == .video))
        await sendSDPCall(LKTypes.callOffer, callId: callId, sdp: offer)
    }

    /// Accepts the ringing incoming call.
    public func accept() async {
        let state = machine.state
        guard state.kind == .incomingRinging else { return }
        await apply(LKCallEvent(kind: .localAccept, callId: state.callId, peer: "", video: false))
        // The answer rides behind the machine's call.accept envelope.
        if let answer = try? await engine.accept() {
            await sendSDPCall(LKTypes.callAnswer, callId: state.callId, sdp: answer)
        }
    }

    /// Declines the ringing incoming call.
    public func reject() async {
        let state = machine.state
        guard state.kind == .incomingRinging else { return }
        await apply(LKCallEvent(kind: .localReject, callId: state.callId, peer: "", video: false))
    }

    /// Ends the current call with the event the machine pins for its state.
    public func hangup() async {
        let state = machine.state
        let eventKind: LKCallEventKind? = switch state.kind {
        case .outgoingRinging, .connecting: .localCancel
        case .incomingRinging: .localReject
        case .active, .reconnecting: .localHangup
        case .idle, .ended: nil
        @unknown default: nil
        }
        guard let eventKind else { return }
        await apply(LKCallEvent(kind: eventKind, callId: state.callId, peer: "", video: false))
    }

    /// Mutes/unmutes the local audio track.
    public func toggleMute() async {
        muted.toggle()
        await engine.setMuted(muted)
    }

    /// Enables/disables the local camera for the current call (Task 13
    /// part 2: the call tray's camera toggle routes through here).
    public func setVideoEnabled(_ enabled: Bool) async {
        await engine.setVideoEnabled(enabled)
    }

    /// The engine's local video track handle (the camera preview binding);
    /// nil for audio-only sessions and between calls.
    public func localVideoTrack() async -> (any VideoTrackHandle)? {
        await engine.localVideoTrack
    }

    /// The engine's remote video track handle (the full-screen surface
    /// binding); nil for audio-only sessions and between calls.
    public func remoteVideoTrack() async -> (any VideoTrackHandle)? {
        await engine.remoteVideoTrack
    }

    // MARK: - Machine application

    /// The funnel: every machine input goes through here. Applies the event,
    /// publishes the UI snapshot when the state moved, executes the effect
    /// vector, then handles the two things the machine cannot express — the
    /// engine session for a new call and the end-of-call teardown.
    func apply(_ event: LKCallEvent) async {
        let preState = machine.state
        let effects = machine.apply(event: event)
        let postState = machine.state
        if postState.callId != preState.callId, isLiveCall(postState) {
            setupStartMs = nowMs()
        }
        let snapshot = CallState(postState)
        if snapshot != currentState {
            currentState = snapshot
            callStateContinuation.yield(snapshot)
        }
        for effect in effects {
            await execute(effect, preState: preState, postState: postState, event: event)
        }
        if postState.callId != preState.callId, isLiveCall(postState) {
            await ensureEngineSession(callId: postState.callId, video: postState.video)
        }
        if postState.kind == .ended {
            await finishCall(postState)
        }
    }

    func isLiveCall(_ state: LKCallState) -> Bool {
        switch state.kind {
        case .idle, .ended: false
        default: true
        }
    }

    // MARK: - Effect execution

    func execute(_ effect: LKEffect, preState: LKCallState, postState: LKCallState, event: LKCallEvent) async {
        switch effect.kind {
        case .sendMessage:
            await sendMachineMessage(effect.messageType, preState: preState, event: event)
        case .startRinging:
            await reporting.startRinging()
        case .stopRinging:
            await reporting.stopRinging()
        case .startTimer:
            await timer.start(Self.timerKind(forTimeoutMs: effect.timeoutMs), timeoutMs: effect.timeoutMs)
        case .cancelTimer:
            await timer.cancel(Self.timerKind(forTimeoutMs: effect.timeoutMs))
        case .reportIncoming:
            await reporting.reportIncoming(callId: postState.callId, peer: postState.peer, video: postState.video)
        case .reportEnded:
            await reporting.reportEnded(callId: postState.callId, reason: CallEndReason(effect.reason))
        case .startIceRestart:
            await performIceRestart(for: postState.callId)
        @unknown default:
            break // a future core effect arrives with a core bump
        }
    }

    // MARK: - Timers

    /// The machine's timeout constants are not exported by CoreBridge; the
    /// mapping follows the core's k*TimeoutMs values (45/20/15 s, pinned by
    /// the plan tests). Unknown values keep the ring budget.
    static func timerKind(forTimeoutMs timeoutMs: Int) -> CallTimerKind {
        switch timeoutMs {
        case 20000: .connect
        case 15000: .reconnect
        default: .ring
        }
    }

    func handleTimerExpiry(_ kind: CallTimerKind) async {
        let eventKind: LKCallEventKind = switch kind {
        case .ring: .timerRingExpired
        case .connect: .timerConnectExpired
        case .reconnect: .timerReconnectExpired
        }
        await feedMachine(eventKind)
    }

    // MARK: - Engine session and stats

    /// One engine session per call. A session for a different call is
    /// recycled (hangup, then prepare for the new call's media) — this is
    /// what glare needs when the outgoing call is withdrawn and the peer's
    /// call survives. Failures leave the session unowned; the call then dies
    /// through its own timeout (the machine stays authoritative).
    func ensureEngineSession(callId: String, video: Bool) async {
        guard sessionCallId != callId else { return }
        if sessionCallId != nil {
            await engine.hangup()
            await stopStatsCollection()
        }
        do {
            try await engine.prepare(media: video ? .video : .audio)
            sessionCallId = callId
            startStatsCollection()
        } catch {
            sessionCallId = nil
        }
    }

    func startStatsCollection() {
        let puller = StatisticsPuller(stream: engine.statistics)
        let poller = StatsPoller(
            nextReport: { await puller.pull() },
            statsInterval: statsInterval,
            onSample: { [statsContinuation] in statsContinuation.yield($0) }
        )
        self.poller = poller
        Task { await poller.start() }
    }

    func stopStatsCollection() async {
        await poller?.stop()
        poller = nil
    }

    // MARK: - End of call

    /// The end sequence: the report goes out before the capture is released
    /// (plan Task 9), then the machine resets to a fresh Idle for the next
    /// call and the UI sees the reset.
    func finishCall(_ ended: LKCallState) async {
        let samples = await poller?.samples ?? []
        let report = CallReport.build(
            callId: ended.callId,
            setupMs: Int(nowMs() - setupStartMs),
            endReason: CallEndReason(ended.endReason).reportName,
            samples: samples
        )
        try? await uploader.post(callId: ended.callId, report: report.asJSON())
        await stopStatsCollection()
        // Release capture through the engine (the capture anti-goal).
        await engine.hangup()
        sessionCallId = nil
        isDataChannelOpen = false
        muted = false
        await timer.cancelAll()
        machine = LKCallStateMachine(state: .idle())
        publish(machine.state)
    }

    func publish(_ state: LKCallState) {
        let snapshot = CallState(state)
        currentState = snapshot
        callStateContinuation.yield(snapshot)
    }
}
