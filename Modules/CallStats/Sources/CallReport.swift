// CallReport (Plan 4 Task 8): the flat end-of-call quality summary the
// coordinator uploads through ReportsClient (POST /api/v1/calls/{callId}/
// report, body ≤ 8 KiB). The server stores the JSON verbatim; the
// aggregation keeps the body flat no matter how long the call ran.

import Foundation

public struct CallReport: Codable, Equatable, Sendable {
    public let callId: String
    public let setupMs: Int
    public let endReason: String
    public let avgRttMs: Double
    public let peakRttMs: Double
    public let lossPercent: Double
    public let bitrateBps: Int
    public let pairType: String?

    public init(
        callId: String,
        setupMs: Int,
        endReason: String,
        avgRttMs: Double,
        peakRttMs: Double,
        lossPercent: Double,
        bitrateBps: Int,
        pairType: String?
    ) {
        self.callId = callId
        self.setupMs = setupMs
        self.endReason = endReason
        self.avgRttMs = avgRttMs
        self.peakRttMs = peakRttMs
        self.lossPercent = lossPercent
        self.bitrateBps = bitrateBps
        self.pairType = pairType
    }

    /// Aggregates the call's samples: average and peak RTT, average loss and
    /// bitrate; the pair type is the last observed one (the winning pair at
    /// the end). An empty call reports zeros and no pair type.
    public static func build(
        callId: String,
        setupMs: Int,
        endReason: String,
        samples: [CallStatsSample]
    ) -> CallReport {
        let count = Double(samples.count)
        let avgRtt = samples.map(\.rttMs).reduce(0, +) / max(count, 1)
        let peakRtt = samples.map(\.rttMs).max() ?? 0
        let loss = samples.map(\.lossPercent).reduce(0, +) / max(count, 1)
        let bitrate = Double(samples.map(\.bitrateBps).reduce(0, +)) / max(count, 1)
        return CallReport(
            callId: callId,
            setupMs: setupMs,
            endReason: endReason,
            avgRttMs: avgRtt,
            peakRttMs: peakRtt,
            lossPercent: loss,
            bitrateBps: Int(bitrate.rounded()),
            pairType: samples.last(where: { $0.pairType != nil })?.pairType
        )
    }

    /// The JSON body for the report endpoint: a flat object that stays well
    /// under the server's 8 KiB gate for any realistic call.
    public func asJSON() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(bytes: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}
