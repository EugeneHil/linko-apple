// AdaptationPolicy (Plan 4 Task 8): the pure bitrate plan. Cut #3 applied
// (spec §1): only the cellular / Low-Data-Mode video cap ships in v0.1 —
// Wi-Fi stays uncapped; thermal resolution drops and audio-only fallback
// remain roadmap (the BitratePlan shape keeps room for them). The cap is a
// builder-tunable constant.

import CallEngine
import Foundation

/// The network inputs the coordinator (Task 9) derives from NWPathMonitor's
/// path and Low Data Mode. Pure values: no NWPathMonitor types here.
public enum NetworkInterface: Sendable, Equatable {
    case wifi
    case cellular
    case other
}

/// The network state the policy reads.
public struct NetworkState: Sendable, Equatable {
    public let interface: NetworkInterface
    /// Low Data Mode (NWPath.isConstrained) — capped like cellular.
    public let isLowDataMode: Bool

    public init(interface: NetworkInterface, isLowDataMode: Bool) {
        self.interface = interface
        self.isLowDataMode = isLowDataMode
    }
}

/// The pure adaptation policy (plan Task 8).
public struct AdaptationPolicy: Sendable {
    /// The video bitrate cap applied on cellular or in Low Data Mode.
    public let cellularCapBps: Int

    public init(cellularCapBps: Int = 500_000) {
        self.cellularCapBps = cellularCapBps
    }

    /// Pure: cellular or Low Data Mode caps the video bitrate at the
    /// tunable constant; every other network stays at the uncapped default.
    public func plan(state: NetworkState) -> BitratePlan {
        let capped = state.interface == .cellular || state.isLowDataMode
        return BitratePlan(maxVideoBitrateBps: capped ? cellularCapBps : nil)
    }
}
