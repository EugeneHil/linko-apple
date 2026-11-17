// CallViewModel (Plan 4 Task 13 part 1): the call screen's state — the
// coordinator's UI-facing call stream and stats stream bound into
// observable properties (LNK-38 conventions: @Observable, @MainActor, all
// dependencies injected by initializer), the stats overlay preference read
// through the defaults seam, and the tray/incoming actions routed to the
// coordinator. No call state machine knowledge of its own.

import Calls
import CallStats
import Foundation
import ServerAPI

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
    private var stateTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    public init(coordinator: CallCoordinator, defaults: any DefaultsWriting) {
        self.coordinator = coordinator
        self.defaults = defaults
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
                guard let stream = self?.coordinator.callState else { return }
                for await snapshot in stream {
                    guard let self else { break }
                    handle(snapshot)
                }
            }
        }
        if statsTask == nil {
            statsTask = Task { [weak self] in
                guard let stream = self?.coordinator.stats else { return }
                for await sample in stream {
                    guard let self else { break }
                    stats = sample
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
    }

    private func handle(_ snapshot: CallState) {
        state = snapshot
        if snapshot.kind == .idle || snapshot.kind == .ended {
            isMuted = false
            isCameraOn = true
            stats = nil
        }
    }

    // MARK: - Tray and incoming actions (routed to the coordinator)

    public func toggleMute() async {
        isMuted.toggle()
        await coordinator.toggleMute()
    }

    /// The tray's camera toggle flips the local flag only: the coordinator
    /// and its engine expose no video-enable surface yet — the gap part 2
    /// (composition) closes with an engine API; no local plumbing invented
    /// here.
    public func toggleCamera() {
        isCameraOn.toggle()
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
}
