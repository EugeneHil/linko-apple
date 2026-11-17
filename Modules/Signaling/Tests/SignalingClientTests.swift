// TDD tests (Plan 4 Task 4 / LNK-30, Step 1) for the SignalingClient actor:
// hello on connect, heartbeat ping/pong with an injected clock, pong timeout
// treated as a disconnect with backoff reconnect, hostile server frames
// surfaced as errors (Review Focus 2), and secret hygiene — the bearer token
// reaches the request headers but never the logs (Review Focus 5).

import CoreBridge
@testable import Signaling
import XCTest

/// The seams startConnectedClient hands back to each test.
private struct StartedClient {
    let client: SignalingClient
    let factory: FakeSessionFactory
    let clock: GatedClock
    let recorder: EventRecorder
    let collector: Task<Void, Never>
}

final class SignalingClientTests: XCTestCase {
    // MARK: - Plan test name: test_hello_sent_after_connect

    func test_hello_sent_after_connect() async throws {
        let started = try await startConnectedClient(autoPong: false)
        let (factory, recorder, collector) = (started.factory, started.recorder, started.collector)
        defer { collector.cancel() }

        let session = try XCTUnwrap(factory.sessions.first, "the client must create exactly one session to connect")
        let helloWire = try XCTUnwrap(session.sentFrames.first, "session.hello must be the first frame sent after connect")

        let parsed = LKEnvelope.parse(jsonString: helloWire)
        let envelope = try XCTUnwrap(parsed.envelope, "the hello frame must be a valid protocol v1 envelope")
        XCTAssertEqual(envelope.type, LKTypes.sessionHello)

        let hello = try LKSessionHello.from(bodyJSON: envelope.bodyJSON)
        XCTAssertEqual(hello.user, "eugene")
        XCTAssertEqual(hello.device, "dev-1")

        try await waitUntil("the connected event") { recorder.isConnected }
        XCTAssertFalse(recorder.hasDisconnect, "a fresh connection must not report a disconnect")
    }

    // MARK: - Plan test name: test_ping_sent_periodically

    func test_ping_sent_periodically() async throws {
        let started = try await startConnectedClient(autoPong: true)
        let (factory, clock, recorder, collector) = (started.factory, started.clock, started.recorder, started.collector)
        defer { collector.cancel() }

        try await advanceHeartbeatCycle(factory: factory, clock: clock, cycle: 1)
        try await advanceHeartbeatCycle(factory: factory, clock: clock, cycle: 2)

        let session = try XCTUnwrap(factory.sessions.first, "pings answered with pongs keep one session alive")
        XCTAssertEqual(session.closeCallCount, 0, "the client must not close a healthy connection")
        XCTAssertFalse(recorder.hasDisconnect, "pings answered with pongs must keep the connection alive")
        collector.cancel()
    }

    // MARK: - Plan test name: test_pong_timeout_treated_as_disconnect

    func test_pong_timeout_treated_as_disconnect() async throws {
        let started = try await startConnectedClient(autoPong: false)
        let (factory, clock, recorder, collector) = (started.factory, started.clock, started.recorder, started.collector)
        defer { collector.cancel() }

        // One heartbeat cycle with no pong in the window.
        try await waitUntil("the heartbeat interval was armed") { await clock.isPending(.heartbeatInterval) }
        await clock.elapse(.heartbeatInterval)
        try await waitUntil("the first ping was sent") {
            pingCount(in: factory.sessions.last?.sentFrames ?? []) == 1
        }
        try await waitUntil("the pong window opened") { await clock.isPending(.pongTimeout) }
        await clock.elapse(.pongTimeout)

        // The pong timeout is treated as a disconnect (abnormal close code).
        try await waitUntil("the disconnected event with code 1006") { recorder.hasDisconnect(withCode: 1006) }
        let session = try XCTUnwrap(factory.sessions.first, "the dead connection must be the first session")
        XCTAssertEqual(session.closeCallCount, 1, "the client must close the socket it declared dead")

        // And the client reconnects after the gated backoff.
        try await waitUntil("the reconnect backoff was armed") { await clock.isPending(.reconnectBackoff) }
        await clock.elapse(.reconnectBackoff)
        try await waitUntil("a second session was created") { factory.sessions.count == 2 }
        try await waitUntil("hello was sent on the reconnect") { !(factory.sessions.last?.sentFrames.isEmpty ?? true) }
        try await waitUntil("the client reconnected") { recorder.isConnected && recorder.recorded.count >= 3 }
    }

    // MARK: - Plan test name: test_malformed_envelope_surfaces_error

    func test_malformed_envelope_surfaces_error() async throws {
        let started = try await startConnectedClient(autoPong: false)
        let (factory, recorder, collector) = (started.factory, started.recorder, started.collector)
        defer { collector.cancel() }

        let session = try XCTUnwrap(factory.sessions.first)
        session.enqueue(.text("this is not json"))

        try await waitUntil("the malformed envelope error") {
            recorder.hasError { error in
                if case let .malformedEnvelope(issues) = error {
                    return !issues.isEmpty
                }
                return false
            }
        }
        XCTAssertFalse(recorder.hasDisconnect, "a malformed frame must not close the socket from our side")
        XCTAssertEqual(session.closeCallCount, 0, "the socket stays until the server closes it")

        session.enqueue(.closed(code: 1009))
        try await waitUntil("the server-initiated disconnect") { recorder.hasDisconnect(withCode: 1009) }
    }

