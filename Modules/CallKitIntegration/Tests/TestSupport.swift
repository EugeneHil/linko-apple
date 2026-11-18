// TestSupport (Plan 4 Task 10 / LNK-36): the fakes for every OS seam the
// CallKitIntegration module talks to (CallKit provider surface, audio
// session, notification center, Mac incoming window, notifications), the
// coordinator routing spy, and the bounded-wait helper that keeps
// cross-actor settling out of assertions.

import CallEngine
@testable import CallKitIntegration
import Calls
import Foundation
import Synchronization
import XCTest

// MARK: - Shared fakes

/// The per-action counters of the routing spy.
struct RoutingCounts: Equatable {
    var accept = 0
    var reject = 0
    var hangup = 0
    var mute = 0
}

/// Records which coordinator actions the adapters route (accept, reject,
/// hangup, toggle mute).
final class FakeCallRouting: CallCoordinating, @unchecked Sendable {
    private let lock = Mutex(RoutingCounts())

    var counts: RoutingCounts {
        lock.withLock { $0 }
    }

    var acceptCount: Int {
        counts.accept
    }

    var rejectCount: Int {
        counts.reject
    }

    var hangupCount: Int {
        counts.hangup
    }

    var toggleMuteCount: Int {
        counts.mute
    }

    func accept() async {
        lock.withLock { $0.accept += 1 }
    }

    func reject() async {
        lock.withLock { $0.reject += 1 }
    }

    func hangup() async {
        lock.withLock { $0.hangup += 1 }
    }

    func toggleMute() async {
        lock.withLock { $0.mute += 1 }
    }
}

// MARK: - iOS fakes

#if os(iOS)
    import CallKit

    /// One CallKit incoming report the adapter requested.
    struct ReportedIncoming: Equatable {
        let uuid: UUID
        let handle: String
        let video: Bool
    }

    /// One CallKit ended report the adapter requested.
    struct ReportedEnded: Equatable {
        let uuid: UUID
        let reason: CallEndReason
    }

    /// Records the reports the adapter renders onto CXProvider.
    final class FakeIncomingCallReporter: IncomingCallReporting, @unchecked Sendable {
        private let lock = Mutex<(incoming: [ReportedIncoming], ended: [ReportedEnded])>(([], []))

        var incoming: [ReportedIncoming] {
            lock.withLock { $0.incoming }
        }

        var ended: [ReportedEnded] {
            lock.withLock { $0.ended }
        }

        func reportIncoming(uuid: UUID, handle: String, video: Bool) async -> Bool {
            lock.withLock { $0.incoming.append(ReportedIncoming(uuid: uuid, handle: handle, video: video)) }
            return true
        }

        func reportEnded(uuid: UUID, reason: CallEndReason) {
            lock.withLock { $0.ended.append(ReportedEnded(uuid: uuid, reason: reason)) }
        }
    }

    /// Records which CallKit actions were fulfilled or failed.
    final class FakeCallActionCompleter: CallActionCompleting, @unchecked Sendable {
        private let lock = Mutex<(fulfilled: [UUID], failed: [UUID])>(([], []))

        var fulfilled: [UUID] {
            lock.withLock { $0.fulfilled }
        }

        var failed: [UUID] {
            lock.withLock { $0.failed }
        }

        func fulfill(_ action: CXCallAction) {
            lock.withLock { $0.fulfilled.append(action.callUUID) }
        }

        func fail(_ action: CXCallAction) {
            lock.withLock { $0.failed.append(action.callUUID) }
        }
    }

    /// One setCategory call recorded by the fake audio session.
    struct RecordedConfiguration: Equatable {
        let category: AudioSessionCategory
        let mode: AudioSessionMode
        let options: AudioSessionOptions
    }

    /// Records the audio session configuration and activation calls.
    final class FakeAudioSessionConfigurator: AudioSessionConfiguring, @unchecked Sendable {
        private let lock = Mutex<(configurations: [RecordedConfiguration], activations: [Bool])>(([], []))

        var configurations: [RecordedConfiguration] {
            lock.withLock { $0.configurations }
        }

        var activations: [Bool] {
            lock.withLock { $0.activations }
        }

        func setCategory(
            _ category: AudioSessionCategory,
            mode: AudioSessionMode,
            options: AudioSessionOptions
        ) throws {
            lock.withLock { $0.configurations.append(RecordedConfiguration(category: category, mode: mode, options: options)) }
        }

        func setActive(_ active: Bool) throws {
            lock.withLock { $0.activations.append(active) }
        }
    }

    /// The manual-audio flags surface as plain state.
    final class FakeManualAudio: ManualAudioControlling, @unchecked Sendable {
        private let lock = Mutex<(use: Bool, enabled: Bool)>((false, false))

        var useManualAudio: Bool {
            get { lock.withLock { $0.use } }
            set { lock.withLock { $0.use = newValue } }
        }

        var isAudioEnabled: Bool {
            get { lock.withLock { $0.enabled } }
            set { lock.withLock { $0.enabled = newValue } }
        }
    }

    /// The fake's registry: pending pushes (that landed before an observer
    /// registered) plus the live observers per name.
    struct NotificationRegistry {
        var pending: [Notification.Name: [ObservedNotification]] = [:]
        var observers: [Notification.Name: [AsyncStream<ObservedNotification>.Continuation]] = [:]
    }

    /// A notification center seam the tests push notifications into; pushes
    /// that land before an observer registers are buffered (the monitor's
    /// pump tasks register asynchronously).
    final class FakeNotificationCenter: NotificationObserving, @unchecked Sendable {
        private let lock = Mutex(NotificationRegistry())

        func notifications(named name: Notification.Name) -> AsyncStream<ObservedNotification> {
            AsyncStream { continuation in
                let pending = lock.withLock { registry -> [ObservedNotification] in
                    registry.observers[name, default: []].append(continuation)
                    let drained = registry.pending[name] ?? []
                    registry.pending[name] = nil
                    return drained
                }
                for notification in pending {
                    continuation.yield(notification)
                }
            }
        }

        /// Delivers one notification to every registered observer of `name`.
        func push(_ name: Notification.Name, userInfo: [AnyHashable: Any]) {
            let notification = ObservedNotification(name: name, userInfo: userInfo)
            lock.withLock { registry in
                let observers = registry.observers[name] ?? []
                if observers.isEmpty {
                    registry.pending[name, default: []].append(notification)
                } else {
                    for continuation in observers {
                        continuation.yield(notification)
                    }
                }
            }
        }
    }

    // MARK: iOS fixtures

    struct AdapterFixture {
        let adapter: ProviderAdapter
        let reporter: FakeIncomingCallReporter
        let actions: FakeCallActionCompleter
        let configurator: FakeAudioSessionConfigurator
        let manual: FakeManualAudio
        let routing: FakeCallRouting
    }

    /// Builds the provider adapter over one set of fakes.
    func makeAdapterFixture() -> AdapterFixture {
        let reporter = FakeIncomingCallReporter()
        let actions = FakeCallActionCompleter()
        let configurator = FakeAudioSessionConfigurator()
        let manual = FakeManualAudio()
        let routing = FakeCallRouting()
        let audio = AudioSessionCoordinator(configurator: configurator, manualAudio: manual)
        let adapter = ProviderAdapter(coordinator: routing, audio: audio, reporter: reporter, actions: actions)
        return AdapterFixture(
            adapter: adapter,
            reporter: reporter,
            actions: actions,
            configurator: configurator,
            manual: manual,
            routing: routing
        )
    }

    struct AudioFixture {
        let audio: AudioSessionCoordinator
        let configurator: FakeAudioSessionConfigurator
        let manual: FakeManualAudio
    }

    /// Builds the audio session coordinator over one set of fakes.
    func makeAudioFixture() -> AudioFixture {
        let configurator = FakeAudioSessionConfigurator()
        let manual = FakeManualAudio()
        return AudioFixture(
            audio: AudioSessionCoordinator(configurator: configurator, manualAudio: manual),
            configurator: configurator,
            manual: manual
        )
    }
