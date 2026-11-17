// Codec preference tests (Plan 4 Task 7 / LNK-33): VP8 is the preferred
// video codec (plan contract; H.264 is the Task 13 cut candidate). Opus is
// the audio default of the WebRTC factory and needs no ordering code.

@testable import CallEngine
import Foundation
import WebRTC
import XCTest

final class CodecPreferenceTests: XCTestCase {
    func test_codec_ordering_prefers_vp8() {
        let h264 = RTCVideoCodecInfo(name: "H264")
        let vp8 = RTCVideoCodecInfo(name: "VP8")
        let vp9 = RTCVideoCodecInfo(name: "VP9")

        let ordered = CodecPreference.vp8First([h264, vp8, vp9])

        XCTAssertEqual(ordered.first?.name, "VP8")
        XCTAssertEqual(ordered.map(\.name), ["VP8", "H264", "VP9"], "the remaining order is preserved")
    }

    func test_codec_ordering_keeps_vp8_first_when_already_preferred() {
        let vp8 = RTCVideoCodecInfo(name: "VP8")
        let h264 = RTCVideoCodecInfo(name: "H264")

        let ordered = CodecPreference.vp8First([vp8, h264])

        XCTAssertEqual(ordered.map(\.name), ["VP8", "H264"])
    }
}
