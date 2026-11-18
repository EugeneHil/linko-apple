// FakeWorld (Plan 4 Task 9 / LNK-35): fakes for every seam the coordinator
// drives — signaling send, signaling events, the media engine, reporting,
// the incoming-call source, the network monitor, the report uploader and a
// gate clock that parks every timer until the test fires it.

import CallEngine
@testable import Calls
import CallStats
import CoreBridge
import Foundation
import Signaling

// MARK: - Signaling

/// Records everything the coordinator sends; nothing ever leaves the test.
final class FakeCallSignaling: CallSignalingSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LKEnvelope] = []

    func send(_ envelope: LKEnvelope) async throws {
        lock.withLock {
            sent.append(envelope)
        }
    }

    var sentEnvelopes: [LKEnvelope] {
        lock.withLock { sent }
    }

    var sentTypes: [String] {
        sentEnvelopes.map(\.type)
    }

    func sentEnvelope(ofType type: String) -> LKEnvelope? {
        sentEnvelopes.last { $0.type == type }
    }
}

// MARK: - Engine

/// A CallMediaEngine fake: records every control call and hands the test
/// continuations to fire what the live WebRTC adapters would stream.
final class FakeCallEngine: CallMediaEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _prepared: [CallMedia] = []
    private var _startCallCount = 0
    private var _acceptCount = 0
    private var _remoteSDPs: [RecordedSDP] = []
    private var _addedCandidates: [IceCandidate] = []
    private var _hangupCount = 0
    private var _restartIceCount = 0
    private var _channelSends: [Data] = []
    private var _bitratePlans: [BitratePlan] = []
    private var _mutes: [Bool] = []
    private var _videoEnables: [Bool] = []

    struct RecordedSDP: Equatable, Sendable {
        let sdp: String
        let isAnswer: Bool
    }

    let iceCandidates: AsyncStream<IceCandidate>
    let iceCandidatesContinuation: AsyncStream<IceCandidate>.Continuation
    let connectionStates: AsyncStream<IceConnectionState>
    let connectionStatesContinuation: AsyncStream<IceConnectionState>.Continuation
    let dataChannelMessages: AsyncStream<Data>
    let dataChannelMessagesContinuation: AsyncStream<Data>.Continuation
    let dataChannelStates: AsyncStream<Bool>
    let dataChannelStatesContinuation: AsyncStream<Bool>.Continuation
    let statistics: AsyncStream<RawStatsReport>
    let statisticsContinuation: AsyncStream<RawStatsReport>.Continuation

    init() {
        (iceCandidates, iceCandidatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (connectionStates, connectionStatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (dataChannelMessages, dataChannelMessagesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (dataChannelStates, dataChannelStatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (statistics, statisticsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func prepare(media: CallMedia) async throws {
        lock.withLock { _prepared.append(media) }
    }

    func startCall() async throws -> String {
        lock.withLock { _startCallCount += 1 }
        return "offer-sdp"
    }

    func accept() async throws -> String {
        lock.withLock { _acceptCount += 1 }
        return "answer-sdp"
    }

    func restartIce() async throws -> String {
        lock.withLock { _restartIceCount += 1 }
        return "restart-offer-sdp"
    }

    func setRemoteSDP(_ sdp: String, isAnswer: Bool) async throws {
        lock.withLock { _remoteSDPs.append(RecordedSDP(sdp: sdp, isAnswer: isAnswer)) }
    }

    func addIceCandidate(candidate: String, sdpMid: String?, lineIndex: Int32) async {
        lock.withLock { _addedCandidates.append(IceCandidate(candidate: candidate, sdpMid: sdpMid, lineIndex: lineIndex)) }
    }

    func hangup() async {
        lock.withLock { _hangupCount += 1 }
    }

    func sendOverDataChannel(_ data: Data) async throws {
        lock.withLock { _channelSends.append(data) }
    }

    func applyBitratePlan(_ plan: BitratePlan) async {
        lock.withLock { _bitratePlans.append(plan) }
    }

    func setMuted(_ muted: Bool) async {
        lock.withLock { _mutes.append(muted) }
    }

    func setVideoEnabled(_ enabled: Bool) async {
        lock.withLock { _videoEnables.append(enabled) }
    }

    var localVideoTrack: (any VideoTrackHandle)? {
        get async { nil }
    }

    var remoteVideoTrack: (any VideoTrackHandle)? {
        get async { nil }
    }

    // MARK: Test surface

    var prepared: [CallMedia] {
        lock.withLock { _prepared }
    }

    var startCallCount: Int {
        lock.withLock { _startCallCount }
    }

    var acceptCount: Int {
        lock.withLock { _acceptCount }
    }

    var remoteSDPs: [RecordedSDP] {
        lock.withLock { _remoteSDPs }
    }

    var addedCandidates: [IceCandidate] {
        lock.withLock { _addedCandidates }
    }

    var hangupCount: Int {
        lock.withLock { _hangupCount }
    }

    var restartIceCount: Int {
        lock.withLock { _restartIceCount }
    }

    var channelSends: [Data] {
        lock.withLock { _channelSends }
    }

    var bitratePlans: [BitratePlan] {
        lock.withLock { _bitratePlans }
    }

    var mutes: [Bool] {
        lock.withLock { _mutes }
    }

    var videoEnables: [Bool] {
        lock.withLock { _videoEnables }
    }

    /// Fires what the live peer connection adapter would stream.
    func fireConnectionState(_ state: IceConnectionState) {
        connectionStatesContinuation.yield(state)
    }

    func fireIceCandidate(_ candidate: IceCandidate) {
        iceCandidatesContinuation.yield(candidate)
    }

    func fireDataChannelState(_ open: Bool) {
        dataChannelStatesContinuation.yield(open)
    }

    func fireDataChannelMessage(_ data: Data) {
        dataChannelMessagesContinuation.yield(data)
    }
}

// MARK: - Reporting

final class FakeCallReporting: CallReporting, @unchecked Sendable {
    struct Incoming: Equatable, Sendable {
        let callId: String
        let peer: String
        let video: Bool
    }

    struct Ended: Equatable, Sendable {
        let callId: String
        let reason: CallEndReason
    }

    private let lock = NSLock()
    private var _startRingingCount = 0
    private var _stopRingingCount = 0
    private var _incoming: [Incoming] = []
    private var _ended: [Ended] = []

    func startRinging() async {
        lock.withLock { _startRingingCount += 1 }
    }

    func stopRinging() async {
        lock.withLock { _stopRingingCount += 1 }
    }

    func reportIncoming(callId: String, peer: String, video: Bool) async {
        lock.withLock { _incoming.append(Incoming(callId: callId, peer: peer, video: video)) }
    }

    func reportEnded(callId: String, reason: CallEndReason) async {
        lock.withLock { _ended.append(Ended(callId: callId, reason: reason)) }
    }

    var startRingingCount: Int {
        lock.withLock { _startRingingCount }
    }

    var stopRingingCount: Int {
        lock.withLock { _stopRingingCount }
    }

    var incoming: [Incoming] {
        lock.withLock { _incoming }
    }

    var ended: [Ended] {
        lock.withLock { _ended }
    }
}

// MARK: - Incoming calls and network

final class FakeIncomingCallSource: IncomingCallSource, @unchecked Sendable {
    let calls: AsyncStream<IncomingCall>
    private let continuation: AsyncStream<IncomingCall>.Continuation

    init() {
        (calls, continuation) = AsyncStream.makeStream(of: IncomingCall.self, bufferingPolicy: .unbounded)
    }

    func yield(_ call: IncomingCall) {
        continuation.yield(call)
    }
}

final class FakeCallNetworkMonitor: CallNetworkMonitoring, @unchecked Sendable {
    let states: AsyncStream<NetworkState>
    private let continuation: AsyncStream<NetworkState>.Continuation

    init() {
        (states, continuation) = AsyncStream.makeStream(of: NetworkState.self, bufferingPolicy: .unbounded)
    }

    func yield(_ state: NetworkState) {
        continuation.yield(state)
    }
}

// MARK: - Report upload

struct RecordedPost: Equatable, Sendable {
    let callId: String
    let report: String
}

final class FakeCallReportUploader: CallReportUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [RecordedPost] = []

    func post(callId: String, report: String) async throws {
        lock.withLock { _posts.append(RecordedPost(callId: callId, report: report)) }
    }

    var posts: [RecordedPost] {
        lock.withLock { _posts }
    }
}

// MARK: - Gate clock

/// Parks every timer sleep until the test fires it; wakes release a parked
/// sleep with false. Exactly one sleep per kind is pending at a time (the
/// CallTimer's own contract), and wake/fire target that pending sleep —
/// with nothing pending they are no-ops, never presets.
final class GateCallClock: CallClock, @unchecked Sendable {
    struct Sleep: Equatable, Sendable {
        let kind: CallTimerKind
        let milliseconds: Int
    }

    private let lock = NSLock()
    private var sleeps: [Sleep] = []
    private var currentToken: [CallTimerKind: UUID] = [:]
    private var parked: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cancelledTokens: Set<UUID> = []

    func sleep(_ kind: CallTimerKind, for duration: Duration) async -> Bool {
        let token = UUID()
        lock.withLock {
            sleeps.append(Sleep(kind: kind, milliseconds: Self.milliseconds(of: duration)))
            currentToken[kind] = token
        }
        let elapsed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumedEarly = lock.withLock { () -> Bool in
                    if cancelledTokens.contains(token) {
                        continuation.resume(returning: false)
                        return true
                    }
                    parked[token] = continuation
                    return false
                }
                _ = resumedEarly
            }
        } onCancel: {
            self.release(token, result: false)
        }
        lock.withLock {
            if currentToken[kind] == token {
                currentToken[kind] = nil
            }
            cancelledTokens.remove(token)
        }
        return elapsed
    }

    func wake(_ kind: CallTimerKind) {
        releaseCurrent(of: kind, result: false)
    }

    /// Fires the pending sleep of `kind` as a full-duration expiry.
    func fire(_ kind: CallTimerKind) {
        releaseCurrent(of: kind, result: true)
    }

    var recordedSleeps: [Sleep] {
        lock.withLock { sleeps }
    }

    func hasSleep(kind: CallTimerKind, milliseconds: Int) -> Bool {
        recordedSleeps.contains(Sleep(kind: kind, milliseconds: milliseconds))
    }

    private func releaseCurrent(of kind: CallTimerKind, result: Bool) {
        let token = lock.withLock { currentToken[kind] }
        guard let token else { return }
        release(token, result: result)
    }

    private func release(_ token: UUID, result: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            if let parked = parked.removeValue(forKey: token) {
                return parked
            }
            // The sleep has not parked yet (or already resumed): the token
            // carries the result to the store block.
            cancelledTokens.insert(token)
            return nil
        }
        continuation?.resume(returning: result)
    }

    private static func milliseconds(of duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
