// TDD tests (Plan 4 Task 4 / LNK-30, Step 1) for ReconnectPolicy: full jitter
// over an exponential curve — base 1 s, doubling per attempt, capped at 30 s —
// as a pure function of (attempt, random) so it is testable without clocks.

@testable import Signaling
import XCTest

final class ReconnectPolicyTests: XCTestCase {
    // MARK: - Plan test name: test_reconnect_backoff_jittered_and_capped

    func test_reconnect_backoff_jittered_and_capped() {
        // Full jitter: uniform in [0, delay) — random 0 collapses to zero.
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 0, random: 0), .seconds(0))
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 0, random: 0.5), .seconds(0.5))
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 0, random: 1), .seconds(1), "attempt 0 tops out at the 1 s base")

        // Doubling per attempt.
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 1, random: 1), .seconds(2))
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 2, random: 1), .seconds(4))
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 3, random: 0.25), .seconds(2))

        // The cap: 2^5 = 32 s would exceed 30 s, and later attempts stay capped.
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 5, random: 1), .seconds(30), "the delay is capped at 30 s")
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 10, random: 1), .seconds(30), "long failure streaks stay capped")
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 10, random: 0), .seconds(0), "jitter still spans [0, cap)")

        // Out-of-range random values are clamped into [0, 1] instead of
        // producing negative or oversized delays.
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 0, random: -3), .seconds(0))
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 0, random: 7), .seconds(1))
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: 9, random: 7), .seconds(30))

        // A negative attempt is treated as 0.
        XCTAssertEqual(ReconnectPolicy.nextDelay(attempt: -1, random: 1), .seconds(1))
    }
}
