// CallCoordinator+Wire (Plan 4 Task 9): the coordinator's wire half — the
// consumers of every input stream (signaling events, incoming calls, engine
// streams, network states), the call.* envelope → machine event mapping and
// the mechanical rendering of what a pure machine cannot carry (SDP and
// candidate payloads) plus the in-call control fallback (spec 4.2).

import CallEngine
import CallStats
import CoreBridge
import Foundation
import Signaling

extension CallCoordinator {
    // MARK: - Consuming loops

    func consumeSignalingEvents() async {
        for await event in signalingEvents {
            switch event {
            case let .envelope(envelope):
                await handleEnvelope(envelope)
            case .connected, .disconnected, .error:
                break // transport lifecycle is the SignalingClient's own affair
            }
        }
    }

    func consumeIncomingCalls() async {
        for await incoming in source.calls {
            await apply(LKCallEvent(
                kind: .remoteInvite,
                callId: incoming.callId,
                peer: incoming.peer,
                video: incoming.video
            ))
        }
    }

    func consumeConnectionStates() async {
        for await state in engine.connectionStates {
            switch state {
            case .connected, .completed:
                await feedMachine(.iceConnected)
            case .failed:
                await feedMachine(.iceFailed)
            case .new, .checking, .disconnected, .closed:
                break // intermediate transport detail, not a machine event
            }
        }
    }

    func consumeDataChannelMessages() async {
        for await data in engine.dataChannelMessages {
            guard let json = String(data: data, encoding: .utf8),
                  let envelope = LKEnvelope.parse(jsonString: json).envelope
            else { continue }
            await handleEnvelope(envelope)
        }
    }

    func consumeDataChannelStates() async {
        for await open in engine.dataChannelStates {
            isDataChannelOpen = open
        }
    }

    func consumeIceCandidates() async {
        for await candidate in engine.iceCandidates {
            guard isLiveCall(machine.state) else { continue }
            let body = LKCallIce(
                callId: machine.state.callId,
                candidate: candidate.candidate,
                sdpMid: candidate.sdpMid ?? "",
                sdpMLineIndex: candidate.lineIndex
            ).bodyJSON
            await routeSend(LKEnvelope(v: 1, type: LKTypes.callIce, id: UUID().uuidString, ts: nowMs(), bodyJSON: body))
        }
    }

    func consumeNetworkStates() async {
        for await state in network.states {
            await feedMachine(.networkChanged)
            await engine.applyBitratePlan(adaptation.plan(state: state))
        }
    }

    // MARK: - Envelope mapping

    /// The call.* envelope types that map straight to a machine event whose
    /// body is an LKCallRef (ringing, accept, ice-restart).
    static let refEventKinds: [String: LKCallEventKind] = [
        LKTypes.callRinging: .remoteRinging,
        LKTypes.callAccept: .remoteAccept,
        LKTypes.callIceRestart: .remoteIceRestart
    ]

    /// The call.* envelope types that map straight to a machine event whose
    /// body is an LKCallEnd (reject, busy, cancel, hangup).
    static let endEventKinds: [String: LKCallEventKind] = [
        LKTypes.callReject: .remoteReject,
        LKTypes.callBusy: .remoteBusy,
        LKTypes.callCancel: .remoteCancel,
        LKTypes.callHangup: .remoteHangup
    ]

    /// Maps one decoded call.* envelope to machine events plus the engine
    /// plumbing the machine cannot carry (SDP and candidates). Everything
    /// outside the call family — and call.invite, which reaches the machine
    /// through the IncomingCallSource only, so an invite is never applied
    /// twice — is dropped here.
    func handleEnvelope(_ envelope: LKEnvelope) async {
        if let kind = Self.refEventKinds[envelope.type] {
            await feedRef(envelope, as: kind)
        } else if let kind = Self.endEventKinds[envelope.type] {
            await feedEnd(envelope, as: kind)
        } else {
            switch envelope.type {
            case LKTypes.callOffer:
                await handleRemoteSDP(envelope, isAnswer: false)
            case LKTypes.callAnswer:
                await handleRemoteSDP(envelope, isAnswer: true)
            case LKTypes.callIce:
                await handleRemoteIce(envelope)
            default:
                break // session, presence, msg and file families are not call lifecycle
            }
        }
    }

