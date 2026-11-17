// SignalingClient (Plan 4 Task 4): the WSS signaling connection of the apps —
// protocol v1 envelopes over a pinned WebSocket, session.hello on connect, a
// 60 s heartbeat whose pong window is shorter than the server's 300 s idle
// timeout, and jittered exponential reconnects until the consumer stops
// listening. Callback-based URLSession APIs are wrapped once here behind the
// WebSocketSession seam (spec 4.3); everything above sends envelopes and
// consumes SignalingEvents. Logging never carries tokens, SDP or ICE
// credentials — only lifecycle words, codes and byte counts.

import CoreBridge
import Foundation
import os
import Synchronization

// MARK: - Transport seam

/// One inbound WebSocket frame or close.
public enum WebSocketInbound: Sendable, Equatable {
    case text(String)
    case closed(code: Int)
}

/// The raw socket under the client. A protocol seam so tests inject a
/// scripted fake; production wraps URLSessionWebSocketTask once.
public protocol WebSocketSession: Sendable {
    func sendText(_ text: String) async throws
    func receive() async throws -> WebSocketInbound
    func close() async
}

// MARK: - Clock seam

/// What the heartbeat and reconnect timers sleep on.
public enum ClockSleepKind: Hashable, Sendable {
    case heartbeatInterval
    case pongTimeout
    case reconnectBackoff
}

/// Injectable clock: `sleep` returns true when the full duration elapsed,
/// false when the client is stopping (or a wake fired). Production uses
/// SystemClock; the tests park every timer behind a gate.
public protocol SignalingClock: Sendable {
    func sleep(_ kind: ClockSleepKind, for duration: Duration) async -> Bool
    func wake(_ kind: ClockSleepKind) async
}

struct SystemClock: SignalingClock {
    func sleep(_: ClockSleepKind, for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false // cancelled — the client is stopping
        }
    }

    /// Nothing to wake on a real clock: the pong window is judged by the
    /// awaitingPong flag when the sleep completes.
    func wake(_: ClockSleepKind) async {}
}

// MARK: - Logging seam

/// Log seam for the client; implementations must never carry tokens, SDP or
/// ICE credentials (Review Focus 5).
public protocol SignalingLogging: Sendable {
    func info(_ message: String)
    func error(_ message: String)
}

