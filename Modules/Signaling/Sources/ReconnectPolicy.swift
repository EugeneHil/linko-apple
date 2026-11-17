// Reconnect backoff (Plan 4 Task 4): full jitter over an exponential curve —
// base 1 s, doubling per consecutive failed attempt, capped at 30 s. The
// random source is a parameter so the policy is a pure function, testable
// without clocks (spec 7: Swift Concurrency only; no timers to mock here).

import Foundation

public enum ReconnectPolicy {
    /// Backoff for the first attempt.
    public static let base: Duration = .seconds(1)
    /// Upper bound for any single delay.
    public static let cap: Duration = .seconds(30)

    /// 2^5 = 32 s exceeds the cap, so larger attempts clamp at the cap.
    private static let maxExponent = 5

    /// Delay before reconnect attempt `attempt` (0-based). `random` is the
    /// uniform random draw in [0, 1] (out-of-range values are clamped); the
    /// result is uniform in [0, min(base * 2^attempt, cap)] — AWS-style full
    /// jitter, which avoids reconnect stampedes after a server restart.
    public static func nextDelay(attempt: Int, random: Double) -> Duration {
        let exponent = min(max(attempt, 0), maxExponent)
        let uncappedSeconds = Double(1 << exponent)
        let cappedSeconds = min(uncappedSeconds, 30)
        let jitter = min(max(random, 0), 1)
        return .seconds(cappedSeconds * jitter)
    }
}
