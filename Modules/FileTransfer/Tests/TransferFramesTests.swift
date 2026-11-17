// Ack framing (Plan 4 Task 11): the app-side ack frame rides the same data
// channel as the core's chunk frames and must round-trip byte-exactly, with
// anything malformed rejected rather than guessed at.

import CoreBridge
@testable import FileTransfer
import XCTest

final class TransferFramesTests: XCTestCase {
    // Plan test name: test_ack_frame_roundtrip

    func test_ack_frame_roundtrip() {
        let fileId = Data((0 ..< 16).map { UInt8($0) })
        let frame = TransferFrames.frameAck(fileId: fileId, uptoIndex: 41)

        let parsed = TransferFrames.parseAckFrame(frame)
        XCTAssertEqual(parsed?.fileId, fileId)
        XCTAssertEqual(parsed?.uptoIndex, 41)

        // Truncated: shorter than the 21-byte fixed layout.
        XCTAssertNil(TransferFrames.parseAckFrame(Data(frame.prefix(20))))
        // Trailing garbage beyond the announced length is not an ack frame.
        XCTAssertNil(TransferFrames.parseAckFrame(Data(frame + Data([0x01]))))
        // Wrong version byte.
        XCTAssertNil(TransferFrames.parseAckFrame(Data([0x7F]) + frame.dropFirst()))
        // A chunk frame is not an ack frame (version 0x01, 25-byte header).
        let chunk = LKFileChunker.frameChunk(fileId: fileId, index: 0, payload: Data(repeating: 9, count: 8))
        XCTAssertNotNil(chunk)
        XCTAssertNil(TransferFrames.parseAckFrame(chunk ?? Data()))
    }
}
