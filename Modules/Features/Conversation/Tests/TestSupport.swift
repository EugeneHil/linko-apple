// Shared fixtures and fakes for the Conversation test target (Plan 4
// Task 12): the recording signaling fake (offline-aware), an in-memory
// store, message fixtures and fresh streams. The real MessagingService
// drives sends and open-reads; TransferEvents ride the injected stream
// (composition fan-out from TransferCoordinator.events, LNK-39).

@testable import Conversation
import CoreBridge
import FileTransfer
import Foundation
import Messaging
import XCTest

/// Records every envelope handed to the signaling seam and models the
/// connection state: sends while offline throw, like the real client.
final class SignalingSendingFake: SignalingSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LKEnvelope] = []
    private var online = true

    func send(_ envelope: LKEnvelope) async throws {
        let up: Bool = lock.withLock {
            online
        }
        guard up else {
            throw URLError(.notConnectedToInternet)
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

    static func fileMeta(name: String = "notes.txt", transport: String = "p2p") -> FileMeta {
        FileMeta(
            name: name,
            size: 2048,
            sha256: String(repeating: "ab", count: 32),
            transport: transport,
            fileId: "ff01"
        )
    }
}

/// One conversation scenario: the view model over a real MessagingService,
/// plus the handles the tests assert against.
/// A controllable event source: every subscribe() hands out a FRESH stream
/// (mirroring the composition's multiplexer branches — the stop/start
/// regression this pins), and yields reach the latest subscriber, queued
/// until the first subscribe arrives.
final class EventSource<Event: Sendable>: @unchecked Sendable {
    /// A class box around the (struct) continuation: the retirement handler
    /// needs identity to only retire its own stream.
    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<Event>.Continuation
        init(_ continuation: AsyncStream<Event>.Continuation) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var box: Box?
    private var pending: [Event] = []

    func subscribe() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let holder = Box(continuation)
        // A cancelled consumer finishes the stream: retire the handle so
        // later yields queue up for the next subscriber instead of falling
        // into the finished one.
        continuation.onTermination = { [weak self] _ in
            self?.retire(holder)
        }
        lock.withLock {
            box = holder
            for event in pending {
                continuation.yield(event)
            }
            pending = []
        }
        return stream
    }

    func yield(_ event: Event) {
        lock.withLock {
            if let box {
                box.continuation.yield(event)
            } else {
                pending.append(event)
            }
        }
    }

    /// Finishes the current stream (the next subscribe() starts a new one).
    func finish() {
        lock.withLock {
            box?.continuation.finish()
            box = nil
        }
    }

    private func retire(_ retired: Box) {
        lock.withLock {
            if box === retired {
                box = nil
            }
        }
    }
}

struct Context {
    let viewModel: ConversationViewModel
    let outbox: Outbox
    let signaling: SignalingSendingFake
    let events: EventSource<MessagingEvent>
    let transfers: EventSource<TransferEvent>
}

enum Scenario {
    @MainActor
    static func context(store: MessageStore, localUser: String = "alice", peer: String = "bob") -> Context {
        let outbox = Outbox()
        let signaling = SignalingSendingFake()
        let messaging = MessagingService(
            localUser: localUser, store: store, outbox: outbox, signaling: signaling
        )
        let events = EventSource<MessagingEvent>()
        let transfers = EventSource<TransferEvent>()
        let viewModel = ConversationViewModel(
            localUser: localUser,
            peer: peer,
            store: store,
            messaging: messaging,
            events: events.subscribe,
            transfers: transfers.subscribe
        )
        return Context(
            viewModel: viewModel,
            outbox: outbox,
            signaling: signaling,
            events: events,
            transfers: transfers
        )
    }
}

/// Polls until `condition` holds (bounded); the pumped streams drain within
/// ticks because AsyncStream buffers. MainActor-isolated: view model state
/// the conditions read is MainActor-confined.
@MainActor
func waitFor(
    timeoutSeconds: Double = 2,
    _ condition: @autoclosure () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
