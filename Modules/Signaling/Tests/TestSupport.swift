// Shared fixtures for the Signaling test targets (Plan 4 Task 4 / LNK-30):
// a scripted WebSocket session fake, a gated clock that makes the heartbeat
// timers deterministic, a recording logger for the log-hygiene assertion, a
// session-factory recorder for the Authorization header assertion, and the
// public DER bytes of two throwaway self-signed test certificates with their
// precomputed SPKI pins.

import CoreBridge
import Foundation
@testable import Signaling
import Synchronization
import XCTest

// MARK: - Test certificates (public material only)

/// The two throwaway self-signed P-256 certificates used by the SPKI tests.
/// Only the public certificate DER is embedded here — the plan forbids key
/// material in the repository, and the private keys never left the machine
/// that generated them.
///
/// The pins were precomputed once with the openssl pipeline the plan
/// prescribes; test_spki_pin_matches_known_answer asserts that the Swift
/// implementation reproduces them:
///
///     openssl x509 -in cert.pem -pubkey -noout \
///       | openssl pkey -pubin -outform DER \
///       | openssl dgst -sha256 -binary | openssl enc -base64
enum TestCertificates {
    static let aPin = "NOFwaottIq6/ZIaAYKJd2bIZ/YcjL5v5wd9mwgAOJIs="
    static let bPin = "9jj/EuNfAyJtnCdhMpDWvcS39rnTuKeuyrux8ymCmh8="

    // swiftlint:disable line_length
    private static let aDerBase64 =
        "MIIBYTCCAQigAwIBAgIUXaCnke5Vt9lFZfV/bRI243AeVgAwCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMbGlua28tdGVzdC1hMB4XDTI2MTExNzAxMTAyMFoXDTI2MTIxNzAxMTAyMFowFzEVMBMGA1UEAwwMbGlua28tdGVzdC1hMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEWU0QBB7kZhsmZxyNlx0nvEi/fOqLR+nY32cu9v8EVF7Jno6MCsrB/XQDPv32HiN5SXhROnPgbJkXyLw5X4cO3KMyMDAwHQYDVR0OBBYEFARLcuKZ61KPB8ms9wr82PZ0HUGWMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgbcllFLH7AkOazEdPiGVhKbC5wsCTfWsSWVjubaRjU6gCIBTNWGYWWOssruYhjlRcvexiGzY7r4HwxQqOKcY1igR8"
    private static let bDerBase64 =
        "MIIBYjCCAQigAwIBAgIUH2RID2TdeUt8DRFqHvXqKrVXqdgwCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMbGlua28tdGVzdC1iMB4XDTI2MTExNzAxMTAyMFoXDTI2MTIxNzAxMTAyMFowFzEVMBMGA1UEAwwMbGlua28tdGVzdC1iMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEoNJt52DBJNhoSj9b+Vc+VHGHy8jHp/p1mYUNVA0gnULc7PGmvTWoFT1tm8zAG1EmPiR8LdPko7/J9LfJMK0nYqMyMDAwHQYDVR0OBBYEFJs6qwxnizBRCa4kU3/MH12D6xEGMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgdkx+gPvHCteV2Scrn61Cp+3Bq9xij2R3pMlazrnCKFgCIQCkT+ZcDJs0OCVTt8E9S1PZIIpVMRbCQYcan72XDt3N7w=="
    // swiftlint:enable line_length

    static func aDER() throws -> Data {
        try decoded(aDerBase64)
    }

    static func bDER() throws -> Data {
        try decoded(bDerBase64)
    }

    private static func decoded(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw TestFixtureError(message: "embedded certificate DER base64 does not decode")
        }
        return data
    }
}

struct TestFixtureError: Error {
    let message: String
}

// MARK: - Fake WebSocket session

/// Scripted WebSocketSession fake: records everything the client sends,
/// delivers the frames the test enqueues, optionally answers pings with
/// pongs, and counts close calls.
final class FakeWebSocketSession: WebSocketSession, @unchecked Sendable {
    private struct State {
        var sent: [String] = []
        var queued: [WebSocketInbound] = []
        var receiveContinuation: CheckedContinuation<WebSocketInbound, Error>?
        var closeCount = 0
    }

    private let state = Mutex(State())
    private let autoPong: Bool

    init(autoPong: Bool) {
        self.autoPong = autoPong
    }

    func sendText(_ text: String) async throws {
        let shouldPong = state.withLock { locked -> Bool in
            locked.sent.append(text)
            return autoPong && text.contains("session.ping")
        }
        if shouldPong {
            enqueue(.text(Self.pongWire))
        }
    }

    func receive() async throws -> WebSocketInbound {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    if !state.queued.isEmpty {
                        let frame = state.queued.removeFirst()
                        continuation.resume(returning: frame)
                    } else {
                        state.receiveContinuation = continuation
                    }
                }
            }
        } onCancel: {
            state.withLock { state in
                if let pending = state.receiveContinuation {
                    state.receiveContinuation = nil
                    pending.resume(throwing: CancellationError())
                }
            }
        }
    }

    func close() async {
        state.withLock { $0.closeCount += 1 }
    }

    // MARK: Test surface

    var sentFrames: [String] {
        state.withLock { $0.sent }
    }

    var closeCallCount: Int {
        state.withLock { $0.closeCount }
    }

    func enqueue(_ inbound: WebSocketInbound) {
        state.withLock { state in
            if let pending = state.receiveContinuation {
                state.receiveContinuation = nil
                pending.resume(returning: inbound)
            } else {
                state.queued.append(inbound)
            }
        }
    }

    /// A wire-format session.pong envelope the fake answers with.
    static let pongWire =
        #"{"v":1,"type":"session.pong","id":"srv-pong","ts":1792877416123,"body":{}}"#
}