#endif

// MARK: - macOS fakes

#if os(macOS)
    /// One incoming-call window presentation recorded by the fake.
    struct ShownIncoming: Equatable {
        let callId: String
        let peer: String
        let video: Bool
    }

    /// The incoming-call window surface as recorded state; the presented
    /// window's action closures are stored and fired explicitly.
    /// The recorded state of the fake incoming-call window.
    struct WindowState {
        var shown: [ShownIncoming] = []
        var hidden: [String] = []
        var key = false
    }

    final class FakeIncomingWindow: MacIncomingWindowPresenting, @unchecked Sendable {
        private let lock = Mutex(WindowState())
        private let closures = Mutex<(accept: (@Sendable () async -> Void)?, reject: (@Sendable () async -> Void)?)>((nil, nil))

        var shown: [ShownIncoming] {
            lock.withLock { $0.shown }
        }

        var hidden: [String] {
            lock.withLock { $0.hidden }
        }

        func setKey(_ key: Bool) {
            lock.withLock { $0.key = key }
        }

        func showIncoming(
            callId: String,
            peer: String,
            video: Bool,
            onAccept: @escaping @Sendable () async -> Void,
            onReject: @escaping @Sendable () async -> Void
        ) async {
            lock.withLock { $0.shown.append(ShownIncoming(callId: callId, peer: peer, video: video)) }
            closures.withLock { $0 = (onAccept, onReject) }
        }

        /// Fires the accept action the presenter wired into the window.
        func fireAccept() async {
            let accept = closures.withLock { $0.accept }
            await accept?()
        }

        /// Fires the reject action the presenter wired into the window.
        func fireReject() async {
            let reject = closures.withLock { $0.reject }
            await reject?()
        }

        func hideIncoming(callId: String) async {
            lock.withLock { $0.hidden.append(callId) }
        }

        func incomingWindowIsKey() async -> Bool {
            lock.withLock { $0.key }
        }
    }

    /// One posted user notification recorded by the fake.
    struct PostedNotification: Equatable {
        let callId: String
        let peer: String
    }

    /// The user notification surface as recorded state.
    final class FakeMacNotifier: MacUserNotifying, @unchecked Sendable {
        private let lock = Mutex<[PostedNotification]>([])

        var posted: [PostedNotification] {
            lock.withLock { $0 }
        }

        func postIncomingCall(callId: String, peer: String) async {
            lock.withLock { $0.append(PostedNotification(callId: callId, peer: peer)) }
        }
    }

    struct PresenterFixture {
        let presenter: MacCallPresenter
        let window: FakeIncomingWindow
        let notifier: FakeMacNotifier
        let routing: FakeCallRouting
    }

    /// Builds the Mac presenter over one set of fakes; `windowIsKey` decides
    /// whether the window reports itself key.
    func makePresenterFixture(windowIsKey: Bool) -> PresenterFixture {
        let window = FakeIncomingWindow()
        window.setKey(windowIsKey)
        let notifier = FakeMacNotifier()
        let routing = FakeCallRouting()
        let presenter = MacCallPresenter(window: window, notifier: notifier, coordinator: routing)
        return PresenterFixture(presenter: presenter, window: window, notifier: notifier, routing: routing)
    }
#endif

// MARK: - Async helpers

/// Polls a predicate until it holds or the timeout expires (bounded; no
/// sleeps in the happy path — the streams buffer, the loop drains within
/// ticks).
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await !predicate() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(description)")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
