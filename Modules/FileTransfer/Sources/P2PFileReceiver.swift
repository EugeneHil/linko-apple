// P2PFileReceiver (Plan 4 Task 11): feeds inbound chunk frames into the
// core's LKFileReassembler, filters by fileId, verifies the SHA-256 of the
// reassembly (takeIfCompleteAndValid) and emits progress. Chunks may arrive
// in any order; duplicates are re-acked and ignored; a full-size assembly
// whose digest mismatches fails loudly instead of ever handing out bytes.

import CoreBridge
import Foundation

/// Where an inbound frame landed for this receiver.
public struct P2PFrameOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Stored; the receiver acked the chunk.
        case accepted
        /// Already stored; the stored bytes stand, re-acked.
        case duplicate
        /// Outside the manifest or a size mismatch; not acked.
        case unexpected
        /// A chunk frame for a different file.
        case notForThisFile
        /// Not a parseable chunk frame at all.
        case invalidFrame
    }

    public let kind: Kind
    /// Ack frames to put back on the data channel for the sender.
    public let ackFrames: [Data]

    public init(kind: Kind, ackFrames: [Data]) {
        self.kind = kind
        self.ackFrames = ackFrames
    }
}

/// Lifecycle of one inbound P2P file.
public enum P2PReceiveState: Equatable, Sendable {
    /// Bytes accepted so far, manifest total.
    case receiving(bytesTransferred: Int64, totalBytes: Int64)
    /// Digest verified; the bytes are available via takeCompletedFile().
    case completed(bytes: Int64)
    /// The assembly is complete but the digest mismatches, or the transfer
    /// was cancelled before it could complete.
    case failed(TransferError)

    /// True for the two terminal states.
    public var isTerminal: Bool {
        switch self {
        case .receiving: false
        case .completed, .failed: true
        }
    }
}

/// Reassembles one file from data-channel chunk frames.
public actor P2PFileReceiver {
    public let progress: AsyncStream<TransferProgress>

    /// The manifest this receiver assembles against.
    public let manifest: LKFileManifest

    private let fileId: Data
    private let reassembler: LKFileReassembler
    private let progressContinuation: AsyncStream<TransferProgress>.Continuation
    private var stateValue: P2PReceiveState
    private var completedData: Data?
    private var duplicatesSeen = 0

    public init(manifest: LKFileManifest, fileId: Data) {
        self.manifest = manifest
        self.fileId = fileId
        reassembler = LKFileReassembler(manifest: manifest)
        let (stream, continuation) = AsyncStream.makeStream(of: TransferProgress.self)
        progress = stream
        progressContinuation = continuation
        // An empty file's manifest is complete by definition: verify the
        // digest of the empty assembly right away.
        if manifest.size == 0, let file = reassembler.takeIfCompleteAndValid() {
            completedData = file
            stateValue = .completed(bytes: Int64(file.count))
        } else {
            stateValue = .receiving(
                bytesTransferred: 0,
                totalBytes: Int64(manifest.size)
            )
        }
    }

    /// Parses and stores one inbound data-channel frame. A duplicate is
    /// re-acknowledged (the stored bytes stand); once every expected byte
    /// has arrived the assembly is digest-checked — a mismatch fails the
    /// transfer loudly, never emitting wrong bytes.
    public func handleFrame(_ data: Data) async -> P2PFrameOutcome {
        guard let frame = LKFileChunker.parse(frame: data) else {
            return P2PFrameOutcome(kind: .invalidFrame, ackFrames: [])
        }
        guard frame.fileId == fileId else {
            return P2PFrameOutcome(kind: .notForThisFile, ackFrames: [])
        }
        let ack = TransferFrames.frameAck(fileId: fileId, uptoIndex: frame.index)
        switch reassembler.addChunk(index: frame.index, payload: frame.payload) {
        case .duplicate:
            duplicatesSeen += 1
            return P2PFrameOutcome(kind: .duplicate, ackFrames: [ack])
        case .unexpected:
            return P2PFrameOutcome(kind: .unexpected, ackFrames: [])
        case .accepted:
            let bytes = Int64(reassembler.receivedBytes)
            stateValue = .receiving(
                bytesTransferred: bytes,
                totalBytes: Int64(manifest.size)
            )
            progressContinuation.yield(
                TransferProgress(
                    fileId: Hex.encode(fileId),
                    bytesTransferred: bytes,
                    totalBytes: Int64(manifest.size)
                )
            )
            guard Int64(manifest.size) > 0, bytes >= Int64(manifest.size) else {
                return P2PFrameOutcome(kind: .accepted, ackFrames: [ack])
            }
            if let file = reassembler.takeIfCompleteAndValid() {
                completedData = file
                stateValue = .completed(bytes: Int64(file.count))
                progressContinuation.finish()
            } else {
                // Every byte is here but the digest mismatches: loud
                // failure, nothing is ever handed out.
                stateValue = .failed(.corrupted)
                progressContinuation.finish()
            }
            return P2PFrameOutcome(kind: .accepted, ackFrames: [ack])
        @unknown default:
            return P2PFrameOutcome(kind: .unexpected, ackFrames: [])
        }
    }

    /// The current lifecycle state.
    public var state: P2PReceiveState {
        stateValue
    }

    /// The verified file bytes; nil until completed (and consumed once).
    public func takeCompletedFile() async -> Data? {
        let file = completedData
        completedData = nil
        return file
    }

    /// How many duplicate chunk frames were seen (test observability and
    /// resume-verification).
    public var duplicateCount: Int {
        duplicatesSeen
    }
}
