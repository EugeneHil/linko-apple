// MessageStore (Plan 4 Task 6): idempotent appends by id, seq-ordered
// history, monotonic receipt watermarks (read implies delivered), core-owned
// gap detection and file-backed reopen.

import CoreBridge
@testable import Messaging
import XCTest

final class MessageStoreTests: XCTestCase {
    // MARK: - Appends and ordering

    func test_append_is_idempotent_by_id() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        let message = Fixtures.message(
            id: "m-1", conversation: conversation, from: "bob", to: "alice", seq: 1
        )

        let first = await store.append(message)
        XCTAssertTrue(first)
        let second = await store.append(message)
        XCTAssertFalse(second)

        let history = await store.history(conversation: conversation)
        XCTAssertEqual(history.count, 1)
    }

    func test_history_orders_by_seq() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        for (index, seq) in [Int64(3), 1, 2].enumerated() {
            _ = await store.append(Fixtures.message(
                id: "m-\(index)",
                conversation: conversation,
                from: "bob",
                to: "alice",
                seq: seq,
                text: "msg \(seq)"
            ))
        }

        let history = await store.history(conversation: conversation)
        XCTAssertEqual(history.map(\.seq), [1, 2, 3])
        XCTAssertEqual(history.map(\.text), ["msg 1", "msg 2", "msg 3"])

        let after = await store.history(conversation: conversation, afterSeq: 2)
        XCTAssertEqual(after.map(\.seq), [3])
    }

    func test_append_rejects_non_positive_seq() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        let appended = await store.append(Fixtures.message(
            id: "m-0", conversation: conversation, from: "bob", to: "alice", seq: 0
        ))
        XCTAssertFalse(appended)
    }

    // MARK: - Conversation key (server ordering, store.cpp conversationKey)

    func test_conversation_key_matches_server_ordering() {
        XCTAssertEqual(ConversationKey.key("zeta", "alpha"), "alpha\u{1F}zeta")
        XCTAssertEqual(ConversationKey.key("alpha", "zeta"), "alpha\u{1F}zeta")
        XCTAssertEqual(ConversationKey.key("alice", "alice"), "alice\u{1F}alice")
    }

    // MARK: - Receipts

    func test_receipts_never_regress() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        _ = await store.append(Fixtures.message(
            id: "m-3", conversation: conversation, from: "bob", to: "alice", seq: 3
        ))

        await store.markDelivered(conversation: conversation, uptoSeq: 3)
        let delivered = await store.receipt(messageId: "m-3")
        XCTAssertEqual(delivered?.delivered, true)
        XCTAssertEqual(delivered?.read, false)

        // A lower watermark is ignored.
        await store.markDelivered(conversation: conversation, uptoSeq: 2)
        await store.markRead(conversation: conversation, uptoSeq: 2)
        let afterLower = await store.receipt(messageId: "m-3")
        XCTAssertEqual(afterLower?.delivered, true)
        XCTAssertEqual(afterLower?.read, false)
    }

    func test_read_implies_delivered() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        _ = await store.append(Fixtures.message(
            id: "m-5", conversation: conversation, from: "bob", to: "alice", seq: 5
        ))

        await store.markRead(conversation: conversation, uptoSeq: 5)
        let receipt = await store.receipt(messageId: "m-5")
        XCTAssertEqual(receipt?.read, true)
        XCTAssertEqual(receipt?.delivered, true)
    }

    func test_receipt_unknown_message_is_nil() async throws {
        let store = try Fixtures.inMemoryStore()
        let receipt = await store.receipt(messageId: "missing")
        XCTAssertNil(receipt)
    }

    func test_highest_seq_zero_when_empty() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        let highest = await store.highestSeq(conversation: conversation)
        XCTAssertEqual(highest, 0)
    }

    // MARK: - Gap detection (delegated to the core's hasGapAfter)

    func test_gap_detection_matches_core_semantics() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        for (index, seq) in [Int64(1), 2, 4].enumerated() {
            _ = await store.append(Fixtures.message(
                id: "g-\(index)", conversation: conversation, from: "bob", to: "alice", seq: seq
            ))
        }

        let hasGap = await store.hasGap(conversation: conversation)
        XCTAssertTrue(hasGap)
        let boundary = await store.highestContiguousSeq(conversation: conversation)
        XCTAssertEqual(boundary, 2)

        // Closing the gap clears the flag.
        _ = await store.append(Fixtures.message(
            id: "g-3", conversation: conversation, from: "bob", to: "alice", seq: 3
        ))
        let closed = await store.hasGap(conversation: conversation)
        XCTAssertFalse(closed)
        let fullBoundary = await store.highestContiguousSeq(conversation: conversation)
        XCTAssertEqual(fullBoundary, 4)
    }

    func test_gap_false_when_contiguous_and_empty() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        let empty = await store.hasGap(conversation: conversation)
        XCTAssertFalse(empty)

        _ = await store.append(Fixtures.message(
            id: "c-1", conversation: conversation, from: "bob", to: "alice", seq: 1
        ))
        _ = await store.append(Fixtures.message(
            id: "c-2", conversation: conversation, from: "bob", to: "alice", seq: 2
        ))
        let contiguous = await store.hasGap(conversation: conversation)
        XCTAssertFalse(contiguous)
    }

    // MARK: - File messages

    func test_file_message_roundtrip() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key("alice", "bob")
        _ = await store.append(Fixtures.message(
            id: "f-1",
            conversation: conversation,
            from: "bob",
            to: "alice",
            seq: 2,
            text: nil,
            file: Fixtures.fileMeta()
        ))

        let history = await store.history(conversation: conversation)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history.first?.text)
        XCTAssertEqual(history.first?.file?.name, "notes.txt")
        XCTAssertEqual(history.first?.file?.transport, "p2p")
    }

    // MARK: - Reopen (file-backed persistence)

    func test_store_survives_reopen() async throws {
        let directory = NSTemporaryDirectory().appending("linko-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory.appending("messages.sqlite")

        let first = try MessageStore(path: path)
        let conversation = ConversationKey.key("alice", "bob")
        _ = await first.append(Fixtures.message(
            id: "r-1", conversation: conversation, from: "bob", to: "alice", seq: 1
        ))
        _ = await first.append(Fixtures.message(
            id: "r-2", conversation: conversation, from: "bob", to: "alice", seq: 2
        ))
        await first.markRead(conversation: conversation, uptoSeq: 2)

        let reopened = try MessageStore(path: path)
        let history = await reopened.history(conversation: conversation)
        XCTAssertEqual(history.map(\.id), ["r-1", "r-2"])
        let receipt = await reopened.receipt(messageId: "r-2")
        XCTAssertEqual(receipt?.read, true)
        XCTAssertEqual(receipt?.delivered, true)
        let conversations = await reopened.conversations()
        XCTAssertEqual(conversations, [conversation])
    }
}
