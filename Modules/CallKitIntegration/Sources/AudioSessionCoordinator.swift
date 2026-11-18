// AudioSessionCoordinator (Plan 4 Task 10 / LNK-36, iOS only): the audio
// session configuration pinned by ADR-0001 (category .playAndRecord, mode
// .videoChat/.voiceChat, options .allowBluetoothHFP + .allowBluetoothA2DP +
// .defaultToSpeaker — never the deprecated .allowBluetooth) and the
// manual-audio handover CallKit drives in provider(_:didActivate:)/
// didDeactivate: (the microphone-indicator anti-goal).

#if os(iOS)
    import AVFAudio
    import CallEngine
    import Foundation

    /// The plain-Swift mirror of AVAudioSession.Category (the seam keeps the
    /// OS types out of the tests).
    public enum AudioSessionCategory: String, Sendable, Equatable {
        case playAndRecord
    }

    /// The plain-Swift mirror of AVAudioSession.Mode.
    public enum AudioSessionMode: String, Sendable, Equatable {
        case videoChat
        case voiceChat
    }

    /// The plain-Swift mirror of AVAudioSession.CategoryOptions — only the
    /// ADR-0001 flags belong here.
    public struct AudioSessionOptions: OptionSet, Sendable, Equatable {
        public let rawValue: UInt

        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// The HFP profile (Bluetooth hands-free with microphone).
        public static let allowBluetoothHFP = AudioSessionOptions(rawValue: 1 << 0)
        /// The A2DP profile (Bluetooth stereo output).
        public static let allowBluetoothA2DP = AudioSessionOptions(rawValue: 1 << 1)
        /// The built-in speaker instead of the receiver by default.
        public static let defaultToSpeaker = AudioSessionOptions(rawValue: 1 << 2)
    }

    /// The audio session configuration surface (the live configurator wraps
    /// AVAudioSession.sharedInstance(); tests record instead).
    public protocol AudioSessionConfiguring: Sendable {
        func setCategory(
            _ category: AudioSessionCategory,
            mode: AudioSessionMode,
            options: AudioSessionOptions
        ) throws
        func setActive(_ active: Bool) throws
    }

    /// The audio session half of the CallKit boundary.
    public final class AudioSessionCoordinator: Sendable {
        private let configurator: any AudioSessionConfiguring
        private let manualAudio: any ManualAudioControlling

        public init(
            configurator: any AudioSessionConfiguring,
            manualAudio: any ManualAudioControlling
        ) {
            self.configurator = configurator
            self.manualAudio = manualAudio
        }

        /// The ADR-0001 configuration for the call's media mode. A refused
        /// configuration degrades the call but never blocks it (the machine
        /// stays authoritative).
        public func configure(video: Bool) {
            let mode: AudioSessionMode = video ? .videoChat : .voiceChat
            try? configurator.setCategory(
                .playAndRecord,
                mode: mode,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
        }

        /// provider(_:didActivate:): CallKit owns the activation; WebRTC's
        /// audio unit may run again (manual audio hands control to CallKit).
        public func activate() {
            // The flags are written through a mutable existential binding
            // (a `let` box refuses the coroutined setter).
            var flags = manualAudio
            flags.useManualAudio = true
            flags.isAudioEnabled = true
        }

        /// provider(_:didDeactivate:): the microphone indicator must die with
        /// the call.
        public func deactivate() {
            var flags = manualAudio
            flags.isAudioEnabled = false
            try? configurator.setActive(false)
        }

        /// The live coordinator over AVAudioSession and the engine's shared
        /// manual-audio controller (composition root wiring, Task 13).
        public static func live() -> AudioSessionCoordinator {
            AudioSessionCoordinator(
                configurator: LiveAudioSessionConfigurator(),
                manualAudio: LiveManualAudioController.shared
            )
        }
    }

    /// The live AVAudioSession configurator.
    public struct LiveAudioSessionConfigurator: AudioSessionConfiguring {
        public init() {}

        public func setCategory(
            _ category: AudioSessionCategory,
            mode: AudioSessionMode,
            options: AudioSessionOptions
        ) throws {
            let avCategory: AVAudioSession.Category = switch category {
            case .playAndRecord: .playAndRecord
            }
            let avMode: AVAudioSession.Mode = switch mode {
            case .videoChat: .videoChat
            case .voiceChat: .voiceChat
            }
            var avOptions: AVAudioSession.CategoryOptions = []
            if options.contains(.allowBluetoothHFP) {
                avOptions.insert(.allowBluetoothHFP)
            }
            if options.contains(.allowBluetoothA2DP) {
                avOptions.insert(.allowBluetoothA2DP)
            }
            if options.contains(.defaultToSpeaker) {
                avOptions.insert(.defaultToSpeaker)
            }
            try AVAudioSession.sharedInstance().setCategory(avCategory, mode: avMode, options: avOptions)
        }

        public func setActive(_ active: Bool) throws {
            try AVAudioSession.sharedInstance().setActive(active)
        }
    }
#endif
