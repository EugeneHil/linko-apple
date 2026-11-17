// Settings (Plan 4 Task 12): server, SPKI pin and account read from the
// persisted SessionConfig, the local device id row (no client-facing
// devices endpoint in server v0.1 — cut), and the stats overlay toggle
// persisted through the defaults seam.

import Foundation
import Messaging
import ServerAPI
@testable import Settings
import XCTest

@MainActor
final class SettingsTests: XCTestCase {
    private let config = SessionConfig(
        host: "chat.example", port: 8443, pin: "SPKIPIN1", username: "anna"
    )

    private func makeViewModel(
        defaults: DefaultsFake
    ) -> (SettingsViewModel, AsyncStream<MessagingEvent>.Continuation) {
        let events = AsyncStream.makeStream(of: MessagingEvent.self)
        let viewModel = SettingsViewModel(
            configStore: SessionConfigStore(defaults: defaults),
            defaults: defaults,
            deviceId: "7",
            events: events.stream
        )
        return (viewModel, events.continuation)
    }

    func test_settings_shows_pin_and_account() throws {
        let defaults = DefaultsFake()
        try SessionConfigStore(defaults: defaults).persist(config)
        let (viewModel, _) = makeViewModel(defaults: defaults)

        viewModel.load()

        XCTAssertEqual(viewModel.serverText, "chat.example:8443")
        XCTAssertEqual(viewModel.pinText, "SPKIPIN1")
        XCTAssertEqual(viewModel.accountText, "anna")
        XCTAssertEqual(viewModel.deviceIdText, "7", "the devices row shows the local device id only")
    }

    func test_stats_overlay_toggle_persists() {
        let defaults = DefaultsFake()
        let (viewModel, _) = makeViewModel(defaults: defaults)

        viewModel.load()
        XCTAssertFalse(viewModel.statsOverlayEnabled, "the overlay starts off")

        viewModel.statsOverlayEnabled = true
        XCTAssertEqual(
            persistedBool(defaults, key: SettingsViewModel.statsOverlayKey),
            true,
            "toggling on persists through the defaults seam"
        )

        viewModel.statsOverlayEnabled = false
        XCTAssertEqual(
            persistedBool(defaults, key: SettingsViewModel.statsOverlayKey),
            false,
            "toggling off persists too"
        )

        let (reloaded, _) = makeViewModel(defaults: defaults)
        reloaded.load()
        XCTAssertFalse(reloaded.statsOverlayEnabled, "a fresh view model reads the persisted value")
    }

    func test_settings_offline_banner_surfaces_on_disconnect() async throws {
        let defaults = DefaultsFake()
        try SessionConfigStore(defaults: defaults).persist(config)
        let (viewModel, events) = makeViewModel(defaults: defaults)

        viewModel.start()
        events.yield(.connectionChanged(online: false))
        let offline = await waitFor(!viewModel.online)
        XCTAssertTrue(offline)
        XCTAssertTrue(viewModel.showOfflineBanner)
        viewModel.stop()
    }
}
