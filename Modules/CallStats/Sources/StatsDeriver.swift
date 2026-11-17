// StatsDeriver (Plan 4 Task 8): the pure derivation from two consecutive
// RawStatsReports into a CallStatsSample. Nominated succeeded candidate-pair
// selection, bitrate from outbound byte deltas over the poll interval, loss
// and jitter from inbound deltas, codec/resolution from the video stream.
// Pure: no RTC types cross this file — only the CallEngine report values.

import CallEngine
import Foundation

/// One derived statistics sample at the poll cadence.
public struct CallStatsSample: Sendable, Equatable {
    public struct Resolution: Sendable, Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Outbound bitrate over the poll interval, all outbound streams summed.
    public let bitrateBps: Int
    /// Current round-trip time of the nominated pair, in milliseconds.
    public let rttMs: Double
    /// Inbound loss percentage over the poll interval.
    public let lossPercent: Double
    /// Current inbound jitter, in milliseconds.
    public let jitterMs: Double
    public let fps: Double?
    public let resolution: Resolution?
    public let codec: String?
    /// The local candidate's type of the nominated pair (host/srflx/relay).
    public let pairType: String?

    public init(
        bitrateBps: Int,
        rttMs: Double,
        lossPercent: Double,
        jitterMs: Double,
        fps: Double?,
        resolution: Resolution?,
        codec: String?,
        pairType: String?
    ) {
        self.bitrateBps = bitrateBps
        self.rttMs = rttMs
        self.lossPercent = lossPercent
        self.jitterMs = jitterMs
        self.fps = fps
        self.resolution = resolution
        self.codec = codec
        self.pairType = pairType
    }
}

/// The pure deriver (plan Task 8): a sample per report once a candidate
/// pair is nominated; nil before that. Everything else degrades to zeros or
/// nil when the underlying stats are absent (audio-only calls), never
/// crashes on a missing field.
public struct StatsDeriver: Sendable {
    public init() {}

    public func derive(previous: RawStatsReport?, current: RawStatsReport) -> CallStatsSample? {
        guard let pair = Self.nominatedPair(in: current) else { return nil }
        return CallStatsSample(
            bitrateBps: Self.bitrateBps(previous: previous, current: current),
            rttMs: (Self.number("currentRoundTripTime", in: pair.values) ?? 0) * 1000,
            lossPercent: Self.lossPercent(previous: previous, current: current),
            jitterMs: Self.jitterMs(in: current),
            fps: Self.fps(in: current),
            resolution: Self.resolution(in: current),
            codec: Self.codec(in: current),
            pairType: Self.pairType(of: pair, in: current)
        )
    }
}

// MARK: - Pure derivations

private extension StatsDeriver {
    /// The nominated succeeded candidate pair; ids are sorted so the choice
    /// is deterministic when several pairs qualify.
    static func nominatedPair(in report: RawStatsReport) -> RawStatsReport.Entry? {
        for id in report.entries.keys.sorted() {
            guard let entry = report.entries[id], entry.type == "candidate-pair",
                  string("state", in: entry.values) == "succeeded",
                  boolean("nominated", in: entry.values) == true
            else { continue }
            return entry
        }
        return nil
    }

    /// Outbound byte deltas over the poll interval, summed across the
    /// outbound streams; streams without a matching prior entry (just
    /// appeared, or first report) contribute nothing. A counters-reset
    /// (shrinking) delta is treated as no traffic.
    static func bitrateBps(previous: RawStatsReport?, current: RawStatsReport) -> Int {
        guard let previous else { return 0 }
        var total = 0.0
        for (id, entry) in current.entries where entry.type == "outbound-rtp" {
            guard let prior = previous.entries[id], prior.type == "outbound-rtp",
                  let nowBytes = number("bytesSent", in: entry.values),
                  let thenBytes = number("bytesSent", in: prior.values),
                  nowBytes >= thenBytes
            else { continue }
            let seconds = (entry.timestampMs - prior.timestampMs) / 1000
            guard seconds > 0 else { continue }
            total += (nowBytes - thenBytes) * 8 / seconds
        }
        return Int(total.rounded())
    }

