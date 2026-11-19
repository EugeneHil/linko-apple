// Conversation (Plan 4 Task 12): ordered messages with receipts, sends
// through the outbox, opening marks read, file bubble transport labels and
// progress bound to the transfer-events stream, and the offline banner on
// disconnect events.

@testable import Conversation
import CoreBridge
import FileTransfer
import Foundation
import Messaging
import XCTest

@MainActor
final class ConversationTests: XCTestCase {
    private let alice = "alice"
    private let bob = "bob"

    func test_conversation_messages_ordered_with_receipts() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        // Appended out of seq order; history is seq-ordered by the store.
        _ = await store.append(Fixtures.message(
            id: "m3", conversation: conversation, from: alice, to: bob,
            seq: 3, ts: 10_800_000
        ))
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice,
            seq: 1, ts: 3_600_000
        ))
        _ = await store.append(Fixtures.message(
            id: "m2", conversation: conversation, from: alice, to: bob,
            seq: 2, ts: 7_200_000
        ))
        await store.markDelivered(conversation: conversation, uptoSeq: 2)
        await store.markRead(conversation: conversation, uptoSeq: 1)

        let context = Scenario.context(store: store)
        await context.viewModel.refresh()

        XCTAssertEqual(context.viewModel.rows.map(\.id), ["m1", "m2", "m3"], "rows follow the seq order")
        XCTAssertNil(context.viewModel.rows[0].receipt, "incoming rows carry no receipt line")
        XCTAssertEqual(context.viewModel.rows[1].receipt?.delivered, true)
        XCTAssertEqual(context.viewModel.rows[1].receipt?.read, false)
        XCTAssertEqual(context.viewModel.rows[1].receipt?.label, "Delivered 02:00")
        XCTAssertEqual(context.viewModel.rows[2].receipt?.label, "Sent 03:00")
        XCTAssertEqual(context.viewModel.rows[0].timestamp, "01:00")
        XCTAssertEqual(context.viewModel.rows[1].outgoing, true)
        XCTAssertEqual(context.viewModel.rows[0].outgoing, false)
    }

    func test_send_goes_through_outbox() async throws {
        let context = try Scenario.context(store: Fixtures.inMemoryStore())

        context.viewModel.draft = "hello there"
        await context.viewModel.send()

        let pending = await context.outbox.pending()
        XCTAssertEqual(pending.count, 1, "the send rides the outbox until msg.stored")
        XCTAssertEqual(pending.first?.envelope.type, LKTypes.msgSend)
        XCTAssertEqual(context.signaling.types, [LKTypes.msgSend], "the first attempt goes out immediately")
        XCTAssertTrue(context.viewModel.draft.isEmpty, "the draft clears once queued")
    }

    func test_opening_marks_read() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice, seq: 1
        ))
        let context = Scenario.context(store: store)

        await context.viewModel.markOpened()

        let receipt = await store.receipt(messageId: "m1")
        XCTAssertEqual(receipt?.read, true, "opening the conversation reads everything")
        XCTAssertEqual(context.signaling.types, [LKTypes.msgAckRead], "the peer learns about the read")
    }

    func test_file_bubble_labels_transport() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: alice, to: bob,
            seq: 1, text: nil, file: Fixtures.fileMeta(transport: "p2p")
        ))
        _ = await store.append(Fixtures.message(
            id: "m2", conversation: conversation, from: bob, to: alice,
            seq: 2, text: nil, file: Fixtures.fileMeta(name: "photo.jpg", transport: "server")
        ))

        let context = Scenario.context(store: store)
        await context.viewModel.refresh()

        XCTAssertEqual(context.viewModel.rows[0].file?.name, "notes.txt")
        XCTAssertEqual(context.viewModel.rows[0].transportLabel, "peer-to-peer")
        XCTAssertEqual(context.viewModel.rows[1].transportLabel, "via server")
    }

    func test_file_bubble_progress_binds_transfer_stream() async throws {
        let context = try Scenario.context(store: Fixtures.inMemoryStore())

        context.viewModel.start()
        context.transfers.yield(.progress(TransferProgress(
            fileId: "ff01", bytesTransferred: 500, totalBytes: 1000
        )))
        context.transfers.finish()
        let bound = await waitFor(context.viewModel.progress(for: "ff01") == 0.5)
        XCTAssertTrue(bound, "transfer progress stream updates reach the file bubble")

        context.viewModel.handle(.completed(CompletedTransfer(
            callId: "call-1",
            fileId: "ff01",
            name: "notes.txt",
            size: 1000,
            sha256: "ab",
            transport: .p2p
        )))
        XCTAssertNil(context.viewModel.progress(for: "ff01"), "completion clears the progress bar")
        context.viewModel.stop()
    }

    func test_offline_banner_on_disconnect_event() async throws {
        let context = try Scenario.context(store: Fixtures.inMemoryStore())

        context.viewModel.start()
        context.events.yield(.connectionChanged(online: false))
        let offline = await waitFor(!context.viewModel.online)
        XCTAssertTrue(offline)
        XCTAssertTrue(context.viewModel.showOfflineBanner)

        context.events.yield(.connectionChanged(online: true))
        let back = await waitFor(context.viewModel.online)
        XCTAssertTrue(back, "reconnecting clears the banner")
        context.viewModel.stop()
    }

    // MARK: Live receipts (the rehearsal found them stalling at Delivered)

    func test_message_arriving_while_open_sends_read_receipt() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        let record = Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice,
            seq: 1, ts: 3_600_000
        )
        // The service persists the delivered message BEFORE emitting
        // messageStored — mirror that order here.
        _ = await store.append(record)
        let context = Scenario.context(store: store, localUser: alice, peer: bob)

        context.viewModel.start()
        context.events.yield(.messageStored(record))
        let readSent = await waitFor(context.signaling.types.contains(LKTypes.msgAckRead))
        XCTAssertTrue(readSent, "an incoming message in the open chat marks it read at once")
        context.viewModel.stop()
    }

    func test_receipt_event_refreshes_label_live() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: alice, to: bob,
            seq: 1, ts: 3_600_000
        ))
        await store.markDelivered(conversation: conversation, uptoSeq: 1)
        let context = Scenario.context(store: store, localUser: alice, peer: bob)
        context.viewModel.start()
        await context.viewModel.refresh()
        XCTAssertEqual(context.viewModel.rows.first?.receipt?.label, "Delivered 01:00")

        // The peer read it: the watermark advances in the store and the
        // service yields receiptsUpdated — the row flips without a reopen.
        await store.markRead(conversation: conversation, uptoSeq: 1)
        context.events.yield(.receiptsUpdated(conversation: conversation))
        let flipped = await waitFor(
            context.viewModel.rows.first?.receipt?.label == "Read 01:00"
        )
        XCTAssertTrue(flipped, "receipts update the label live")
        context.viewModel.stop()
    }
}
