// TestSupport (Plan 4 Task 9 / LNK-35): the fixture builder that wires a
// fresh coordinator to one set of fakes, the state collector that mirrors
// the UI-facing stream, the envelope helpers for simulating the wire, and
// the bounded-wait helper that keeps cross-actor settling out of assertions.

import CallEngine
@testable import Calls
import CallStats
import CoreBridge
import Foundation
import Signaling
import XCTest

// MARK: - Fixture

/// Collects everything the coordinator publishes on its UI-facing state
/// stream, in order.
final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [CallState] = []

    func append(_ state: CallState) {
        lock.withLock {
            states.append(state)
        }
    }

    var recorded: [CallState] {
        lock.withLock { states }
    }

    func lastState(where predicate: (CallState) -> Bool) -> CallState? {
        recorded.last(where: predicate)
    }
}

struct CoordinatorFixture: @unchecked Sendable {
    let coordinator: CallCoordinator
    let signaling: FakeCallSignaling
    let signalingEventsContinuation: AsyncStream<SignalingEvent>.Continuation
    let engine: FakeCallEngine
    let reporting: FakeCallReporting
    let source: FakeIncomingCallSource
    let network: FakeCallNetworkMonitor
    let uploader: FakeCallReportUploader
    let clock: GateCallClock
    let states: StateCollector
    private var stateTask: Task<Void, Never>?

    init(
        coordinator: CallCoordinator,
        signaling: FakeCallSignaling,
        signalingEventsContinuation: AsyncStream<SignalingEvent>.Continuation,
        engine: FakeCallEngine,
        reporting: FakeCallReporting,
        source: FakeIncomingCallSource,
        network: FakeCallNetworkMonitor,
        uploader: FakeCallReportUploader,
        clock: GateCallClock,
        states: StateCollector,
        stateTask: Task<Void, Never>?
    ) {
        self.coordinator = coordinator
        self.signaling = signaling
        self.signalingEventsContinuation = signalingEventsContinuation
        self.engine = engine
        self.reporting = reporting
        self.source = source
        self.network = network
        self.uploader = uploader
        self.clock = clock
        self.states = states
        self.stateTask = stateTask
    }

    /// Yields one event onto the coordinator's signaling event stream.
    func simulateEnvelope(_ envelope: LKEnvelope) {
        signalingEventsContinuation.yield(.envelope(envelope))
    }

    /// Waits until the state stream carried a state matching `predicate` and
    /// returns the last such state (nil on timeout).
    func nextState(
        where predicate: @escaping @Sendable (CallState) -> Bool,
        description: String
    ) async throws -> CallState? {
        try await waitUntil("the state stream carries \(description)") {
            states.recorded.contains { predicate($0) }
        }
        return states.lastState(where: predicate)
    }

    /// Drives an outgoing call to OutgoingRinging and waits for the invite
    /// to hit the wire.
    func startOutgoingCall(peer: String = "anna", media: CallMedia = .audio) async throws {
        await coordinator.invite(peer: peer, media: media)
        try await waitUntil("the call.invite envelope is sent") {
            signaling.sentTypes.contains(LKTypes.callInvite)
        }
    }

    /// Drives an incoming call to Connecting (reported, accepted).
    func makeConnectingCall(callId: String = "c1", peer: String = "bob", video: Bool = false) async throws {
        source.yield(IncomingCall(callId: callId, peer: peer, video: video))
        try await waitUntil("the incoming call is reported") {
            !reporting.incoming.isEmpty
        }
        await coordinator.accept()
        try await waitUntil("the call.accept envelope is sent") {
            signaling.sentTypes.contains(LKTypes.callAccept)
        }
    }

    /// Drives an incoming call to Active (reported, accepted, ICE connected).
    func makeActiveCall(callId: String = "c1", peer: String = "bob", video: Bool = false) async throws {
        try await makeConnectingCall(callId: callId, peer: peer, video: video)
        engine.fireConnectionState(.connected)
        try await waitUntil("the call turns active") {
            await coordinator.currentState.kind == .active
        }
    }
}

/// Builds a fresh fixture; the coordinator's call ids are pinned to "zz11"
/// so glare and end-reason assertions stay deterministic. The consuming task
/// for the state stream is torn down with the test.
@MainActor
func makeFixture(test: XCTestCase) async -> CoordinatorFixture {
    let (events, eventsContinuation) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .unbounded)
    let signaling = FakeCallSignaling()
    let engine = FakeCallEngine()
    let reporting = FakeCallReporting()
    let source = FakeIncomingCallSource()
    let network = FakeCallNetworkMonitor()
    let uploader = FakeCallReportUploader()
    let clock = GateCallClock()
    let coordinator = CallCoordinator(
        signaling: signaling,
        signalingEvents: events,
        engine: engine,
        reporting: reporting,
        source: source,
        network: network,
        uploader: uploader,
        clock: clock,
        statsInterval: .zero,
        makeCallId: { "zz11" }
    )
    coordinator.start()
    let collector = StateCollector()
    let stateTask = Task {
        for await state in coordinator.callState {
            collector.append(state)
        }
    }
    test.addTeardownBlock { [coordinator] in
        await coordinator.stop()
        stateTask.cancel()
    }
    return CoordinatorFixture(
        coordinator: coordinator,
        signaling: signaling,
        signalingEventsContinuation: eventsContinuation,
        engine: engine,
        reporting: reporting,
        source: source,
        network: network,
        uploader: uploader,
        clock: clock,
        states: collector,
        stateTask: stateTask
    )
}

// MARK: - Wire helpers

/// Builds a call.* envelope with an LKCallEnd body (reject/cancel/hangup/busy).
func callEndEnvelope(type: String, callId: String, reason: String? = nil) -> LKEnvelope {
    LKEnvelope(
        v: 1,
        type: type,
        id: "env-\(type)-\(callId)",
        ts: 1000,
        bodyJSON: LKCallEnd(callId: callId, reason: reason).bodyJSON
    )
}

/// Builds a call.* envelope with an LKCallRef body (ringing/accept/ice-restart).
func callRefEnvelope(type: String, callId: String) -> LKEnvelope {
    LKEnvelope(
        v: 1,
        type: type,
        id: "env-\(type)-\(callId)",
        ts: 1000,
        bodyJSON: LKCallRef(callId: callId).bodyJSON
    )
}

// MARK: - Async helpers

/// Polls a predicate until it holds or the timeout expires (bounded; no
/// sleeps in the happy path — the streams buffer, the loop drains within
/// ticks).
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
    _ predicate: @escaping @Sendable () async -> Bool
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
