// MessageStore (Plan 4 Task 6): the GRDB (SQLite, WAL) persistence for one
// device's messages and receipt watermarks. Appends are idempotent by
// message id (the first record wins — idempotent sends), history is
// seq-ordered, receipts are monotonic watermarks (read implies delivered,
// lower marks are ignored), and gap detection is delegated to the core's
// ConversationHistory.hasGapAfter — the store never invents sync semantics
// of its own. Message bodies are never logged.

import CoreBridge
import Foundation
import GRDB

/// File metadata attached to a message (mirrors the wire's LKFileMeta).
public struct FileMeta: Codable, Equatable, Sendable {
    public let name: String
    public let size: Int64
    public let sha256: String
    public let transport: String
    public let fileId: String

    public init(name: String, size: Int64, sha256: String, transport: String, fileId: String) {
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.transport = transport
        self.fileId = fileId
    }
}

/// One persisted chat message. `conversation` is the server-agreed
/// ConversationKey; `seq` is the server-assigned sequence number.
public struct StoredMessage: Equatable, Sendable {
    public let id: String
    public let conversation: String
    public let from: String
    public let to: String
    public let text: String?
    public let file: FileMeta?
    public let seq: Int64
    public let ts: Int64

    public init(
        id: String,
        conversation: String,
        from: String,
        to: String,
        text: String?,
        file: FileMeta?,
        seq: Int64,
        ts: Int64
    ) {
        self.id = id
        self.conversation = conversation
        self.from = from
        self.to = to
        self.text = text
        self.file = file
        self.seq = seq
        self.ts = ts
    }
}

/// Receipt snapshot for one stored message (mirrors the core's
/// LKReceiptState).
public struct ReceiptState: Equatable, Sendable {
    public let delivered: Bool
    public let read: Bool
}

