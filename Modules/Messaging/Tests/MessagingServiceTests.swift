// MessagingService (Plan 4 Task 6): msg.deliver persistence + acks, gap
// driven msg.sync on connect, outbox resend until msg.stored, duplicates
// ignored. Fakes cover signaling; the store is the real in-memory one.

import CoreBridge
@testable import Messaging
import XCTest

/// Lock-guarded event buffer for the service's surfacing stream.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MessagingEvent] = []

    func add(_ event: MessagingEvent) {
        lock.withLock {
            items.append(event)
        }
    }

    func contains(_ event: MessagingEvent) -> Bool {
        lock.withLock {
            items.contains(event)
        }
    }
}

final class MessagingServiceTests: XCTestCase {
    private let alice = "alice"
    private let bob = "bob"

    private func makeService(
        store: MessageStore,
        outbox: Outbox = Outbox(),
        signaling: SignalingSendingFake = SignalingSendingFake()
    ) -> MessagingService {
        MessagingService(
            localUser: alice,
            store: store,
            outbox: outbox,
            signaling: signaling
        )
    }

    /// Polls until the collector saw `event` (bounded; no sleeps in the
    /// happy path — AsyncStream buffers, the loop drains within ticks).
    private func waitFor(
        _ collector: EventCollector,
        event: MessagingEvent,
        timeoutSeconds: Double = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if collector.contains(event) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return collector.contains(event)
    }

    // MARK: - msg.deliver

