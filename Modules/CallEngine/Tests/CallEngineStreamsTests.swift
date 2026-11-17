// Stream tests (Plan 4 Task 7 / LNK-33): delegate callbacks wrapped exactly
// once into AsyncStreams — ICE candidates, connection states, data channel
// messages and open states, and the 1 s statistics cadence that feeds the
// CallStats task (Task 8).

@testable import CallEngine
import Foundation
import XCTest

final class CallEngineStreamsTests: XCTestCase {
    // MARK: Candidates and states (plan test 5)

    func test_candidates_and_states_stream_from_fake_delegate() async throws {
        let fixture = try await makeEngineFixture(media: .audio)
        let candidate = IceCandidate(
            candidate: "candidate:2 1 udp 2113932095 192.168.0.2 5001 typ host",
            sdpMid: "0",
            lineIndex: 0
        )

        fixture.connection.fireIceCandidate(candidate)
        fixture.connection.fireConnectionState(.connected)
        fixture.connection.fireConnectionState(.failed)

        let engine = fixture.engine
        let receivedCandidate = await nextEvent(of: engine.iceCandidates)
        XCTAssertEqual(receivedCandidate, candidate)
        let firstState = await nextEvent(of: engine.connectionStates)
        XCTAssertEqual(firstState, .connected)
        let secondState = await nextEvent(of: engine.connectionStates)
        XCTAssertEqual(secondState, .failed)
    }

    // MARK: Data channel (plan test 6)

    func test_data_channel_send_and_receive_roundtrip() async throws {
        let fixture = try await makeEngineFixture(media: .audio)
        _ = try await fixture.engine.startCall()
        let channel = try XCTUnwrap(fixture.connection.channels.first)

        channel.simulateOpen()
        try await fixture.engine.sendOverDataChannel(Data("ping".utf8))
        XCTAssertEqual(channel.sent, [Data("ping".utf8)])

        channel.receive(Data("pong".utf8))
        let engine = fixture.engine
        let received = await nextEvent(of: engine.dataChannelMessages)
        XCTAssertEqual(received, Data("pong".utf8))

        let openState = await nextEvent(of: engine.dataChannelStates)
        XCTAssertEqual(openState, true)
    }

    // MARK: Statistics cadence

    func test_statistics_stream_polls_peer_connection() async throws {
        let fixture = try await makeEngineFixture(media: .audio, statsInterval: .milliseconds(50))
        let values = ["state": RawStatValue.string("succeeded"), "nominated": RawStatValue.boolean(true)]
        let entry = RawStatsReport.Entry(id: "pair-1", type: "candidate-pair", timestampMs: 1000, values: values)
        let report = RawStatsReport(entries: ["pair-1": entry])
        fixture.connection.cannedReport = report

        let engine = fixture.engine
        let received = await nextEvent(of: engine.statistics)
        XCTAssertEqual(received, report)
        XCTAssertGreaterThanOrEqual(fixture.connection.statisticsCalls, 1)

        // Hangup stops the poller: no further statistics calls arrive.
        let callsAtHangup = fixture.connection.statisticsCalls
        await fixture.engine.hangup()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.connection.statisticsCalls, callsAtHangup, "the poller is cancelled with the call")
    }
}
