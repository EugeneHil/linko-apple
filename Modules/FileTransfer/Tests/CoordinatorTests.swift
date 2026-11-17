// Coordinator tests (Plan 4 Task 11): cancel stops everything and announces
// itself on both transports, and every completed transfer — P2P and server —
// is recorded as a normal msg.send message carrying the FileMeta.

import CoreBridge
@testable import FileTransfer
import Foundation
import ServerAPI
import XCTest

final class TransferCoordinatorTests: XCTestCase {
    private let callId = "call-1"
    private let peer = "alice"

    private func makeCoordinator(
        signaling: SignalingFake,
        recorder: RecorderFake,
        transport: FilesTransportFake
    ) throws -> TransferCoordinator {
        let files = try FilesClient(
            baseURL: XCTUnwrap(URL(string: "https://server.example")),
            transport: transport,
            tokens: TokenFake(token: "tok-123")
        )
        return TransferCoordinator(
            signaling: signaling,
            recorder: recorder,
            server: ServerFileTransfer(files: files)
        )
    }

    /// A sender-side and a receiver-side coordinator (two devices), their
    /// signaling fakes, recorders and the sender's server transport.
    private struct CoordinatorPair {
        let sender: TransferCoordinator
        let receiver: TransferCoordinator
        let senderSignaling: SignalingFake
        let receiverSignaling: SignalingFake
        let senderRecorder: RecorderFake
        let receiverRecorder: RecorderFake
        let transport: FilesTransportFake
    }

    private func makePair(uploadReply digest: String, size: Int64) throws -> CoordinatorPair {
        let senderSignaling = SignalingFake()
        let receiverSignaling = SignalingFake()
        let senderRecorder = RecorderFake()
        let receiverRecorder = RecorderFake()
        let transport = FilesTransportFake { _ in
            FilesTransportFake.CannedReply(
                status: 201,
                body: Data(
                    #"{"fileId":"srv0000000000000000000000000000000","sha256":"\#(digest)","size":\#(size)}"#
                        .utf8
                ),
                headers: [:]
            )
        }
        let receiverTransport = FilesTransportFake { _ in
            FilesTransportFake.CannedReply(status: 200, body: Data(), headers: [:])
        }
        return try CoordinatorPair(
            sender: makeCoordinator(
                signaling: senderSignaling, recorder: senderRecorder, transport: transport
            ),
            receiver: makeCoordinator(
                signaling: receiverSignaling,
                recorder: receiverRecorder,
                transport: receiverTransport
            ),
            senderSignaling: senderSignaling,
            receiverSignaling: receiverSignaling,
            senderRecorder: senderRecorder,
            receiverRecorder: receiverRecorder,
            transport: transport
        )
    }

    /// Feeds `box` from the coordinator's event stream for the test's
    /// lifetime.
    private func collectEvents(of coordinator: TransferCoordinator) -> (EventBox, Task<Void, Never>) {
        let box = EventBox()
        let task = Task {
            let events = await coordinator.events
            for await event in events {
                box.append(event)
            }
        }
        return (box, task)
    }

    /// Counts chunk and ack frames (anything that is not an envelope JSON).
    private func wireFrameCount(_ frames: [Data]) -> Int {
        frames.filter { frame in
            guard let json = String(data: frame, encoding: .utf8),
                  LKEnvelope.parse(jsonString: json).envelope != nil
            else { return true }
            return false
        }.count
    }

