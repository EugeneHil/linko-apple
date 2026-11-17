// IncomingCallSource (Plan 4 Task 9): where call invitations come from. The
// v0.1 implementation is ForegroundWebSocketSource (Task 10), which adapts
// the foreground WebSocket's call.invite envelopes; PushKit plugs in later
// (spec §2). The coordinator consumes this stream as the machine's
// RemoteInvite input — call.invite envelopes on the coordinator's signaling
// event stream are ignored, so an invite is never applied twice.

import Foundation

/// One observed invitation: the call id the peer chose, the caller's
/// username and the media mode.
public struct IncomingCall: Sendable, Equatable {
    public let callId: String
    public let peer: String
    public let video: Bool

    public init(callId: String, peer: String, video: Bool) {
        self.callId = callId
        self.peer = peer
        self.video = video
    }
}

/// The invitation surface. The stream is single-consumer: the coordinator
/// is its only reader.
public protocol IncomingCallSource: Sendable {
    var calls: AsyncStream<IncomingCall> { get }
}
