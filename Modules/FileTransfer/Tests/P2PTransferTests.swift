// P2P transfer tests (Plan 4 Task 11): sender backpressure and resume, the
// receiver's reassembly rules (duplicate, missing, corrupt) and a full
// loopback roundtrip over the fake channel. Small chunk sizes keep every
// file a handful of frames.

import CoreBridge
@testable import FileTransfer
import XCTest

final class P2PTransferTests: XCTestCase {
    private let fileId = Data((0x40 ..< 0x50).map { UInt8($0) })

    private func makeManifest(_ contents: Data, chunkSize: UInt32) -> LKFileManifest {
        LKFileManifest.make(
            name: "notes.bin",
            size: UInt64(contents.count),
            sha256Hex: sha256Hex(contents),
            chunkSize: chunkSize
        )
    }

    /// The data-channel loopback: chunks flow to the receiver, the
    /// receiver's ack frames flow back into the sender's tracker.
    private func pump(
        _ channel: LoopbackChannel,
        receiver: P2PFileReceiver,
        sender: P2PFileSender?
    ) -> Task<Void, Never> {
        Task {
            for await frame in channel.frames {
                if TransferFrames.parseAckFrame(frame) != nil {
                    if let sender {
                        await sender.handleInbound(frame)
                    }
                    continue
                }
                let outcome = await receiver.handleFrame(frame)
                for ack in outcome.ackFrames {
                    try? await channel.send(ack)
                }
            }
        }
    }