    /// Plan test name: test_cancel_sends_file_cancel_and_stops
    func test_cancel_sends_file_cancel_and_stops() async throws {
        let contents = randomBytes(80 * 1024) // 5 chunks of 16 KiB
        let url = try makeTempFile(name: "cancel.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }

        let signaling = SignalingFake()
        let recorder = RecorderFake()
        let coordinator = try makeCoordinator(
            signaling: signaling,
            recorder: recorder,
            transport: FilesTransportFake { _ in
                FilesTransportFake.CannedReply(status: 200, body: Data(), headers: [:])
            }
        )
        let (eventBox, eventsTask) = collectEvents(of: coordinator)
        defer { eventsTask.cancel() }

        await coordinator.bindPeer(callId: callId, peer: peer)
        // A channel that never drains: the sender parks in the backpressure
        // gate after the first four chunks — exactly the state a user
        // cancels from.
        let channel = LoopbackChannel()
        let hex = try await coordinator.sendFile(
            fileURL: url, callId: callId, peer: peer, channel: channel
        )

        let acceptBody = LKFileAccept(callId: callId, fileId: hex)
        await coordinator.handle(
            .envelope(envelope(LKTypes.fileAccept, bodyJSON: acceptBody.bodyJSON))
        )
        try await waitUntil { channel.sentFrames.count >= 2 }

        await coordinator.cancel(callId: callId, fileId: hex, reason: "user")
        try await waitUntil { eventBox.hasCancelled(callId: self.callId, fileId: hex) }

        try await assertCancelAnnounced(
            signaling: signaling, recorder: recorder, channel: channel, fileId: hex
        )
    }

    /// The cancel announcement and the anti-goal: after cancel, nothing new
    /// moves on the wire and nothing is recorded.
    private func assertCancelAnnounced(
        signaling: SignalingFake,
        recorder: RecorderFake,
        channel: LoopbackChannel,
        fileId: String
    ) async throws {
        // file.cancel went to the server and over the data channel.
        let cancels = signaling.envelopesOfType(LKTypes.fileCancel)
        XCTAssertEqual(cancels.count, 1)
        let body = try LKFileCancel.from(bodyJSON: XCTUnwrap(cancels.first).bodyJSON)
        XCTAssertEqual(body.callId, callId)
        XCTAssertEqual(body.fileId, fileId)
        XCTAssertEqual(body.reason, "user")
        let cancelOnChannel = channel.sentFrames.filter { frame in
            guard let json = String(data: frame, encoding: .utf8),
                  let parsed = LKEnvelope.parse(jsonString: json).envelope,
                  parsed.type == LKTypes.fileCancel
            else { return false }
            return true
        }
        XCTAssertEqual(cancelOnChannel.count, 1)

        // Anti-goal: nothing new moves after the cancel. The sender was
        // parked in the backpressure gate and must not send another chunk.
        let framesAtCancel = channel.sentFrames
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(channel.sentFrames.count, framesAtCancel.count)
        XCTAssertEqual(wireFrameCount(channel.sentFrames), wireFrameCount(framesAtCancel))
        XCTAssertTrue(recorder.envelopes.isEmpty, "a cancelled transfer records nothing")
    }

    /// Plan test name: test_completed_transfer_recorded_as_message
    func test_completed_transfer_recorded_as_message() async throws {
        let contents = randomBytes(1000)
        let url = try makeTempFile(name: "record.bin", contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = sha256Hex(contents)
        let expectedName = url.lastPathComponent

        let pair = try makePair(uploadReply: digest, size: Int64(contents.count))
        let (senderEvents, senderEventsTask) = collectEvents(of: pair.sender)
        let (receiverEvents, receiverEventsTask) = collectEvents(of: pair.receiver)
        defer {
            senderEventsTask.cancel()
            receiverEventsTask.cancel()
        }

        await pair.sender.bindPeer(callId: callId, peer: peer)
        await pair.receiver.bindPeer(callId: callId, peer: peer)

        let channel = LoopbackChannel()
        await pair.receiver.attach(channel: channel, for: callId)
        let hex = try await pair.sender.sendFile(
            fileURL: url, callId: callId, peer: peer, channel: channel
        )

        try await runP2PLoopback(pair: pair, channel: channel, events: (senderEvents, receiverEvents), fileId: hex)

        // Both sides recorded the completed transfer as a normal message.
        XCTAssertEqual(pair.senderRecorder.envelopes.count, 1)
        let sentEnvelope = try XCTUnwrap(pair.senderRecorder.envelopes.first)
        XCTAssertEqual(sentEnvelope.type, LKTypes.msgSend)
        let sentMessage = try LKMsgSend.from(bodyJSON: sentEnvelope.bodyJSON)
        XCTAssertEqual(sentMessage.to, peer)
        let fileMeta = try XCTUnwrap(sentMessage.file)
        XCTAssertEqual(fileMeta.name, expectedName)
        XCTAssertEqual(fileMeta.size, 1000)
        XCTAssertEqual(fileMeta.sha256, digest)
        XCTAssertEqual(fileMeta.transport, "p2p")
        XCTAssertEqual(fileMeta.fileId, hex)

        XCTAssertEqual(pair.receiverRecorder.envelopes.count, 1)
        let receivedEnvelope = try XCTUnwrap(pair.receiverRecorder.envelopes.first)
        let receivedMessage = try LKMsgSend.from(bodyJSON: receivedEnvelope.bodyJSON)
        let receivedMeta = try XCTUnwrap(receivedMessage.file)
        XCTAssertEqual(receivedMeta.transport, "p2p")
        XCTAssertEqual(receivedMeta.fileId, hex)
        XCTAssertEqual(receivedMeta.sha256, digest)

        // --- Server path: the upload completes and is recorded too ---
        try await assertServerRecording(
            pair: pair, url: url, name: expectedName, digest: digest, size: Int64(contents.count)
        )
    }

    /// The server fallback: the upload went over HTTP and the recording
    /// carries FileMeta with transport "server" and the server's file id.
    private func assertServerRecording(
        pair: CoordinatorPair,
        url: URL,
        name: String,
        digest: String,
        size: Int64
    ) async throws {
        let completed = try await pair.sender.sendViaServer(
            fileURL: url, callId: callId, peer: peer
        )
        XCTAssertEqual(completed.transport, .server)
        XCTAssertTrue(pair.transport.calls.contains { $0.request.httpMethod == "PUT" })

        XCTAssertEqual(pair.senderRecorder.envelopes.count, 2)
        let envelope = try XCTUnwrap(pair.senderRecorder.envelopes.last)
        let message = try LKMsgSend.from(bodyJSON: envelope.bodyJSON)
        let meta = try XCTUnwrap(message.file)
        XCTAssertEqual(meta.transport, "server")
        XCTAssertEqual(meta.fileId, "srv0000000000000000000000000000000")
        XCTAssertEqual(meta.name, name)
        XCTAssertEqual(meta.size, size)
        XCTAssertEqual(meta.sha256, digest)
    }

    /// Relays the offer to the receiver side, the accept back to the sender
    /// side, and pumps the shared channel both ways until both sides report
    /// the completed transfer.
    private func runP2PLoopback(
        pair: CoordinatorPair,
        channel: LoopbackChannel,
        events: (sender: EventBox, receiver: EventBox),
        fileId: String
    ) async throws {
        // The server relays the offer; the receiver answers file.accept on
        // both transports and the accept loops back to start the sender.
        let offer = try XCTUnwrap(pair.senderSignaling.envelopesOfType(LKTypes.fileOffer).first)
        await pair.receiver.handle(.envelope(offer))
        let accept = try XCTUnwrap(pair.receiverSignaling.envelopesOfType(LKTypes.fileAccept).first)
        await pair.sender.handle(.envelope(accept))

        // One pump loop over the shared channel: ack frames land in the
        // sender side (its tracker advances), chunks and envelopes land in
        // the receiver side.
        let pumpTask = Task {
            for await frame in channel.frames {
                if TransferFrames.parseAckFrame(frame) != nil {
                    await pair.sender.handleInboundFrame(frame)
                } else {
                    await pair.receiver.handleInboundFrame(frame)
                }
            }
        }
        defer { pumpTask.cancel() }

        try await waitUntil(timeout: 10) {
            events.sender.completedEvents().contains { $0.transport == .p2p && $0.fileId == fileId }
        }
        try await waitUntil(timeout: 10) {
            events.receiver.completedEvents().contains { $0.transport == .p2p && $0.fileId == fileId }
        }
    }
}
