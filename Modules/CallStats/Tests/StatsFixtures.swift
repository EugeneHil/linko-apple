// Shared RawStatsReport fixtures for the CallStats tests (Plan 4 Task 8).
// The shapes mirror what StatsConversion passes through from libwebrtc:
// candidate-pair state/nominated/currentRoundTripTime, local-candidate
// candidateType, outbound-rtp kind/bytesSent/frameWidth/frameHeight/codecId
// and inbound-rtp packetsLost/packetsReceived/jitter, all keyed by stats id.
// Variadic builders keep fixtures free of multi-line collection literals
// (the SwiftFormat trailingCommas vs SwiftLint trailing_comma conflict).

import CallEngine
@testable import CallStats
import Foundation

enum StatsFixtures {
    static func entry(
        id: String,
        type: String,
        timestampMs: Double,
        values pairs: (String, RawStatValue)...
    ) -> RawStatsReport.Entry {
        var dict: [String: RawStatValue] = [:]
        for (key, value) in pairs {
            dict[key] = value
        }
        return RawStatsReport.Entry(id: id, type: type, timestampMs: timestampMs, values: dict)
    }

    static func report(_ entries: RawStatsReport.Entry...) -> RawStatsReport {
        var keyed: [String: RawStatsReport.Entry] = [:]
        for entry in entries {
            keyed[entry.id] = entry
        }
        return RawStatsReport(entries: keyed)
    }

    /// One succeeded candidate pair that has not been nominated yet — the
    /// state before connectivity is established (plan test 4).
    static func preNominationReport(timestampMs: Double) -> RawStatsReport {
        report(
            entry(
                id: "pair-a",
                type: "candidate-pair",
                timestampMs: timestampMs,
                values: ("state", .string("succeeded")), ("nominated", .boolean(false))
            )
        )
    }

    /// The flowing call: nominated succeeded pair over a relay, one outbound
    /// video stream (VP8, 1280x720 @ 30 fps) and one inbound audio stream.
    static func flowingReport(
        timestampMs: Double,
        bytesSent: Int,
        packetsLost: Int,
        packetsReceived: Int,
        jitterSeconds: Double
    ) -> RawStatsReport {
        report(
            entry(
                id: "pair-b",
                type: "candidate-pair",
                timestampMs: timestampMs,
                values: ("state", .string("succeeded")), ("nominated", .boolean(true)),
                ("currentRoundTripTime", .number(0.045)), ("localCandidateId", .string("cand-relay"))
            ),
            entry(
                id: "cand-relay",
                type: "local-candidate",
                timestampMs: timestampMs,
                values: ("candidateType", .string("relay"))
            ),
            entry(
                id: "ovideo",
                type: "outbound-rtp",
                timestampMs: timestampMs,
                values: ("kind", .string("video")), ("bytesSent", .number(Double(bytesSent))),
                ("framesPerSecond", .number(30)), ("frameWidth", .number(1280)),
                ("frameHeight", .number(720)), ("codecId", .string("codec-vp8"))
            ),
            entry(
                id: "codec-vp8",
                type: "codec",
                timestampMs: timestampMs,
                values: ("mimeType", .string("video/VP8"))
            ),
            entry(
                id: "iaudio",
                type: "inbound-rtp",
                timestampMs: timestampMs,
                values: ("kind", .string("audio")), ("packetsLost", .number(Double(packetsLost))),
                ("packetsReceived", .number(Double(packetsReceived))), ("jitter", .number(jitterSeconds))
            )
        )
    }
}
