// Shared transfer types and seams (Plan 4 Task 11): the value types the
// UI consumes (progress, completions, events), the error surface, the data
// channel seam and the two coordinator seams. Split out of
// TransferCoordinator.swift so every file stays inside the lint budgets.

import CoreBridge
import Foundation

/// The send side of the call's data channel, narrowed from CallMediaEngine
/// to what transfers need. The engine's data channel exposes no
/// bufferedAmount today, so the production adapter reports 0 (no
/// backpressure signal); tests fake it precisely.
public protocol TransferChannel: Sendable {
    /// Bytes the transport still has to flush (0 when unknown).
    var bufferedAmount: Int { get async }
    /// Sends one opaque frame; throws when the channel is closed.
    func send(_ data: Data) async throws
}

/// How a transfer ends.
public enum TransferError: Error, Equatable, Sendable {
    /// The file exceeds the server cap; rejected before any network call.
    case tooLarge(bytes: Int64, cap: Int64)
    /// A digest did not match: `expected`/`actual` lowercase hex.
    case digestMismatch(expected: String, actual: String)
    /// The download carried no X-Linko-Sha256 header, so the bytes cannot
    /// be verified.
    case digestMissing
    /// The reassembled bytes never matched the manifest digest.
    case corrupted
    /// The data channel closed (or was never open) mid-transfer.
    case channelClosed
    /// The user cancelled the transfer.
    case cancelled
    /// P2P was requested but no open channel was provided.
    case noChannel
    /// A transfer is already active for this call and direction.
    case transferAlreadyActive
    /// The envelope or frame referenced an unknown transfer.
    case notFound
    /// The file could not be read from disk.
    case unreadable
    /// A file id was not exactly the 16 raw bytes the framing requires.
    case invalidFileId
}

/// Which transport carried the bytes.
public enum TransferTransport: String, Sendable {
    case p2p
    case server
}

/// Live transfer progress for FileBubble (Task 12).
public struct TransferProgress: Sendable, Equatable {
    /// Lowercase hex file id.
    public let fileId: String
    public let bytesTransferred: Int64
    public let totalBytes: Int64

    public init(fileId: String, bytesTransferred: Int64, totalBytes: Int64) {
        self.fileId = fileId
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}

/// A finished transfer, as the UI and the recording sink see it.
public struct CompletedTransfer: Sendable, Equatable {
    public let callId: String
    /// Lowercase hex file id (the server-assigned id for server transfers).
    public let fileId: String
    public let name: String
    public let size: Int64
    public let sha256: String
    public let transport: TransferTransport

    public init(
        callId: String,
        fileId: String,
        name: String,
        size: Int64,
        sha256: String,
        transport: TransferTransport
    ) {
        self.callId = callId
        self.fileId = fileId
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.transport = transport
    }
}

/// What TransferCoordinator streams to its consumer (the UI).
public enum TransferEvent: Sendable {
    case progress(TransferProgress)
    case completed(CompletedTransfer)
    /// The UI turns this into "Send via server" (spec 4.2).
    case failed(callId: String, fileId: String, reason: TransferError)
    case cancelled(callId: String, fileId: String)
}

/// The send seam for file.* envelopes — the real implementation forwards to
/// SignalingClient; tests record.
public protocol TransferSignaling: Sendable {
    func send(_ envelope: LKEnvelope) async throws
}

/// The recording seam for completed transfers. The coordinator builds the
/// full msg.send envelope (LKMsgSend + LKFileMeta, transport included); the
/// production implementation (Task 9/12 composition) enqueues it in the
/// outbox and sends it over Signaling so msg.stored files it with its seq.
public protocol CompletedTransferRecording: Sendable {
    func record(_ envelope: LKEnvelope) async
}
