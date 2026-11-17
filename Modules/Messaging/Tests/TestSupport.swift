// Shared test doubles and fixtures for the Messaging test targets (Plan 4
// Task 6). Envelope fixtures build real CoreBridge bodies so the service is
// exercised over the actual wire shapes, not hand-rolled JSON.

import CoreBridge
import Foundation
@testable import Messaging
import XCTest

/// The fake signals offline with its own error (the service swallows any
/// send failure — the outbox retries).
struct FakeOffline: Error {}

/// Records every envelope handed to the signaling seam and models the
/// connection state: sends while offline throw, like the real client.
final class SignalingSendingFake: SignalingSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LKEnvelope] = []
    private var online = true

    func setOnline(_ up: Bool) {
        lock.withLock {
            online = up
        }
    }

    func send(_ envelope: LKEnvelope) async throws {
        let up: Bool = lock.withLock {
            online
        }
        guard up else {
            throw FakeOffline()
        }
        lock.withLock {
            recorded.append(envelope)
        }
    }

    var envelopes: [LKEnvelope] {
        lock.withLock {
            recorded
        }
    }

    var types: [String] {
        lock.withLock {
            recorded.map(\.type)
        }
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

    static func fileMeta(name: String = "notes.txt") -> FileMeta {
        FileMeta(
            name: name,
            size: 128,
            sha256: String(repeating: "ab", count: 32),
            transport: "p2p",
            fileId: "0f9d"
        )
    }

    /// A wire-format msg.deliver carrying `record` as its message.
    static func deliverEnvelope(
        identifier: String,
        from: String,
        to: String,
        seq: Int64,
        file: LKFileMeta? = nil,
        text: String = "hello",
        ts: Int64 = 1000
    ) -> LKEnvelope {
        let record = LKMessageRecord(
            identifier: identifier,
            from: from,
            to: to,
            text: text,
            file: file,
            seq: seq,
            ts: ts
        )
        let body = LKMsgDeliver(message: record)
        return LKEnvelope(
            v: 1,
            type: LKTypes.msgDeliver,
            id: "env-\(identifier)",
            ts: ts,
            bodyJSON: body.bodyJSON
        )
    }

    /// A wire-format msg.stored confirming `identifier` with a server seq.
    static func storedEnvelope(identifier: String, seq: Int64, ts: Int64 = 1000) -> LKEnvelope {
        let body = LKMsgStored(identifier: identifier, seq: seq, ts: ts)
        return LKEnvelope(
            v: 1,
            type: LKTypes.msgStored,
            id: "env-stored-\(identifier)",
            ts: ts,
            bodyJSON: body.bodyJSON
        )
    }

    /// A wire-format msg.send body envelope (what the service enqueues).
    static func sendEnvelope(messageId: String, to: String, text: String) -> LKEnvelope {
        let body = LKMsgSend(identifier: messageId, to: to, text: text, file: nil)
        return LKEnvelope(
            v: 1,
            type: LKTypes.msgSend,
            id: "env-send-\(messageId)",
            ts: 1000,
            bodyJSON: body.bodyJSON
        )
    }

    /// A wire-format msg.ack-delivered / msg.ack-read envelope.
    static func ackEnvelope(type: String, conversation: String, uptoSeq: Int64) -> LKEnvelope {
        let body = LKMsgAck(conversation: conversation, uptoSeq: uptoSeq)
        return LKEnvelope(
            v: 1,
            type: type,
            id: "env-ack",
            ts: 1000,
            bodyJSON: body.bodyJSON
        )
    }
}
