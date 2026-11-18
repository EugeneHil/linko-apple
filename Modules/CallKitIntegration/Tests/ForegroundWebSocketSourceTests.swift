// ForegroundWebSocketSourceTests (Plan 4 Task 10 / LNK-36): the sole invite
// source — call.invite envelopes on the signaling event stream become
// IncomingCall values; every other event is dropped; the stream splitter
// feeds the coordinator and the source from one SignalingClient stream
// without an invite ever reaching the coordinator's copy twice.

@testable import CallKitIntegration
import Calls
import CoreBridge
import Foundation
import Signaling
import XCTest

/// Builds a call.invite envelope.
private func inviteEnvelope(callId: String, peer: String, media: String) -> LKEnvelope {
    LKEnvelope(
        v: 1,
        type: LKTypes.callInvite,
        id: "env-invite-\(callId)",
        ts: 1000,
        bodyJSON: LKCallInvite(callId: callId, to: peer, media: media).bodyJSON
    )
}

final class ForegroundWebSocketSourceTests: XCTestCase {
    func test_invite_envelope_becomes_incoming_call() async {
        let (events, continuation) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .unbounded)
        let source = ForegroundWebSocketSource(events: events)

        continuation.yield(.envelope(inviteEnvelope(callId: "c1", peer: "bob", media: "video")))
        var iterator = source.calls.makeAsyncIterator()
        let call = await iterator.next()

        XCTAssertEqual(call, IncomingCall(callId: "c1", peer: "bob", video: true))
    }

    func test_other_events_are_dropped() async {
        let (events, continuation) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .unbounded)
        let source = ForegroundWebSocketSource(events: events)

        continuation.yield(.connected)
        continuation.yield(.disconnected(code: 1006))
        continuation.yield(.envelope(inviteEnvelope(callId: "c1", peer: "bob", media: "audio")))
        var iterator = source.calls.makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertEqual(first, IncomingCall(callId: "c1", peer: "bob", video: false))
    }

    func test_malformed_invite_body_is_dropped() async {
        let (events, continuation) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .unbounded)
        let source = ForegroundWebSocketSource(events: events)

        continuation.yield(.envelope(LKEnvelope(
            v: 1,
            type: LKTypes.callInvite,
            id: "env-bad",
            ts: 1000,
            bodyJSON: "{\"callId\":42}"
        )))
        continuation.finish()
        var iterator = source.calls.makeAsyncIterator()

        let call = await iterator.next()
        XCTAssertNil(call)
    }

    func test_split_feeds_coordinator_and_source() async {
        let (events, continuation) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .unbounded)
        let split = ForegroundWebSocketSource.split(events)

        var sourceIterator = split.source.calls.makeAsyncIterator()
        var coordinatorIterator = split.events.makeAsyncIterator()

        continuation.yield(.envelope(inviteEnvelope(callId: "c1", peer: "bob", media: "audio")))
        continuation.yield(.connected)

        let call = await sourceIterator.next()
        XCTAssertEqual(call, IncomingCall(callId: "c1", peer: "bob", video: false))

        let firstEvent = await coordinatorIterator.next()
        guard case let .envelope(envelope) = firstEvent else {
            XCTFail("expected the envelope event on the coordinator copy")
            return
        }
        XCTAssertEqual(envelope.type, LKTypes.callInvite)
        let secondEvent = await coordinatorIterator.next()
        guard case .connected = secondEvent else {
            XCTFail("expected the connected event on the coordinator copy")
            return
        }

        continuation.finish()
        let sourceDone = await sourceIterator.next()
        let coordinatorDone = await coordinatorIterator.next()
        XCTAssertNil(sourceDone)
        XCTAssertNil(coordinatorDone)
    }
}