    /// Plan test name: test_p2p_roundtrip_small_file
    func test_p2p_roundtrip_small_file() async throws {
        let contents = randomBytes(1000)
        let url = try makeTempFile(name: "roundtrip.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = makeManifest(contents, chunkSize: 256)

        let channel = LoopbackChannel()
        let sender = try P2PFileSender(
            fileURL: url, manifest: manifest, fileId: fileId, channel: channel
        )
        let receiver = P2PFileReceiver(manifest: manifest, fileId: fileId)
        let pumpTask = pump(channel, receiver: receiver, sender: nil)
        defer { pumpTask.cancel() }

        try await sender.run()
        try await waitUntil { await receiver.state.isTerminal }
        let state = await receiver.state
        guard case .completed = state else {
            return XCTFail("expected completed, got \(state)")
        }
        let taken = await receiver.takeCompletedFile()
        let assembled = try XCTUnwrap(taken)
        XCTAssertEqual(assembled, contents)
        XCTAssertEqual(sha256Hex(assembled), manifest.sha256Hex)
    }

    /// Plan test name: test_backpressure_awaits_buffered_amount
    func test_backpressure_awaits_buffered_amount() async throws {
        // 32 chunks of 1 KiB against a 4 KiB low-water mark; each
        // bufferedAmount query flushes only 128 bytes, so the sender must
        // repeatedly wait for the buffer to fall below the mark. Without
        // the gate the peak would reach the full 32 KiB.
        let contents = randomBytes(32 * 1024)
        let url = try makeTempFile(name: "backpressure.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = makeManifest(contents, chunkSize: 1024)

        let channel = LoopbackChannel(drainBytesPerQuery: 128)
        let sender = try P2PFileSender(
            fileURL: url,
            manifest: manifest,
            fileId: fileId,
            channel: channel,
            lowWaterMark: 4 * 1024,
            pollInterval: .milliseconds(1)
        )

        try await sender.run()

        let frameOverhead = 25
        XCTAssertLessThanOrEqual(
            channel.peakBuffered,
            4 * 1024 + 1024 + frameOverhead,
            "peak buffering must stay near the low-water mark"
        )
        XCTAssertGreaterThanOrEqual(channel.blockedBufferQueries, 1, "the sender must have waited on bufferedAmount")
        XCTAssertGreaterThanOrEqual(channel.bufferedAmountQueries, 32)
        XCTAssertEqual(channel.sentFrames.count, Int(manifest.chunkCount))
    }

    /// Plan test name: test_corrupt_chunk_fails_sha256_loudly
    func test_corrupt_chunk_fails_sha256_loudly() async throws {
        var contents = randomBytes(1000)
        let url = try makeTempFile(name: "corrupt.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = makeManifest(contents, chunkSize: 256)

        let receiver = P2PFileReceiver(manifest: manifest, fileId: fileId)
        // Corrupt one byte inside chunk 1, same length: sizes stay valid,
        // only the reassembly digest can catch it.
        contents[300] ^= 0xFF

        for index in 0 ..< manifest.chunkCount {
            let offset = Int(index) * 256
            let payload = contents.subdata(in: offset ..< min(offset + 256, contents.count))
            let frame = try XCTUnwrap(LKFileChunker.frameChunk(fileId: fileId, index: index, payload: payload))
            let outcome = await receiver.handleFrame(frame)
            XCTAssertEqual(outcome.kind, .accepted)
        }

        let state = await receiver.state
        guard case let .failed(error) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertEqual(error, .corrupted)
        let withheld = await receiver.takeCompletedFile()
        XCTAssertNil(withheld)
    }

    /// Plan test name: test_duplicate_chunk_ignored
    func test_duplicate_chunk_ignored() async throws {
        let contents = randomBytes(512)
        let url = try makeTempFile(name: "duplicate.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = makeManifest(contents, chunkSize: 256)

        let receiver = P2PFileReceiver(manifest: manifest, fileId: fileId)
        let payload = contents.subdata(in: 0 ..< 256)
        let frame = try XCTUnwrap(LKFileChunker.frameChunk(fileId: fileId, index: 0, payload: payload))

        let first = await receiver.handleFrame(frame)
        XCTAssertEqual(first.kind, .accepted)
        XCTAssertEqual(first.ackFrames.count, 1)

        let duplicate = await receiver.handleFrame(frame)
        XCTAssertEqual(duplicate.kind, .duplicate)
        XCTAssertEqual(duplicate.ackFrames.count, 1, "a duplicate is re-acknowledged")

        // The stored bytes stand: the duplicate changed nothing.
        guard case let .receiving(bytes, _) = await receiver.state else {
            return XCTFail("expected receiving state")
        }
        XCTAssertEqual(bytes, 256)
        let unconsumed = await receiver.takeCompletedFile()
        XCTAssertNil(unconsumed)
    }

    /// Plan test name: test_missing_chunk_never_completes
    func test_missing_chunk_never_completes() async throws {
        let contents = randomBytes(1000)
        let url = try makeTempFile(name: "missing.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = makeManifest(contents, chunkSize: 256)

        let receiver = P2PFileReceiver(manifest: manifest, fileId: fileId)
        for index in [UInt32(0), 1, 3] {
            let offset = Int(index) * 256
            let payload = contents.subdata(in: offset ..< min(offset + 256, contents.count))
            let frame = try XCTUnwrap(LKFileChunker.frameChunk(fileId: fileId, index: index, payload: payload))
            let outcome = await receiver.handleFrame(frame)
            XCTAssertEqual(outcome.kind, .accepted)
        }

        let state = await receiver.state
        guard case let .receiving(bytes, total) = state else {
            return XCTFail("expected receiving state, got \(state)")
        }
        // Chunks 0 and 1 are 256 bytes; chunk 3 is the short last chunk
        // (1000 - 2*256 = 232). Chunk 2 is missing entirely.
        XCTAssertEqual(bytes, 744)
        XCTAssertEqual(total, 1000)
        let incomplete = await receiver.takeCompletedFile()
        XCTAssertNil(incomplete)
    }

    /// Plan test name: test_resume_from_last_acked
    func test_resume_from_last_acked() async throws {
        let contents = randomBytes(5 * 64)
        let url = try makeTempFile(name: "resume.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = makeManifest(contents, chunkSize: 64)

        let channel = LoopbackChannel()
        channel.failAfterSends(2) // chunks 0 and 1 go out, chunk 2 kills the channel
        let sender = try P2PFileSender(
            fileURL: url, manifest: manifest, fileId: fileId, channel: channel
        )
        let receiver = P2PFileReceiver(manifest: manifest, fileId: fileId)

        let pumpTask = pump(channel, receiver: receiver, sender: sender)
        defer { pumpTask.cancel() }

        do {
            try await sender.run()
            XCTFail("expected the dead channel to fail the run")
        } catch let error as TransferError {
            XCTAssertEqual(error, .channelClosed)
        }

        // The acks for chunks 0 and 1 land even after the failure.
        try await waitUntil { await sender.nextToSend == 2 }

        channel.failAfterSends(Int.max)
        try await sender.resume()

        try await waitUntil { await receiver.state.isTerminal }
        let resumedState = await receiver.state
        guard case .completed = resumedState else {
            return XCTFail("expected completed after resume, got \(resumedState)")
        }
        let taken = await receiver.takeCompletedFile()
        let assembled = try XCTUnwrap(taken)
        XCTAssertEqual(assembled, contents)
        XCTAssertEqual(sha256Hex(assembled), manifest.sha256Hex)
        // Chunks 2, 3, 4 were re-sent from the resume point; nothing was
        // delivered twice on the wire after the failure.
        let duplicates = await receiver.duplicateCount
        XCTAssertEqual(duplicates, 0)
    }
}
