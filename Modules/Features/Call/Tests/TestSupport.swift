// TestSupport (Plan 4 Task 13 part 1, LNK-39): the fixture that wires a
// fresh coordinator + view model to one set of fakes, the state collector
// that mirrors the UI-facing call stream, the raw-stats fixtures shaped
// like the CallStats tests' StatsFixtures, and the bounded-wait helper.

@testable import Call
import CallEngine
import Calls
import CallStats
import CoreBridge
import Foundation
import ServerAPI
import Settings
import Signaling
import XCTest

// MARK: - Defaults

/// In-memory DefaultsWriting (the Settings test target's shape): seed with
/// `setData`, read back with `data(forKey:)`.
final class DefaultsFake: DefaultsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func setData(_ data: Data, forKey key: String) {
        lock.withLock {
            storage[key] = data
        }
    }

    func data(forKey key: String) -> Data? {
        lock.withLock {
            storage[key]
        }
    }

    func removeObject(forKey key: String) {
        lock.withLock {
            _ = storage.removeValue(forKey: key)
        }
    }
}

// MARK: - Signaling

/// Records everything the coordinator sends; nothing leaves the test.
final class FakeCallSignaling: CallSignalingSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LKEnvelope] = []

    func send(_ envelope: LKEnvelope) async throws {
        lock.withLock {
            sent.append(envelope)
        }
    }

    var sentTypes: [String] {
        lock.withLock { sent.map(\.type) }
    }
}

// MARK: - Engine

/// A CallMediaEngine fake: records the control calls the coordinator makes
/// and hands the test continuations to fire what the live WebRTC adapters
/// would stream (connection states, raw statistics).
final class FakeCallEngine: CallMediaEngine, @unchecked Sendable {
    let iceCandidates: AsyncStream<IceCandidate>
    let connectionStates: AsyncStream<IceConnectionState>
    let connectionStatesContinuation: AsyncStream<IceConnectionState>.Continuation
    let dataChannelMessages: AsyncStream<Data>
    let dataChannelStates: AsyncStream<Bool>
    let statistics: AsyncStream<RawStatsReport>
    let statisticsContinuation: AsyncStream<RawStatsReport>.Continuation

    private let lock = NSLock()
    private var _prepared: [CallMedia] = []
    private var _mutes: [Bool] = []
    private var _videoEnables: [Bool] = []

    init() {
        (iceCandidates, _) = AsyncStream.makeStream(of: IceCandidate.self, bufferingPolicy: .unbounded)
        (connectionStates, connectionStatesContinuation) =
            AsyncStream.makeStream(of: IceConnectionState.self, bufferingPolicy: .unbounded)
        (dataChannelMessages, _) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        (dataChannelStates, _) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .unbounded)
        (statistics, statisticsContinuation) = AsyncStream.makeStream(of: RawStatsReport.self, bufferingPolicy: .unbounded)
    }

    func prepare(media: CallMedia) async throws {
        lock.withLock { _prepared.append(media) }
    }

    func startCall() async throws -> String {
        "offer-sdp"
    }

    func accept() async throws -> String {
        "answer-sdp"
    }

    func restartIce() async throws -> String {
        "restart-offer-sdp"
    }

    func setRemoteSDP(_ sdp: String, isAnswer: Bool) async throws {
        _ = sdp
        _ = isAnswer
    }

    func addIceCandidate(candidate: String, sdpMid: String?, lineIndex: Int32) async {
        _ = candidate
        _ = sdpMid
        _ = lineIndex
    }

    func hangup() async {}

    func sendOverDataChannel(_ data: Data) async throws {
        _ = data
    }

    func applyBitratePlan(_ plan: BitratePlan) async {
        _ = plan
    }

    func setMuted(_ muted: Bool) async {
        lock.withLock { _mutes.append(muted) }
    }

    func setVideoEnabled(_ enabled: Bool) async {
        lock.withLock { _videoEnables.append(enabled) }
    }

    var localVideoTrack: (any VideoTrackHandle)? {
        get async { nil }
    }

    var remoteVideoTrack: (any VideoTrackHandle)? {
        get async { nil }
    }

    // MARK: Test surface

    var prepared: [CallMedia] {
        lock.withLock { _prepared }
    }

    var mutes: [Bool] {
        lock.withLock { _mutes }
    }

    var videoEnables: [Bool] {
        lock.withLock { _videoEnables }
    }

    func fireConnectionState(_ state: IceConnectionState) {
        connectionStatesContinuation.yield(state)
    }

    func fireStatistics(_ report: RawStatsReport) {
        statisticsContinuation.yield(report)
    }
}

