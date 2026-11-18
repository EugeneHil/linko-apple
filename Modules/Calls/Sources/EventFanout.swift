// EventFanout (Plan 4 Task 13 part 2, LNK-39): composition helpers for the
// single-consumer AsyncStreams the call and messaging surfaces publish. The
// coordinator's callState, the messaging service's events and the transfer
// coordinator's events each have several logical consumers in the app roots
// (view models, the call layout watcher, the missed-call mapper) — the
// multiplexer fans one source stream out to any number of branches, and
// fanoutMap adapts one element type onto another (the
// ForegroundWebSocketSource.split precedent, generalized).

import Foundation
import Observation
import Synchronization

/// Fans one AsyncStream out to any number of concurrently-subscribed
/// branches. Every branch receives every element (unbounded buffering per
/// branch, so a slow consumer never drops). A branch's stream terminates
/// with the source; cancelling a branch's iteration only detaches that
/// branch — the remaining branches keep flowing.
public final class EventMultiplexer<Event: Sendable>: @unchecked Sendable {
    /// One subscribed branch: an opaque id (the continuation itself is not
    /// Equatable on our deployment targets) plus its yield surface.
    private struct Branch: Sendable {
        let id: UUID
        let continuation: AsyncStream<Event>.Continuation
    }

    /// The pump's captured state. A box keeps the Task closure off `self`:
    /// a Task capturing the (not yet fully initialized) multiplexer in its
    /// initializer is refused by Swift's definite-initialization rules, and
    /// a lazy pump would never start before the first deinit — the box lets
    /// the pump start eagerly in init.
    private final class PumpBox: @unchecked Sendable {
        let source: AsyncStream<Event>
        let branches = Mutex<[Branch]>([])
        let finished = Mutex(false)

        init(source: AsyncStream<Event>) {
            self.source = source
        }
    }

    private let box: PumpBox
    private let pump: Task<Void, Never>

    /// Starts the fan-out pump (it copies every source element into every
    /// branch) immediately — a subscribed branch starts receiving as soon
    /// as its consumer iterates, with no ordering constraint on subscribe.
    public init(_ source: AsyncStream<Event>) {
        let box = PumpBox(source: source)
        self.box = box
        pump = Task {
            for await element in box.source {
                for branch in box.branches.withLock({ $0 }) {
                    branch.continuation.yield(element)
                }
            }
            box.finished.withLock { $0 = true }
            for branch in box.branches.withLock({ $0 }) {
                branch.continuation.finish()
            }
        }
    }

    deinit {
        pump.cancel()
    }

    /// Adds one branch. Subscribing after the source finished yields an
    /// immediately-finished stream.
    public func subscribe() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let isFinished = box.finished.withLock { $0 }
        if isFinished {
            continuation.finish()
            return stream
        }
        let branch = Branch(id: UUID(), continuation: continuation)
        box.branches.withLock { $0.append(branch) }
        continuation.onTermination = { [weak self] _ in
            self?.detach(branch.id)
        }
        return stream
    }

    private func detach(_ id: UUID) {
        box.branches.withLock { list in
            list.removeAll(where: { $0.id == id })
        }
    }
}

/// Maps one stream's elements onto another value type (a pump per
/// transform; the mapped stream is itself single-consumer).
public func fanoutMap<Source: Sendable, Destination: Sendable>(
    _ source: AsyncStream<Source>,
    transform: @escaping @Sendable (Source) -> Destination
) -> AsyncStream<Destination> {
    let (stream, continuation) = AsyncStream<Destination>.makeStream(bufferingPolicy: .unbounded)
    let pump = Task {
        for await element in source {
            continuation.yield(transform(element))
        }
        continuation.finish()
    }
    continuation.onTermination = { _ in
        pump.cancel()
    }
    return stream
}

/// The call-layout input the app roots read to decide when the call screen
/// replaces the shell (sidebar/chats). Fed by a callState multiplexer
/// branch; reading is free of the coordinator's single-consumer stream.
@MainActor
@Observable
public final class CallLayoutState {
    /// The layout-relevant part of the newest call snapshot.
    public private(set) var kind: CallState.Kind = .idle

    public init() {}

    /// Whether the call screen is on screen (any live call or ringing).
    public var showsCallScreen: Bool {
        kind != .idle && kind != .ended
    }

    /// Feeds the newest call snapshot in (the composition root's layout
    /// loop; public because the app targets feed their own branches).
    public func update(_ state: CallState) {
        kind = state.kind
    }
}
