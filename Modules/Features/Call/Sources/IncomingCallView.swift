// IncomingCallView (Plan 4 Task 13 part 1, macOS): the ringing surface the
// Mac call presenter (LNK-36, part 2) hosts in its call window — the
// caller's username, the media mode and the accept/decline actions routed
// through the view model to the coordinator. The view is only the surface:
// window presentation belongs to the presenter.

import Calls
import DesignSystem
import SwiftUI

#if os(macOS)
    public struct IncomingCallView: View {
        /// The caller's username (the ringing snapshot's peer).
        public let peer: String
        /// Whether the caller invites to a video call.
        public let isVideo: Bool
        let accept: () -> Void
        let reject: () -> Void

        /// Binds the ringing snapshot's presentation values and routes the
        /// two actions through the view model to the coordinator. The same
        /// closures the buttons fire are what the routing test drives.
        @MainActor
        public init(viewModel: CallViewModel) {
            peer = viewModel.state.peer
            isVideo = viewModel.state.video
            accept = { Task { await viewModel.accept() } }
            reject = { Task { await viewModel.reject() } }
        }

        public var body: some View {
            VStack(spacing: LKTokens.Spacing.s16) {
                Text(peer)
                    .font(.title2)
                    .accessibilityLabel("Incoming call from \(peer)")
                Text(isVideo ? "Video call" : "Audio call")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: LKTokens.Spacing.s16) {
                    LKButton(title: "Decline") {
                        reject()
                    }
                    LKButton(title: "Accept") {
                        accept()
                    }
                }
            }
            .padding(LKTokens.Spacing.s24)
        }
    }
#endif
