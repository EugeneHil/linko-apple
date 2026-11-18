// AudioRouteSwitching (Plan 4 Task 13 part 2, LNK-39, iOS only): the
// in-call audio route surface (spec §10 item 6) — the speaker override and
// the current output description, over the shared AVAudioSession. The seam
// keeps the view model testable without a live session. macOS has no
// AVAudioSession (routes default to the selected output device) — the
// surface is iOS-only by platform design.

#if os(iOS)
    import AVFAudio
    import Foundation

    /// The audio route surface the call screen reads and toggles.
    public protocol AudioRouteSwitching: Sendable {
        /// Routes the call audio to the built-in speaker (true) or back to
        /// the default route (receiver/Bluetooth, false).
        func setSpeakerOverride(_ enabled: Bool) throws
        /// The current output's port name (e.g. "iPhone", "AirPods Pro"),
        /// nil when the route carries no output.
        func currentOutputName() -> String?
    }

    /// The live switcher over the shared AVAudioSession. CallKit owns the
    /// session's activation; the override composes with it (both write the
    /// same session, never a second one).
    public final class LiveAudioRouteSwitcher: AudioRouteSwitching, @unchecked Sendable {
        public init() {}

        public func setSpeakerOverride(_ enabled: Bool) throws {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        }

        public func currentOutputName() -> String? {
            AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
        }
    }
#endif
