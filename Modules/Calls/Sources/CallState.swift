// CallState (Plan 4 Task 9): the UI-facing call snapshot — the core call
// state machine's LKCallState mirrored as a plain Swift value, so call
// surfaces never import CoreBridge (the reporting seam mirrors end reasons
// the same way).

import CoreBridge
import Foundation

public struct CallState: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case idle
        case outgoingRinging
        case incomingRinging
        case connecting
        case active
        case reconnecting
        case ended
    }

    public let kind: Kind
    public let callId: String
    public let peer: String
    public let video: Bool
    /// Meaningful only while kind is ended.
    public let endReason: CallEndReason?

    init(kind: Kind, callId: String, peer: String, video: Bool, endReason: CallEndReason?) {
        self.kind = kind
        self.callId = callId
        self.peer = peer
        self.video = video
        self.endReason = endReason
    }

    init(_ state: LKCallState) {
        let kind: Kind = switch state.kind {
        case .idle: .idle
        case .outgoingRinging: .outgoingRinging
        case .incomingRinging: .incomingRinging
        case .connecting: .connecting
        case .active: .active
        case .reconnecting: .reconnecting
        case .ended: .ended
        @unknown default: .idle
        }
        self.init(
            kind: kind,
            callId: state.callId,
            peer: state.peer,
            video: state.video,
            endReason: state.kind == .ended ? CallEndReason(state.endReason) : nil
        )
    }

    /// The fresh coordinator's state: no call.
    public static let idle = CallState(kind: .idle, callId: "", peer: "", video: false, endReason: nil)
}
