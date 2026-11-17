// CallScreen (Plan 4 Task 13 part 1): the in-call surface (spec 4.7) —
// remote video full screen, local preview top right, StatsOverlay top left
// (hidden when Settings says off), CallControlsTray bottom (mute, camera
// toggle, hangup; tray geometry from Task 3). All state lives in
// CallViewModel; the view only maps it. The remote and local layers render
// placeholders today: the engine's VideoTrackHandle has no platform
// renderer binding yet — part 2 (composition) closes that gap with the
// CallKit/Mac presenter wiring; no RTC plumbing invented in the feature
// module.

import Calls
import DesignSystem
import SwiftUI

public struct CallScreen: View {
    @State private var viewModel: CallViewModel

    public init(viewModel: CallViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ZStack {
            // The remote video layer (placeholder until part 2 binds the
            // engine's VideoTrackHandle through a platform renderer).
            Color.black

            if viewModel.state.kind == .incomingRinging {
                incomingCall
            } else {
                caption
            }

            if viewModel.state.video, viewModel.state.kind != .incomingRinging {
                localPreview
            }

            if viewModel.isStatsOverlayVisible {
                StatsOverlay(
                    bitrateKbps: viewModel.stats.map(StatsOverlayBinding.bitrateKbps(of:)),
                    rttMs: viewModel.stats?.rttMs,
                    lossPercent: viewModel.stats?.lossPercent
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(LKTokens.Spacing.s16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showsTray {
                tray
            }
        }
        .task {
            viewModel.start()
            viewModel.load()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    // MARK: - Layers

    /// The ringing surface: on macOS the view routes accept/reject to the
    /// coordinator (window presentation is part 2's MacCallPresenter); on
    /// iOS the CallKit UI covers the ringing call (LNK-36).
    @ViewBuilder
    private var incomingCall: some View {
        #if os(macOS)
            IncomingCallView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
            EmptyView()
        #endif
    }

    /// Who the call is with and where it stands — visible while no remote
    /// video renders (the video surface is part 2's renderer binding).
    private var caption: some View {
        VStack(spacing: LKTokens.Spacing.s4) {
            if !viewModel.state.peer.isEmpty {
                Text(viewModel.state.peer)
                    .font(.title2)
            }
            if let status = statusText {
                Text(status)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// The local camera preview layer (placeholder until part 2 binds the
    /// engine's local VideoTrackHandle).
    private var localPreview: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .frame(width: 120, height: 160)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(LKTokens.Spacing.s16)
    }

    private var tray: some View {
        CallControlsTray(
            isMuted: viewModel.isMuted,
            isCameraOn: viewModel.isCameraOn,
            onToggleMute: { Task { await viewModel.toggleMute() } },
            onToggleCamera: { viewModel.toggleCamera() },
            onHangup: { Task { await viewModel.hangup() } }
        )
    }

    // MARK: - Mapping

    private var showsTray: Bool {
        viewModel.state.kind != .idle && viewModel.state.kind != .ended
    }

    private var statusText: String? {
        switch viewModel.state.kind {
        case .outgoingRinging:
            "Calling…"
        case .connecting:
            "Connecting…"
        case .reconnecting:
            "Reconnecting…"
        case .incomingRinging:
            "Incoming call"
        default:
            nil
        }
    }
}
