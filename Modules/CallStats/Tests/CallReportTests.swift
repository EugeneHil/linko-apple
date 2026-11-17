// CallReport tests (Plan 4 Task 8 / LNK-34): the flat end-of-call quality
// summary (callId, setupMs, endReason, avg/peak RTT, loss, bitrate, candidate
// pair type) that the coordinator uploads through ReportsClient. The
// aggregation keeps the JSON body far below the server's 8 KiB gate no
// matter how long the call ran.

@testable import CallStats
import Foundation
import XCTest

final class CallReportTests: XCTestCase {
    // MARK: - Plan test name: test_report_json_shape_and_size

    func test_report_json_shape_and_size() throws {
        // Five thousand samples — an hour at the 1 s cadence — must stay
        // flat: the aggregation collapses the samples into scalars.
        let samples = (0 ..< 5000).map { index in
            CallStatsSample(
                bitrateBps: 250_000,
                rttMs: 40 + Double(index % 10),
                lossPercent: 0.5,
                jitterMs: 15,
                fps: 30,
                resolution: CallStatsSample.Resolution(width: 1280, height: 720),
                codec: "VP8",
                pairType: index == 4999 ? "relay" : "host"
            )
        }
        let report = CallReport.build(
            callId: String(repeating: "a", count: 128),
            setupMs: 950,
            endReason: "remote-hangup",
            samples: samples
        )

        let json = report.asJSON()

        XCTAssertLessThanOrEqual(json.utf8.count, 8192, "the server rejects report bodies over 8 KiB")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["callId", "setupMs", "endReason", "avgRttMs", "peakRttMs", "lossPercent", "bitrateBps", "pairType"]
        )
        let decoded = try JSONDecoder().decode(CallReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, report, "the JSON roundtrips through the Codable shape")
    }

    func test_report_aggregates_samples() {
        let first = sample(bitrateBps: 200_000, rttMs: 30, lossPercent: 1, pairType: "host")
        let second = sample(bitrateBps: 400_000, rttMs: 50, lossPercent: 2, pairType: nil)
        let third = sample(bitrateBps: 300_000, rttMs: 40, lossPercent: 3, pairType: "relay")
        let report = CallReport.build(
            callId: "call-1",
            setupMs: 120,
            endReason: "hangup",
            samples: [first, second, third]
        )

        XCTAssertEqual(report.callId, "call-1")
        XCTAssertEqual(report.setupMs, 120)
        XCTAssertEqual(report.endReason, "hangup")
        XCTAssertEqual(report.avgRttMs, 40.0, accuracy: 0.001)
        XCTAssertEqual(report.peakRttMs, 50.0, accuracy: 0.001)
        XCTAssertEqual(report.lossPercent, 2.0, accuracy: 0.001)
        XCTAssertEqual(report.bitrateBps, 300_000)
        XCTAssertEqual(report.pairType, "relay", "the pair type at the end of the call")
    }

    func test_report_of_empty_call_is_flat_zeros() {
        let report = CallReport.build(callId: String(repeating: "b", count: 64), setupMs: 120, endReason: "missed", samples: [])

        XCTAssertEqual(report.avgRttMs, 0)
        XCTAssertEqual(report.peakRttMs, 0)
        XCTAssertEqual(report.lossPercent, 0)
        XCTAssertEqual(report.bitrateBps, 0)
        XCTAssertNil(report.pairType)
        XCTAssertLessThanOrEqual(report.asJSON().utf8.count, 8192, "even a maximal callId keeps the body far under the gate")
    }

    private func sample(bitrateBps: Int, rttMs: Double, lossPercent: Double, pairType: String?) -> CallStatsSample {
        CallStatsSample(
            bitrateBps: bitrateBps,
            rttMs: rttMs,
            lossPercent: lossPercent,
            jitterMs: 15,
            fps: nil,
            resolution: nil,
            codec: nil,
            pairType: pairType
        )
    }
}
