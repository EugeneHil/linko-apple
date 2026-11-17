// P2PFileSender (Plan 4 Task 11): reads the file in 16 KiB chunks, frames
// them with the core's LKFileChunker and sends them over the call's data
// channel, applying backpressure by awaiting the transport's bufferedAmount
// below a low-water mark. Acks feed LKAckTracker; resume continues from the
// last acknowledged chunk within the same call. Nothing is logged except
// name/size/progress — and there is no logging here at all.

import CoreBridge
import Foundation

/// Sends one file over the data channel. Each chunk is sent exactly once
/// per run/resume; `nextToSend` exposes the acknowledged resume point for
/// callers that wait for the receiver's acks. The channel seam is
/// `TransferChannel`; the production adapter wraps CallMediaEngine's data
/// channel.
public actor P2PFileSender {
    /// Bytes below which the sender keeps pushing (64 KiB = 4 chunks).
    public static let defaultLowWaterMark = 64 * 1024

    public let progress: AsyncStream<TransferProgress>

    private let fileURL: URL
    private let manifest: LKFileManifest
    private let fileId: Data
    private let channel: any TransferChannel
    private let lowWaterMark: Int
    private let pollInterval: Duration
    private let tracker = LKAckTracker()
    private let progressContinuation: AsyncStream<TransferProgress>.Continuation
    private var handle: FileHandle?
    private var cancelled = false

    public init(
        fileURL: URL,
        manifest: LKFileManifest,
        fileId: Data,
        channel: any TransferChannel,
        lowWaterMark: Int = P2PFileSender.defaultLowWaterMark,
        pollInterval: Duration = .milliseconds(5)
    ) throws {
        guard fileId.count == 16 else {
            throw TransferError.invalidFileId
        }
        self.fileURL = fileURL
        self.manifest = manifest
        self.fileId = fileId
        self.channel = channel
        self.lowWaterMark = lowWaterMark
        self.pollInterval = pollInterval
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw TransferError.unreadable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: TransferProgress.self)
        progress = stream
        progressContinuation = continuation
    }

    deinit {
        try? handle?.close()
    }

    /// Inbound data-channel frames: ack frames feed the tracker; anything
    /// else is ignored (chunks belong to the receiver).
    public func handleInbound(_ data: Data) {
        guard let parsed = TransferFrames.parseAckFrame(data), parsed.fileId == fileId else {
            return
        }
        tracker.ack(index: parsed.uptoIndex)
    }

    /// Sends every remaining chunk; throws on channel failure or cancel.
    /// Returns once every chunk is on the wire — wait on `nextToSend` to
    /// observe the receiver's acknowledgements.
    public func run() async throws {
        try await sendLoop()
    }

    /// Continues from the last acknowledged chunk within the same call.
    public func resume() async throws {
        try await sendLoop()
    }

    /// Stops the loop at the next gate check; the coordinator turns this
    /// into a file.cancel envelope on both transports.
    public func cancel() {
        cancelled = true
    }

    /// The acked resume point: the next chunk index to send.
    public var nextToSend: UInt32 {
        tracker.nextToSend
    }

    // MARK: - Internals

    private func sendLoop() async throws {
        // Start from the acknowledged resume point: the first run sends
        // from zero, a resume after a channel failure skips every chunk the
        // receiver already confirmed. The handle stays open across a failed
        // run so resume() can pick up from the ack point.
        if handle == nil {
            do {
                handle = try FileHandle(forReadingFrom: fileURL)
            } catch {
                throw TransferError.unreadable
            }
        }
        var sentHigh = Int(tracker.nextToSend)
        while !cancelled, sentHigh < Int(manifest.chunkCount) {
            // Backpressure: wait for the transport buffer to fall below the
            // low-water mark before pushing the next chunk.
            while !cancelled, await channel.bufferedAmount >= lowWaterMark {
                try? await Task.sleep(for: pollInterval)
            }
            if cancelled {
                progressContinuation.finish()
                throw TransferError.cancelled
            }
            let payload = try readChunk(UInt32(sentHigh))
            guard let frame = LKFileChunker.frameChunk(
                fileId: fileId, index: UInt32(sentHigh), payload: payload
            ) else {
                throw TransferError.invalidFileId
            }
            do {
                try await channel.send(frame)
            } catch {
                throw TransferError.channelClosed
            }
            sentHigh += 1
            progressContinuation.yield(
                TransferProgress(
                    fileId: Hex.encode(fileId),
                    bytesTransferred: min(
                        Int64(sentHigh) * Int64(manifest.chunkSize),
                        Int64(manifest.size)
                    ),
                    totalBytes: Int64(manifest.size)
                )
            )
        }
        if cancelled {
            progressContinuation.finish()
            throw TransferError.cancelled
        }
        progressContinuation.finish()
    }

    private func readChunk(_ index: UInt32) throws -> Data {
        guard let file = handle else {
            throw TransferError.unreadable
        }
        do {
            try file.seek(toOffset: UInt64(index) * UInt64(manifest.chunkSize))
            guard let chunk = try file.read(upToCount: Int(manifest.chunkSize)) else {
                throw TransferError.unreadable
            }
            return chunk
        } catch let error as TransferError {
            throw error
        } catch {
            throw TransferError.unreadable
        }
    }
}
