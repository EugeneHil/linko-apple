// CallViewModel (Plan 4 Task 13 part 1): the call screen's state — the
// coordinator's UI-facing call stream and stats stream bound into
// observable properties (LNK-38 conventions: @Observable, @MainActor, all
// dependencies injected by initializer), the stats overlay preference read
// through the defaults seam, and the tray/incoming actions routed to the
// coordinator. No call state machine knowledge of its own.

import CallEngine
import Calls
import CallStats
import Foundation
import ServerAPI

#if os(iOS)
    import CallKitIntegration
#endif

@MainActor
@Observable
public final class CallViewModel {
    /// The coordinator's current call snapshot, bound from the state stream.
    public private(set) var state: CallState = .idle
    /// The newest derived stats sample; nil until the stream produces one
    /// and reset with the call.
    public private(set) var stats: CallStatsSample?
    /// The persisted stats overlay preference (Settings' key); read at load().
    public private(set) var statsOverlayEnabled = false
    /// The tray's mute state (mirrors the coordinator's toggle; the
    /// coordinator's own flag is not observable). Resets with the call.
    public private(set) var isMuted = false
    /// The tray's camera state. Resets with the call.
    public private(set) var isCameraOn = true
    /// The engine's current local video track (the camera preview binding);
    /// nil for audio-only sessions and between calls. Refreshed with each
    /// state snapshot and stats sample.
    public private(set) var localVideoTrack: (any VideoTrackHandle)?
    /// The engine's current remote video track (the full-screen surface
    /// binding); same refresh rules.
    public private(set) var remoteVideoTrack: (any VideoTrackHandle)?

    /// Whether the top-left StatsOverlay renders: the Settings preference is
    /// on and the live call has produced a sample.
    public var isStatsOverlayVisible: Bool {
        statsOverlayEnabled && stats != nil && isLiveCall
    }

    private var isLiveCall: Bool {
        state.kind == .active || state.kind == .reconnecting
    }

    private let coordinator: CallCoordinator
    private let defaults: any DefaultsWriting
    /// The consumed call-state and stats streams as subscription factories:
    /// the composition's multiplexers hand out a fresh branch per start(),
    /// so stop/start cycles (the call screen appearing and disappearing)
    /// never strand the view model on a finished one-shot stream. Nil falls
    /// back to the coordinator's own streams (single start() only).
    private let makeStateStream: (@Sendable () -> AsyncStream<CallState>)?
    private let makeStatsStream: (@Sendable () -> AsyncStream<CallStatsSample>)?
    private var stateTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var trackRefreshTask: Task<Void, Never>?

    public init(
        coordinator: CallCoordinator,
        defaults: any DefaultsWriting,
        stateStream: (@Sendable () -> AsyncStream<CallState>)? = nil,
        statsStream: (@Sendable () -> AsyncStream<CallStatsSample>)? = nil
    ) {
        self.coordinator = coordinator
        self.defaults = defaults
        makeStateStream = stateStream
        makeStatsStream = statsStream
    }

    /// Reads the persisted preferences (the SettingsViewModel.load()
    /// precedent). Safe to call again.
    public func load() {
        statsOverlayEnabled = StatsOverlayBinding.isEnabled(defaults)
    }

    /// Begins consuming the coordinator's call and stats streams
    /// (composition fan-out of the coordinator's published streams). Safe
    /// to call again.
    public func start() {
        if stateTask == nil {
            state = coordinator.currentState
            stateTask = Task { [weak self] in
                let stream = self?.makeStateStream?() ?? self?.coordinator.callState
                guard let stream else { return }
                for await snapshot in stream {
                    guard let self else { break }
                    handle(snapshot)
                }
            }
        }
        if statsTask == nil {
            statsTask = Task { [weak self] in
                guard let stream = self?.makeStatsStream?() ?? self?.coordinator.stats else { return }
                for await sample in stream {
                    guard let self else { break }
                    stats = sample
                    // The live-session heartbeat: re-read the track handles
                    // so a late remote track (or late local setup) binds.
                    refreshTracks()
                }
            }
        }
    }