    /// Inbound loss percentage over the poll interval; a counters-reset
    /// delta counts as no loss, and the result is clamped to 0...100.
    static func lossPercent(previous: RawStatsReport?, current: RawStatsReport) -> Double {
        guard let previous else { return 0 }
        var deltaLost = 0.0
        var deltaReceived = 0.0
        for (id, entry) in current.entries where entry.type == "inbound-rtp" {
            guard let prior = previous.entries[id], prior.type == "inbound-rtp" else { continue }
            let lost = (number("packetsLost", in: entry.values) ?? 0)
                - (number("packetsLost", in: prior.values) ?? 0)
            let received = (number("packetsReceived", in: entry.values) ?? 0)
                - (number("packetsReceived", in: prior.values) ?? 0)
            deltaLost += max(0, lost)
            deltaReceived += max(0, received)
        }
        let total = deltaLost + deltaReceived
        guard total > 0 else { return 0 }
        return min(100, deltaLost / total * 100)
    }

    /// The current inbound jitter (WebRTC reports seconds), preferring the
    /// video stream and falling back to the first inbound stream by id.
    static func jitterMs(in report: RawStatsReport) -> Double {
        let inbound = report.entries.values
            .filter { $0.type == "inbound-rtp" }
            .sorted { $0.id < $1.id }
        guard let entry = inbound.first(where: { string("kind", in: $0.values) == "video" }) ?? inbound.first,
              let jitter = number("jitter", in: entry.values)
        else { return 0 }
        return jitter * 1000
    }

    /// The video outbound stream, deterministically the first by id.
    static func videoOutbound(in report: RawStatsReport) -> RawStatsReport.Entry? {
        for id in report.entries.keys.sorted() {
            guard let entry = report.entries[id], entry.type == "outbound-rtp",
                  string("kind", in: entry.values) == "video"
            else { continue }
            return entry
        }
        return nil
    }

    static func fps(in report: RawStatsReport) -> Double? {
        guard let entry = videoOutbound(in: report) else { return nil }
        return number("framesPerSecond", in: entry.values)
    }

    static func resolution(in report: RawStatsReport) -> CallStatsSample.Resolution? {
        guard let entry = videoOutbound(in: report),
              let width = number("frameWidth", in: entry.values),
              let height = number("frameHeight", in: entry.values)
        else { return nil }
        return CallStatsSample.Resolution(width: Int(width), height: Int(height))
    }

    /// The codec name after the MIME type slash ("video/VP8" → "VP8"),
    /// resolved through the report's codec entry by the stream's codecId.
    static func codec(in report: RawStatsReport) -> String? {
        guard let entry = videoOutbound(in: report),
              let codecId = string("codecId", in: entry.values),
              let codecEntry = report.entries[codecId],
              let mimeType = string("mimeType", in: codecEntry.values),
              let slash = mimeType.lastIndex(of: "/")
        else { return nil }
        return String(mimeType[mimeType.index(after: slash)...])
    }

    /// The nominated pair's type: its local candidate's candidateType (the
    /// relay/srflx/host path this side sends on).
    static func pairType(of pair: RawStatsReport.Entry, in report: RawStatsReport) -> String? {
        guard let localId = string("localCandidateId", in: pair.values),
              let candidate = report.entries[localId]
        else { return nil }
        return string("candidateType", in: candidate.values)
    }

    static func number(_ key: String, in values: [String: RawStatValue]) -> Double? {
        if case let .number(value) = values[key] {
            return value
        }
        return nil
    }

    static func string(_ key: String, in values: [String: RawStatValue]) -> String? {
        if case let .string(value) = values[key] {
            return value
        }
        return nil
    }

    static func boolean(_ key: String, in values: [String: RawStatValue]) -> Bool? {
        if case let .boolean(value) = values[key] {
            return value
        }
        return nil
    }
}