    func feedRef(_ envelope: LKEnvelope, as kind: LKCallEventKind) async {
        guard let body = try? LKCallRef.from(bodyJSON: envelope.bodyJSON) else { return }
        await apply(LKCallEvent(kind: kind, callId: body.callId, peer: "", video: false))
    }

    func feedEnd(_ envelope: LKEnvelope, as kind: LKCallEventKind) async {
        guard let body = try? LKCallEnd.from(bodyJSON: envelope.bodyJSON) else { return }
        await apply(LKCallEvent(kind: kind, callId: body.callId, peer: "", video: false))
    }

    /// SDP feeds the peer connection, not the machine — but the event still
    /// goes through the machine first, which keeps the transition discipline.
    func handleRemoteSDP(_ envelope: LKEnvelope, isAnswer: Bool) async {
        guard let body = try? LKCallSdp.from(bodyJSON: envelope.bodyJSON) else { return }
        await apply(LKCallEvent(
            kind: isAnswer ? .remoteAnswer : .remoteOffer,
            callId: body.callId,
            peer: "",
            video: false
        ))
        try? await engine.setRemoteSDP(body.sdp, isAnswer: isAnswer)
    }

    func handleRemoteIce(_ envelope: LKEnvelope) async {
        guard let body = try? LKCallIce.from(bodyJSON: envelope.bodyJSON) else { return }
        await apply(LKCallEvent(kind: .remoteIce, callId: body.callId, peer: "", video: false))
        await engine.addIceCandidate(
            candidate: body.candidate,
            sdpMid: body.sdpMid,
            lineIndex: body.sdpMLineIndex
        )
    }

    func feedMachine(_ kind: LKCallEventKind) async {
        await apply(LKCallEvent(kind: kind, callId: machine.state.callId, peer: "", video: false))
    }

    // MARK: - Wire rendering

    /// Renders a SendMessage effect onto the wire. Every message the machine
    /// emits names the pre-transition call (glare's call.cancel withdraws the
    /// LOSING call, whose id is the pre-state's), except call.invite, whose
    /// body is the new call's identity riding the event.
    func sendMachineMessage(_ type: String, preState: LKCallState, event: LKCallEvent) async {
        let bodyJSON: String
        switch type {
        case LKTypes.callInvite:
            bodyJSON = LKCallInvite(
                callId: event.callId,
                to: event.peer,
                media: event.video ? CallMedia.video.rawValue : CallMedia.audio.rawValue
            ).bodyJSON
        case LKTypes.callAccept, LKTypes.callRinging, LKTypes.callIceRestart:
            bodyJSON = LKCallRef(callId: preState.callId).bodyJSON
        case LKTypes.callReject, LKTypes.callCancel, LKTypes.callHangup, LKTypes.callBusy:
            bodyJSON = LKCallEnd(callId: preState.callId, reason: nil).bodyJSON
        default:
            return // the machine never asks for anything else in v0.1
        }
        await routeSend(LKEnvelope(v: 1, type: type, id: UUID().uuidString, ts: nowMs(), bodyJSON: bodyJSON))
    }

    func performIceRestart(for callId: String) async {
        guard let offer = try? await engine.restartIce() else { return }
        await sendSDPCall(LKTypes.callOffer, callId: callId, sdp: offer)
    }

    func sendSDPCall(_ type: String, callId: String, sdp: String) async {
        let body = LKCallSdp(callId: callId, sdp: sdp).bodyJSON
        await routeSend(LKEnvelope(v: 1, type: type, id: UUID().uuidString, ts: nowMs(), bodyJSON: body))
    }

    /// The in-call control fallback (spec 4.2): an open data channel carries
    /// the envelope and the server hears nothing; without a channel the
    /// signaling path carries it. The channel payload is the full wire JSON.
    func routeSend(_ envelope: LKEnvelope) async {
        if isDataChannelOpen {
            try? await engine.sendOverDataChannel(Data(envelope.wireJSON.utf8))
        } else {
            try? await signaling.send(envelope)
        }
    }
}
