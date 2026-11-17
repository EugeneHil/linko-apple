// TDD boundary tests (Plan 4 Task 2 / LNK-28, Step 1): the bridge must
// re-prove the core contracts end-to-end — envelope validation with paths,
// the call state machine, file chunking and the sync helpers — through the
// Objective-C surface Swift consumes.

import CoreBridge
import CryptoKit
import XCTest

final class CoreBridgeBoundaryTests: XCTestCase {
    // MARK: - Envelope parsing (Review Focus 2: hostile envelopes surface as errors)

    func test_envelope_errors_carry_paths() throws {
        // call.offer without the mandatory sdp: the envelope-level fields are
        // fine, so the typed body accessor is where "body.sdp" must appear.
        let wire =
            #"{"v":1,"type":"call.offer","id":"6f1c","ts":1792877416123,"body":{"callId":"c7a2","to":"anna","media":"video"}}"#
        let parsed = LKEnvelope.parse(jsonString: wire)
        let envelope = try XCTUnwrap(parsed.envelope, "envelope-level fields are valid")
        XCTAssertTrue(parsed.errors.isEmpty)

        XCTAssertThrowsError(try LKCallSdp.from(bodyJSON: envelope.bodyJSON)) { error in
            let userInfo = (error as NSError).userInfo
            XCTAssertEqual(userInfo[LKBodyErrorPathKey] as? String, "body.sdp", "the error must carry its JSON path")
            XCTAssertEqual(userInfo[LKBodyErrorMessageKey] as? String, "missing", "the error must carry its message")
        }
    }

    func test_unsupported_version_flagged() {
        let parsed = LKEnvelope.parse(
            jsonString: #"{"v":2,"type":"session.ping","id":"6f1c","ts":1792877416123,"body":{}}"#
        )
        XCTAssertNil(parsed.envelope, "v != 1 must not parse into an envelope")
        XCTAssertTrue(parsed.unsupportedVersion, "the caller must be able to answer session.error{unsupported_version}")
        XCTAssertFalse(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.errors.first?.path, "v")
    }

    // MARK: - Call state machine

    func test_outgoing_happy_path_effects() {
        let machine = LKCallStateMachine(state: .idle())
        let effects = machine.apply(event: LKCallEvent(kind: .localInvite, callId: "c7a2", peer: "anna", video: false))

        XCTAssertEqual(machine.state.kind, .outgoingRinging)
        XCTAssertEqual(machine.state.callId, "c7a2")
        XCTAssertEqual(machine.state.peer, "anna")
        XCTAssertFalse(machine.state.video)
        XCTAssertEqual(machine.state.endReason, .normal)
        XCTAssertEqual(effects.map(\.kind), [.sendMessage, .startTimer])
        XCTAssertEqual(effects[0].messageType, LKTypes.callInvite)
        XCTAssertEqual(effects[1].timeoutMs, 45000, "the ring budget is 45 s (kRingTimeoutMs)")
    }

    func test_glare_smaller_call_id_survives() {
        // Our outgoing call carries the larger id: the peer's smaller call id
        // wins and we take their call as incoming after withdrawing ours.
        let loser = LKCallStateMachine(
            state: LKCallState(kind: .outgoingRinging, callId: "zz11", peer: "anna", video: false, endReason: .normal)
        )
        let withdrawEffects = loser.apply(event: LKCallEvent(kind: .remoteInvite, callId: "aa00", peer: "bob", video: false))

        XCTAssertEqual(loser.state.kind, .incomingRinging)
        XCTAssertEqual(loser.state.callId, "aa00")
        XCTAssertEqual(loser.state.peer, "bob")
        XCTAssertEqual(withdrawEffects.map(\.kind), [.sendMessage, .startRinging, .reportIncoming, .cancelTimer, .startTimer])
        XCTAssertEqual(withdrawEffects.first?.messageType, LKTypes.callCancel)

        // And the mirror case: our smaller id survives; the peer hears busy.
        let survivor = LKCallStateMachine(
            state: LKCallState(kind: .outgoingRinging, callId: "aa00", peer: "anna", video: false, endReason: .normal)
        )
        let busyEffects = survivor.apply(event: LKCallEvent(kind: .remoteInvite, callId: "zz11", peer: "bob", video: false))

        XCTAssertEqual(survivor.state.kind, .outgoingRinging)
        XCTAssertEqual(survivor.state.callId, "aa00")
        XCTAssertEqual(busyEffects.map(\.kind), [.sendMessage])
        XCTAssertEqual(busyEffects.first?.messageType, LKTypes.callBusy)
    }

