// StatsDeriver tests (Plan 4 Task 8 / LNK-34): the pure derivation from two
// consecutive raw WebRTC statistics reports into a CallStatsSample —
// nominated pair selection, byte-delta bitrate, and graceful handling of
// missing video stats. nil only before a pair is nominated.

import CallEngine
@testable import CallStats
import XCTest

final class StatsDeriverTests: XCTestCase {
    private let deriver = StatsDeriver()

    // MARK: - Plan test name: test_deriver_selects_nominated_pair

    func test_deriver_selects_nominated_pair() throws {
        let timestamp = 1000.0
        let current = StatsFixtures.report(
            StatsFixtures.entry(
                id: "pair-a",
                type: "candidate-pair",
                timestampMs: timestamp,
                values: ("state", .string("succeeded")), ("nominated", .boolean(false))
            ),
            StatsFixtures.entry(
                id: "pair-b",
                type: "candidate-pair",
                timestampMs: timestamp,
                values: ("state", .string("succeeded")), ("nominated", .boolean(true)),
                ("currentRoundTripTime", .number(0.045)), ("localCandidateId", .string("cand-relay"))
            ),
            StatsFixtures.entry(
                id: "pair-c",
                type: "candidate-pair",
                timestampMs: timestamp,
                values: ("state", .string("failed")), ("nominated", .boolean(true))
            ),
            StatsFixtures.entry(
                id: "cand-relay",
                type: "local-candidate",
                timestampMs: timestamp,
                values: ("candidateType", .string("relay"))
            ),
            StatsFixtures.entry(
                id: "cand-host",
                type: "local-candidate",
                timestampMs: timestamp,
                values: ("candidateType", .string("host"))
            )
        )

        let sample = try XCTUnwrap(deriver.derive(previous: nil, current: current))

        XCTAssertEqual(sample.rttMs, 45.0, accuracy: 0.001, "the nominated succeeded pair's RTT, in ms")
        XCTAssertEqual(sample.pairType, "relay", "the nominated pair's local candidate type")
        XCTAssertEqual(sample.bitrateBps, 0, "no previous report means no byte delta yet")
        XCTAssertEqual(sample.lossPercent, 0, accuracy: 0.001, "no previous report means no loss delta yet")
    }

    // MARK: - Plan test name: test_deriver_bitrate_from_byte_delta

    func test_deriver_bitrate_from_byte_delta() throws {
        let previous = StatsFixtures.flowingReport(
            timestampMs: 1000,
            bytesSent: 10000,
            packetsLost: 2,
            packetsReceived: 98,
            jitterSeconds: 0.02
        )
        let current = StatsFixtures.flowingReport(
            timestampMs: 2000,
            bytesSent: 16000,
            packetsLost: 3,
            packetsReceived: 198,
            jitterSeconds: 0.03
        )

        let sample = try XCTUnwrap(deriver.derive(previous: previous, current: current))

        XCTAssertEqual(sample.bitrateBps, 48000, "6000 bytes over exactly 1 s is 48 kbps")
        XCTAssertEqual(sample.rttMs, 45.0, accuracy: 0.001)
        XCTAssertEqual(sample.lossPercent, 0.99, accuracy: 0.001, "1 lost of the 101 delta packets")
        XCTAssertEqual(sample.jitterMs, 30.0, accuracy: 0.001, "current inbound jitter, in ms")
        XCTAssertEqual(try XCTUnwrap(sample.fps), 30.0, accuracy: 0.001)
        XCTAssertEqual(sample.resolution, CallStatsSample.Resolution(width: 1280, height: 720))
        XCTAssertEqual(sample.codec, "VP8", "the codec name after the MIME type slash")
        XCTAssertEqual(sample.pairType, "relay")
    }

    // MARK: - Plan test name: test_deriver_handles_missing_video_stats

    func test_deriver_handles_missing_video_stats() throws {
        // An audio-only call: no outbound-rtp and no codec entries at all;
        // the sample still derives with the video fields nil.
        let timestamp = 1000.0
        let current = StatsFixtures.report(
            StatsFixtures.entry(
                id: "pair-b",
                type: "candidate-pair",
                timestampMs: timestamp,
                values: ("state", .string("succeeded")), ("nominated", .boolean(true)),
                ("currentRoundTripTime", .number(0.05)), ("localCandidateId", .string("cand-host"))
            ),
            StatsFixtures.entry(
                id: "cand-host",
                type: "local-candidate",
                timestampMs: timestamp,
                values: ("candidateType", .string("host"))
            ),
            StatsFixtures.entry(
                id: "iaudio",
                type: "inbound-rtp",
                timestampMs: timestamp,
                values: ("kind", .string("audio")), ("jitter", .number(0.02)),
                ("packetsLost", .number(0)), ("packetsReceived", .number(150))
            )
        )

        let sample = try XCTUnwrap(deriver.derive(previous: nil, current: current))

        XCTAssertEqual(sample.bitrateBps, 0)
        XCTAssertEqual(sample.rttMs, 50.0, accuracy: 0.001)
        XCTAssertEqual(sample.jitterMs, 20.0, accuracy: 0.001)
        XCTAssertEqual(sample.lossPercent, 0, accuracy: 0.001)
        XCTAssertNil(sample.fps)
        XCTAssertNil(sample.resolution)
        XCTAssertNil(sample.codec)
        XCTAssertEqual(sample.pairType, "host")
    }

    // MARK: - Plan test name: test_deriver_nil_before_nominated_pair

    func test_deriver_nil_before_nominated_pair() {
        let previous = StatsFixtures.preNominationReport(timestampMs: 1000)
        let current = StatsFixtures.preNominationReport(timestampMs: 2000)

        XCTAssertNil(deriver.derive(previous: nil, current: current), "no report carries a nominated pair")
        XCTAssertNil(deriver.derive(previous: previous, current: current), "a succeeded but unnominated pair is not enough")
    }
}