    /// Stops consuming the coordinator's streams.
    public func stop() {
        stateTask?.cancel()
        stateTask = nil
        statsTask?.cancel()
        statsTask = nil
        trackRefreshTask?.cancel()
        trackRefreshTask = nil
        #if os(iOS)
            routeTask?.cancel()
            routeTask = nil
            interruptionTask?.cancel()
            interruptionTask = nil
        #endif
    }

    private func handle(_ snapshot: CallState) {
        state = snapshot
        if snapshot.kind == .idle || snapshot.kind == .ended {
            isMuted = false
            isCameraOn = true
            stats = nil
            localVideoTrack = nil
            remoteVideoTrack = nil
        } else {
            refreshTracks()
        }
    }

    /// Reads the engine's current track handles through the coordinator
    /// (the tracks appear at session setup and remote arrival, not at the
    /// call's start — so every state snapshot and stats sample re-reads
    /// them; the stats cadence doubles as the binding heartbeat while the
    /// session is live).
    private func refreshTracks() {
        trackRefreshTask?.cancel()
        trackRefreshTask = Task { [weak self] in
            guard let self else { return }
            localVideoTrack = await coordinator.localVideoTrack()
            remoteVideoTrack = await coordinator.remoteVideoTrack()
        }
    }

    // MARK: - Tray and incoming actions (routed to the coordinator)

    public func toggleMute() async {
        isMuted.toggle()
        await coordinator.toggleMute()
    }

    /// The tray's camera toggle flips the local flag and routes to the
    /// coordinator's engine (setVideoEnabled — the part 2 composition
    /// surface): capture stops/resumes, the track leaves/returns to the
    /// sent SDP-less stream. A no-op on audio-only sessions (engine-side).
    public func toggleCamera() async {
        isCameraOn.toggle()
        await coordinator.setVideoEnabled(isCameraOn)
    }

    public func hangup() async {
        await coordinator.hangup()
    }

    public func accept() async {
        await coordinator.accept()
    }

    public func reject() async {
        await coordinator.reject()
    }

    // MARK: - Audio route (iOS, spec §10 item 6)

    #if os(iOS)
        /// The bound route monitor/switcher; nil until bindAudioRoutes runs
        /// (composition root; tests bind fakes or leave nil).
        private var routeMonitor: RouteChangeMonitor?
        private var routeSwitcher: (any AudioRouteSwitching)?
        private var routeTask: Task<Void, Never>?
        private var interruptionTask: Task<Void, Never>?
        /// The live output's port name; refreshed on every route change.
        public private(set) var audioRouteName: String?
        /// The tray's speaker override state.
        public private(set) var isSpeakerOn = false

        /// Binds the audio route surface. The monitor's routeChanges and
        /// interruptions streams are single-consumer each — the call screen
        /// (this view model) is their only reader. Safe to call once per
        /// binding; later calls with the same objects are no-ops.
        public func bindAudioRoutes(monitor: RouteChangeMonitor, switcher: any AudioRouteSwitching) {
            guard routeTask == nil else { return }
            routeMonitor = monitor
            routeSwitcher = switcher
            audioRouteName = switcher.currentOutputName()
            routeTask = Task { [weak self] in
                for await _ in monitor.routeChanges {
                    guard let self else { break }
                    audioRouteName = routeSwitcher?.currentOutputName()
                }
            }
            interruptionTask = Task { [weak self] in
                for await interruption in monitor.interruptions {
                    guard let self else { break }
                    // The route label refreshes when the interruption ends
                    // (the began side owns the session while it lasts).
                    if interruption.kind == .ended {
                        audioRouteName = routeSwitcher?.currentOutputName()
                    }
                }
            }
        }

        /// The route chip's speaker toggle: routes the call audio to the
        /// built-in speaker or back. A refused override leaves the current
        /// route (and this flag) untouched.
        public func toggleSpeaker() {
            guard let routeSwitcher else { return }
            let target = !isSpeakerOn
            do {
                try routeSwitcher.setSpeakerOverride(target)
                isSpeakerOn = target
            } catch {
                // The system refused the override; the current route stands.
            }
        }
    #endif
}