struct DefaultSignalingLogging: SignalingLogging {
    private let logger = Logger(subsystem: "io.github.eugenehil.linko", category: "signaling")

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

// MARK: - The client

public actor SignalingClient {
    /// Heartbeat cadence: well inside the server's 300 s idle timeout.
    private static let heartbeatInterval: Duration = .seconds(60)
    /// How long one ping may stay unanswered before the connection is dead.
    private static let pongTimeout: Duration = .seconds(30)

    private let url: URL
    private let expectedPin: String
    private let user: String
    private let deviceId: String
    private let tokenProvider: @Sendable () async -> String?
    private let sessionFactory: @Sendable (URLRequest) -> any WebSocketSession
    private let clock: any SignalingClock
    private let random: @Sendable () -> Double
    private let logging: any SignalingLogging

    private var stream: AsyncStream<SignalingEvent>?
    private var streamContinuation: AsyncStream<SignalingEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var connectionTask: Task<Int, Never>?
    private var activeSession: (any WebSocketSession)?
    private var generation = 0
    private var stopped = false
    private var awaitingPong = false
    private var connectionWasEstablished = false

    /// - Parameters:
    ///   - sessionFactory: injectable transport seam; defaults to the pinned
    ///     URLSessionWebSocketTask transport.
    ///   - clock: injectable heartbeat/reconnect timer; defaults to the
    ///     system clock.
    ///   - random: injectable jitter source for the reconnect policy.
    ///   - logging: injectable log seam.
    public init(
        url: URL,
        expectedPin: String,
        user: String,
        deviceId: String,
        tokenProvider: @escaping @Sendable () async -> String?,
        sessionFactory: (@Sendable (URLRequest) -> any WebSocketSession)? = nil,
        clock: (any SignalingClock)? = nil,
        random: (@Sendable () -> Double)? = nil,
        logging: (any SignalingLogging)? = nil
    ) {
        self.url = url
        self.expectedPin = expectedPin
        self.user = user
        self.deviceId = deviceId
        self.tokenProvider = tokenProvider
        self.sessionFactory = sessionFactory ?? { request in
            RealWebSocketSession(request: request, expectedPin: expectedPin)
        }
        self.clock = clock ?? SystemClock()
        self.random = random ?? { Double.random(in: 0 ... 1) }
        self.logging = logging ?? DefaultSignalingLogging()
    }

    /// The event stream. Consuming it starts (and keeps alive) the connect,
    /// heartbeat and reconnect loop; ending the iteration stops the client.
    public var events: AsyncStream<SignalingEvent> {
        if stream == nil {
            let (stream, continuation) = AsyncStream<SignalingEvent>.makeStream(
                bufferingPolicy: .unbounded
            )
            self.stream = stream
            streamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.stop() }
            }
            runTask = Task { await self.run() }
        }
        return stream ?? AsyncStream { _ in }
    }

    /// Sends one envelope on the live connection. Wire-limit violations are
    /// refused locally; without a live connection this throws immediately.
    public func send(_ envelope: LKEnvelope) async throws {
        guard let session = activeSession else {
            throw SignalingError.notConnected
        }
        let wire = envelope.wireJSON
        guard !wire.isEmpty else {
            throw SignalingError.invalidOutgoingEnvelope
        }
        let bytes = wire.utf8.count
        guard bytes <= Int(LKTypes.maxEnvelopeBytes) else {
            throw SignalingError.oversizedEnvelope(bytes: bytes)
        }
        try await session.sendText(wire)
    }

    /// Stops the client: no further reconnects, the stream finishes.
    func stop() {
        guard !stopped else { return }
        stopped = true
        connectionTask?.cancel()
        runTask?.cancel()
    }

    // MARK: - The connect / reconnect loop

    private func run() async {
        var attempt = 0
        while !stopped, !Task.isCancelled {
            let token = await tokenProvider()
            guard !stopped, !Task.isCancelled else { break }
            guard let token else {
                logging.error("no device token available for the signaling handshake")
                emit(.error(.tokenMissing))
                guard await backoffSleep(&attempt) else { break }
                continue
            }

            let session = sessionFactory(makeRequest(token: token))
            generation += 1
            awaitingPong = false
            connectionWasEstablished = false
            activeSession = nil
            let connectionGeneration = generation
            let connection = Task<Int, Never> {
                await self.runConnection(session: session, generation: connectionGeneration)
            }
            connectionTask = connection
            let closeCode = await connection.value
            connectionTask = nil
            activeSession = nil
            guard !stopped, !Task.isCancelled else { break }

            // A connection that reached .connected resets the failure streak;
            // only consecutive failures grow the backoff.
            if connectionWasEstablished {
                attempt = 0
            }

            logging.info("signaling disconnected")
            emit(.disconnected(code: closeCode))
            guard await backoffSleep(&attempt) else { break }
        }
        streamContinuation?.finish()
    }

    /// One connection from hello to close; returns the close code the peer
    /// (or we) ended it with.
    private func runConnection(session: any WebSocketSession, generation runGeneration: Int) async -> Int {
        do {
            let hello = LKEnvelope(
                v: 1,
                type: LKTypes.sessionHello,
                id: makeEnvelopeID(),
                ts: nowMs(),
                bodyJSON: LKSessionHello(user: user, device: deviceId).bodyJSON
            )
            try await session.sendText(hello.wireJSON)
        } catch {
            logging.error("signaling handshake write failed")
            return 1006
        }
        activeSession = session
        connectionWasEstablished = true
        logging.info("signaling connected")
        emit(.connected)

        return await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.runHeartbeat(session: session, generation: runGeneration)
            }
            var closeCode = 1006
            do {
                while !Task.isCancelled, generation == runGeneration, !stopped {
                    switch try await session.receive() {
                    case let .text(text):
                        await handleFrame(text)
                    case let .closed(code):
                        closeCode = code
                        group.cancelAll()
                        return closeCode
                    }
                }
            } catch is CancellationError {
                // The pong-timeout path (or stop) cancelled the receive.
            } catch {
                logging.error("signaling receive failed")
            }
            group.cancelAll()
            return closeCode
        }
    }

    /// 60 s cadence: ping, then judge the pong window.
    private func runHeartbeat(session: any WebSocketSession, generation runGeneration: Int) async {
        while !Task.isCancelled, generation == runGeneration, !stopped {
            let intervalElapsed = await clock.sleep(.heartbeatInterval, for: Self.heartbeatInterval)
            guard intervalElapsed, generation == runGeneration, !stopped else { return }
            do {
                let ping = LKEnvelope(
                    v: 1,
                    type: LKTypes.sessionPing,
                    id: makeEnvelopeID(),
                    ts: nowMs(),
                    bodyJSON: "{}"
                )
                try await session.sendText(ping.wireJSON)
            } catch {
                logging.error("heartbeat ping failed")
                return // the receive loop will surface the transport failure
            }
            awaitingPong = true
            // Fast path: the pong may already have been processed while this
            // task was switching — then no window is needed.
            if awaitingPong {
                let windowElapsed = await clock.sleep(.pongTimeout, for: Self.pongTimeout)
                if windowElapsed {
                    guard awaitingPong else { continue } // pong inside the window
                    // No pong within the window: the connection is dead. We
                    // close our side (1006 abnormal), the loop reconnects
                    // after the backoff.
                    logging.error("heartbeat pong timed out")
                    generation += 1
                    await session.close()
                    connectionTask?.cancel()
                    return
                }
                // Woken early by the pong — or the client is stopping.
                if Task.isCancelled || generation != runGeneration || stopped {
                    return
                }
            }
        }
    }

    /// Hostile frames surface as errors and never close the socket from our
    /// side; session.pong is consumed by the heartbeat, session.error by the
    /// error path.
    private func handleFrame(_ text: String) async {
        let bytes = text.utf8.count
        guard bytes <= Int(LKTypes.maxEnvelopeBytes) else {
            emit(.error(.oversizedFrame(bytes: bytes)))
            return
        }
        let result = LKEnvelope.parse(jsonString: text)
        if result.unsupportedVersion {
            emit(.error(.unsupportedVersion))
            return
        }
        guard let envelope = result.envelope else {
            emit(.error(.malformedEnvelope(result.errors.map { issue in
                EnvelopeIssue(path: issue.path, message: issue.message)
            })))
            return
        }
        if envelope.type == LKTypes.sessionPong {
            awaitingPong = false
            await clock.wake(.pongTimeout)
            return
        }
        if envelope.type == LKTypes.sessionError {
            guard let body = try? LKSessionError.from(bodyJSON: envelope.bodyJSON) else { return }
            emit(.error(.sessionError(code: body.code, detail: body.detail)))
            return
        }
        emit(.envelope(envelope))
    }

    private func emit(_ event: SignalingEvent) {
        streamContinuation?.yield(event)
    }

    /// The reconnect gate: full jitter, growing with consecutive failures.
    /// Returns false only when the client is stopping.
    private func backoffSleep(_ attempt: inout Int) async -> Bool {
        let delay = ReconnectPolicy.nextDelay(attempt: attempt, random: random())
        attempt += 1
        let elapsed = await clock.sleep(.reconnectBackoff, for: delay)
        return elapsed || !Task.isCancelled
    }

    private func makeRequest(token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeEnvelopeID() -> String {
        UUID().uuidString
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
