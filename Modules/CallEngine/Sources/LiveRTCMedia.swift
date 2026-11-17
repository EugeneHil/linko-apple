// LiveRTCMedia (Plan 4 Task 7 / LNK-33): the production adapters for the
// data channel, tracks, capturer, RTP sender, camera availability and the
// statistics conversion — the smaller live WebRTC objects (the peer
// connection and its shared factory live in LiveRTC.swift). Every delegate
// callback crosses into a sink exactly once.

import CoreMedia
import Foundation
import Synchronization
import WebRTC

// MARK: - Live data channel

/// Wraps one RTCDataChannel; the channel object is fixed at construction
/// (delegate assigned immediately after) and read from anywhere afterwards
/// — the @unchecked Sendable box covers that write-once discipline.
final class LiveDataChannel: NSObject, EngineDataChannel, RTCDataChannelDelegate, @unchecked Sendable {
    private let sink: DataChannelSink
    private let rtcChannel: RTCDataChannel

    init(rtc: RTCDataChannel, sink: DataChannelSink) {
        rtcChannel = rtc
        self.sink = sink
        super.init()
        rtc.delegate = self
    }

    var isOpen: Bool {
        rtcChannel.readyState == RTCDataChannelState.open
    }

    func send(_ data: Data) throws {
        // The BOOL result reports a full/unavailable channel; the peer
        // connection state stream is the health surface, so drop the value.
        _ = rtcChannel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        sink.onStateChange(dataChannel.readyState == .open)
    }

    func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        sink.onMessage(buffer.data)
    }
}

/// A channel that never opened (no live connection): refuses sends, reports
/// closed.
final class DetachedDataChannel: EngineDataChannel, @unchecked Sendable {
    private let sink: DataChannelSink

    init(sink: DataChannelSink) {
        self.sink = sink
    }

    var isOpen: Bool {
        false
    }

    func send(_: Data) throws {
        throw CallEngineError.channelNotOpen
    }
}

/// An audio track that cannot exist (no live connection): mute is a no-op.
final class DetachedAudioTrack: EngineAudioTrack, @unchecked Sendable {
    func setEnabled(_: Bool) {}
}

// MARK: - Tracks, capturer, sender

final class LiveAudioTrack: EngineAudioTrack, @unchecked Sendable {
    private let rtc: RTCAudioTrack

    init(rtc: RTCAudioTrack) {
        self.rtc = rtc
    }

    func setEnabled(_ enabled: Bool) {
        rtc.isEnabled = enabled
    }
}

final class LiveVideoCapturer: EngineVideoCapturer, @unchecked Sendable {
    private let rtc: RTCCameraVideoCapturer

    init(rtc: RTCCameraVideoCapturer) {
        self.rtc = rtc
    }

    func startCapture() async throws {
        // Device and format selection follows the spike-proven pattern:
        // front camera when present, a format at most 1280 wide, at most
        // 30 fps. No device (Simulator) → capture stays off.
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
            return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.last {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1280
        } ?? formats.first
        guard let format else { return }
        let fps = min(30, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        try await rtc.startCapture(with: device, format: format, fps: fps)
    }

    func stopCapture() {
        rtc.stopCapture()
    }
}

final class LiveRtpSender: RtpSenderControlling, @unchecked Sendable {
    private let rtc: RTCRtpSender

    init(rtc: RTCRtpSender) {
        self.rtc = rtc
    }

    func applyEncodingParameters(_ parameters: EncodingParameters) {
        let params = rtc.parameters
        if params.encodings.isEmpty {
            params.encodings = [RTCRtpEncodingParameters()]
        }
        params.encodings[0].maxBitrateBps = parameters.maxBitrateBps.map(NSNumber.init(value:))
        rtc.parameters = params
    }
}

// MARK: - Camera availability

public struct LiveCameraAvailability: CameraAvailabilityChecking {
    public var hasCamera: Bool {
        !RTCCameraVideoCapturer.captureDevices().isEmpty
    }

    public init() {}
}

// MARK: - Statistics conversion

/// RTCStatisticsReport → the engine's raw report. Values keep their report
/// shapes: booleans, numbers, strings; anything else degrades to a string.
enum StatsConversion {
    static func convert(_ report: RTCStatisticsReport) -> RawStatsReport {
        var entries: [String: RawStatsReport.Entry] = [:]
        for (id, stat) in report.statistics {
            var values: [String: RawStatValue] = [:]
            for (key, raw) in stat.values {
                if let boolean = raw as? Bool {
                    values[key] = .boolean(boolean)
                } else if let number = raw as? NSNumber {
                    values[key] = .number(number.doubleValue)
                } else if let string = raw as? String {
                    values[key] = .string(string)
                } else {
                    values[key] = .string(String(describing: raw))
                }
            }
            // The report timestamps are microseconds since epoch; the raw
            // report carries milliseconds (delta math in Task 8 is
            // unit-agnostic once consistent).
            entries[id] = RawStatsReport.Entry(
                id: id,
                type: stat.type,
                timestampMs: stat.timestamp_us / 1000.0,
                values: values
            )
        }
        return RawStatsReport(entries: entries)
    }
}