public actor MessageStore {
    private let queue: DatabaseQueue

    private static let schema = """
    CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY NOT NULL,
        conversation TEXT NOT NULL,
        sender TEXT NOT NULL,
        recipient TEXT NOT NULL,
        body_text TEXT,
        file_meta TEXT,
        seq INTEGER NOT NULL,
        ts INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS messages_conversation_seq
        ON messages (conversation, seq);
    CREATE TABLE IF NOT EXISTS conversation_receipts (
        conversation TEXT PRIMARY KEY NOT NULL,
        delivered_seq INTEGER NOT NULL DEFAULT 0,
        read_seq INTEGER NOT NULL DEFAULT 0
    );
    """

    /// `path = nil` gives an anonymous in-memory database (tests); a path
    /// gives a WAL-backed file database the store can be reopened from.
    public init(path: String? = nil) throws {
        if let path {
            queue = try DatabaseQueue(path: path)
        } else {
            queue = try DatabaseQueue()
        }
        try queue.writeWithoutTransaction { db in
            if path != nil {
                try db.execute(sql: "PRAGMA journal_mode=WAL")
            }
            for statement in Self.schema.split(separator: ";") {
                try db.execute(sql: String(statement))
            }
        }
    }

    /// Inserts `message`; false when a record with the same id already
    /// exists (idempotent) or the seq is not a positive server seq.
    /// Database failures also answer false — the write is simply retried
    /// by the caller's resend flow, never crash.
    public func append(_ message: StoredMessage) -> Bool {
        guard message.seq > 0 else { return false }
        let fileMetaJSON: String? = message.file.flatMap { meta in
            guard let data = try? JSONEncoder().encode(meta) else { return nil }
            return data.base64EncodedString()
        }
        do {
            return try queue.write { db in
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE id = ?)",
                    arguments: [message.id]
                ) ?? false
                guard !exists else { return false }
                try db.execute(
                    sql: """
                    INSERT INTO messages
                        (id, conversation, sender, recipient, body_text, file_meta, seq, ts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        message.id, message.conversation, message.from, message.to,
                        message.text, fileMetaJSON, message.seq, message.ts
                    ]
                )
                return true
            }
        } catch {
            return false
        }
    }

    /// The conversation's messages with seq > afterSeq, in seq order.
    public func history(conversation: String, afterSeq: Int64 = 0) -> [StoredMessage] {
        let rows: [MessageRow] = (try? queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, conversation, sender, recipient, body_text, file_meta, seq, ts
                FROM messages WHERE conversation = ? AND seq > ? ORDER BY seq
                """,
                arguments: [conversation, afterSeq]
            ).compactMap { MessageRow(row: $0) }
        }) ?? []
        return rows.map(\.message)
    }

    /// The highest seq seen in the conversation; 0 when empty.
    public func highestSeq(conversation: String) -> Int64 {
        let highest: Int64? = try? queue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MAX(seq) FROM messages WHERE conversation = ?",
                arguments: [conversation]
            )
        }
        return highest ?? 0
    }

    /// True when the conversation's records above 0 are not the contiguous
    /// run 1, 2, ... up to the highest seq — the core's gap decision.
    public func hasGap(conversation: String) -> Bool {
        withHistory(conversation: conversation) { $0.hasGapAfter(0) }
    }

    /// The highest seq such that 1 ... seq are all present — the afterSeq
    /// value of a msg.sync request. 0 when empty or broken at the start.
    public func highestContiguousSeq(conversation: String) -> Int64 {
        let seqs = seqs(conversation: conversation)
        var boundary: Int64 = 0
        for seq in seqs {
            guard seq == boundary + 1 else { break }
            boundary = seq
        }
        return boundary
    }

    /// Advances the delivered watermark; lower values are ignored.
    public func markDelivered(conversation: String, uptoSeq: Int64) {
        mark(conversation: conversation, uptoSeq: uptoSeq, isRead: false)
    }

    /// Advances the read watermark (and delivered with it); lower values
    /// are ignored.
    public func markRead(conversation: String, uptoSeq: Int64) {
        mark(conversation: conversation, uptoSeq: uptoSeq, isRead: true)
    }

    /// The receipt snapshot for the stored message with `messageId`; nil
    /// when no such message exists.
    public func receipt(messageId: String) -> ReceiptState? {
        struct Snapshot {
            let seq: Int64
            let deliveredSeq: Int64
            let readSeq: Int64
        }
        // Typed closure pins the synchronous GRDB overload (the async one
        // would need `await` and has no place in an actor method).
        let fetch: (Database) throws -> Snapshot? = { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT m.seq AS seq,
                       COALESCE(c.delivered_seq, 0) AS delivered_seq,
                       COALESCE(c.read_seq, 0) AS read_seq
                FROM messages m
                LEFT JOIN conversation_receipts c ON c.conversation = m.conversation
                WHERE m.id = ?
                """,
                arguments: [messageId]
            ).map { row in
                Snapshot(
                    seq: row["seq"] ?? 0,
                    deliveredSeq: row["delivered_seq"] ?? 0,
                    readSeq: row["read_seq"] ?? 0
                )
            }
        }
        let snapshot: Snapshot? = (try? queue.read(fetch)) ?? nil
        guard let snapshot else { return nil }
        return ReceiptState(
            delivered: snapshot.seq <= snapshot.deliveredSeq,
            read: snapshot.seq <= snapshot.readSeq
        )
    }

    /// Every conversation the store knows about, sorted.
    public func conversations() -> [String] {
        (try? queue.read { (db: Database) -> [String] in
            try String.fetchAll(
                db, sql: "SELECT DISTINCT conversation FROM messages ORDER BY conversation"
            )
        }) ?? []
    }

    // MARK: - Internals

    private func seqs(conversation: String) -> [Int64] {
        (try? queue.read { (db: Database) -> [Int64] in
            try Int64.fetchAll(
                db,
                sql: "SELECT seq FROM messages WHERE conversation = ? ORDER BY seq",
                arguments: [conversation]
            )
        }) ?? []
    }

    /// Loads the conversation into the core's ConversationHistory and asks
    /// it — gap semantics live in the core, not here.
    private func withHistory(
        conversation: String,
        _ body: (LKConversationHistory) -> Bool
    ) -> Bool {
        let messages = history(conversation: conversation)
        let history = LKConversationHistory()
        for message in messages {
            history.add(message.record)
        }
        return body(history)
    }

    private func mark(conversation: String, uptoSeq: Int64, isRead: Bool) {
        _ = try? queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_receipts (conversation, delivered_seq, read_seq)
                VALUES (?, ?, ?)
                ON CONFLICT(conversation) DO UPDATE SET
                    delivered_seq = MAX(delivered_seq, excluded.delivered_seq),
                    read_seq = MAX(read_seq, excluded.read_seq)
                """,
                arguments: [conversation, uptoSeq, isRead ? uptoSeq : 0]
            )
        }
    }
}

/// Raw row for the messages table; file metadata rides as base64 JSON in
/// file_meta. Never logged.
private struct MessageRow {
    let message: StoredMessage

    init(row: Row) {
        let stored: String? = row["file_meta"]
        let fileMeta: FileMeta? = stored.flatMap { encoded -> FileMeta? in
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return try? JSONDecoder().decode(FileMeta.self, from: data)
        }
        message = StoredMessage(
            id: row["id"] ?? "",
            conversation: row["conversation"] ?? "",
            from: row["sender"] ?? "",
            to: row["recipient"] ?? "",
            text: row["body_text"],
            file: fileMeta,
            seq: row["seq"] ?? 0,
            ts: row["ts"] ?? 0
        )
    }
}

private extension StoredMessage {
    /// The core record view of this message (for gap decisions).
    var record: LKMessageRecord {
        LKMessageRecord(
            identifier: id,
            from: from,
            to: to,
            text: text ?? "",
            file: file.map {
                LKFileMeta(
                    name: $0.name, size: $0.size, sha256: $0.sha256,
                    transport: $0.transport, fileId: $0.fileId
                )
            },
            seq: seq,
            ts: ts
        )
    }
}
