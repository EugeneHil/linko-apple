// Shared test doubles for the FileTransfer test targets (Plan 4 Task 11):
// a loopback data channel that records every frame and models transport
// buffering, a signaling fake, a recording transfer sink, and a canned HTTP
// transport that can read a streamed request body. Lock-guarded classes:
// recording stays synchronous and `NSLock.withLock` is the async-safe scoped
// form Swift 6 accepts from async contexts.

import CoreBridge
import CryptoKit
import FileTransfer
import Foundation
import ServerAPI
import XCTest

/// Lowercase-hex SHA-256 digest of `data` — the expected-value form every
/// manifest, upload reply and download header in these tests compares.
func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func randomBytes(_ count: Int) -> Data {
    Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
}

/// Writes `contents` to a fresh temporary file; the caller removes it.
func makeTempFile(name: String, contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("filetransfer-\(UUID().uuidString)-\(name)")
    try contents.write(to: url)
    return url
}

/// A file whose logical size is `size` bytes without writing every byte:
/// truncation at an offset gives a sparse file, enough for size checks.
func makeSparseTempFile(name: String, size: Int64) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("filetransfer-\(UUID().uuidString)-\(name)")
    try Data().write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(size))
    return url
}

/// Builds a protocol v1 envelope around a typed body's canonical JSON.
func envelope(_ type: String, bodyJSON: String) -> LKEnvelope {
    LKEnvelope(v: 1, type: type, id: UUID().uuidString, ts: 1_731_840_000_000, bodyJSON: bodyJSON)
}

/// Polls `condition` until it holds or the timeout elapses; fails the test
/// rather than hanging when the awaited state never arrives.
func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition not met within \(timeout)s", file: file, line: line)
}

// MARK: - Data channel fake

/// The fake data channel: records every frame, yields it on `frames`, and
/// models transport buffering for the backpressure test. Draining happens
/// either per `bufferedAmount` query (deterministic, one `drainBytesPerQuery`
/// per call) or never (cancellation tests park the sender in the gate).
final class LoopbackChannel: TransferChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data] = []
    private var buffered = 0
    private var peak = 0
    private var queries = 0
    private var blockedQueries = 0
    private var sendsUntilFailure: Int?
    private let drainBytesPerQuery: Int

    /// Outbound frames in send order, also yielded as they appear.
    let frames: AsyncStream<Data>
    private let frameContinuation: AsyncStream<Data>.Continuation

    init(drainBytesPerQuery: Int = 0) {
        self.drainBytesPerQuery = drainBytesPerQuery
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        frames = stream
        frameContinuation = continuation
    }

    /// Fails the (n+1)th and every later send without recording the frame,
    /// modelling a channel that dies mid-transfer.
    func failAfterSends(_ count: Int) {
        lock.withLock { sendsUntilFailure = count }
    }

    var bufferedAmount: Int {
        get async {
            lock.withLock {
                queries += 1
                if buffered >= 4096 {
                    blockedQueries += 1
                }
                if drainBytesPerQuery > 0 {
                    buffered = max(0, buffered - drainBytesPerQuery)
                }
                return buffered
            }
        }
    }

    func send(_ data: Data) async throws {
        // The failure budget counts chunk frames only: the receiver's acks
        // must keep flowing so the sender can resume from the ack point.
        let isAck = TransferFrames.parseAckFrame(data) != nil
        let failed: Bool = lock.withLock {
            if !isAck, let remaining = sendsUntilFailure {
                if remaining <= 0 {
                    return true
                }
                sendsUntilFailure = remaining - 1
            }
            return false
        }
        if failed {
            throw TransferError.channelClosed
        }
        lock.withLock {
            recorded.append(data)
            buffered += data.count
            peak = max(peak, buffered)
        }
        frameContinuation.yield(data)
    }

    var sentFrames: [Data] {
        lock.withLock { recorded }
    }

    var peakBuffered: Int {
        lock.withLock { peak }
    }

    var bufferedAmountQueries: Int {
        lock.withLock { queries }
    }

    var blockedBufferQueries: Int {
        lock.withLock { blockedQueries }
    }
}

// MARK: - Signaling and recording fakes

/// In-memory token source for the FilesClient-backed server tests.
final class TokenFake: TokenStoring, @unchecked Sendable {
    private let token: String

    init(token: String) {
        self.token = token
    }

    func save(_: String) async throws {}

    func load() async throws -> String? {
        token
    }

    func clear() async throws {}
}

/// Records every envelope the coordinator hands it, in order.
final class SignalingFake: TransferSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LKEnvelope] = []

    func send(_ envelope: LKEnvelope) async throws {
        lock.withLock {
            recorded.append(envelope)
        }
    }

    var envelopes: [LKEnvelope] {
        lock.withLock { recorded }
    }

    func envelopesOfType(_ type: String) -> [LKEnvelope] {
        lock.withLock { recorded.filter { $0.type == type } }
    }
}

/// The completed-transfer sink fake: captures the msg.send envelopes the
/// coordinator built so the test can parse the FileMeta record back out.
final class RecorderFake: CompletedTransferRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LKEnvelope] = []

    func record(_ envelope: LKEnvelope) async {
        lock.withLock {
            recorded.append(envelope)
        }
    }

    var envelopes: [LKEnvelope] {
        lock.withLock { recorded }
    }
}

/// Collects TransferEvents while the test drives the coordinator.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [TransferEvent] = []

    func append(_ event: TransferEvent) {
        lock.withLock {
            collected.append(event)
        }
    }

    var events: [TransferEvent] {
        lock.withLock { collected }
    }

    func completedEvents() -> [CompletedTransfer] {
        events.compactMap {
            if case let .completed(completed) = $0 {
                return completed
            }
            return nil
        }
    }

    func hasCancelled(callId: String, fileId: String) -> Bool {
        events.contains {
            if case let .cancelled(cancelledCall, cancelledFile) = $0 {
                return cancelledCall == callId && cancelledFile == fileId
            }
            return false
        }
    }
}