    func test_deliver_envelope_persisted_and_acked() async throws {
        let store = try Fixtures.inMemoryStore()
        let signaling = SignalingSendingFake()
        let service = makeService(store: store, signaling: signaling)

        let deliver = Fixtures.deliverEnvelope(identifier: "m-7", from: bob, to: alice, seq: 7)
        await service.handle(.envelope(deliver))

        let conversation = ConversationKey.key(alice, bob)
        let history = await store.history(conversation: conversation)
        XCTAssertEqual(history.map(\.id), ["m-7"])
        XCTAssertEqual(history.first?.seq, 7)
        XCTAssertEqual(history.first?.from, bob)
        XCTAssertEqual(history.first?.to, alice)

        let sent = signaling.envelopes
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.type, LKTypes.msgAckDelivered)
        let ack = try? LKMsgAck.from(bodyJSON: sent.first?.bodyJSON ?? "")
        XCTAssertEqual(ack?.conversation, conversation)
        XCTAssertEqual(ack?.uptoSeq, 7)
    }

    func test_duplicate_deliver_ignored() async throws {
        let store = try Fixtures.inMemoryStore()
        let signaling = SignalingSendingFake()
        let service = makeService(store: store, signaling: signaling)

        let deliver = Fixtures.deliverEnvelope(identifier: "m-1", from: bob, to: alice, seq: 1)
        await service.handle(.envelope(deliver))
        await service.handle(.envelope(deliver))

        let conversation = ConversationKey.key(alice, bob)
        let history = await store.history(conversation: conversation)
        XCTAssertEqual(history.count, 1)

        let sent = signaling.envelopes
        XCTAssertEqual(sent.count, 1, "a duplicate deliver must not re-ack")
    }

    func test_file_deliver_persisted_with_meta() async throws {
        let store = try Fixtures.inMemoryStore()
        let service = makeService(store: store)

        let meta = LKFileMeta(
            name: "photo.jpg", size: 2048, sha256: String(repeating: "ef", count: 32),
            transport: "server", fileId: "9a3c"
        )
        let deliver = Fixtures.deliverEnvelope(
            identifier: "f-1", from: bob, to: alice, seq: 3, file: meta, text: ""
        )
        await service.handle(.envelope(deliver))

        let conversation = ConversationKey.key(alice, bob)
        let history = await store.history(conversation: conversation)
        XCTAssertNil(history.first?.text)
        XCTAssertEqual(history.first?.file?.name, "photo.jpg")
        XCTAssertEqual(history.first?.file?.transport, "server")
        XCTAssertEqual(history.first?.file?.fileId, "9a3c")
    }

    // MARK: - Receipt acks from the peer

    func test_ack_read_advances_receipts() async throws {
        let store = try Fixtures.inMemoryStore()
        let service = makeService(store: store)

        _ = await store.append(Fixtures.message(
            id: "s-1", conversation: ConversationKey.key(alice, bob), from: alice, to: bob, seq: 4
        ))

        let ack = Fixtures.ackEnvelope(
            type: LKTypes.msgAckRead,
            conversation: ConversationKey.key(alice, bob),
            uptoSeq: 4
        )
        await service.handle(.envelope(ack))

        let receipt = await store.receipt(messageId: "s-1")
        XCTAssertEqual(receipt?.read, true)
        XCTAssertEqual(receipt?.delivered, true)
    }

    // MARK: - Sync on connect (Review Focus 3: gapped history heals)

    func test_gap_triggers_sync_request() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        for (index, seq) in [Int64(1), 2, 4].enumerated() {
            _ = await store.append(Fixtures.message(
                id: "g-\(index)", conversation: conversation, from: bob, to: alice, seq: seq
            ))
        }
        let signaling = SignalingSendingFake()
        let service = makeService(store: store, signaling: signaling)

        await service.handle(.connected)

        let sent = signaling.envelopes
        let syncs = sent.filter { $0.type == LKTypes.msgSync }
        XCTAssertEqual(syncs.count, 1)
        let body = try? LKMsgSync.from(bodyJSON: syncs.first?.bodyJSON ?? "")
        XCTAssertEqual(body?.conversation, conversation)
        XCTAssertEqual(body?.afterSeq, 2, "afterSeq is the highest contiguous seq")
    }

    func test_no_sync_when_history_contiguous() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        for (index, seq) in [Int64(1), 2].enumerated() {
            _ = await store.append(Fixtures.message(
                id: "c-\(index)", conversation: conversation, from: bob, to: alice, seq: seq
            ))
        }
        let signaling = SignalingSendingFake()
        let service = makeService(store: store, signaling: signaling)

        await service.handle(.connected)

        let sent = signaling.envelopes
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Outbox (Review Focus 3: nothing lost across reconnects)

    func test_outbox_resends_after_reconnect() async throws {
        let store = try Fixtures.inMemoryStore()
        let outbox = Outbox()
        let signaling = SignalingSendingFake()
        let service = makeService(store: store, outbox: outbox, signaling: signaling)

        // Compose offline: the send is swallowed, the envelope waits.
        signaling.setOnline(false)
        await service.send(to: bob, text: "first")
        XCTAssertTrue(signaling.envelopes.isEmpty)

        signaling.setOnline(true)
        await service.handle(.connected)
        XCTAssertEqual(signaling.types, [LKTypes.msgSend])

        // Reconnect re-attempts the still-unconfirmed send.
        signaling.setOnline(false)
        await service.handle(.disconnected(code: 1006))
        signaling.setOnline(true)
        await service.handle(.connected)
        XCTAssertEqual(signaling.types, [LKTypes.msgSend, LKTypes.msgSend])
    }

    func test_outbox_stops_after_stored() async throws {
        let store = try Fixtures.inMemoryStore()
        let outbox = Outbox()
        let signaling = SignalingSendingFake()
        let service = makeService(store: store, outbox: outbox, signaling: signaling)

        signaling.setOnline(false)
        await service.send(to: bob, text: "keep me")
        let pending = await outbox.pending()
        let messageId = try XCTUnwrap(pending.first?.messageId)

        signaling.setOnline(true)
        await service.handle(.connected)
        XCTAssertEqual(signaling.types.count, 1)

        await service.handle(.envelope(Fixtures.storedEnvelope(identifier: messageId, seq: 1)))

        await service.handle(.connected)
        XCTAssertEqual(
            signaling.types.count, 1, "only the original send; msg.stored stops resending"
        )
    }

    func test_outbox_stored_message_lands_in_store_with_seq() async throws {
        let store = try Fixtures.inMemoryStore()
        let outbox = Outbox()
        let service = makeService(store: store, outbox: outbox)

        await service.send(to: bob, text: "mine")
        let pending = await outbox.pending()
        let messageId = try XCTUnwrap(pending.first?.messageId)

        await service.handle(.envelope(Fixtures.storedEnvelope(identifier: messageId, seq: 9)))

        let conversation = ConversationKey.key(alice, bob)
        let history = await store.history(conversation: conversation)
        XCTAssertEqual(history.map(\.id), [messageId])
        XCTAssertEqual(history.first?.from, alice)
        XCTAssertEqual(history.first?.seq, 9)
        XCTAssertEqual(history.first?.text, "mine")
    }

    // MARK: - Opening a conversation (read receipts)

    func test_open_marks_read_up_to_highest() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        for (index, seq) in [Int64(1), 2, 3].enumerated() {
            _ = await store.append(Fixtures.message(
                id: "o-\(index)", conversation: conversation, from: bob, to: alice, seq: seq
            ))
        }
        let signaling = SignalingSendingFake()
        let service = makeService(store: store, signaling: signaling)

        try await service.open(conversation: conversation)

        let receipts = await store.receipt(messageId: "o-2")
        XCTAssertEqual(receipts?.read, true)
        let sent = signaling.envelopes
        XCTAssertEqual(sent.first?.type, LKTypes.msgAckRead)
        let body = try? LKMsgAck.from(bodyJSON: sent.first?.bodyJSON ?? "")
        XCTAssertEqual(body?.uptoSeq, 3)
    }

    // MARK: - Surfacing (presence, session errors)

    func test_presence_and_session_error_surfaced() async throws {
        let store = try Fixtures.inMemoryStore()
        let service = makeService(store: store)

        let collector = EventCollector()
        let stream = await service.events
        let run = Task {
            for await event in stream {
                collector.add(event)
            }
        }

        let presence = LKPresenceChanged(user: bob, online: true)
        let presenceEnvelope = LKEnvelope(
            v: 1, type: LKTypes.presenceChanged, id: "env-p", ts: 1000,
            bodyJSON: presence.bodyJSON
        )
        await service.handle(.envelope(presenceEnvelope))
        await service.handle(.error(.sessionError(code: "gone", detail: "device revoked")))

        let sawPresence = await waitFor(collector, event: .presenceChanged(user: bob, online: true))
        XCTAssertTrue(sawPresence, "presence.changed must surface")
        let sawError = await waitFor(collector, event: .sessionError(code: "gone", detail: "device revoked"))
        XCTAssertTrue(sawError, "session.error must surface, never swallowed")

        run.cancel()
    }

    // MARK: - Connection state (offline/reconnecting banners, Task 12)

    func test_connection_state_surfaces_on_connect_and_disconnect() async throws {
        let store = try Fixtures.inMemoryStore()
        let service = makeService(store: store)

        let collector = EventCollector()
        let stream = await service.events
        let run = Task {
            for await event in stream {
                collector.add(event)
            }
        }

        await service.handle(.connected)
        await service.handle(.disconnected(code: 1006))

        let sawOffline = await waitFor(collector, event: .connectionChanged(online: false))
        XCTAssertTrue(sawOffline, "a disconnect must surface as offline for the banners")
        let sawOnline = await waitFor(collector, event: .connectionChanged(online: true))
        XCTAssertTrue(sawOnline, "a connect must surface as online again")

        run.cancel()
    }
}
