// CallCoordinator tests (Plan 4 Task 9 / LNK-35): the fourteen plan-named
// behaviors, wired through the real bridge machine — every transition goes
// through LKCallStateMachine and the machine's effects are the only
// outputs. Fakes cover signaling, engine, reporting, incoming source,
// network, uploads and timers (FakeWorld.swift).

import CallEngine
@testable import Calls
import CallStats
import CoreBridge
import Foundation
import Signaling
import XCTest

@MainActor
final class CallCoordinatorTests: XCTestCase {
    // MARK: Plan test 1: outgoing invite

    func test_outgoing_invite_sends_and_rings() async throws {
        let fixture = await makeFixture(test: self)

        try await fixture.startOutgoingCall(peer: "anna", media: .audio)

        // LocalInvite's SendMessage effect reaches the wire as call.invite.
        let invite = try XCTUnwrap(fixture.signaling.sentEnvelope(ofType: LKTypes.callInvite))
        let body = try XCTUnwrap(LKCallInvite.from(bodyJSON: invite.bodyJSON))
        XCTAssertEqual(body.to, "anna")
        XCTAssertEqual(body.media, CallMedia.audio.rawValue)
        XCTAssertEqual(body.callId, "zz11")
        // The engine was prepared for the media mode the caller asked for.
        XCTAssertEqual(fixture.engine.prepared, [.audio])
        // The StartTimer effect arms the ring budget: 45 s.
        try await waitUntil("the ring timer is armed for 45 s") {
            fixture.clock.hasSleep(kind: .ring, milliseconds: 45000)
        }
        // The UI-facing stream carries the machine state.
        let published = fixture.states.recorded.first
        XCTAssertEqual(published?.kind, .outgoingRinging)
        XCTAssertEqual(published?.callId, "zz11")
        let outgoingState = fixture.coordinator.currentState
        XCTAssertEqual(outgoingState.kind, .outgoingRinging)
    }

    // MARK: Plan test 2: incoming accept

    func test_incoming_accept_connects_and_stops_ringing() async throws {
        let fixture = await makeFixture(test: self)

        try await fixture.makeActiveCall(callId: "c1", peer: "bob")

        // RemoteInvite reported the call; LocalAccept stopped the ringing.
        XCTAssertEqual(fixture.reporting.incoming, [.init(callId: "c1", peer: "bob", video: false)])
        XCTAssertEqual(fixture.reporting.stopRingingCount, 1)
        // The callee's accept rode the wire for the same call id.
        let accept = try XCTUnwrap(fixture.signaling.sentEnvelope(ofType: LKTypes.callAccept))
        XCTAssertEqual(try LKCallRef.from(bodyJSON: accept.bodyJSON).callId, "c1")
        // The callee's engine answered after preparing for the invited media.
        XCTAssertEqual(fixture.engine.prepared, [.audio])
        XCTAssertEqual(fixture.engine.acceptCount, 1)
        // IceConnected turned the machine Active.
        let activeState = fixture.coordinator.currentState
        XCTAssertEqual(activeState.kind, .active)
        XCTAssertEqual(activeState.callId, "c1")
        // The connect budget was armed at accept: 20 s.
        try await waitUntil("the connect timer is armed for 20 s") {
            fixture.clock.hasSleep(kind: .connect, milliseconds: 20000)
        }
    }

    // MARK: Plan test 3: remote hangup uploads the report exactly once

    func test_remote_hangup_ends_and_reports() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")

        fixture.simulateEnvelope(callEndEnvelope(type: LKTypes.callHangup, callId: "c1"))

