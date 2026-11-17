// TransferCoordinator lifecycle (Plan 4 Task 11): the outgoing/incoming
// transfer state machines and the recording plumbing, split into a
// same-module extension so each file stays inside the lint budgets. The
// nested state structs live here; the coordinator actor's stored
// properties are internal for exactly this file.

import CoreBridge
import Foundation

extension TransferCoordinator {
    // MARK: - Outgoing lifecycle

    /// Runs the sender and waits for every chunk to be acknowledged; then
    /// records the transfer as a normal msg.send message and surfaces the
    /// completion. Channel failures surface `TransferError` for the UI's
    /// "Send via server" fallback; cancellation is silent (cancel() owns
    /// the announcement).
    func driveOutgoing(fileId: String, sender: P2PFileSender) async {
        guard let entry = outgoing[fileId] else {
            return
        }
        do {
            try await sender.run()
            // All chunks are on the wire; completion is the receiver's last
            // acknowledgement. Cancel (flag or task) ends the wait.
            while await sender.nextToSend < entry.manifest.chunkCount {
                try? await Task.sleep(for: .milliseconds(5))
                if Task.isCancelled {
                    return
                }
            }
            outgoing.removeValue(forKey: fileId)
            if activeOutgoingCall[entry.callId] == fileId {
                activeOutgoingCall[entry.callId] = nil
            }
            let completed = CompletedTransfer(
                callId: entry.callId,
                fileId: fileId,
                name: entry.manifest.name,
                size: Int64(entry.manifest.size),
                sha256: entry.manifest.sha256Hex,
                transport: .p2p
            )
            await recordCompletion(completed, to: entry.peer)
            eventsContinuation.yield(.completed(completed))
        } catch is CancellationError {
            // Task cancellation rides along with cancel(); it announced.
        } catch let error as TransferError where error == .cancelled {
            // cancel() announced it; nothing to record.
        } catch let error as TransferError {
            failOutgoing(fileId: fileId, callId: entry.callId, reason: error)
        } catch {
            failOutgoing(fileId: fileId, callId: entry.callId, reason: .channelClosed)
        }
    }

    func failOutgoing(fileId: String, callId: String, reason: TransferError) {
        outgoing.removeValue(forKey: fileId)
        if activeOutgoingCall[callId] == fileId {
            activeOutgoingCall[callId] = nil
        }
        eventsContinuation.yield(.failed(callId: callId, fileId: fileId, reason: reason))
    }

    // MARK: - Incoming lifecycle

    /// Records an inbound transfer once its receiver reached a terminal
    /// state: completed → recorded as msg.send (transport "p2p"); corrupt →
    /// failed event for the UI.
    func finishIncomingIfDone(_ fileIdHex: String) async {
        guard let entry = incoming[fileIdHex] else {
            return
        }
        let state = await entry.receiver.state
        guard case .completed = state else {
            if case let .failed(error) = state {
                incoming.removeValue(forKey: fileIdHex)
                eventsContinuation.yield(
                    .failed(callId: entry.callId, fileId: fileIdHex, reason: error)
                )
            }
            return
        }
        incoming.removeValue(forKey: fileIdHex)
        let manifest = entry.receiver.manifest
        let completed = CompletedTransfer(
            callId: entry.callId,
            fileId: fileIdHex,
            name: manifest.name,
            size: Int64(manifest.size),
            sha256: manifest.sha256Hex,
            transport: .p2p
        )
        await recordCompletion(completed, to: peers[entry.callId] ?? "")
        eventsContinuation.yield(.completed(completed))
    }

    // MARK: - Shared plumbing

    func stop(fileId: String, callId: String, announce: Bool) async {
        if var entry = outgoing[fileId] {
            await entry.sender?.cancel()
            entry.task?.cancel()
            entry.task = nil
            outgoing.removeValue(forKey: fileId)
            if activeOutgoingCall[callId] == fileId {
                activeOutgoingCall[callId] = nil
            }
        }
        // A receiver removed here simply goes away: a cancel before
        // completion records nothing.
        incoming.removeValue(forKey: fileId)
        if announce {
            eventsContinuation.yield(.cancelled(callId: callId, fileId: fileId))
        }
    }

    func recordCompletion(_ completed: CompletedTransfer, to peer: String) async {
        let meta = LKFileMeta(
            name: completed.name,
            size: completed.size,
            sha256: completed.sha256,
            transport: completed.transport.rawValue,
            fileId: completed.fileId
        )
        let body = LKMsgSend(identifier: UUID().uuidString, to: peer, text: "", file: meta)
        let envelope = Self.envelope(
            LKTypes.msgSend, bodyJSON: body.bodyJSON, ts: nowMs()
        )
        await recorder.record(envelope)
    }

    func forwardProgress(_ stream: AsyncStream<TransferProgress>) {
        Task {
            for await progress in stream {
                eventsContinuation.yield(.progress(progress))
            }
        }
    }

    func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw TransferError.unreadable
        }
        return number.int64Value
    }

    static func envelope(_ type: String, bodyJSON: String, ts: Int64) -> LKEnvelope {
        LKEnvelope(v: 1, type: type, id: UUID().uuidString, ts: ts, bodyJSON: bodyJSON)
    }
}
