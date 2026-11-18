// RouteChangeMonitor (Plan 4 Task 10 / LNK-36, iOS only): audio route
// changes and interruptions observed through a seamed notification center
// and surfaced as typed AsyncStreams for the call screen (speaker/Bluetooth
// switching per spec §10 item 6).

#if os(iOS)
    import AVFAudio
    import Foundation

    /// One observed notification's test-relevant payload. @unchecked because
    /// the user info values come from the system (numbers only).
    public struct ObservedNotification: @unchecked Sendable {
        public let name: Notification.Name
        public let userInfo: [AnyHashable: Any]

        public init(name: Notification.Name, userInfo: [AnyHashable: Any]) {
            self.name = name
            self.userInfo = userInfo
        }
    }

    /// The notification center seam (the live observer wraps
    /// NotificationCenter.default; tests push into a fake).
    public protocol NotificationObserving: Sendable {
        func notifications(named name: Notification.Name) -> AsyncStream<ObservedNotification>
    }

    /// The live observer. The bridge into the typed stream happens inside
    /// one task, so the non-Sendable Notification never crosses.
    public struct LiveNotificationObserving: NotificationObserving {
        public init() {}

        public func notifications(named name: Notification.Name) -> AsyncStream<ObservedNotification> {
            AsyncStream { continuation in
                let task = Task {
                    for await notification in NotificationCenter.default.notifications(named: name) {
                        continuation.yield(ObservedNotification(
                            name: notification.name,
                            userInfo: notification.userInfo ?? [:]
                        ))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }

    /// Why the audio route changed (the system reason mirrored plain Swift).
    public enum AudioRouteChangeReason: Sendable, Equatable {
        case newDeviceAvailable
        case oldDeviceUnavailable
        case categoryChanged
        case override
        case wakeFromSleep
        case noSuitableRouteForCategory
        case routeConfigurationChanged
        case setCategoryDescription
        case unknown
    }

    /// One route change surfaced to the call screen.
    public struct AudioRouteChange: Sendable, Equatable {
        public let reason: AudioRouteChangeReason

        public init(reason: AudioRouteChangeReason) {
            self.reason = reason
        }
    }

    /// One audio interruption surfaced to the call screen.
    public struct AudioInterruption: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case began
            case ended
            case unknown
        }

        public let kind: Kind
        public let shouldResume: Bool

        public init(kind: Kind, shouldResume: Bool) {
            self.kind = kind
            self.shouldResume = shouldResume
        }
    }

    /// The route-change and interruption streams. Single consumer each: the
    /// call screen.
    public final class RouteChangeMonitor: Sendable {
        public let routeChanges: AsyncStream<AudioRouteChange>
        public let interruptions: AsyncStream<AudioInterruption>

        private let routeContinuation: AsyncStream<AudioRouteChange>.Continuation
        private let interruptionContinuation: AsyncStream<AudioInterruption>.Continuation
        private let routeTask: Task<Void, Never>
        private let interruptionTask: Task<Void, Never>

        public init(center: any NotificationObserving) {
            let (routeStream, routeContinuationLocal) = AsyncStream<AudioRouteChange>.makeStream(
                bufferingPolicy: .unbounded
            )
            let (interruptionStream, interruptionContinuationLocal) = AsyncStream<AudioInterruption>.makeStream(
                bufferingPolicy: .unbounded
            )
            routeChanges = routeStream
            interruptions = interruptionStream
            routeContinuation = routeContinuationLocal
            interruptionContinuation = interruptionContinuationLocal
            routeTask = Task {
                for await note in center.notifications(named: AVAudioSession.routeChangeNotification) {
                    routeContinuationLocal.yield(AudioRouteChange(reason: Self.routeReason(note.userInfo)))
                }
                routeContinuationLocal.finish()
            }
            interruptionTask = Task {
                for await note in center.notifications(named: AVAudioSession.interruptionNotification) {
                    interruptionContinuationLocal.yield(Self.interruption(note.userInfo))
                }
                interruptionContinuationLocal.finish()
            }
        }

        deinit {
            routeTask.cancel()
            interruptionTask.cancel()
            routeContinuation.finish()
            interruptionContinuation.finish()
        }

        /// Maps the system's route-change reason.
        static func routeReason(_ userInfo: [AnyHashable: Any]) -> AudioRouteChangeReason {
            guard let raw = (userInfo[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue else {
                return .unknown
            }
            return switch raw {
            case 1: .newDeviceAvailable
            case 2: .oldDeviceUnavailable
            case 3: .categoryChanged
            case 4: .override
            case 6: .wakeFromSleep
            case 7: .noSuitableRouteForCategory
            case 8: .routeConfigurationChanged
            case 9: .setCategoryDescription
            default: .unknown
            }
        }

        /// Maps the system's interruption type and options.
        static func interruption(_ userInfo: [AnyHashable: Any]) -> AudioInterruption {
            let type = (userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let kind: AudioInterruption.Kind = switch type {
            case 1: .began
            case 2: .ended
            default: .unknown
            }
            let options = (userInfo[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            return AudioInterruption(kind: kind, shouldResume: options & 1 == 1)
        }
    }

    /// The live monitor over the default notification center (composition
    /// root wiring, Task 13).
    public extension RouteChangeMonitor {
        static func live() -> RouteChangeMonitor {
            RouteChangeMonitor(center: LiveNotificationObserving())
        }
    }
#endif