    // MARK: - Plan test name: test_oversized_frame_surfaces_error

    func test_oversized_frame_surfaces_error() async throws {
        let started = try await startConnectedClient(autoPong: false)
        let (factory, recorder, collector) = (started.factory, started.recorder, started.collector)
        defer { collector.cancel() }

        let session = try XCTUnwrap(factory.sessions.first)
        let oversized = String(repeating: "a", count: Int(LKTypes.maxEnvelopeBytes) + 1)
        session.enqueue(.text(oversized))

        try await waitUntil("the oversized frame error") {
            recorder.hasError { error in
                if case let .oversizedFrame(bytes) = error {
                    return bytes == Int(LKTypes.maxEnvelopeBytes) + 1
                }
                return false
            }
        }
        XCTAssertFalse(recorder.hasDisconnect, "an oversized frame must not close the socket from our side")
        XCTAssertEqual(session.closeCallCount, 0, "the socket stays until the server closes it")

        session.enqueue(.closed(code: 1009))
        try await waitUntil("the server-initiated disconnect") { recorder.hasDisconnect(withCode: 1009) }
    }

    // MARK: - Plan test name: test_unsupported_version_surfaces_error

    func test_unsupported_version_surfaces_error() async throws {
        let started = try await startConnectedClient(autoPong: false)
        let (factory, recorder, collector) = (started.factory, started.recorder, started.collector)
        defer { collector.cancel() }

        let session = try XCTUnwrap(factory.sessions.first)
        session.enqueue(.text(makeWire(type: "session.ping", version: 2)))

        try await waitUntil("the unsupported version error") {
            recorder.hasError { error in
                if case .unsupportedVersion = error {
                    return true
                }
                return false
            }
        }
        XCTAssertFalse(recorder.hasDisconnect, "an unsupported version must not close the socket from our side")
        XCTAssertEqual(session.closeCallCount, 0, "the socket stays until the server closes it")

        session.enqueue(.closed(code: 1000))
        try await waitUntil("the server-initiated disconnect") { recorder.hasDisconnect(withCode: 1000) }
    }

    // MARK: - Plan test name: test_send_uses_bearer_token

    func test_send_uses_bearer_token() async throws {
        let token = "linko-device-token-abc"
        let logger = RecordingLogger()
        let started = try await startConnectedClient(autoPong: false, token: token, logging: logger)
        let (client, factory, collector) = (started.client, started.factory, started.collector)
        defer { collector.cancel() }

        try await client.send(makeEnvelope(type: LKTypes.sessionPing))
        try await waitUntil("the envelope reached the socket") { (factory.sessions.first?.sentFrames.count ?? 0) == 2 }

        let request = try XCTUnwrap(factory.requests.first, "the client must hand the session factory the request")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.url, try signalingURL())

        XCTAssertFalse(logger.recorded.isEmpty, "the client must have logged its lifecycle")
        for message in logger.recorded {
            XCTAssertFalse(message.contains(token), "the Authorization header value must never appear in logs")
        }
    }

    func test_send_without_connection_throws_not_connected() async throws {
        let client = try SignalingClient(
            url: signalingURL(),
            expectedPin: TestCertificates.aPin,
            user: "eugene",
            deviceId: "dev-1",
            tokenProvider: { "some-token" }
        )
        do {
            try await client.send(makeEnvelope(type: LKTypes.sessionPing))
            XCTFail("sending without a live connection must throw")
        } catch let error as SignalingError {
            if case .notConnected = error {
                return
            }
            XCTFail("expected .notConnected, got \(error)")
        }
    }

    // MARK: - Start-up helper

    /// Starts a client against the fakes and waits for its .connected event;
    /// returns every seam the assertions need. The caller cancels the
    /// collector to stop the client.
    private func startConnectedClient(
        autoPong: Bool,
        token: String = "linko-test-device-token",
        logging: SignalingLogging = RecordingLogger()
    ) async throws -> StartedClient {
        let factory = FakeSessionFactory(autoPong: autoPong)
        let clock = GatedClock()
        let recorder = EventRecorder()
        let client = try makeSignalingClient(
            url: signalingURL(),
            factory: factory,
            clock: clock,
            token: token,
            logging: logging
        )
        let collector = Task {
            for await event in await client.events {
                recorder.append(event)
            }
        }
        try await waitUntil("hello was sent after connect") { !(factory.sessions.first?.sentFrames.isEmpty ?? true) }
        try await waitUntil("the connected event") { recorder.isConnected }
        return StartedClient(
            client: client,
            factory: factory,
            clock: clock,
            recorder: recorder,
            collector: collector
        )
    }

    /// Releases one heartbeat interval gate and waits for the resulting ping
    /// (the auto-pong fake then hands the connection back to the interval).
    private func advanceHeartbeatCycle(factory: FakeSessionFactory, clock: GatedClock, cycle: Int) async throws {
        try await waitUntil("the heartbeat interval was armed") { await clock.isPending(.heartbeatInterval) }
        await clock.elapse(.heartbeatInterval)
        try await waitUntil("ping #\(cycle) was sent") {
            pingCount(in: factory.sessions.last?.sentFrames ?? []) == cycle
        }
    }
}

/// Counted outside the class so the @Sendable waitUntil predicates never
/// capture self.
private func pingCount(in frames: [String]) -> Int {
    frames.filter { $0.contains("session.ping") }.count
}
