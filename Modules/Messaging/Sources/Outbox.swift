// Outbox (Plan 4 Task 6): pending msg.send envelopes waiting for the
// server's msg.stored confirmation. Every reconnect re-attempts the sends
// (idempotent server-side by message id); msg.stored retires the entry and
// hands back its wire body so the service can file the message into the
// store with the server-assigned seq. In-memory on purpose: the store is
// the durability boundary, the outbox only bridges one session's flights.

import CoreBridge
import Foundation

/// One pending send: the client-generated message id plus the full wire
/// envelope (reused verbatim on resend — the server dedupes by message id).
public struct PendingEntry: Sendable {
    public let messageId: String
    public let envelope: LKEnvelope
}

public actor Outbox {
    private var entries: [PendingEntry] = []

    public init() {}

    /// Queues an envelope for (re)sending; re-enqueueing an existing
    /// message id keeps the first envelope.
    public func enqueue(messageId: String, envelope: LKEnvelope) {
        guard !entries.contains(where: { $0.messageId == messageId }) else { return }
        entries.append(PendingEntry(messageId: messageId, envelope: envelope))
    }

    /// All pending entries in enqueue order.
    public func pending() -> [PendingEntry] {
        entries
    }

    /// Retires the entry confirmed by msg.stored; returns it so the caller
    /// can file the message into the store. nil when the id is unknown
    /// (e.g. a confirmation for a send from a previous session).
    public func markStored(messageId: String) -> PendingEntry? {
        guard let index = entries.firstIndex(where: { $0.messageId == messageId }) else {
            return nil
        }
        return entries.remove(at: index)
    }

    public var count: Int {
        entries.count
    }
}
