// CallCoordinating (Plan 4 Task 10 / LNK-36): the routing surface the
// CallKit boundary and the Mac presenter drive. CallCoordinator witnesses it
// directly — the adapters add no state machine knowledge of their own
// (spec §7: the boundary adapter does exactly that and nothing more).

import Calls
import Foundation

/// The user actions a call boundary surface can route: the CallKit provider
/// adapter (iOS) and the Mac presenter's buttons call these.
public protocol CallCoordinating: Sendable {
    /// Accepts the ringing incoming call.
    func accept() async
    /// Declines the ringing incoming call.
    func reject() async
    /// Ends the current call with the state-appropriate event.
    func hangup() async
    /// Mutes or unmutes the local audio track.
    func toggleMute() async
}

extension CallCoordinator: CallCoordinating {}
