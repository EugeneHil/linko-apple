// SplitDataChannelEngine (Plan 4 Task 13 part 2, LNK-39): the data-channel
// split — the coordinator and the transfer coordinator both read the
// engine's channel streams, so the composition root wraps the engine once
// and hands the coordinator multiplexer branches while everything else
// forwards untouched.

import CallEngine
import Foundation

/// The engine decorator the coordinator sees; the root keeps the real
/// engine for the transfer pumps and the UI track access.
final class SplitDataChannelEngine: CallMediaEngine, @unchecked Sendable {
    private let inner: any CallMediaEngine
    private let messagesBranch: AsyncStream<Data>
    private let statesBranch: AsyncStream<Bool>

    init(inner: any CallMediaEngine, messages: AsyncStream<Data>, states: AsyncStream<Bool>) {
        self.inner = inner
        messagesBranch = messages
        statesBranch = states
    }

    func prepare(media: CallMedia) async throws {
        try await inner.prepare(media: media)
    }

    func startCall() async throws -> String {
        try await inner.startCall()
    }

    func accept() async throws -> String {
        try await inner.accept()
    }

    func restartIce() async throws -> String {
        try await inner.restartIce()
    }

    func setRemoteSDP(_ sdp: String, isAnswer: Bool) async throws {
        try await inner.setRemoteSDP(sdp, isAnswer: isAnswer)
    }

    func addIceCandidate(candidate: String, sdpMid: String?, lineIndex: Int32) async {
        await inner.addIceCandidate(candidate: candidate, sdpMid: sdpMid, lineIndex: lineIndex)
    }

    func hangup() async {
        await inner.hangup()
    }

    func sendOverDataChannel(_ data: Data) async throws {
        try await inner.sendOverDataChannel(data)
    }

    func applyBitratePlan(_ plan: BitratePlan) async {
        await inner.applyBitratePlan(plan)
    }

    func setMuted(_ muted: Bool) async {
        await inner.setMuted(muted)
    }

    func setVideoEnabled(_ enabled: Bool) async {
        await inner.setVideoEnabled(enabled)
    }

    var iceCandidates: AsyncStream<IceCandidate> {
        inner.iceCandidates
    }

    var connectionStates: AsyncStream<IceConnectionState> {
        inner.connectionStates
    }

    var dataChannelMessages: AsyncStream<Data> {
        messagesBranch
    }

    var dataChannelStates: AsyncStream<Bool> {
        statesBranch
    }

    var statistics: AsyncStream<RawStatsReport> {
        inner.statistics
    }

    var localVideoTrack: (any VideoTrackHandle)? {
        get async { await inner.localVideoTrack }
    }

    var remoteVideoTrack: (any VideoTrackHandle)? {
        get async { await inner.remoteVideoTrack }
    }
}
