// MissedCallRecorder (Plan 4 Task 13 part 2, LNK-39): the missed-call seam.
// The coordinator reports every incoming call and every end through the
// CallReporting surface — the recorder sits between the coordinator and the
// platform reporter (CallKit adapter on iOS, MacCallPresenter on macOS),
// forwards all four reports untouched, and turns an Ended(.missed) report
// into a MissedCallNotice for the chats list (spec 4.7 "Missed call"). The
// primary reporter binds late: the platform adapter needs the coordinator,
// which needs its reporting at initialization — the composition root fills
// the slot right after building both.

import Foundation
import Synchronization

/// One missed incoming call, as the composition root maps onto the chats
/// feature's MissedCallEvent.
public struct MissedCallNotice: Sendable, Equatable {
    public let peer: String
    /// Missed-call time, ms since epoch (the wire timestamp unit).
    public let ts: Int64

    public init(peer: String, ts: Int64) {
        self.peer = peer
        self.ts = ts
    }
}

/// The CallReporting composite: late-bound platform reporter plus missed-call
/// recording. The coordinator's callState stream stays single-consumer (the
/// view model's) — missed calls surface through this reporting seam instead.
public final class MissedCallRecorder: CallReporting, @unchecked Sendable {
    /// The missed calls the chats list consumes.
    public let calls: AsyncStream<MissedCallNotice>

    private let continuation: AsyncStream<MissedCallNotice>.Continuation
    private let primary = Mutex<(any CallReporting)?>(nil)
    private let peers = Mutex<[String: String]>([:])
    private let nowMs: @Sendable () -> Int64

    public init(
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        (calls, continuation) = AsyncStream.makeStream(of: MissedCallNotice.self, bufferingPolicy: .unbounded)
        self.nowMs = nowMs
    }

    /// Binds the platform reporter once the coordinator exists (composition
    /// root). Reports before the binding are simply not forwarded — nothing
    /// can report before the coordinator's loops run.
    public func setPrimary(_ reporter: any CallReporting) {
        primary.withLock { $0 = reporter }
    }

    // MARK: CallReporting (forwarding + recording)

    public func startRinging() async {
        await primary.withLock { $0 }?.startRinging()
    }

    public func stopRinging() async {
        await primary.withLock { $0 }?.stopRinging()
    }

    public func reportIncoming(callId: String, peer: String, video: Bool) async {
        peers.withLock { $0[callId] = peer }
        await primary.withLock { $0 }?.reportIncoming(callId: callId, peer: peer, video: video)
    }

    /// Forwards the end and records the missed ones (an incoming call that
    /// rang unanswered — the machine's own classification).
    public func reportEnded(callId: String, reason: CallEndReason) async {
        if reason == .missed, let peer = peers.withLock({ $0[callId] }) {
            continuation.yield(MissedCallNotice(peer: peer, ts: nowMs()))
        }
        await primary.withLock { $0 }?.reportEnded(callId: callId, reason: reason)
    }
}
