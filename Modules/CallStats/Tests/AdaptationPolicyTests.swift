// AdaptationPolicy tests (Plan 4 Task 8 / LNK-34): the pure bitrate plan.
// Cut #3 applied (spec §1): only the cellular / Low-Data-Mode video cap
// ships — Wi-Fi stays uncapped; thermal resolution drops and audio-only
// fallback remain roadmap (the BitratePlan shape keeps room for them).

import CallEngine
@testable import CallStats
import XCTest

final class AdaptationPolicyTests: XCTestCase {
    private let policy = AdaptationPolicy()

    // MARK: - Plan test name: test_policy_caps_bitrate_on_cellular

    func test_policy_caps_bitrate_on_cellular() {
        let plan = policy.plan(state: NetworkState(interface: .cellular, isLowDataMode: false))

        XCTAssertEqual(plan.maxVideoBitrateBps, 500_000)
    }

    // MARK: - Plan test name: test_policy_caps_on_low_data_mode

    func test_policy_caps_on_low_data_mode() {
        let plan = policy.plan(state: NetworkState(interface: .wifi, isLowDataMode: true))

        XCTAssertEqual(plan.maxVideoBitrateBps, 500_000)
    }

    // MARK: - Plan test name: test_policy_uncapped_on_wifi

    func test_policy_uncapped_on_wifi() {
        let plan = policy.plan(state: NetworkState(interface: .wifi, isLowDataMode: false))

        XCTAssertNil(plan.maxVideoBitrateBps, "nil is the uncapped default")
    }

    func test_policy_cap_constant_is_builder_tunable() {
        let tuned = AdaptationPolicy(cellularCapBps: 250_000)
        let plan = tuned.plan(state: NetworkState(interface: .cellular, isLowDataMode: false))

        XCTAssertEqual(plan.maxVideoBitrateBps, 250_000)
    }
}