    func test_no_effects_after_ended() {
        let machine = LKCallStateMachine(
            state: LKCallState(kind: .ended, callId: "c7a2", peer: "anna", video: false, endReason: .normal)
        )
        XCTAssertTrue(
            machine.apply(event: LKCallEvent(kind: .remoteHangup, callId: "c7a2", peer: "anna", video: false)).isEmpty,
            "remoteHangup must produce no effects after Ended"
        )
        XCTAssertTrue(
            machine.apply(event: LKCallEvent(kind: .localHangup, callId: "c7a2", peer: "anna", video: false)).isEmpty,
            "localHangup must produce no effects after Ended"
        )
        XCTAssertTrue(
            machine.apply(event: LKCallEvent(kind: .iceConnected, callId: "c7a2", peer: "", video: false)).isEmpty,
            "iceConnected must produce no effects after Ended"
        )
        XCTAssertTrue(
            machine.apply(event: LKCallEvent(kind: .remoteInvite, callId: "aa00", peer: "bob", video: false)).isEmpty,
            "a new remoteInvite must produce no effects after Ended"
        )
        XCTAssertEqual(machine.state.kind, .ended, "Ended is terminal")
        XCTAssertEqual(machine.state.callId, "c7a2")
        XCTAssertEqual(machine.state.endReason, .normal)
    }

    func test_events_for_other_call_ignored() {
        let machine = LKCallStateMachine(
            state: LKCallState(kind: .active, callId: "c7a2", peer: "anna", video: false, endReason: .normal)
        )

        let foreign = machine.apply(event: LKCallEvent(kind: .remoteHangup, callId: "other", peer: "anna", video: false))
        XCTAssertTrue(foreign.isEmpty)
        XCTAssertEqual(machine.state.kind, .active)
        XCTAssertEqual(machine.state.callId, "c7a2")

        // An empty callId addresses no call at all.
        let empty = machine.apply(event: LKCallEvent(kind: .remoteHangup, callId: "", peer: "anna", video: false))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(machine.state.kind, .active)
    }

    // MARK: - File chunking

    func test_chunk_framing_roundtrip() throws {
        let fileId = Data((0 ..< 16).map { UInt8($0) })
        let payload = Data("hello linko".utf8)

        let frame = try XCTUnwrap(LKFileChunker.frameChunk(fileId: fileId, index: 3, payload: payload))
        let parsed = try XCTUnwrap(LKFileChunker.parse(frame: frame))
        XCTAssertEqual(parsed.fileId, fileId)
        XCTAssertEqual(parsed.index, 3)
        XCTAssertEqual(parsed.payload, payload)

        // A fileId that is not 16 raw bytes cannot be framed.
        XCTAssertNil(LKFileChunker.frameChunk(fileId: Data(repeating: 0, count: 15), index: 0, payload: payload))
        // Truncated frames are rejected: the length field must match exactly.
        XCTAssertNil(LKFileChunker.parse(frame: Data(frame.prefix(frame.count - 1))))
    }

    func test_reassembler_corrupt_payload_fails() {
        // "linko" split into the 4-byte chunk "link" and the 1-byte last chunk
        // "o"; the last chunk arrives bit-flipped: the size matches so it is
        // stored, but the digest check must never hand out wrong bytes.
        let content = Data("linko".utf8)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let manifest = LKFileManifest.make(name: "hello.txt", size: 5, sha256Hex: digest, chunkSize: 4)
        XCTAssertEqual(manifest.chunkCount, 2)
        XCTAssertEqual(manifest.chunkSize, 4)

        let reassembler = LKFileReassembler(manifest: manifest)
        XCTAssertEqual(reassembler.addChunk(index: 0, payload: Data("link".utf8)), .accepted)
        XCTAssertEqual(
            reassembler.addChunk(index: 1, payload: Data("o?".utf8)),
            .unexpected,
            "the last chunk is 1 byte: 2 bytes exceed the manifest's expectation"
        )
        XCTAssertEqual(reassembler.addChunk(index: 1, payload: Data("O".utf8)), .accepted, "a same-size corrupt chunk passes the size gate")
        XCTAssertEqual(reassembler.receivedBytes, 5)
        XCTAssertNil(reassembler.takeIfCompleteAndValid(), "corrupt bytes must never complete")

        // The stored corrupt bytes stand; re-delivering the index is a duplicate.
        XCTAssertEqual(reassembler.addChunk(index: 1, payload: Data("o".utf8)), .duplicate)
        XCTAssertNil(reassembler.takeIfCompleteAndValid())

        // A clean assembly over the same manifest does complete.
        let clean = LKFileReassembler(manifest: manifest)
        XCTAssertEqual(clean.addChunk(index: 1, payload: Data("o".utf8)), .accepted)
        XCTAssertEqual(clean.addChunk(index: 0, payload: Data("link".utf8)), .accepted)
        XCTAssertEqual(clean.takeIfCompleteAndValid(), content)

        // Outside the manifest: unexpected, never stored. A stored index wins
        // over any payload check: the stored bytes stand.
        XCTAssertEqual(clean.addChunk(index: 2, payload: Data("x".utf8)), .unexpected)
        XCTAssertEqual(clean.addChunk(index: 0, payload: Data("x".utf8)), .duplicate, "a stored index is a duplicate regardless of the payload")
        XCTAssertEqual(clean.nextIndexNeeded, 2, "every index is present")
    }