// MARK: - Reporting, incoming calls, network, uploads

final class FakeCallReporting: CallReporting, @unchecked Sendable {
    struct Incoming: Equatable, Sendable {
        let callId: String
        let peer: String
        let video: Bool
    }

    struct Ended: Equatable, Sendable {
        let callId: String
        let reason: CallEndReason
    }

    private let lock = NSLock()
    private var _incoming: [Incoming] = []
    private var _ended: [Ended] = []

    func startRinging() async {}

    func stopRinging() async {}

    func reportIncoming(callId: String, peer: String, video: Bool) async {
        lock.withLock { _incoming.append(Incoming(callId: callId, peer: peer, video: video)) }
    }

    func reportEnded(callId: String, reason: CallEndReason) async {
        lock.withLock { _ended.append(Ended(callId: callId, reason: reason)) }
    }

    var incoming: [Incoming] {
        lock.withLock { _incoming }
    }

    var ended: [Ended] {
        lock.withLock { _ended }
    }
}

final class FakeIncomingCallSource: IncomingCallSource, @unchecked Sendable {
    let calls: AsyncStream<IncomingCall>
    private let continuation: AsyncStream<IncomingCall>.Continuation

    init() {
        (calls, continuation) = AsyncStream.makeStream(of: IncomingCall.self, bufferingPolicy: .unbounded)
    }

    func yield(_ call: IncomingCall) {
        continuation.yield(call)
    }
}

final class FakeCallNetworkMonitor: CallNetworkMonitoring, @unchecked Sendable {
    let states: AsyncStream<NetworkState>

    init() {
        (states, _) = AsyncStream.makeStream(of: NetworkState.self, bufferingPolicy: .unbounded)
    }
}

final class FakeCallReportUploader: CallReportUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [String] = []

    func post(callId: String, report _: String) async throws {
        lock.withLock { _posts.append(callId) }
    }

    var posts: [String] {
        lock.withLock { _posts }
    }
}

// MARK: - Fixture

/// MainActor-isolated: the fixture is touched entirely from the MainActor
/// test methods, and its helper predicates read the coordinator's state
/// directly. The call state stream is single-consumer — the view model is
/// its only reader (a Calls-style StateCollector would steal snapshots from
/// it), so end-of-call evidence comes from the reporting fake instead.
@MainActor
struct CallContext {
    let coordinator: CallCoordinator
    let viewModel: CallViewModel
    let signaling: FakeCallSignaling
    let engine: FakeCallEngine
    let reporting: FakeCallReporting
    let source: FakeIncomingCallSource
    let defaults: DefaultsFake

    /// Yields one incoming call and waits until the coordinator reported it
    /// (the machine sits in incomingRinging).
    func makeIncomingRinging(callId: String = "c1", peer: String = "bob", video: Bool = false) async throws {
        source.yield(IncomingCall(callId: callId, peer: peer, video: video))
        try await waitUntil("the incoming call is reported") {
            !reporting.incoming.isEmpty
        }
    }

    /// Accepts through the coordinator and fires the ICE connected state so
    /// the machine reaches Active.
    func connectActive() async throws {
        await coordinator.accept()
        try await waitUntil("the call.accept envelope is sent") {
            signaling.sentTypes.contains(LKTypes.callAccept)
        }
        engine.fireConnectionState(.connected)
        try await waitUntil("the call turns active") {
            coordinator.currentState.kind == .active
        }
    }
}

