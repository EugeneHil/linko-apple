// StatsOverlayBinding (Plan 4 Task 13 part 1): the StatsOverlay's inputs —
// the persisted preference read through the defaults seam (the same
// io.github.eugenehil.linko.stats-overlay key SettingsViewModel writes; the
// Call test target pins the two constants together so they cannot drift)
// and the derived sample's mapping onto the overlay's rows.

import CallStats
import Foundation
import ServerAPI

public enum StatsOverlayBinding {
    /// The stats overlay preference key — the literal under which
    /// SettingsViewModel persists the toggle.
    public static let overlayKey = "io.github.eugenehil.linko.stats-overlay"

    /// Reads the persisted preference (Bool JSON, off when absent or
    /// unreadable — the overlay starts off).
    public static func isEnabled(_ defaults: any DefaultsWriting) -> Bool {
        guard let data = defaults.data(forKey: overlayKey) else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    /// The overlay's bitrate row value (bps → kbps).
    public static func bitrateKbps(of sample: CallStatsSample) -> Double {
        Double(sample.bitrateBps) / 1000
    }
}
