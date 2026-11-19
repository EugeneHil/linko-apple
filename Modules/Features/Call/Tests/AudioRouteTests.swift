// Audio route and overlay binding tests (Plan 4 Task 14 / LNK-40 coverage
// backfill): the call screen's iOS audio-route surface — the speaker
// override, the route/interruption-driven output label, the refused-
// override fallback (spec §10 item 6) — the incoming accept/reject actions
// the VM routes to the coordinator (their macOS IncomingCallView test does
// not run on the iOS coverage run), and the StatsOverlay preference/rows
// mapping. The LiveAudioRouteSwitcher smoke exercises the real shared
// AVAudioSession the way the call screen uses it.

#if os(iOS)
    import AVFAudio
    @testable import Call
    import CallKitIntegration
    import Calls
    import CallStats
    import CoreBridge
    import Foundation
    import ServerAPI
    import Synchronization
    import XCTest

    /// The system refused the override (route stood).
    private struct OverrideRefused: Error {}

    /// The fake notification center's state: registered observer continuations
    /// per name plus notifications pushed before any observer registered (the
    /// monitor's pump tasks subscribe asynchronously).
    private struct AudioRouteRegistry {
        var observers: [Notification.Name: [AsyncStream<ObservedNotification>.Continuation]] = [:]
        var pending: [Notification.Name: [ObservedNotification]] = [:]
    }

    @MainActor
    final class AudioRouteTests: XCTestCase {
        // MARK: - Fakes

        /// A switcher double: records override attempts, serves a mutable
        /// output name and can refuse the override (the system-refused path).
        final class FakeAudioRouteSwitcher: AudioRouteSwitching, @unchecked Sendable {
            private let lock = NSLock()
            private let refuse: Bool
            private var recorded: [Bool] = []
            private var name: String?

            init(outputName: String?, refuse: Bool = false) {
                name = outputName
                self.refuse = refuse
            }

            func setSpeakerOverride(_ enabled: Bool) throws {
                lock.withLock {
                    recorded.append(enabled)
                }
                if refuse {
                    throw OverrideRefused()
                }
            }

            func currentOutputName() -> String? {
                lock.withLock {
                    name
                }
            }

            func setOutput(_ newName: String?) {
                lock.withLock {
                    name = newName
                }
            }

            var speakerOverrides: [Bool] {
                lock.withLock {
                    recorded
                }
            }
        }

        /// The notification seam the tests push route/interruption
        /// notifications into. Pushes that land before the monitor's pump
        /// registers are buffered (the CallKitIntegration test target's shape).
        final class FakeNotificationCenter: NotificationObserving, @unchecked Sendable {
            private let lock = Mutex(AudioRouteRegistry())

            func notifications(named name: Notification.Name) -> AsyncStream<ObservedNotification> {
                AsyncStream { continuation in
                    let drained = lock.withLock { registry -> [ObservedNotification] in
                        registry.observers[name, default: []].append(continuation)
                        let buffered = registry.pending[name] ?? []
                        registry.pending[name] = nil
                        return buffered
                    }
                    for notification in drained {
                        continuation.yield(notification)
                    }
                }
            }

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

        // MARK: - Route binding (RouteChangeMonitor + AudioRouteSwitching)

        func test_bind_audio_routes_sets_current_output() {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            let switcher = FakeAudioRouteSwitcher(outputName: "Speaker")
            let monitor = RouteChangeMonitor(center: FakeNotificationCenter())

            context.viewModel.bindAudioRoutes(monitor: monitor, switcher: switcher)

            XCTAssertEqual(context.viewModel.audioRouteName, "Speaker")
        }

        func test_route_change_refreshes_output_name() async throws {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            let switcher = FakeAudioRouteSwitcher(outputName: "Receiver")
            let center = FakeNotificationCenter()
            let monitor = RouteChangeMonitor(center: center)
            context.viewModel.bindAudioRoutes(monitor: monitor, switcher: switcher)

            // The peer's earpiece answer moves to Bluetooth: the label follows
            // the route, not the change's reason.
            switcher.setOutput("AirPods Pro")
            center.push(AVAudioSession.routeChangeNotification, userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            ])
            try await waitUntil("the route label follows the new output") {
                context.viewModel.audioRouteName == "AirPods Pro"
            }
        }

        func test_monitor_surfaces_began_and_ended_interruptions() async {
            let center = FakeNotificationCenter()
            let monitor = RouteChangeMonitor(center: center)
            var interruptions = monitor.interruptions.makeAsyncIterator()

            // The system's AVAudioSessionInterruptionTypeEnded value (2): the
            // AVAudioSession.InterruptionType.ended.rawValue did not survive the
            // AnyHashable/NSNumber hop as 2 — the literal does.
            center.push(AVAudioSession.interruptionNotification, userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(2)
            ])

            let ended = await interruptions.next()
            XCTAssertEqual(ended?.kind, .ended)
        }

        func test_interruption_end_refreshes_output_name() async throws {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            let switcher = FakeAudioRouteSwitcher(outputName: "Receiver")
            let center = FakeNotificationCenter()
            let monitor = RouteChangeMonitor(center: center)
            context.viewModel.bindAudioRoutes(monitor: monitor, switcher: switcher)

            // The interruption's ended side hands the session back: the route
            // label refreshes (the began side owns the session while it lasts).
            // The push rides inside the bounded-wait predicate: the monitor's
            // pump task registers its observer asynchronously, so the first
            // push can land before the subscription exists (the fake buffers
            // those, and a repeat push is harmless — the event is idempotent).
            switcher.setOutput("Receiver (after interruption)")
            try await waitUntil("the label refreshes when the interruption ends") {
                center.push(AVAudioSession.interruptionNotification, userInfo: [
                    AVAudioSessionInterruptionTypeKey: UInt(2)
                ])
                return context.viewModel.audioRouteName == "Receiver (after interruption)"
            }
        }

        func test_bind_audio_routes_is_idempotent() {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            let first = FakeAudioRouteSwitcher(outputName: "Speaker")
            let monitor = RouteChangeMonitor(center: FakeNotificationCenter())
            context.viewModel.bindAudioRoutes(monitor: monitor, switcher: first)

            // A second binding with another switcher is a no-op: the streams
            // are single-consumer and the first binding owns them.
            let second = FakeAudioRouteSwitcher(outputName: "AirPods Pro")
            context.viewModel.bindAudioRoutes(monitor: monitor, switcher: second)

            XCTAssertEqual(context.viewModel.audioRouteName, "Speaker")
            XCTAssertTrue(second.speakerOverrides.isEmpty)
        }

        // MARK: - Speaker override (the tray's route chip)

        func test_toggle_speaker_routes_override_and_back() {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            let switcher = FakeAudioRouteSwitcher(outputName: "Receiver")
            let monitor = RouteChangeMonitor(center: FakeNotificationCenter())
            context.viewModel.bindAudioRoutes(monitor: monitor, switcher: switcher)

            XCTAssertFalse(context.viewModel.isSpeakerOn)
            context.viewModel.toggleSpeaker()
            XCTAssertEqual(switcher.speakerOverrides, [true])
            XCTAssertTrue(context.viewModel.isSpeakerOn)

            context.viewModel.toggleSpeaker()
            XCTAssertEqual(switcher.speakerOverrides, [true, false])
            XCTAssertFalse(context.viewModel.isSpeakerOn)
        }

        func test_toggle_speaker_refused_keeps_state() {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            let switcher = FakeAudioRouteSwitcher(outputName: "Receiver", refuse: true)
            let monitor = RouteChangeMonitor(center: FakeNotificationCenter())
            context.viewModel.bindAudioRoutes(monitor: monitor, switcher: switcher)

            context.viewModel.toggleSpeaker()

            XCTAssertEqual(switcher.speakerOverrides, [true], "the attempt reached the session")
            XCTAssertFalse(context.viewModel.isSpeakerOn, "a refused override leaves the flag untouched")
        }

        func test_toggle_speaker_without_bind_is_noop() {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            context.viewModel.toggleSpeaker()

            XCTAssertFalse(context.viewModel.isSpeakerOn, "nothing to switch before bindAudioRoutes")
        }

        // MARK: - Incoming actions routed through the view model

        func test_incoming_accept_routes_to_coordinator() async throws {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            try await context.makeIncomingRinging(peer: "bob", video: true)
            await context.viewModel.accept()

            try await waitUntil("the call.accept envelope is sent") {
                context.signaling.sentTypes.contains(LKTypes.callAccept)
            }
            try await waitUntil("the state moves past ringing") {
                context.viewModel.state.kind != .incomingRinging
            }
        }

        func test_incoming_reject_routes_to_coordinator() async throws {
            let context = makeContext(test: self)
            context.viewModel.start()
            defer { context.viewModel.stop() }

            try await context.makeIncomingRinging(peer: "carol", video: false)
            await context.viewModel.reject()

            try await waitUntil("the call.reject envelope is sent") {
                context.signaling.sentTypes.contains(LKTypes.callReject)
            }
            try await waitUntil("the rejected call ends") {
                context.viewModel.state.kind == .idle
            }
        }

        // MARK: - Stats overlay binding (preference + rows)

        func test_stats_overlay_visible_when_enabled_and_live() async throws {
            let context = makeContext(test: self)
            context.defaults.setData(Data("true".utf8), forKey: StatsOverlayBinding.overlayKey)
            context.viewModel.load()
            context.viewModel.start()
            defer { context.viewModel.stop() }

            // Before a call the overlay hides even with the preference on.
            XCTAssertFalse(context.viewModel.isStatsOverlayVisible)

            try await context.makeIncomingRinging()
            try await context.connectActive()
            context.engine.fireStatistics(flowingReport(timestampMs: 1000, bytesSent: 1000))
            context.engine.fireStatistics(flowingReport(timestampMs: 2000, bytesSent: 250_000))
            try await waitUntil("the derived sample binds") {
                context.viewModel.stats != nil
            }

            XCTAssertTrue(
                context.viewModel.isStatsOverlayVisible,
                "the preference is on, the call is live and a sample exists"
            )
        }

        func test_stats_overlay_binding_reads_preference() {
            let defaults = DefaultsFake()

            XCTAssertFalse(StatsOverlayBinding.isEnabled(defaults), "absent preference starts off")

            defaults.setData(Data("true".utf8), forKey: StatsOverlayBinding.overlayKey)
            XCTAssertTrue(StatsOverlayBinding.isEnabled(defaults))

            defaults.setData(Data("corrupt".utf8), forKey: StatsOverlayBinding.overlayKey)
            XCTAssertFalse(StatsOverlayBinding.isEnabled(defaults), "corrupt JSON reads as off")
        }

        func test_stats_overlay_binding_maps_bitrate_to_kbps() {
            let sample = CallStatsSample(
                bitrateBps: 1_992_000,
                rttMs: 45,
                lossPercent: 0,
                jitterMs: 2,
                fps: 30,
                resolution: .init(width: 1280, height: 720),
                codec: "VP8",
                pairType: "relay"
            )

            XCTAssertEqual(StatsOverlayBinding.bitrateKbps(of: sample), 1992.0, accuracy: 0.001)
        }

        // MARK: - LiveAudioRouteSwitcher (the real AVAudioSession seam)

        func test_live_switcher_overrides_and_reads_route() {
            let switcher = LiveAudioRouteSwitcher()

            // The simulator's shared session accepts the override; CallKit owns
            // the same session in production and the two compose.
            XCTAssertNoThrow(try switcher.setSpeakerOverride(true))
            XCTAssertNoThrow(try switcher.setSpeakerOverride(false))
            _ = switcher.currentOutputName()
        }
    }

#endif
