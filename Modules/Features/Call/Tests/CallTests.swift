// Call (Plan 4 Task 13 part 1, LNK-39): the view model binds the
// coordinator's call and stats streams, the tray and incoming actions route
// to the coordinator, and the stats overlay honors the Settings preference
// (the io.github.eugenehil.linko.stats-overlay key through the defaults
// seam). The plan's test_incoming_call_mac_window_shown is part 2 (LNK-36's
// MacCallPresenter owns window presentation); the incoming surface is
// tested here as its view's action routing.

@testable import Call
import CallEngine
import Calls
import CallStats
import CoreBridge
import Foundation
import ServerAPI
import Settings
import XCTest

@MainActor
final class CallTests: XCTestCase {
    func test_call_view_model_binds_state_and_stats() async throws {
        let context = makeContext(test: self)
        context.viewModel.start()

        try await context.makeIncomingRinging(peer: "bob", video: true)
        try await context.connectActive()

        try await waitUntil("the view model binds the active state") {
            context.viewModel.state.kind == .active
        }
        XCTAssertEqual(context.viewModel.state.peer, "bob")
        XCTAssertTrue(context.viewModel.state.video)

        // Two flowing reports a second apart: the newest derived sample
        // binds (bitrate over the delta, the pair's round-trip time).
        context.engine.fireStatistics(flowingReport(timestampMs: 1000, bytesSent: 1000))
        context.engine.fireStatistics(flowingReport(timestampMs: 2000, bytesSent: 250_000))
        try await waitUntil("the view model binds the derived sample") {
            context.viewModel.stats?.bitrateBps == 1_992_000
        }
        XCTAssertEqual(context.viewModel.stats?.rttMs ?? 0, 45, accuracy: 0.1)
        XCTAssertEqual(context.viewModel.stats?.lossPercent ?? 0, 0, accuracy: 0.1)
        XCTAssertEqual(context.viewModel.stats?.pairType, "relay")

        context.viewModel.stop()
    }

    func test_tray_actions_route_to_coordinator() async throws {
        let context = makeContext(test: self)
        context.viewModel.start()

        try await context.makeIncomingRinging()
        try await context.connectActive()

        await context.viewModel.toggleMute()
        try await waitUntil("the engine's mute flips") {
            !context.engine.mutes.isEmpty
        }
        XCTAssertEqual(context.engine.mutes, [true])
        XCTAssertTrue(context.viewModel.isMuted, "the tray's mute state flips with the action")

        await context.viewModel.toggleCamera()
        XCTAssertFalse(context.viewModel.isCameraOn, "the camera flag flips locally")
        try await waitUntil("the engine's video toggle routes through the coordinator") {
            context.engine.videoEnables == [false]
        }
        await context.viewModel.toggleCamera()
        try await waitUntil("the re-enable reaches the engine") {
            context.engine.videoEnables == [false, true]
        }

        await context.viewModel.hangup()
        try await waitUntil("the hangup envelope is sent") {
            context.signaling.sentTypes.contains(LKTypes.callHangup)
        }
        try await waitUntil("the call ends") {
            context.viewModel.state.kind == .idle
        }
        XCTAssertFalse(context.viewModel.isMuted, "the tray flags reset with the call")
        XCTAssertTrue(context.viewModel.isCameraOn)

        context.viewModel.stop()
    }

    func test_stats_overlay_hidden_when_disabled() async throws {
        // The binding's key is the Settings toggle's storage key — one
        // literal, pinned so the two modules cannot drift.
        XCTAssertEqual(StatsOverlayBinding.overlayKey, SettingsViewModel.statsOverlayKey)

        let context = makeContext(test: self)
        context.viewModel.start()
        context.viewModel.load()
        XCTAssertFalse(context.viewModel.statsOverlayEnabled, "the overlay starts off")

        try await context.makeIncomingRinging()
        try await context.connectActive()
        context.engine.fireStatistics(flowingReport(timestampMs: 1000, bytesSent: 1000))
        context.engine.fireStatistics(flowingReport(timestampMs: 2000, bytesSent: 250_000))
        try await waitUntil("a sample arrives") {
            context.viewModel.stats != nil
        }
        XCTAssertFalse(
            context.viewModel.isStatsOverlayVisible,
            "the overlay stays hidden while the Settings preference is off"
        )

        // The preference flips through the same defaults seam Settings
        // writes (Bool JSON under the stats-overlay key).
        try context.defaults.setData(JSONEncoder().encode(true), forKey: StatsOverlayBinding.overlayKey)
        context.viewModel.load()
        XCTAssertTrue(context.viewModel.statsOverlayEnabled)
        XCTAssertTrue(context.viewModel.isStatsOverlayVisible, "the overlay shows once enabled and a sample arrived")

        context.viewModel.stop()
    }

    // The macOS ringing surface's routing test (the plan's
    // test_incoming_call_mac_window_shown, adapted to part 1 scope: the
    // view exists here, its window presentation is part 2 / LNK-36).
    #if os(macOS)
        func test_incoming_call_view_routes_actions_to_coordinator() async throws {
            // The macOS ringing surface: accept routes to the coordinator.
            let accepted = makeContext(test: self)
            accepted.viewModel.start()
            try await accepted.makeIncomingRinging(peer: "bob", video: false)
            try await waitUntil("the view model binds the ringing state") {
                accepted.viewModel.state.kind == .incomingRinging
            }
            let view = IncomingCallView(viewModel: accepted.viewModel)
            XCTAssertEqual(view.peer, "bob")
            XCTAssertFalse(view.isVideo)

            view.accept()
            try await waitUntil("the call.accept envelope is sent") {
                accepted.signaling.sentTypes.contains(LKTypes.callAccept)
            }
            try await waitUntil("the state moves past ringing") {
                accepted.viewModel.state.kind == .connecting
            }
            accepted.viewModel.stop()

            // A fresh call: reject routes to the coordinator and ends it.
            let rejected = makeContext(test: self)
            rejected.viewModel.start()
            try await rejected.makeIncomingRinging(peer: "carol", video: true)
            try await waitUntil("the second ringing state binds") {
                rejected.viewModel.state.kind == .incomingRinging
            }
            let rejectView = IncomingCallView(viewModel: rejected.viewModel)
            XCTAssertEqual(rejectView.peer, "carol")
            XCTAssertTrue(rejectView.isVideo)

            rejectView.reject()
            try await waitUntil("the call.reject envelope is sent") {
                rejected.signaling.sentTypes.contains(LKTypes.callReject)
            }
            try await waitUntil("the rejected call ends") {
                rejected.viewModel.state.kind == .idle
            }
            rejected.viewModel.stop()
        }
    #endif
}
