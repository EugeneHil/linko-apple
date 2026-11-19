// MessagingService (Plan 4 Task 6): consumes SignalingClient events and
// drives the store, the outbox and the server-facing replies.
//
// - msg.deliver -> persist (idempotent by id) + msg.ack-delivered at the
//   record's seq; duplicates are neither re-stored nor re-acked.
// - msg.ack-delivered / msg.ack-read -> advance the receipt watermarks.
// - msg.stored -> retire the outbox entry and file the outgoing message
//   with its server-assigned seq.
// - .connected -> resend every pending outbox envelope (idempotent
//   server-side) and send msg.sync per conversation whose history has a
//   gap (the core decides; afterSeq is the highest contiguous seq).
// - presence.changed / session.error -> surfaced to the UI, never
//   swallowed. Message bodies never reach logs — this type only produces
//   typed events.

import CoreBridge
import Foundation

// What the service surfaces to its consumer (the chats list, view models).
import Signaling

public enum MessagingEvent: Sendable, Equatable {
    case presenceChanged(user: String, online: Bool)
    case sessionError(code: String, detail: String)
    case messageStored(StoredMessage)
    /// The peer advanced the receipt watermarks (msg.ack-delivered /
    /// msg.ack-read): the conversation's outgoing receipt lines are stale.
    case receiptsUpdated(conversation: String)
    /// The signaling connection lifecycle for the UI banners
    /// (offline/reconnecting, spec 4.7): `false` on .disconnected, `true`
    /// again on .connected.
    case connectionChanged(online: Bool)
}

/// The send seam — the real implementation forwards to SignalingClient;
/// tests record.
public protocol SignalingSending: Sendable {
    func send(_ envelope: LKEnvelope) async throws
}

