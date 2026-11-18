// CallScreen (Plan 4 Task 13 part 1, video binding in part 2 / LNK-39):
// the in-call surface (spec 4.7) — remote video full screen (the engine's
// remote track bound through VideoTrackView), local preview top right
// (the local track bound the same way; the material frame stands for
// audio-only or camera-off), StatsOverlay top left (hidden when Settings
// says off), CallControlsTray bottom (mute, camera toggle, hangup; tray
// geometry from Task 3). All state lives in CallViewModel; the view only
// maps it.

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
            // The remote video layer: the live track renders full-screen;
            // without one (audio-only, between tracks) the black background
            // and the caption stand.
            Color.black

            if let handle = viewModel.remoteVideoTrack {
                VideoTrackView(handle: handle)
            }

            if viewModel.state.kind == .incomingRinging {
                incomingCall
            } else if viewModel.remoteVideoTrack == nil {
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
            VStack(spacing: LKTokens.Spacing.s4) {
                if showsTray {
                    audioRouteBar
                    tray
                }
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
    /// video renders (the bound track replaces it).
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

    /// The local camera preview layer: the bound local track while the
    /// camera is on; the material frame stands for camera-off (and for a
    /// not-yet-bound track).
    private var localPreview: some View {
        Group {
            if viewModel.isCameraOn, let handle = viewModel.localVideoTrack {
                VideoTrackView(handle: handle)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            }
        }
        .frame(width: 120, height: 160)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(LKTokens.Spacing.s16)
    }

    private var tray: some View {
        CallControlsTray(
            isMuted: viewModel.isMuted,
            isCameraOn: viewModel.isCameraOn,
            onToggleMute: { Task { await viewModel.toggleMute() } },
            onToggleCamera: { Task { await viewModel.toggleCamera() } },
            onHangup: { Task { await viewModel.hangup() } }
        )
    }

    /// The in-call audio route surface (iOS only, spec §10 item 6): the
    /// live output's name and the speaker override. macOS has no
    /// AVAudioSession — the bar collapses to nothing there.
    @ViewBuilder
    private var audioRouteBar: some View {
        #if os(iOS)
            if viewModel.audioRouteName != nil || viewModel.isSpeakerOn {
                HStack(spacing: LKTokens.Spacing.s8) {
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.caption)
                    Text(viewModel.audioRouteName ?? "Audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        viewModel.toggleSpeaker()
                    } label: {
                        Image(systemName: viewModel.isSpeakerOn
                            ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.body)
                    }
                    .accessibilityLabel(viewModel.isSpeakerOn
                        ? "Route audio to the earpiece" : "Route audio to the speaker")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, LKTokens.Spacing.s16)
            }
        #endif
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
