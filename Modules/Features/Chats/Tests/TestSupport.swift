// Shared fixtures and stream helpers for the Chats test target (Plan 4
// Task 12): an in-memory store, message fixtures and fresh event streams
// the view model consumes. The missed-call events ride the call-events seam
// (AsyncStream of MissedCallEvent) — the composition root will wire the
// call state machine's Ended(Missed) source there (LNK-35/36, LNK-39).

@testable import Chats
import Foundation
import Messaging
import XCTest

/// A controllable event source: every subscribe() hands out a FRESH stream
/// (mirroring the composition's multiplexer branches — the stop/start
/// regression this pins), and yields reach the latest subscriber, queued
/// until the first subscribe arrives.
final class EventSource<Event: Sendable>: @unchecked Sendable {
    /// A class box around the (struct) continuation: the retirement handler
    /// needs identity to only retire its own stream.
    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<Event>.Continuation
        init(_ continuation: AsyncStream<Event>.Continuation) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var box: Box?
    private var pending: [Event] = []

    func subscribe() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let holder = Box(continuation)
        // A cancelled consumer finishes the stream: retire the handle so
        // later yields queue up for the next subscriber instead of falling
        // into the finished one.
        continuation.onTermination = { [weak self] _ in
            self?.retire(holder)
        }
        lock.withLock {
            box = holder
            for event in pending {
                continuation.yield(event)
            }
            pending = []
        }
        return stream
    }

    func yield(_ event: Event) {
        lock.withLock {
            if let box {
                box.continuation.yield(event)
            } else {
                pending.append(event)
            }
        }
    }

    /// Finishes the current stream (the next subscribe() starts a new one).
    func finish() {
        lock.withLock {
            box?.continuation.finish()
            box = nil
        }
    }

    private func retire(_ retired: Box) {
        lock.withLock {
            if box === retired {
                box = nil
            }
        }
    }
}

/// One chats scenario: the view model plus the event sources the tests
/// yield through.
struct ChatsContext {
    let viewModel: ChatsViewModel
    let events: EventSource<MessagingEvent>
    let missedCalls: EventSource<MissedCallEvent>
    let users: UserSearchingFake
}

/// Records the queried prefixes and returns canned matches (or throws) —
/// the seam contract lives in Chats (spec §10 item 1 user search).
final class UserSearchingFake: UserSearching, @unchecked Sendable {
    var matches: [String] = []
    var error: (any Error)?
    private(set) var queried: [String] = []

    func search(prefix: String) async throws -> [String] {
        queried.append(prefix)
        if let error {
            throw error
        }
        return matches
    }
}

enum Fixtures {
    static func inMemoryStore() throws -> MessageStore {
        try MessageStore(path: nil)
    }

    static func message(
        id: String,
        conversation: String,
        from: String,
        to: String,
        seq: Int64,
        text: String? = "hello",
        file: FileMeta? = nil,
        ts: Int64 = 1000
    ) -> StoredMessage {
        StoredMessage(
            id: id,
            conversation: conversation,
            from: from,
            to: to,
            text: text,
            file: file,
            seq: seq,
            ts: ts
        )
    }

    static func fileMeta(name: String = "notes.txt", transport: String = "p2p") -> FileMeta {
        FileMeta(
            name: name,
            size: 2048,
            sha256: String(repeating: "ab", count: 32),
            transport: transport,
            fileId: "ff01"
        )
    }

    static func messagingEvents() -> EventSource<MessagingEvent> {
        EventSource()
    }

    static func missedCallEvents() -> EventSource<MissedCallEvent> {
        EventSource()
    }
}

/// Polls until `condition` holds (bounded); the pumped streams drain within
/// ticks because AsyncStream buffers. MainActor-isolated: view model state
/// the conditions read is MainActor-confined.
@MainActor
func waitFor(
    timeoutSeconds: Double = 2,
    _ condition: @autoclosure () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
