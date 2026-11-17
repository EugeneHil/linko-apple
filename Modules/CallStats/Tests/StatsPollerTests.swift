// StatsPoller tests (Plan 4 Task 8 / LNK-34): the Task-based poll loop at
// the 1 s production cadence (milliseconds-scale here — the CallEngine
// precedent) that reads one raw report per tick, derives a sample per
// nominated report and cancels with the call.

import CallEngine
@testable import CallStats
import Foundation
import XCTest

/// Hands back queued reports once each, then nil forever.
private final class CannedReading: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [RawStatsReport]

    init(reports: [RawStatsReport]) {
        self.reports = reports
    }

    func next() async -> RawStatsReport? {
        lock.withLock {
            reports.isEmpty ? nil : reports.removeFirst()
        }
    }
}

/// Answers every read with a fresh flowing report (monotonic counters) so
/// the poller keeps producing samples until it is stopped.
private final class EndlessReading: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesSent = 10000
    private var timestampMs = 1000.0

    func next() async -> RawStatsReport? {
        lock.withLock {
            bytesSent += 6000
            timestampMs += 1000
            return StatsFixtures.flowingReport(
                timestampMs: timestampMs,
                bytesSent: bytesSent,
                packetsLost: 2,
                packetsReceived: 198,
                jitterSeconds: 0.02
            )
        }
    }
}

final class StatsPollerTests: XCTestCase {
    func test_poller_derives_samples_from_reports() async throws {
        let preNomination = StatsFixtures.preNominationReport(timestampMs: 1000)
        let flowing = StatsFixtures.flowingReport(
            timestampMs: 2000,
            bytesSent: 16000,
            packetsLost: 3,
            packetsReceived: 198,
            jitterSeconds: 0.03
        )
        let reading = CannedReading(reports: [preNomination, flowing])
        let poller = StatsPoller(nextReport: { await reading.next() }, statsInterval: .milliseconds(20))

        await poller.start()
        try await Task.sleep(for: .milliseconds(400))
        await poller.stop()

        let samples = await poller.samples
        XCTAssertEqual(samples.count, 1, "exactly the nominated report derives a sample")
        let first = try XCTUnwrap(samples.first)
        XCTAssertEqual(first.rttMs, 45.0, accuracy: 0.001)
        XCTAssertEqual(first.bitrateBps, 0, "the first nominated report has no matching outbound prior")
    }

    func test_poller_stop_cancels_the_loop() async throws {
        let reading = EndlessReading()
        let poller = StatsPoller(nextReport: { await reading.next() }, statsInterval: .milliseconds(20))

        await poller.start()
        try await Task.sleep(for: .milliseconds(200))
        await poller.stop()

        let frozen = await poller.samples.count
        try await Task.sleep(for: .milliseconds(200))
        let afterWait = await poller.samples.count

        XCTAssertGreaterThan(frozen, 0, "the loop produced samples while running")
        XCTAssertEqual(frozen, afterWait, "no samples accrue after stop() cancels the loop")
    }
}