// MARK: - Gated clock

/// Clock fake that parks every timer until the test releases it: `elapse`
/// makes a sleep return "fully elapsed" (pong timeout fires, reconnect
/// proceeds), `wake` from the production code makes it return "completed
/// early" (the pong arrived in the window). All sleeps are explicit, so the
/// heartbeat tests are fully deterministic.
final class GatedClock: SignalingClock, @unchecked Sendable {
    private struct State {
        var pending: [ClockSleepKind: CheckedContinuation<Bool, Never>] = [:]
    }

    private let state = Mutex(State())

    func sleep(_ kind: ClockSleepKind, for _: Duration) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock { state in
                    state.pending[kind] = continuation
                }
            }
        } onCancel: {
            state.withLock { state in
                if let parked = state.pending.removeValue(forKey: kind) {
                    parked.resume(returning: false)
                }
            }
        }
    }

    func wake(_ kind: ClockSleepKind) async {
        state.withLock { state in
            if let parked = state.pending.removeValue(forKey: kind) {
                parked.resume(returning: false)
            }
        }
    }

    // MARK: Test surface

    /// Makes a pending sleep return "fully elapsed" (the timeout fired).
    func elapse(_ kind: ClockSleepKind) async {
        state.withLock { state in
            if let parked = state.pending.removeValue(forKey: kind) {
                parked.resume(returning: true)
            }
        }
    }

    func isPending(_ kind: ClockSleepKind) async -> Bool {
        state.withLock { $0.pending[kind] != nil }
    }
}

// MARK: - Recording logger

/// Log seam fake that records every message so tests can assert secret
/// hygiene (Review Focus 5: the token never appears in logs).
final class RecordingLogger: SignalingLogging, @unchecked Sendable {
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

// MARK: - Session factory recorder

/// Builds FakeWebSocketSessions and records every URLRequest the client
/// hands in, so tests can assert the Authorization header (Review Focus 5).
final class FakeSessionFactory: @unchecked Sendable {
    private struct State {
        var requests: [URLRequest] = []
        var sessions: [FakeWebSocketSession] = []
    }

    private let state = Mutex(State())
    private let autoPong: Bool

    init(autoPong: Bool) {
        self.autoPong = autoPong
    }

    func make(request: URLRequest) -> FakeWebSocketSession {
        let session = FakeWebSocketSession(autoPong: autoPong)
        state.withLock { state in
            state.requests.append(request)
            state.sessions.append(session)
        }
        return session
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    var sessions: [FakeWebSocketSession] {
        state.withLock { $0.sessions }
    }
}

// MARK: - Event recorder

/// Collects the events the client emits; tests assert on the recorded list.
final class EventRecorder: @unchecked Sendable {
    private let events = Mutex<[SignalingEvent]>([])

    func append(_ event: SignalingEvent) {
        events.withLock { $0.append(event) }
    }

    var recorded: [SignalingEvent] {
        events.withLock { $0 }
    }

    var isConnected: Bool {
        recorded.contains { event in
            if case .connected = event {
                return true
            }
            return false
        }
    }

    func hasError(where matches: (SignalingError) -> Bool) -> Bool {
        recorded.contains { event in
            if case let .error(error) = event {
                return matches(error)
            }
            return false
        }
    }

    func hasDisconnect(withCode code: Int) -> Bool {
        recorded.contains { event in
            if case let .disconnected(eventCode) = event {
                return eventCode == code
            }
            return false
        }
    }

    var hasDisconnect: Bool {
        recorded.contains { event in
            if case .disconnected = event {
                return true
            }
            return false
        }
    }
}

// MARK: - Client and envelope builders

/// Builds a SignalingClient wired to the test fakes (internal initializer).
func makeSignalingClient(
    url: URL,
    factory: FakeSessionFactory,
    clock: GatedClock,
    token: String,
    logging: SignalingLogging,
    user: String = "eugene",
    deviceId: String = "dev-1"
) -> SignalingClient {
    SignalingClient(
        url: url,
        expectedPin: TestCertificates.aPin,
        user: user,
        deviceId: deviceId,
        tokenProvider: { token },
        sessionFactory: { factory.make(request: $0) },
        clock: clock,
        random: { 1.0 },
        logging: logging
    )
}

/// A valid protocol v1 wire envelope for scripted inbound frames.
func makeWire(type: String, version: Int = 1, body: String = "{}", id: String = "srv-1") -> String {
    "{\"v\":\(version),\"type\":\"\(type)\",\"id\":\"\(id)\",\"ts\":1792877416123,\"body\":\(body)}"
}

/// An outgoing envelope built through the CoreBridge surface.
func makeEnvelope(type: String, body: String = "{}") -> LKEnvelope {
    LKEnvelope(v: 1, type: type, id: "client-1", ts: 1_792_877_416_123, bodyJSON: body)
}

extension XCTestCase {
    /// The signaling URL used by every client-level test.
    func signalingURL() throws -> URL {
        try XCTUnwrap(URL(string: "wss://linko.example/ws"), "the test URL literal must parse")
    }

    /// Polls a predicate until it holds or the timeout expires — the bounded
    /// wait that keeps cross-actor settling out of the assertions.
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
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