    func test_ack_tracker_resume_point() {
        let tracker = LKAckTracker()
        XCTAssertEqual(tracker.nextToSend, 0)

        tracker.ack(index: 0)
        tracker.ack(index: 1)
        XCTAssertEqual(tracker.nextToSend, 2)

        tracker.ack(index: 3)
        tracker.ack(index: 4)
        XCTAssertEqual(tracker.nextToSend, 2, "acks ahead of a gap must not skip the missing chunk")

        tracker.ack(index: 2)
        XCTAssertEqual(tracker.nextToSend, 5, "the gap closed: the resume point jumps past the queued acks")

        tracker.ack(index: 1)
        XCTAssertEqual(tracker.nextToSend, 5, "duplicate acks behind the resume point change nothing")
    }

    // MARK: - Conversation history

    private func record(id: String, seq: Int64, timestamp: Int64 = 100) -> LKMessageRecord {
        LKMessageRecord(identifier: id, from: "anna", to: "bob", text: "hi \(seq)", file: nil, seq: seq, ts: timestamp)
    }

    func test_history_orders_by_seq() {
        let history = LKConversationHistory()
        XCTAssertTrue(history.add(record(id: "m3", seq: 3)))
        XCTAssertTrue(history.add(record(id: "m1", seq: 1)))
        XCTAssertTrue(history.add(record(id: "m2", seq: 2)))

        XCTAssertEqual(history.afterSeq(0).map(\.identifier), ["m1", "m2", "m3"])
        XCTAssertEqual(history.afterSeq(2).map(\.identifier), ["m3"])
        XCTAssertTrue(history.afterSeq(3).isEmpty)
    }

    func test_history_receipts_never_regress() throws {
        let history = LKConversationHistory()
        for seq in 1 ... 5 {
            XCTAssertTrue(history.add(record(id: "m\(seq)", seq: Int64(seq))))
        }

        history.markDelivered(uptoSeq: 5)
        history.markDelivered(uptoSeq: 2)
        XCTAssertEqual(try XCTUnwrap(history.receiptFor("m5")).delivered, true, "a lower watermark must not undo delivery")
        XCTAssertEqual(try XCTUnwrap(history.receiptFor("m5")).read, false)

        history.markRead(uptoSeq: 4)
        let third = try XCTUnwrap(history.receiptFor("m3"))
        XCTAssertTrue(third.read, "read implies delivered")
        XCTAssertTrue(third.delivered)
        let fifth = try XCTUnwrap(history.receiptFor("m5"))
        XCTAssertFalse(fifth.read, "above the read watermark only delivery is known")
        XCTAssertTrue(fifth.delivered)

        history.markRead(uptoSeq: 1)
        XCTAssertTrue(try XCTUnwrap(history.receiptFor("m3")).read, "reads never regress: m3 stays read")
        XCTAssertFalse(try XCTUnwrap(history.receiptFor("m5")).read, "reads never regress: m5 stays unread")

        XCTAssertNil(history.receiptFor("nope"), "unknown ids have no receipt")
    }

    func test_history_gap_detected() {
        let history = LKConversationHistory()
        XCTAssertFalse(history.hasGapAfter(0), "an empty history has no gap")

        XCTAssertTrue(history.add(record(id: "m1", seq: 1)))
        XCTAssertTrue(history.add(record(id: "m2", seq: 2)))
        XCTAssertTrue(history.add(record(id: "m4", seq: 4)))
        XCTAssertTrue(history.hasGapAfter(0), "3 is missing")
        XCTAssertFalse(history.hasGapAfter(3), "everything above 3 is contiguous")
        XCTAssertTrue(history.afterSeq(0).map(\.seq) == [1, 2, 4])

        // Duplicate ids are rejected idempotently; the first record wins.
        XCTAssertFalse(history.add(record(id: "m4", seq: 4)))
        XCTAssertEqual(history.lastError, .duplicateId)
        // A server seq starts at 1.
        XCTAssertFalse(history.add(record(id: "m0", seq: 0)))
        XCTAssertEqual(history.lastError, .invalidSeq)
        // Nothing was stored by the rejected adds.
        XCTAssertEqual(history.afterSeq(0).count, 3)

        // Closing the gap clears the flag.
        XCTAssertTrue(history.add(record(id: "m3", seq: 3)))
        XCTAssertFalse(history.hasGapAfter(0))
    }
}
