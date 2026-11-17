// CallTimer (Plan 4 Task 9): the timer actor behind the machine's
// StartTimer/CancelTimer effects. One armed timer per kind; expiry surfaces
// to the coordinator, which feeds the machine its Timer*Expired events. The
// clock is injectable so tests park every timer behind a gate.

import Foundation

/// Which machine timer is addressed: the timeoutMs effect values map onto
/// these kinds (kRingTimeoutMs, kConnectTimeoutMs, kReconnectTimeoutMs).
public enum CallTimerKind: String, Sendable, Hashable, CaseIterable {
    case ring
    case connect
    case reconnect
}

/// The injectable clock the timer sleeps on: `sleep` returns true when the
/// full duration elapsed, false when the timer was cancelled or woken early.
public protocol CallClock: Sendable {
    func sleep(_ kind: CallTimerKind, for duration: Duration) async -> Bool
    func wake(_ kind: CallTimerKind) async
}

/// The production clock: cancellable Task sleeps; wake is implicit in the
/// cancellation.
public struct SystemCallClock: CallClock {
    public init() {}

    public func sleep(_: CallTimerKind, for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false // cancelled — the timer is stopping
        }
    }

    public func wake(_: CallTimerKind) async {}
}

public actor CallTimer {
    private let clock: any CallClock
    private let onExpiry: @Sendable (CallTimerKind) async -> Void
    private var tasks: [CallTimerKind: Task<Void, Never>] = [:]

    public init(clock: any CallClock, onExpiry: @escaping @Sendable (CallTimerKind) async -> Void) {
        self.clock = clock
        self.onExpiry = onExpiry
    }

    /// Arms (or re-arms) one timer; a full sleep fires `onExpiry` once.
    /// Re-arming cancels the previous task of the kind first, so exactly one
    /// sleep per kind is pending at a time (the gate clock's contract).
    public func start(_ kind: CallTimerKind, timeoutMs: Int) {
        tasks[kind]?.cancel()
        let clock = clock
        let onExpiry = onExpiry
        tasks[kind] = Task {
            // A cancelled or woken-early sleep reports false: no expiry.
            guard await clock.sleep(kind, for: .milliseconds(timeoutMs)) else { return }
            await onExpiry(kind)
        }
    }

    /// Cancels one timer.
    public func cancel(_ kind: CallTimerKind) {
        tasks[kind]?.cancel()
        tasks[kind] = nil
    }

    /// Cancels every timer (the end-of-call sweep).
    public func cancelAll() {
        for kind in CallTimerKind.allCases {
            cancel(kind)
        }
    }
}
