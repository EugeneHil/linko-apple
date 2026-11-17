// ManualAudioControlling (Plan 4 Task 7): the seam over WebRTC's
// RTCAudioSession. The engine flips useManualAudio at prepare so WebRTC
// never activates the audio unit on its own; the CallKit provider adapter
// (Task 10) drives isAudioEnabled in provider(_:didActivate:)/didDeactivate —
// testable with a fake because the flag surface is a protocol, not the
// Objective-C singleton.

import Foundation
import Synchronization
import WebRTC

/// The manual-audio flags of RTCAudioSession.
public protocol ManualAudioControlling: Sendable {
    /// true keeps WebRTC from activating the AVAudioSession itself; the
    /// CallKit activation (Task 10) is then the only activator.
    var useManualAudio: Bool { get set }
    /// Whether WebRTC's audio unit may run; CallKit activation turns it on
    /// and deactivation turns it off (microphone-indicator anti-goal).
    var isAudioEnabled: Bool { get set }
}

/// The production controller. A process-wide singleton: the engine and the
/// CallKit adapter (Task 10) must flip flags on the same instance. iOS wraps
/// RTCAudioSession; macOS has no RTCAudioSession (audio routing belongs to
/// AVFoundation there), so the flags are inert state and the engine's
/// prepare flow stays uniform across platforms.
public final class LiveManualAudioController: ManualAudioControlling, @unchecked Sendable {
    /// The shared instance both the engine and the CallKit adapter use.
    public static let shared = LiveManualAudioController()

    #if os(iOS)
        private let session = RTCAudioSession.sharedInstance()

        private init() {}

        public var useManualAudio: Bool {
            get { session.useManualAudio }
            set { session.useManualAudio = newValue }
        }

        public var isAudioEnabled: Bool {
            get { session.isAudioEnabled }
            set { session.isAudioEnabled = newValue }
        }
    #else
        private let flags = Mutex<(use: Bool, enabled: Bool)>((false, false))

        private init() {}

        public var useManualAudio: Bool {
            get { flags.withLock { $0.use } }
            set { flags.withLock { $0.use = newValue } }
        }

        public var isAudioEnabled: Bool {
            get { flags.withLock { $0.enabled } }
            set { flags.withLock { $0.enabled = newValue } }
        }
    #endif
}