/// Builds a fresh fixture; the coordinator's call ids are pinned to "zz11"
/// and the stats cadence to .zero so the derivation keeps up with the test.
@MainActor
func makeContext(test: XCTestCase) -> CallContext {
    // The signaling-event continuation is discarded: the fixture drives
    // calls through the IncomingCallSource and the coordinator actions, so
    // the (immediately finished) event stream just ends the wire loop.
    let (events, _) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .unbounded)
    let signaling = FakeCallSignaling()
    let engine = FakeCallEngine()
    let reporting = FakeCallReporting()
    let source = FakeIncomingCallSource()
    let network = FakeCallNetworkMonitor()
    let uploader = FakeCallReportUploader()
    let defaults = DefaultsFake()
    let coordinator = CallCoordinator(
        signaling: signaling,
        signalingEvents: events,
        engine: engine,
        reporting: reporting,
        source: source,
        network: network,
        uploader: uploader,
        clock: SystemCallClock(),
        statsInterval: .zero,
        makeCallId: { "zz11" }
    )
    coordinator.start()
    let viewModel = CallViewModel(coordinator: coordinator, defaults: defaults)
    test.addTeardownBlock { [coordinator, viewModel] in
        await coordinator.stop()
        await MainActor.run { viewModel.stop() }
    }
    return CallContext(
        coordinator: coordinator,
        viewModel: viewModel,
        signaling: signaling,
        engine: engine,
        reporting: reporting,
        source: source,
        defaults: defaults
    )
}

// MARK: - Raw stats fixtures

/// The shapes mirror CallStats' StatsFixtures: one nominated succeeded pair
/// over a relay, one outbound video stream (VP8, 1280x720 @ 30 fps) and one
/// inbound audio stream. `timestampMs` and `bytesSent` are parameters so the
/// bitrate delta is the test's to control.
func flowingReport(timestampMs: Double, bytesSent: Int) -> RawStatsReport {
    func entry(
        id: String,
        type: String,
        values pairs: (String, RawStatValue)...
    ) -> RawStatsReport.Entry {
        var dict: [String: RawStatValue] = [:]
        for (key, value) in pairs {
            dict[key] = value
        }
        return RawStatsReport.Entry(id: id, type: type, timestampMs: timestampMs, values: dict)
    }
    return RawStatsReport(entries: [
        "pair-b": entry(
            id: "pair-b",
            type: "candidate-pair",
            values: ("state", .string("succeeded")), ("nominated", .boolean(true)),
            ("currentRoundTripTime", .number(0.045)), ("localCandidateId", .string("cand-relay"))
        ),
        "cand-relay": entry(id: "cand-relay", type: "local-candidate", values: ("candidateType", .string("relay"))),
        "ovideo": entry(
            id: "ovideo",
            type: "outbound-rtp",
            values: ("kind", .string("video")), ("bytesSent", .number(Double(bytesSent))),
            ("framesPerSecond", .number(30)), ("frameWidth", .number(1280)),
            ("frameHeight", .number(720)), ("codecId", .string("codec-vp8"))
        ),
        "codec-vp8": entry(id: "codec-vp8", type: "codec", values: ("mimeType", .string("video/VP8"))),
        "iaudio": entry(
            id: "iaudio",
            type: "inbound-rtp",
            values: ("kind", .string("audio")), ("packetsLost", .number(1)),
            ("packetsReceived", .number(100)), ("jitter", .number(0.02))
        )
    ])
}

// MARK: - Async helpers

/// Polls a predicate until it holds or the timeout expires (bounded; the
/// streams buffer, the loop drains within ticks). MainActor-isolated so the
/// predicates read view model and coordinator state directly (the Settings
/// test target's waitFor shape).
@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
    _ predicate: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await !predicate() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(description)")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
