// Shared fixtures and stream helpers for the Chats test target (Plan 4
// Task 12): an in-memory store, message fixtures and fresh event streams
// the view model consumes. The missed-call events ride the call-events seam
// (AsyncStream of MissedCallEvent) — the composition root will wire the
// call state machine's Ended(Missed) source there (LNK-35/36, LNK-39).

@testable import Chats
import Foundation
import Messaging
import XCTest

/// One chats scenario: the view model plus the continuation handles the
/// tests yield events through.
struct ChatsContext {
    let viewModel: ChatsViewModel
    let events: AsyncStream<MessagingEvent>.Continuation
    let missedCalls: AsyncStream<MissedCallEvent>.Continuation
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

    static func messagingEvents() -> (
        stream: AsyncStream<MessagingEvent>, continuation: AsyncStream<MessagingEvent>.Continuation
    ) {
        AsyncStream.makeStream(of: MessagingEvent.self)
    }

    static func missedCallEvents() -> (
        stream: AsyncStream<MissedCallEvent>, continuation: AsyncStream<MissedCallEvent>.Continuation
    ) {
        AsyncStream.makeStream(of: MissedCallEvent.self)
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