public actor MessagingService {
    private let localUser: String
    private let store: MessageStore
    private let outbox: Outbox
    private let signaling: any SignalingSending
    private let nowMs: @Sendable () -> Int64
    private let eventsContinuation: AsyncStream<MessagingEvent>.Continuation

    /// Surfacing stream for the UI; buffers events until a consumer runs.
    public let events: AsyncStream<MessagingEvent>

    public init(
        localUser: String,
        store: MessageStore,
        outbox: Outbox,
        signaling: any SignalingSending,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.localUser = localUser
        self.store = store
        self.outbox = outbox
        self.signaling = signaling
        self.nowMs = nowMs
        let (stream, continuation) = AsyncStream.makeStream(of: MessagingEvent.self)
        events = stream
        eventsContinuation = continuation
    }

    /// The production entry point: drive the service off the signaling
    /// event stream until it finishes.
    public func run(_ events: AsyncStream<SignalingEvent>) async {
        for await event in events {
            await handle(event)
        }
    }

    // MARK: - Event handling

    public func handle(_ event: SignalingEvent) async {
        switch event {
        case .connected:
            eventsContinuation.yield(.connectionChanged(online: true))
            await handleConnected()
        case let .envelope(envelope):
            await handle(envelope)
        case let .error(.sessionError(code, detail)):
            eventsContinuation.yield(.sessionError(code: code, detail: detail))
        case .disconnected:
            eventsContinuation.yield(.connectionChanged(online: false))
        case .error:
            break // transport errors precede the disconnect event
        }
    }

    private func handleConnected() async {
        for entry in await outbox.pending() {
            try? await signaling.send(entry.envelope)
        }
        for conversation in await store.conversations() {
            guard await store.hasGap(conversation: conversation) else { continue }
            let afterSeq = await store.highestContiguousSeq(conversation: conversation)
            await send(
                LKMsgSync(conversation: conversation, afterSeq: afterSeq),
                type: LKTypes.msgSync
            )
        }
    }

    private func handle(_ envelope: LKEnvelope) async {
        switch envelope.type {
        case LKTypes.msgDeliver:
            await handleDeliver(envelope)
        case LKTypes.msgAckDelivered:
            await handleAck(envelope) { conversation, upto in
                await self.store.markDelivered(conversation: conversation, uptoSeq: upto)
            }
        case LKTypes.msgAckRead:
            await handleAck(envelope) { conversation, upto in
                await self.store.markRead(conversation: conversation, uptoSeq: upto)
            }
        case LKTypes.msgStored:
            await handleStored(envelope)
        case LKTypes.presenceChanged:
            guard let body = try? LKPresenceChanged.from(bodyJSON: envelope.bodyJSON) else {
                return
            }
            eventsContinuation.yield(.presenceChanged(user: body.user, online: body.online))
        default:
            break // call.* and file.* belong to their coordinators
        }
    }

    private func handleDeliver(_ envelope: LKEnvelope) async {
        guard let body = try? LKMsgDeliver.from(bodyJSON: envelope.bodyJSON) else {
            return
        }
        let record = body.message
        let message = StoredMessage(
            id: record.identifier,
            conversation: ConversationKey.key(record.from, record.to),
            from: record.from,
            to: record.to,
            text: record.text.isEmpty ? nil : record.text,
            file: record.file.map(FileMeta.init),
            seq: record.seq,
            ts: record.ts
        )
        guard await store.append(message) else {
            return // duplicate id — the first record won, the first ack stands
        }
        eventsContinuation.yield(.messageStored(message))
        await send(
            LKMsgAck(conversation: message.conversation, uptoSeq: record.seq),
            type: LKTypes.msgAckDelivered
        )
    }

    private func handleAck(
        _ envelope: LKEnvelope,
        apply: (String, Int64) async -> Void
    ) async {
        guard let body = try? LKMsgAck.from(bodyJSON: envelope.bodyJSON) else {
            return
        }
        await apply(body.conversation, body.uptoSeq)
        eventsContinuation.yield(.receiptsUpdated(conversation: body.conversation))
    }

    private func handleStored(_ envelope: LKEnvelope) async {
        guard let stored = try? LKMsgStored.from(bodyJSON: envelope.bodyJSON),
              let entry = await outbox.markStored(messageId: stored.identifier),
              let sent = try? LKMsgSend.from(bodyJSON: entry.envelope.bodyJSON)
        else {
            return
        }
        let message = StoredMessage(
            id: stored.identifier,
            conversation: ConversationKey.key(localUser, sent.to),
            from: localUser,
            to: sent.to,
            text: sent.text.isEmpty ? nil : sent.text,
            file: sent.file.map(FileMeta.init),
            seq: stored.seq,
            ts: stored.ts
        )
        if await store.append(message) {
            eventsContinuation.yield(.messageStored(message))
        }
    }

    // MARK: - Outgoing actions

    /// Builds and sends one text msg.send. Never throws: the envelope
    /// rides the outbox until msg.stored confirms it, and a failed send
    /// (offline, hiccup) is simply retried on the next connect — the
    /// offline UX comes from signaling's disconnect events, not from here.
    public func send(to: String, text: String) async {
        let messageId = UUID().uuidString
        let body = LKMsgSend(identifier: messageId, to: to, text: text, file: nil)
        let envelope = LKEnvelope(
            v: 1,
            type: LKTypes.msgSend,
            id: UUID().uuidString,
            ts: nowMs(),
            bodyJSON: body.bodyJSON
        )
        await outbox.enqueue(messageId: messageId, envelope: envelope)
        try? await signaling.send(envelope)
    }

    /// The UI opened a conversation: read everything and tell the peer.
    public func open(conversation: String) async throws {
        let highest = await store.highestSeq(conversation: conversation)
        guard highest > 0 else { return }
        await store.markRead(conversation: conversation, uptoSeq: highest)
        await send(LKMsgAck(conversation: conversation, uptoSeq: highest), type: LKTypes.msgAckRead)
    }

    // MARK: - Envelope plumbing

    private func send(_ body: LKMsgSync, type: String) async {
        await sendRaw(body.bodyJSON, type: type)
    }

    private func send(_ body: LKMsgAck, type: String) async {
        await sendRaw(body.bodyJSON, type: type)
    }

    private func sendRaw(_ bodyJSON: String, type: String) async {
        let envelope = LKEnvelope(
            v: 1, type: type, id: UUID().uuidString, ts: nowMs(), bodyJSON: bodyJSON
        )
        try? await signaling.send(envelope)
    }
}

extension FileMeta {
    /// The core record's file metadata view.
    init(_ meta: LKFileMeta) {
        self.init(
            name: meta.name,
            size: meta.size,
            sha256: meta.sha256,
            transport: meta.transport,
            fileId: meta.fileId
        )
    }
}
