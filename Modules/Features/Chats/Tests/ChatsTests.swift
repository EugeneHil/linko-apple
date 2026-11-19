// Chats (Plan 4 Task 12): the conversation list — last-message or
// "Missed call" preview (missed incoming calls arrive over the call-events
// seam), unread badge from the receipt watermarks, presence dot from
// presence.changed events, and the offline banner from connection events.

@testable import Chats
import Foundation
import Messaging
import XCTest

@MainActor
final class ChatsTests: XCTestCase {
    private let alice = "alice"
    private let bob = "bob"

    private func makeContext(store: MessageStore) -> ChatsContext {
        let events = Fixtures.messagingEvents()
        let missed = Fixtures.missedCallEvents()
        let users = UserSearchingFake()
        let viewModel = ChatsViewModel(
            localUser: alice,
            store: store,
            events: events.subscribe,
            missedCalls: missed.subscribe,
            users: users
        )
        return ChatsContext(
            viewModel: viewModel,
            events: events,
            missedCalls: missed,
            users: users
        )
    }

    func test_chats_last_message_preview() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice,
            seq: 1, text: "Hi Alice", ts: 3_600_000
        ))
        _ = await store.append(Fixtures.message(
            id: "m2", conversation: conversation, from: bob, to: alice,
            seq: 2, text: "See you tomorrow", ts: 7_200_000
        ))
        let context = makeContext(store: store)

        await context.viewModel.refresh()

        XCTAssertEqual(context.viewModel.rows.count, 1)
        XCTAssertEqual(context.viewModel.rows.first?.peer, "bob")
        XCTAssertEqual(
            context.viewModel.rows.first?.preview,
            "See you tomorrow",
            "the last message wins the preview"
        )
        XCTAssertEqual(context.viewModel.rows.first?.timestamp, "02:00")
    }

    func test_chats_missed_call_preview() async throws {
        let store = try Fixtures.inMemoryStore()
        let context = makeContext(store: store)

        context.viewModel.start()
        context.missedCalls.yield(MissedCallEvent(peer: bob, ts: 7_200_000))
        context.missedCalls.finish()

        let appeared = await waitFor(!context.viewModel.rows.isEmpty)
        XCTAssertTrue(appeared, "a missed call from a peer with no history still shows a row")
        XCTAssertEqual(context.viewModel.rows.first?.peer, "bob")
        XCTAssertEqual(context.viewModel.rows.first?.preview, "Missed call")
        XCTAssertEqual(context.viewModel.rows.first?.timestamp, "02:00")
        context.viewModel.stop()
    }

    func test_chats_unread_badge_counts() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice, seq: 1
        ))
        _ = await store.append(Fixtures.message(
            id: "m2", conversation: conversation, from: bob, to: alice, seq: 2
        ))
        let context = makeContext(store: store)

        await context.viewModel.refresh()
        XCTAssertEqual(
            context.viewModel.rows.first?.unreadCount,
            2,
            "incoming messages above the my-read watermark count"
        )

        await store.markMyRead(conversation: conversation, uptoSeq: 2)
        await context.viewModel.refresh()
        XCTAssertEqual(
            context.viewModel.rows.first?.unreadCount,
            0,
            "opening the conversation (the my-read watermark) clears the badge"
        )
    }

    func test_peer_acks_do_not_clear_unread() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice, seq: 1
        ))
        _ = await store.append(Fixtures.message(
            id: "m2", conversation: conversation, from: bob, to: alice, seq: 2
        ))
        // Alice's own outgoing message; the peer acks read up to its seq.
        // The false-Read bug (the rehearsal's 5th finding) let that ack
        // drive the shared read watermark and clear the incoming badge.
        _ = await store.append(Fixtures.message(
            id: "m3", conversation: conversation, from: alice, to: bob, seq: 3
        ))
        await store.markPeerRead(conversation: conversation, uptoSeq: 3)
        let context = makeContext(store: store)

        await context.viewModel.refresh()
        XCTAssertEqual(
            context.viewModel.rows.first?.unreadCount,
            2,
            "the peer's acks are about their reading — incoming unread is untouched"
        )
    }

    func test_chats_presence_dot_updates() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice, seq: 1
        ))
        let context = makeContext(store: store)

        context.viewModel.start()
        context.events.yield(.presenceChanged(user: bob, online: true))
        let online = await waitFor(context.viewModel.rows.first?.online == true)
        XCTAssertTrue(online, "presence.changed turns the dot on")

        context.events.yield(.presenceChanged(user: bob, online: false))
        let offline = await waitFor(context.viewModel.rows.first?.online == false)
        XCTAssertTrue(offline, "presence.changed turns the dot off")
        context.viewModel.stop()
    }

    func test_chats_events_resume_after_stop_start() async throws {
        let store = try Fixtures.inMemoryStore()
        let conversation = ConversationKey.key(alice, bob)
        _ = await store.append(Fixtures.message(
            id: "m1", conversation: conversation, from: bob, to: alice, seq: 1
        ))
        let context = makeContext(store: store)

        context.viewModel.start()
        context.events.yield(.presenceChanged(user: bob, online: true))
        let online = await waitFor(context.viewModel.rows.first?.online == true)
        XCTAssertTrue(online, "presence.changed turns the dot on")

        // The app root swaps the chats screen for the conversation and
        // back: stop() cancels the consumer, so the next start() must
        // subscribe a fresh stream — a one-shot stream stays finished.
        context.viewModel.stop()
        context.viewModel.start()
        context.events.yield(.presenceChanged(user: bob, online: false))
        let offline = await waitFor(context.viewModel.rows.first?.online == false)
        XCTAssertTrue(offline, "events resume after a stop/start cycle")
    }

    func test_chats_offline_banner_surfaces_on_disconnect() async throws {
        let store = try Fixtures.inMemoryStore()
        let context = makeContext(store: store)

        context.viewModel.start()
        context.events.yield(.connectionChanged(online: false))
        let offline = await waitFor(!context.viewModel.online)
        XCTAssertTrue(offline)
        XCTAssertTrue(context.viewModel.showOfflineBanner)

        context.events.yield(.connectionChanged(online: true))
        let backOnline = await waitFor(context.viewModel.online)
        XCTAssertTrue(backOnline, "reconnecting clears the banner")
        context.viewModel.stop()
    }

    // MARK: User search (spec §10 item 1 — the way a new chat starts)

    func test_search_passes_prefix_to_users_seam_and_shows_matches() async throws {
        let store = try Fixtures.inMemoryStore()
        let context = makeContext(store: store)
        context.users.matches = ["tatsiana", "eugene"]

        await context.viewModel.search(prefix: "  tat  ")

        XCTAssertEqual(context.users.queried, ["tat"], "the prefix is trimmed before the query")
        XCTAssertEqual(context.viewModel.searchResults, ["tatsiana", "eugene"])
    }

    func test_search_empty_prefix_clears_results() async throws {
        let store = try Fixtures.inMemoryStore()
        let context = makeContext(store: store)
        context.users.matches = ["tatsiana"]
        await context.viewModel.search(prefix: "tat")
        let shown = await waitFor(!context.viewModel.searchResults.isEmpty)
        XCTAssertTrue(shown)

        await context.viewModel.search(prefix: "   ")

        XCTAssertTrue(context.viewModel.searchResults.isEmpty, "an empty prefix clears the list")
        XCTAssertEqual(context.users.queried, ["tat"], "the empty prefix makes no server round-trip")
    }

    func test_search_failure_clears_results_quietly() async throws {
        let store = try Fixtures.inMemoryStore()
        let context = makeContext(store: store)
        struct ProbeError: Error {}
        context.users.error = ProbeError()

        await context.viewModel.search(prefix: "tat")

        XCTAssertTrue(context.viewModel.searchResults.isEmpty, "a failed search shows no stale rows")
    }
}