        try await waitUntil("the end-of-call report is uploaded") {
            fixture.uploader.posts.count == 1
        }
        XCTAssertEqual(fixture.reporting.ended, [.init(callId: "c1", reason: .normal)])
        try await waitUntil("capture is released through the engine") {
            fixture.engine.hangupCount == 1
        }
        try await waitUntil("the machine resets for the next call") {
            await fixture.coordinator.currentState.kind == .idle
        }
        // Exactly once: the count stays at one after settling.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.uploader.posts.count, 1)
        XCTAssertEqual(try XCTUnwrap(fixture.uploader.posts.first).callId, "c1")
    }

    // MARK: Plan test 4: busy

    func test_busy_received_ends_call() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.startOutgoingCall(peer: "anna")

        fixture.simulateEnvelope(callEndEnvelope(type: LKTypes.callBusy, callId: "zz11"))

        let ended = try await fixture.nextState(where: { $0.kind == .ended }, description: "an ended state")
        XCTAssertEqual(ended?.endReason, .busy)
        XCTAssertEqual(ended?.callId, "zz11")
        XCTAssertEqual(fixture.reporting.ended, [.init(callId: "zz11", reason: .busy)])
        try await waitUntil("the report is uploaded once") {
            fixture.uploader.posts.count == 1
        }
        try await waitUntil("capture is released") {
            fixture.engine.hangupCount == 1
        }
    }

    // MARK: Plan test 5: the ring timer expires

    func test_ring_timer_missed_sends_cancel() async throws {
        // Plan note: the core v0.1.0 pins the ring-timeout cleanup to the
        // SERVER (it answers the callee with call.cancel — the server plan's
        // test_ring_timeout_sends_cancel_and_cleans_up). The client machine
        // emits reportEnded(Timeout) only, and the coordinator invents no
        // send of its own — this test pins exactly that.
        let fixture = await makeFixture(test: self)
        try await fixture.startOutgoingCall(peer: "anna")
        let sentBefore = fixture.signaling.sentEnvelopes.count

        try await waitUntil("the ring timer is armed") {
            fixture.clock.hasSleep(kind: .ring, milliseconds: 45000)
        }
        fixture.clock.fire(.ring)

        let ended = try await fixture.nextState(where: { $0.kind == .ended }, description: "an ended state")
        XCTAssertEqual(ended?.endReason, .timeout)
        XCTAssertEqual(fixture.reporting.ended, [.init(callId: "zz11", reason: .timeout)])
        // No client-side cancel: the machine pins no SendMessage for this
        // timeout, and the coordinator adds nothing.
        XCTAssertEqual(fixture.signaling.sentEnvelopes.count, sentBefore)
        try await waitUntil("the report is uploaded once") {
            fixture.uploader.posts.count == 1
        }
        try await waitUntil("capture is released") {
            fixture.engine.hangupCount == 1
        }
    }

    // MARK: Plan test 6: connect timeout

    func test_connect_timeout_ends_call() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeConnectingCall(callId: "c1")

        try await waitUntil("the connect timer is armed") {
            fixture.clock.hasSleep(kind: .connect, milliseconds: 20000)
        }
        fixture.clock.fire(.connect)

        let ended = try await fixture.nextState(where: { $0.kind == .ended }, description: "an ended state")
        XCTAssertEqual(ended?.endReason, .timeout)
        XCTAssertEqual(fixture.reporting.ended, [.init(callId: "c1", reason: .timeout)])
        try await waitUntil("the report is uploaded once") {
            fixture.uploader.posts.count == 1
        }
        try await waitUntil("capture is released") {
            fixture.engine.hangupCount == 1
        }
    }

    // MARK: Plan test 7: reconnect timeout

    func test_reconnect_timeout_ends_call() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")

        // IceFailed moves the machine to Reconnecting: the reconnect budget
        // is armed and the StartIceRestart effect reaches the engine.
        fixture.engine.fireConnectionState(.failed)
        try await waitUntil("the engine restarts ICE") {
            fixture.engine.restartIceCount == 1
        }
        try await waitUntil("the reconnect timer is armed for 15 s") {
            fixture.clock.hasSleep(kind: .reconnect, milliseconds: 15000)
        }
        fixture.clock.fire(.reconnect)

        let ended = try await fixture.nextState(where: { $0.kind == .ended }, description: "an ended state")
        XCTAssertEqual(ended?.endReason, .error)
        XCTAssertEqual(fixture.reporting.ended, [.init(callId: "c1", reason: .error)])
        try await waitUntil("the report is uploaded once") {
            fixture.uploader.posts.count == 1
        }
    }

    // MARK: Plan test 8: network change

    func test_network_change_triggers_ice_restart_effect() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")

        fixture.network.yield(NetworkState(interface: .cellular, isLowDataMode: false))

        // The machine's NetworkChanged → StartIceRestart effect reaches the
        // engine, and the restarted offer reaches the peer via the wire.
        try await waitUntil("the engine restarts ICE") {
            fixture.engine.restartIceCount == 1
        }
        try await waitUntil("the restarted offer is sent") {
            fixture.signaling.sentTypes.contains(LKTypes.callOffer)
        }
        // The adaptation policy's plan rides the same input (cellular cap).
        XCTAssertEqual(fixture.engine.bitratePlans, [BitratePlan(maxVideoBitrateBps: 500_000)])
        // The call itself stays up.
        let stillActive = fixture.coordinator.currentState
        XCTAssertEqual(stillActive.kind, .active)
    }

    // MARK: Plan test 9: the data-channel fallback

    func test_hangup_sent_over_data_channel_when_open() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")

        fixture.engine.fireDataChannelState(true)
        try await waitUntil("the data channel is open") {
            await fixture.coordinator.isDataChannelOpen
        }
        let sentBefore = fixture.signaling.sentEnvelopes.count

        await fixture.coordinator.hangup()

        // The hangup rides the open channel; the server hears nothing.
        XCTAssertEqual(fixture.engine.channelSends.count, 1)
        let data = try XCTUnwrap(fixture.engine.channelSends.first)
        let wire = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(wire.contains("call.hangup"), "the envelope wire JSON rides the channel: \(wire)")
        XCTAssertTrue(wire.contains("c1"))
        XCTAssertEqual(fixture.signaling.sentEnvelopes.count, sentBefore)
    }

    // MARK: Plan test 10: no channel, the server carries the send

    func test_hangup_goes_to_server_without_channel() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")

        await fixture.coordinator.hangup()

        XCTAssertEqual(fixture.signaling.sentTypes.last, LKTypes.callHangup)
        XCTAssertTrue(fixture.engine.channelSends.isEmpty)
        let hangup = try XCTUnwrap(fixture.signaling.sentEnvelope(ofType: LKTypes.callHangup))
        XCTAssertEqual(try LKCallEnd.from(bodyJSON: hangup.bodyJSON).callId, "c1")
    }

    // MARK: Plan test 11: glare

    func test_crossed_calls_smaller_call_id_survives() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.startOutgoingCall(peer: "anna") // ours: zz11

        // The peer's invite carries the smaller call id: glare resolves in
        // their favor — our call is withdrawn on the wire and theirs rings
        // as incoming through the real bridge machine.
        fixture.source.yield(IncomingCall(callId: "aa00", peer: "bob", video: false))

        try await waitUntil("our call is withdrawn with call.cancel") {
            fixture.signaling.sentTypes.contains(LKTypes.callCancel)
        }
        let cancelled = try XCTUnwrap(fixture.signaling.sentEnvelope(ofType: LKTypes.callCancel))
        XCTAssertEqual(try LKCallEnd.from(bodyJSON: cancelled.bodyJSON).callId, "zz11")
        XCTAssertEqual(fixture.reporting.incoming.last, .init(callId: "aa00", peer: "bob", video: false))
        let incomingState = fixture.coordinator.currentState
        XCTAssertEqual(incomingState.kind, .incomingRinging)
        XCTAssertEqual(incomingState.callId, "aa00")
        // The ring budget was re-armed for their call (armed twice in total).
        try await waitUntil("the ring timer is re-armed for the surviving call") {
            fixture.clock.recordedSleeps.filter { $0.kind == .ring && $0.milliseconds == 45000 }.count == 2
        }
    }

    // MARK: Plan test 12: foreign events

    func test_events_for_other_call_ignored() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")

        // A foreign hangup on the signaling path and one over the channel:
        // the machine ignores both (they address another call).
        fixture.simulateEnvelope(callEndEnvelope(type: LKTypes.callHangup, callId: "other"))
        fixture.engine.fireDataChannelMessage(
            Data(callEndEnvelope(type: LKTypes.callHangup, callId: "also-other").wireJSON.utf8)
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        let untouched = fixture.coordinator.currentState
        XCTAssertEqual(untouched.kind, .active)
        XCTAssertEqual(untouched.callId, "c1")
        XCTAssertTrue(fixture.reporting.ended.isEmpty)
        XCTAssertEqual(fixture.engine.hangupCount, 0)
        XCTAssertTrue(fixture.uploader.posts.isEmpty)
    }

    // MARK: Plan test 13: exactly one active call

    func test_only_one_active_call() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")
        let sentBefore = fixture.signaling.sentEnvelopes.count

        // The second invite is rejected at coordinator level: no wire send,
        // no engine churn, the first call stays active.
        await fixture.coordinator.invite(peer: "carl", media: .video)

        XCTAssertEqual(fixture.signaling.sentEnvelopes.count, sentBefore)
        XCTAssertEqual(fixture.engine.prepared.count, 1)
        let firstCall = fixture.coordinator.currentState
        XCTAssertEqual(firstCall.kind, .active)
        XCTAssertEqual(firstCall.callId, "c1")
    }

    // MARK: Plan test 14: capture release

    func test_capture_released_after_end() async throws {
        let fixture = await makeFixture(test: self)
        try await fixture.makeActiveCall(callId: "c1")

        await fixture.coordinator.hangup()

        // The coordinator releases capture through the engine's hangup.
        try await waitUntil("capture is released through the engine") {
            fixture.engine.hangupCount == 1
        }
        try await waitUntil("the machine resets for the next call") {
            await fixture.coordinator.currentState.kind == .idle
        }
        // The ended report was uploaded before the engine was released.
        XCTAssertEqual(fixture.uploader.posts.count, 1)
    }
}
