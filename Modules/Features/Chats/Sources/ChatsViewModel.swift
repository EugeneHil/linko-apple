// ChatsViewModel (Plan 4 Task 12): the chats list state — one row per
// conversation with the last-message (or missed-call) preview, the unread
// badge derived from the receipt watermarks, presence dots from
// presence.changed events and the offline banner from connection events.

import Foundation
import Messaging

/// One chats-list row (rendered by ChatRow plus the presence dot).
public struct ChatSummary: Equatable, Identifiable {
    public let id: String
    public let peer: String
    public let preview: String
    public let timestamp: String
    public let unreadCount: Int
    public let online: Bool

    public init(
        id: String,
        peer: String,
        preview: String,
        timestamp: String,
        unreadCount: Int,
        online: Bool
    ) {
        self.id = id
        self.peer = peer
        self.preview = preview
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.online = online
    }
}

/// A missed incoming call, surfaced by the calls lane over the call-events
/// seam. Composition wiring point (LNK-39): CallCoordinator's
/// Ended(Missed) events land with LNK-35/36 and map onto this value.
public struct MissedCallEvent: Sendable, Equatable {
    public let peer: String
    /// Missed-call time, ms since epoch (the wire timestamp unit).
    public let ts: Int64

    public init(peer: String, ts: Int64) {
        self.peer = peer
        self.ts = ts
    }
}

/// The user-search seam (spec §10 item 1: a new chat starts by searching
/// the peer). The composition root wires the ServerAPI UsersClient behind
/// it; tests use fakes. Implementations return ≤ 20 sorted matches for a
/// non-empty prefix.
public protocol UserSearching: Sendable {
    func search(prefix: String) async throws -> [String]
}

@MainActor
@Observable
public final class ChatsViewModel {
    public private(set) var rows: [ChatSummary] = []
    public private(set) var online = true
    public private(set) var searchResults: [String] = []

    public var showOfflineBanner: Bool {
        !online
    }

    private let localUser: String
    private let store: MessageStore
    private let events: AsyncStream<MessagingEvent>
    private let missedCalls: AsyncStream<MissedCallEvent>
    private let users: any UserSearching
    private var presence: [String: Bool] = [:]
    private var missed: [String: MissedCallEvent] = [:]
    private var eventsTask: Task<Void, Never>?
    private var missedTask: Task<Void, Never>?

    public init(
        localUser: String,
        store: MessageStore,
        events: AsyncStream<MessagingEvent>,
        missedCalls: AsyncStream<MissedCallEvent>,
        users: any UserSearching
    ) {
        self.localUser = localUser
        self.store = store
        self.events = events
        self.missedCalls = missedCalls
        self.users = users
    }

    /// Begins consuming the injected streams (composition fan-out of the
    /// messaging and call event sources). Safe to call again.
    public func start() {
        if eventsTask == nil {
            eventsTask = Task { [weak self] in
                guard let stream = self?.events else { return }
                for await event in stream {
                    guard let self else { break }
                    await handle(event)
                }
            }
        }
        if missedTask == nil {
            missedTask = Task { [weak self] in
                guard let stream = self?.missedCalls else { return }
                for await event in stream {
                    guard let self else { break }
                    await handle(event)
                }
            }
        }
    }

    public func stop() {
        eventsTask?.cancel()
        missedTask?.cancel()
        eventsTask = nil
        missedTask = nil
    }

    /// Queries the users seam for the Chats search field. An empty or
    /// whitespace prefix clears the results without a round-trip; a failed
    /// query surfaces as an empty result set (the search field is
    /// exploratory — no error banners here).
    public func search(prefix: String) async {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchResults = await (try? users.search(prefix: trimmed)) ?? []
    }

    /// Rebuilds the rows from the store, the presence map and the locally
    /// recorded missed calls (newest activity first).
    public func refresh() async {
        var summaries: [ChatSummary] = []
        for key in await store.conversations() {
            guard let peer = Self.peer(in: key, localUser: localUser) else { continue }
            let messages = await store.history(conversation: key)
            var unread = 0
            for message in messages where message.from != localUser {
                let receipt = await store.receipt(messageId: message.id)
                if receipt?.read != true {
                    unread += 1
                }
            }
            guard let last = messages.last else { continue }
            let missedCall = missed[peer]
            summaries.append(ChatSummary(
                id: key,
                peer: peer,
                preview: missedCall?.preview ?? last.previewText,
                timestamp: missedCall.map { Self.time($0.ts) } ?? Self.time(last.ts),
                unreadCount: unread,
                online: presence[peer] ?? false
            ))
            // Sorting key: last activity, missed call or message.
            activity[peer] = max(last.ts, missedCall?.ts ?? 0)
        }
        // Peers with a missed call but no history yet still get a row.
        for (peer, missedCall) in missed where !summaries.contains(where: { $0.peer == peer }) {
            let key = ConversationKey.key(localUser, peer)
            summaries.append(ChatSummary(
                id: key,
                peer: peer,
                preview: missedCall.preview,
                timestamp: Self.time(missedCall.ts),
                unreadCount: 0,
                online: presence[peer] ?? false
            ))
            activity[peer] = missedCall.ts
        }
        rows = summaries.sorted { lhs, rhs in
            let lhsKey = activity[lhs.peer] ?? 0
            let rhsKey = activity[rhs.peer] ?? 0
            return lhsKey == rhsKey ? lhs.peer < rhs.peer : lhsKey > rhsKey
        }
    }

    public func handle(_ event: MessagingEvent) async {
        switch event {
        case let .presenceChanged(user, isOnline):
            presence[user] = isOnline
            await refresh()
        case .messageStored:
            await refresh()
        case .receiptsUpdated:
            break // receipt lines live in the conversation screen, not here
        case let .connectionChanged(isOnline):
            online = isOnline
        case .sessionError:
            break // surfaced by the composition root if needed
        }
    }

    /// Records a missed incoming call locally (spec 4.7 "Missed call").
    public func handle(_ event: MissedCallEvent) async {
        missed[event.peer] = event
        await refresh()
    }

    // MARK: - Internals

    /// Last activity per peer, the row sort key (ms since epoch).
    private var activity: [String: Int64] = [:]

    /// The conversation key is min + separator + max; the peer is the side
    /// that is not the local user.
    private static func peer(in key: String, localUser: String) -> String? {
        let sides = key.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard sides.count == 2 else { return nil }
        return sides.first(where: { $0 != localUser })
    }

    /// Wire timestamps are ms since epoch; the v0.1 UI pins UTC + the POSIX
    /// hour/minute form so labels are deterministic (device-local formatting
    /// is a later polish).
    private static func time(_ ts: Int64) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        return String(
            format: "%02d:%02d",
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date)
        )
    }
}

private extension StoredMessage {
    /// The list preview: the text, or the file name for file messages.
    var previewText: String {
        if let text {
            return text
        }
        return file?.name ?? ""
    }
}

private extension MissedCallEvent {
    /// The list preview for a missed incoming call (spec 4.7).
    var preview: String {
        "Missed call"
    }
}
