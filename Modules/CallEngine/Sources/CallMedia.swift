// CallMedia (Plan 4 Task 7): the engine's media values — the audio/video
// selection, the bitrate plan Task 8's adaptation policy produces and Task 7
// applies through the RTP sender seam, and the stream element types (ICE
// candidates, connection states, raw statistics reports). Pure values: none
// of them touches a WebRTC object, so CallStats (Task 8) derives over them
// without linking live RTC state.

import Foundation
import WebRTC

/// The media selection of a call: audio-only or audio+video. The raw value
/// matches the wire field of call.invite ("audio" / "video") so the call
/// coordinator (Task 9) maps it directly to LKCallInvite.
public enum CallMedia: String, Sendable {
    case audio
    case video
}

/// The encoding plan the adaptation policy (Task 8) produces. Only the
/// cellular / Low-Data-Mode video cap ships in v0.1 (cut #3); the shape
/// keeps room for resolution drops and audio caps.
public struct BitratePlan: Sendable, Equatable {
    /// nil = uncapped (the Wi-Fi default).
    public let maxVideoBitrateBps: Int?

    public init(maxVideoBitrateBps: Int?) {
        self.maxVideoBitrateBps = maxVideoBitrateBps
    }

    /// The sender-facing parameters this plan translates to (the pure,
    /// RTC-free mapping the tests exercise through the sender seam).
    public var encodingParameters: EncodingParameters {
        EncodingParameters(maxBitrateBps: maxVideoBitrateBps)
    }
}

/// The encoding parameters an RTP sender receives — deliberately not
/// RTCRtpEncodingParameters, so the application logic (plan Task 7: bitrate
/// application separated from RTC types) never links WebRTC state.
public struct EncodingParameters: Sendable, Equatable {
    public let maxBitrateBps: Int?

    public init(maxBitrateBps: Int?) {
        self.maxBitrateBps = maxBitrateBps
    }
}

/// One ICE candidate as it crosses the wire (call.ice body fields); the
/// engine produces these from the WebRTC delegate and consumes them from the
/// coordinator (Task 9).
public struct IceCandidate: Sendable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let lineIndex: Int32

    public init(candidate: String, sdpMid: String?, lineIndex: Int32) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.lineIndex = lineIndex
    }
}

/// The ICE connection states, mapped one-to-one from RTCIceConnectionState.
/// The coordinator (Task 9) folds connected/completed into IceConnected and
/// failed into IceFailed for the core state machine.
public enum IceConnectionState: String, Sendable {
    case new
    case checking
    case connected
    case completed
    case failed
    case disconnected
    case closed
}

/// A handle to a video track for the UI (Task 13 binds RTCVideoTrack to the
/// renderer view). The Objective-C track class is not Sendable, so the
/// handle boxes it: WebRTC tracks are internally thread-safe for rendering
/// while WebRTC owns their lifetime (spike-proven pattern, ADR-0001).
public protocol VideoTrackHandle: Sendable {
    /// The renderable WebRTC track; nil in test fakes and no-camera paths.
    var renderable: RTCVideoTrack? { get }
}

/// The production handle carrying a real WebRTC video track.
public struct LiveVideoTrack: VideoTrackHandle, @unchecked Sendable {
    public let renderable: RTCVideoTrack?

    public init(renderable: RTCVideoTrack?) {
        self.renderable = renderable
    }
}

/// One statistics entry as WebRTC reported it (type such as "candidate-pair"
/// or "outbound-rtp"), with the raw values typed into the three shapes the
/// stats report actually uses. The StatsDeriver (Task 8) reads them purely.
public struct RawStatsReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let type: String
        public let timestampMs: Double
        public let values: [String: RawStatValue]

        public init(id: String, type: String, timestampMs: Double, values: [String: RawStatValue]) {
            self.id = id
            self.type = type
            self.timestampMs = timestampMs
            self.values = values
        }
    }

    /// Entries keyed by their stats id, so nominated-pair lookups
    /// (localCandidateId → local candidate) stay dictionary reads.
    public let entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }
}

/// A single statistics value: the report's strings, numbers and booleans.
public enum RawStatValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
}
