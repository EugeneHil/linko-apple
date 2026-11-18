// SmokeTests (Plan 4 Task 13 part 2, LNK-39): the composition smoke — the
// real root builds the full session graph over a synthetic config (no
// force unwraps, build failure surfaces as a nil the test asserts on) —
// and the launch smoke — the test host boots the real app, which seeds a
// synthetic session and composes the chats phase.

import Calls
@testable import LinkoiOS
import ServerAPI
import XCTest

/// In-memory DefaultsWriting (the Settings test target's shape).
private final class SmokeDefaults: DefaultsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func setData(_ data: Data, forKey key: String) {
        lock.withLock { storage[key] = data }
    }

    func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func removeObject(forKey key: String) {
        lock.withLock { _ = storage.removeValue(forKey: key) }
    }
}

@MainActor
final class CompositionSmokeTests: XCTestCase {
    func test_ios_root_builds_full_graph() async throws {
        let defaults = SmokeDefaults()
        let configStore = SessionConfigStore(defaults: defaults)
        let config = SessionConfig(
            host: "smoke.linko.test",
            port: 443,
            pin: "c21va2Rldg==",
            username: "smoke-user"
        )

        let graph = await SessionGraph.build(
            config: config,
            deviceId: "42",
            defaults: defaults,
            configStore: configStore,
            makeReporting: makePlatformReporting
        )

        let unwrapped = try XCTUnwrap(graph, "the graph builds over a valid config")
        XCTAssertFalse(unwrapped.callLayout.showsCallScreen, "no call is live at composition")
        XCTAssertEqual(unwrapped.coordinator.currentState.kind, .idle)
        XCTAssertTrue(unwrapped.chatsViewModel.rows.isEmpty)
        // A conversation view model composes from the graph's multiplexer
        // branches (its streams are subscribed lazily per selection).
        let conversation = unwrapped.makeConversationViewModel(peer: "bob")
        XCTAssertTrue(conversation.rows.isEmpty)
        unwrapped.stop()
    }
}

@MainActor
final class LaunchSmokeTests: XCTestCase {
    func test_app_launches_and_shows_chats() async throws {
        // The app booted as this bundle's test host; its root seeded the
        // synthetic session and composed the graph from the root view's
        // task. The signaling client's background reconnect loop against
        // the unroutable smoke host is harmless.
        let deadline = Date().addingTimeInterval(10)
        while !(RootState.shared?.phase == .chats && RootState.shared?.graph != nil) {
            guard Date() < deadline else {
                XCTFail("the app did not reach the chats phase within 10 s")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let graph = try XCTUnwrap(RootState.shared?.graph)
        XCTAssertEqual(graph.config.username, "smoke-user")
        XCTAssertEqual(graph.deviceId, "42")
        XCTAssertFalse(graph.callLayout.showsCallScreen)
    }
}
