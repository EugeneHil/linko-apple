// ConversationViewModel (Plan 4 Task 12): the conversation state — ordered
// messages with receipt lines, sends through the MessagingService outbox,
// opening marks read, file bubble transport labels and transfer progress,
// and the offline banner.

import FileTransfer
import Foundation
import Messaging

/// One receipt line under an outgoing bubble ("Sent/Delivered/Read HH:MM");
/// the view maps it onto DesignSystem's ReceiptLabel (state + timestamp).
public struct ConversationReceipt: Equatable {
    public let delivered: Bool
    public let read: Bool
    /// The "HH:mm" time under the line (the message's own timestamp).
    public let timestamp: String
    /// The composed line, for tests and accessibility.
    public let label: String

    public init(delivered: Bool, read: Bool, timestamp: String, label: String) {
        self.delivered = delivered
        self.read = read
        self.timestamp = timestamp
        self.label = label
    }
}

/// One conversation row: a text bubble or a file bubble.
public struct ConversationRow: Equatable, Identifiable {
    public let id: String
    public let text: String?
    public let file: FileMeta?
    public let outgoing: Bool
    public let timestamp: String
    public let receipt: ConversationReceipt?

    /// "peer-to-peer" / "via server" for file rows (spec 4.7); nil for text.
    public var transportLabel: String? {
        guard let file else { return nil }
        return file.transport == "p2p" ? "peer-to-peer" : "via server"
    }

    public init(
        id: String,
        text: String?,
        file: FileMeta?,
        outgoing: Bool,
        timestamp: String,
        receipt: ConversationReceipt?
    ) {
        self.id = id
        self.text = text
        self.file = file
        self.outgoing = outgoing
        self.timestamp = timestamp
        self.receipt = receipt
    }
}

@MainActor
@Observable
public final class ConversationViewModel {
    public private(set) var rows: [ConversationRow] = []
    public private(set) var online = true
    public var draft = ""

    public var showOfflineBanner: Bool {
        !online
    }

    private let localUser: String
    private let peer: String
    private let conversation: String
    private let store: MessageStore
    private let messaging: MessagingService
    private let makeEvents: @Sendable () -> AsyncStream<MessagingEvent>
    private let makeTransfers: @Sendable () -> AsyncStream<TransferEvent>
    private let fileProgress: FileBubbleProgress
    private var eventsTask: Task<Void, Never>?
    private var transfersTask: Task<Void, Never>?

    public init(
        localUser: String,
        peer: String,
        store: MessageStore,
        messaging: MessagingService,
        events: @escaping @Sendable () -> AsyncStream<MessagingEvent>,
        transfers: @escaping @Sendable () -> AsyncStream<TransferEvent>
    ) {
        self.localUser = localUser
        self.peer = peer
        conversation = ConversationKey.key(localUser, peer)
        self.store = store
        self.messaging = messaging
        makeEvents = events
        makeTransfers = transfers
        fileProgress = FileBubbleProgress()
    }

    /// Subscribes a fresh stream per start and consumes it until stop():
    /// the composition's multiplexer hands out a new branch each call, so
    /// stop/start cycles (the app root swapping screens) never strand the
    /// view model on a finished one-shot stream — read-on-delivery and the
    /// live receipt refresh keep working on every reopen. Safe to call
    /// again.
    public func start() {
        if eventsTask == nil {
            eventsTask = Task { [weak self] in
                guard let stream = self?.makeEvents() else { return }
                for await event in stream {
                    guard let self else { break }
                    await handle(event)
                }
            }
        }
        if transfersTask == nil {
            transfersTask = Task { [weak self] in
                guard let stream = self?.makeTransfers() else { return }
                for await event in stream {
                    guard let self else { break }
                    handle(event)
                }
            }
        }
    }

    public func stop() {
        eventsTask?.cancel()
        transfersTask?.cancel()
        eventsTask = nil
        transfersTask = nil
    }

    /// Rebuilds the rows from the store (history is seq-ordered) with the
    /// receipt watermarks folded in.
    public func refresh() async {
        let history = await store.history(conversation: conversation)
        var built: [ConversationRow] = []
        for message in history {
            let outgoing = message.from == localUser
            let receipt: ConversationReceipt? = outgoing
                ? await Self.receipt(for: message, store: store)
                : nil
            built.append(ConversationRow(
                id: message.id,
                text: message.text,
                file: message.file,
                outgoing: outgoing,
                timestamp: Self.time(message.ts),
                receipt: receipt
            ))
        }
        rows = built
    }

    public func handle(_ event: MessagingEvent) async {
        switch event {
        case .messageStored:
            await refresh()
            // The chat is open on screen: everything visible is read —
            // tell the peer immediately (the rehearsal found the receipt
            // stalling at Delivered until a reopen otherwise).
            await markOpened()
        case let .receiptsUpdated(conversation):
            // The peer's ack advanced the watermarks: refresh the outgoing
            // receipt lines live (Sent → Delivered → Read) instead of
            // waiting for the next reopen.
            if conversation == self.conversation {
                await refresh()
            }
        case let .connectionChanged(isOnline):
            online = isOnline
        case .presenceChanged, .sessionError:
            break // receipts and banners do not depend on these
        }
    }

    public func handle(_ event: TransferEvent) {
        fileProgress.handle(event)
    }

    /// Sends the draft through the MessagingService (which queues it in the
    /// outbox until msg.stored confirms it) and clears it.
    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        await messaging.send(to: peer, text: text)
    }

    /// The UI opened the conversation: read everything and tell the peer.
    public func markOpened() async {
        try? await messaging.open(conversation: conversation)
    }

    /// The in-flight transfer fraction for a file bubble; nil when idle.
    public func progress(for fileId: String) -> Double? {
        fileProgress.progress(for: fileId)
    }

    // MARK: - Internals

    private static func receipt(
        for message: StoredMessage,
        store: MessageStore
    ) async -> ConversationReceipt {
        let snapshot = await store.receipt(messageId: message.id)
        let delivered = snapshot?.delivered ?? false
        let read = snapshot?.read ?? false
        let time = time(message.ts)
        let word = read ? "Read" : delivered ? "Delivered" : "Sent"
        return ConversationReceipt(
            delivered: delivered,
            read: read,
            timestamp: time,
            label: "\(word) \(time)"
        )
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
