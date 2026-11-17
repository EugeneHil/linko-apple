// TransferFrames (Plan 4 Task 11): the app-side framing that rides the
// call's data channel next to the core's chunk frames. The core defines
// chunk frames only (LKFileChunker); acks and the file.id hex form live here.
// Wire format of an ack frame: one version byte (0x02), the 16 raw fileId
// bytes, then a 4-byte big-endian index the sender should resume from.

import CoreBridge
import Foundation

/// Acknowledgement framing over the data channel (app-side, Plan 4
/// Task 11). `uptoIndex` is the chunk index being acknowledged: "the
/// receiver has this chunk", one ack per accepted chunk — the sender's
/// LKAckTracker folds them into a gap-free resume point.
public enum TransferFrames {
    /// Version byte of an ack frame (chunk frames use the core's 0x01).
    static let ackVersion: UInt8 = 0x02
    /// Version + fileId + index.
    static let ackFrameBytes = 1 + 16 + 4

    /// Frames "receiver has chunk `uptoIndex` of `fileId`" as raw data.
    public static func frameAck(fileId: Data, uptoIndex: UInt32) -> Data {
        var frame = Data(capacity: ackFrameBytes)
        frame.append(ackVersion)
        frame.append(fileId)
        let index = uptoIndex.bigEndian
        withUnsafeBytes(of: index) { frame.append(contentsOf: $0) }
        return frame
    }

    /// Parses an ack frame; nil for a wrong version byte, a wrong length, a
    /// trailing garbage byte or a fileId that is not exactly 16 bytes.
    public static func parseAckFrame(_ data: Data) -> (fileId: Data, uptoIndex: UInt32)? {
        guard data.count == ackFrameBytes, data.first == ackVersion else {
            return nil
        }
        let fileId = Data(data.dropFirst().prefix(16))
        let indexBytes = Data(data.dropFirst(17))
        guard fileId.count == 16, indexBytes.count == 4 else {
            return nil
        }
        let uptoIndex = (UInt32(indexBytes[0]) << 24)
            | (UInt32(indexBytes[1]) << 16)
            | (UInt32(indexBytes[2]) << 8)
            | UInt32(indexBytes[3])
        return (fileId, uptoIndex)
    }
}

/// Lowercase hex encoding for file ids: envelopes carry the hex string,
/// chunk and ack frames the raw 16 bytes.
enum Hex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The raw bytes behind a hex file id; nil for anything that is not
    /// exactly 16 bytes (the framing size the core requires).
    static func decode(_ hex: String) -> Data? {
        guard hex.count == 32 else { return nil }
        var bytes = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index ..< next], radix: 16)
            else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
