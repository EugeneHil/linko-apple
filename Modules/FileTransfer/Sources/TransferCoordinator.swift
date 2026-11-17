// TransferCoordinator (Plan 4 Task 11): one place per app that owns every
// file transfer, keyed by callId + fileId — one transfer at a time per call
// and direction. Outgoing: manifest, file.offer on both transports, sender
// on accept, msg.send recording on completion. Incoming: receiver on offer,
// file.accept reply, ack relaying, msg.send recording. Cancel announces
// itself (file.cancel on both transports) and stops everything. A failed
// mid-call transfer surfaces an error the UI turns into "Send via server".
// Every completed transfer is recorded as a normal msg.send message with
// FileMeta{name, size, sha256, transport: "p2p"|"server", fileId} so it
// lands in history with seq and receipts.

import CoreBridge
import Foundation
import Signaling

public actor TransferCoordinator {
    /// A fresh 16-byte file id for P2P framing (the hex form rides
    /// envelopes); the default for `init(makeFileId:)`.
    public static func randomFileId() -> Data {
        Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
    }

    /// Progress, completions, failures and cancellations for the UI.
    public let events: AsyncStream<TransferEvent>

    /// One outgoing transfer's state (internal: the lifecycle extension
    /// in TransferCoordinatorLifecycle.swift drives it).
    struct Outgoing {
        let callId: String
        let peer: String
        let fileURL: URL
        let manifest: LKFileManifest
        let fileIdData: Data
        let channel: any TransferChannel
        var sender: P2PFileSender?
        var task: Task<Void, Never>?
    }

    /// One incoming transfer's state.
    struct Incoming {
        let callId: String
        let fileIdHex: String
        let receiver: P2PFileReceiver
    }

    private let signaling: any TransferSignaling
    let recorder: any CompletedTransferRecording
    private let server: ServerFileTransfer
    let nowMs: @Sendable () -> Int64
    private let makeFileId: @Sendable () -> Data
    let eventsContinuation: AsyncStream<TransferEvent>.Continuation

    /// fileId hex → transfer.
    var outgoing: [String: Outgoing] = [:]
    var incoming: [String: Incoming] = [:]
    /// callId → fileId hex: one outgoing transfer per call at a time.
    var activeOutgoingCall: [String: String] = [:]
    /// callId → an in-flight server upload (one per call at a time).
    var activeServerCalls: Set<String> = []
    /// callId → peer (needed to record inbound completions; envelopes
    /// carry no "from").
    var peers: [String: String] = [:]
    /// callId → the call's open data channel (receive-only transfers get it
    /// attached; sendFile stores its own).
    private var channels: [String: any TransferChannel] = [:]

    public init(
        signaling: any TransferSignaling,
        recorder: any CompletedTransferRecording,
        server: ServerFileTransfer,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        makeFileId: @escaping @Sendable () -> Data = TransferCoordinator.randomFileId
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferEvent.self)
        events = stream
        eventsContinuation = continuation
        self.signaling = signaling
        self.recorder = recorder
        self.server = server
        self.nowMs = nowMs
        self.makeFileId = makeFileId
    }

    /// Registers the peer of a call — the msg.send recorder needs the
    /// recipient for inbound transfers (envelopes carry no "from").
    public func bindPeer(callId: String, peer: String) {
        peers[callId] = peer
    }

    /// Attaches the call's open data channel for transfers that only
    /// receive (outgoing transfers get their channel from sendFile).
    public func attach(channel: any TransferChannel, for callId: String) {
        channels[callId] = channel
    }

    /// Offers a file for P2P transfer in a call; returns the hex file id.
    /// The offer goes to the server's call relay and, while the data
    /// channel is open, over it as well (spec 4.2).
    public func sendFile(
        fileURL: URL,
        callId: String,
        peer: String,
        channel: (any TransferChannel)?
    ) async throws -> String {
        guard let channel else {
            throw TransferError.noChannel
        }
        guard activeOutgoingCall[callId] == nil else {
            throw TransferError.transferAlreadyActive
        }
        let size: Int64
        let digest: String
        do {
            size = try fileSize(fileURL)
            digest = try FileDigest.sha256Hex(fileURL: fileURL)
        } catch let error as TransferError {
            throw error
        } catch {
            throw TransferError.unreadable
        }
        // chunkSize 0 → the core's default (16 KiB).
        let manifest = LKFileManifest.make(
            name: fileURL.lastPathComponent,
            size: UInt64(size),
            sha256Hex: digest,
            chunkSize: 0
        )
        let fileIdData = makeFileId()
        let hex = Hex.encode(fileIdData)
        let offer = LKFileOffer(callId: callId, fileId: hex, manifest: manifest)
        let envelope = Self.envelope(
            LKTypes.fileOffer, bodyJSON: offer.bodyJSON, ts: nowMs()
        )
        try await signaling.send(envelope)
        try? await channel.send(Data(envelope.wireJSON.utf8))
        peers[callId] = peer
        channels[callId] = channel
        outgoing[hex] = Outgoing(
            callId: callId,
            peer: peer,
            fileURL: fileURL,
            manifest: manifest,
            fileIdData: fileIdData,
            channel: channel,
            sender: nil,
            task: nil
        )
        activeOutgoingCall[callId] = hex
        return hex
    }

    /// The server fallback: upload, then record as a normal message with
    /// transport "server". Needs no accept — the bytes go straight up.
    @discardableResult
    public func sendViaServer(
        fileURL: URL,
        callId: String,
        peer: String
    ) async throws -> CompletedTransfer {
        guard !activeServerCalls.contains(callId) else {
            throw TransferError.transferAlreadyActive
        }
        activeServerCalls.insert(callId)
        defer { activeServerCalls.remove(callId) }
        let reply = try await server.upload(fileURL: fileURL)
        let completed = CompletedTransfer(
            callId: callId,
            fileId: reply.fileId,
            name: fileURL.lastPathComponent,
            size: reply.size,
            sha256: reply.sha256,
            transport: .server
        )
        await recordCompletion(completed, to: peer)
        eventsContinuation.yield(.completed(completed))
        return completed
    }

    /// Signaling envelopes: file.offer creates the receiver, file.accept
    /// starts the sender, file.cancel stops everything.
    public func handle(_ event: SignalingEvent) async {
        guard case let .envelope(envelope) = event else {
            return
        }
        await routeEnvelope(envelope)
    }

    /// Inbound data-channel frames: chunk frames to receivers, ack frames
    /// to senders, file.* envelopes to the same paths as signaling.
    public func handleInboundFrame(_ data: Data) async {
        // 1) An ack frame for one of our senders.
        if let ack = TransferFrames.parseAckFrame(data) {
            await outgoing[Hex.encode(ack.fileId)]?.sender?.handleInbound(data)
            return
        }
        // 2) A chunk frame for one of our receivers; its acks go back over
        //    the data channel.
        if let frame = LKFileChunker.parse(frame: data) {
            let hex = Hex.encode(frame.fileId)
            guard let entry = incoming[hex] else {
                return
            }
            let outcome = await entry.receiver.handleFrame(data)
            if let channel = channels[entry.callId] {
                for ackFrame in outcome.ackFrames {
                    try? await channel.send(ackFrame)
                }
            }
            await finishIncomingIfDone(hex)
            return
        }
        // 3) A file.* envelope riding the data channel.
        guard let json = String(data: data, encoding: .utf8),
              let envelope = LKEnvelope.parse(jsonString: json).envelope
        else {
            return
        }
        await routeEnvelope(envelope)
    }

    /// Cancels one transfer and announces it on both transports.
    public func cancel(callId: String, fileId: String, reason: String) async {
        let body = LKFileCancel(callId: callId, fileId: fileId, reason: reason)
        let envelope = Self.envelope(
            LKTypes.fileCancel, bodyJSON: body.bodyJSON, ts: nowMs()
        )
        try? await signaling.send(envelope)
        if let channel = channels[callId] {
            try? await channel.send(Data(envelope.wireJSON.utf8))
        }
        await stop(fileId: fileId, callId: callId, announce: true)
    }

    // MARK: - Envelope paths

    private func routeEnvelope(_ envelope: LKEnvelope) async {
        switch envelope.type {
        case LKTypes.fileOffer:
            await receiveFileOffer(envelope)
        case LKTypes.fileAccept:
            await startOutgoingSend(envelope)
        case LKTypes.fileCancel:
            await receiveFileCancel(envelope)
        default:
            break
        }
    }

    /// An inbound file.offer: register a receiver and answer file.accept on
    /// both transports. Duplicates (the envelope arrives via signaling and
    /// via the data channel) are ignored.
    private func receiveFileOffer(_ envelope: LKEnvelope) async {
        guard let offer = try? LKFileOffer.from(bodyJSON: envelope.bodyJSON),
              incoming[offer.fileId] == nil,
              let fileIdData = Hex.decode(offer.fileId)
        else {
            return
        }
        let receiver = P2PFileReceiver(manifest: offer.manifest, fileId: fileIdData)
        incoming[offer.fileId] = Incoming(
            callId: offer.callId, fileIdHex: offer.fileId, receiver: receiver
        )
        forwardProgress(receiver.progress)
        let body = LKFileAccept(callId: offer.callId, fileId: offer.fileId)
        let accept = Self.envelope(
            LKTypes.fileAccept, bodyJSON: body.bodyJSON, ts: nowMs()
        )
        try? await signaling.send(accept)
        if let channel = channels[offer.callId] {
            try? await channel.send(Data(accept.wireJSON.utf8))
        }
    }

    /// A file.accept for one of our offers: build the sender and start its
    /// loop under a completion task. Duplicates are ignored.
    private func startOutgoingSend(_ envelope: LKEnvelope) async {
        guard let accept = try? LKFileAccept.from(bodyJSON: envelope.bodyJSON),
              var entry = outgoing[accept.fileId],
              entry.sender == nil,
              let sender = try? P2PFileSender(
                  fileURL: entry.fileURL,
                  manifest: entry.manifest,
                  fileId: entry.fileIdData,
                  channel: entry.channel
              )
        else {
            return
        }
        entry.sender = sender
        entry.task = Task {
            await self.driveOutgoing(fileId: accept.fileId, sender: sender)
        }
        outgoing[accept.fileId] = entry
        forwardProgress(sender.progress)
    }

    private func receiveFileCancel(_ envelope: LKEnvelope) async {
        guard let cancel = try? LKFileCancel.from(bodyJSON: envelope.bodyJSON) else {
            return
        }
        // The peer already announced the cancel on both transports.
        await stop(fileId: cancel.fileId, callId: cancel.callId, announce: false)
    }
}
