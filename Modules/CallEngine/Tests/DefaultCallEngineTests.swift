// DefaultCallEngine tests (Plan 4 Task 7 / LNK-33): the named plan tests —
// TURN credentials become ICE servers, media flags select tracks, the bitrate
// plan reaches a fake sender, mute routes to the audio track, and hangup
// releases the capturer — plus the remaining public surface every production
// behavior owes a failing test first (start/accept SDP, remote SDP and
// candidate forwarding, manual audio, prepare guards, data channel open
// guard, remote video track surfacing).

@testable import CallEngine
import Foundation
import WebRTC
import XCTest

final class DefaultCallEngineTests: XCTestCase {
    // MARK: TURN credentials (plan test 1)

    func test_turn_credentials_become_ice_servers() async throws {
        let fixture = try await makeEngineFixture(media: .audio)

        let configuration = try XCTUnwrap(fixture.provider.configuration)
        XCTAssertEqual(configuration.iceServers.count, 1)
        let server = try XCTUnwrap(configuration.iceServers.first)
        XCTAssertEqual(server.urlStrings, sampleCredentials.urls)
        XCTAssertEqual(server.username, sampleCredentials.username)
        XCTAssertEqual(server.credential, sampleCredentials.credential)
        // Continuous ICE over the unified plan, all transports (spike-proven
        // configuration; the server's URI list decides relay usage).
        XCTAssertEqual(configuration.sdpSemantics, .unifiedPlan)
        XCTAssertEqual(configuration.continualGatheringPolicy, .gatherContinually)
        XCTAssertEqual(configuration.iceTransportPolicy, .all)
    }

    // MARK: Media flags (plan test 2)

    func test_media_flags_select_tracks() async throws {
        // Audio only: one audio track, no video bundle, no capture, and the
        // UI-facing local video track stays unset.
        let audio = try await makeEngineFixture(media: .audio)
        XCTAssertEqual(audio.connection.audioTracks.count, 1)
        XCTAssertEqual(audio.connection.videoBundles.count, 0)
        let audioLocalVideo = await audio.engine.localVideoTrack
        XCTAssertNil(audioLocalVideo)

        // Video with a camera present: audio + video, capture started, and
        // the local video track handle surfaced for the UI.
        let video = try await makeEngineFixture(media: .video)
        XCTAssertEqual(video.connection.audioTracks.count, 1)
        XCTAssertEqual(video.connection.videoBundles.count, 1)
        let bundle = try XCTUnwrap(video.connection.videoBundles.first)
        let capturer = try XCTUnwrap(bundle.capturer as? FakeCapturer)
        XCTAssertEqual(capturer.startCount, 1)
        let videoLocalVideo = await video.engine.localVideoTrack
        XCTAssertNotNil(videoLocalVideo)

        // Video without a camera (the Simulator): the track exists but
        // capture never starts.
        let simulator = try await makeEngineFixture(
            media: .video,
            camera: FakeCameraAvailability(hasCamera: false)
        )
        XCTAssertEqual(simulator.connection.videoBundles.count, 1)
        let simulatorBundle = try XCTUnwrap(simulator.connection.videoBundles.first)
        let simulatorCapturer = try XCTUnwrap(simulatorBundle.capturer as? FakeCapturer)
        XCTAssertEqual(simulatorCapturer.startCount, 0)
    }

    // MARK: Bitrate plan (plan test 3)

    func test_bitrate_plan_applied_to_fake_sender() async throws {
        let fixture = try await makeEngineFixture(media: .video)
        let sender = try XCTUnwrap(fixture.connection.videoSenderFake)

        await fixture.engine.applyBitratePlan(BitratePlan(maxVideoBitrateBps: 500_000))
        XCTAssertEqual(sender.appliedParameters, [EncodingParameters(maxBitrateBps: 500_000)])

        // An uncapped plan clears the cap through the same seam.
        await fixture.engine.applyBitratePlan(BitratePlan(maxVideoBitrateBps: nil))
        XCTAssertEqual(
            sender.appliedParameters,
            [EncodingParameters(maxBitrateBps: 500_000), EncodingParameters(maxBitrateBps: nil)]
        )
    }

    func test_bitrate_plan_without_video_is_ignored() async throws {
        let fixture = try await makeEngineFixture(media: .audio)

        await fixture.engine.applyBitratePlan(BitratePlan(maxVideoBitrateBps: 500_000))

        XCTAssertNil(fixture.connection.videoSenderFake)
        XCTAssertFalse(
            fixture.logger.recorded.contains { $0.contains(sampleCredentials.credential) },
            "credentials never appear in logs"
        )
    }

    // MARK: Mute (plan test 4)

    func test_mute_routes_to_audio_track() async throws {
        let fixture = try await makeEngineFixture(media: .audio)
        let track = try XCTUnwrap(fixture.connection.audioTracks.first)

        XCTAssertTrue(track.isEnabled)
        await fixture.engine.setMuted(true)
        XCTAssertFalse(track.isEnabled)
        await fixture.engine.setMuted(false)
        XCTAssertTrue(track.isEnabled)
    }

    // MARK: Hangup (plan test 7)

    func test_hangup_releases_tracks_and_capturer() async throws {
        let fixture = try await makeEngineFixture(media: .video, camera: FakeCameraAvailability(hasCamera: true))
        let bundle = try XCTUnwrap(fixture.connection.videoBundles.first)
        let capturer = try XCTUnwrap(bundle.capturer as? FakeCapturer)
        XCTAssertEqual(capturer.startCount, 1)

        await fixture.engine.hangup()

        // Anti-goal: capture left running after the call ends.
        XCTAssertEqual(capturer.stopCount, 1)
        XCTAssertEqual(fixture.connection.closeCount, 1)

        // A second hangup is a no-op, and the engine no longer sends.
        await fixture.engine.hangup()
        XCTAssertEqual(capturer.stopCount, 1)
        XCTAssertEqual(fixture.connection.closeCount, 1)
        do {
            try await fixture.engine.sendOverDataChannel(Data("after-hangup".utf8))
            XCTFail("sending after hangup must throw")
        } catch let error as CallEngineError {
            XCTAssertEqual(error, .notPrepared)
        }
    }

    // MARK: Offer and answer

    func test_start_call_returns_offer_sdp_and_creates_channel() async throws {
        let fixture = try await makeEngineFixture(media: .audio)

        let offer = try await fixture.engine.startCall()

        XCTAssertEqual(offer, "offer-sdp")
        XCTAssertEqual(fixture.connection.offerCount, 1)
        XCTAssertEqual(fixture.connection.localDescriptions.count, 1)
        XCTAssertEqual(fixture.connection.localDescriptions.first, RecordedDescription(sdp: "offer-sdp", isAnswer: false))
        XCTAssertEqual(fixture.connection.channels.count, 1, "the caller creates the data channel")
    }

    func test_accept_returns_answer_sdp() async throws {
        let fixture = try await makeEngineFixture(media: .audio)
        try await fixture.engine.setRemoteSDP("remote-offer", isAnswer: false)

        let answer = try await fixture.engine.accept()

        XCTAssertEqual(answer, "answer-sdp")
        XCTAssertEqual(fixture.connection.answerCount, 1)
        XCTAssertEqual(fixture.connection.localDescriptions.first, RecordedDescription(sdp: "answer-sdp", isAnswer: true))
    }

    func test_set_remote_sdp_forwards_both_directions() async throws {
        let fixture = try await makeEngineFixture(media: .audio)

        try await fixture.engine.setRemoteSDP("remote-offer", isAnswer: false)
        try await fixture.engine.setRemoteSDP("remote-answer", isAnswer: true)

        XCTAssertEqual(fixture.connection.remoteDescriptions.count, 2)
        XCTAssertEqual(fixture.connection.remoteDescriptions[0], RecordedDescription(sdp: "remote-offer", isAnswer: false))
        XCTAssertEqual(fixture.connection.remoteDescriptions[1], RecordedDescription(sdp: "remote-answer", isAnswer: true))
    }

    func test_add_ice_candidate_forwards_to_peer_connection() async throws {
        let fixture = try await makeEngineFixture(media: .audio)
        let candidate = IceCandidate(
            candidate: "candidate:1 1 udp 2113937151 10.0.0.1 5000 typ host",
            sdpMid: "0",
            lineIndex: 1
        )

        await fixture.engine.addIceCandidate(
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            lineIndex: candidate.lineIndex
        )

        XCTAssertEqual(fixture.connection.addedCandidates, [candidate])
    }

    // MARK: Audio session

    func test_prepare_enables_manual_audio() async throws {
        let fixture = try await makeEngineFixture(media: .audio)

        // CallKit (Task 10) drives isAudioEnabled; the engine only flips the
        // manual mode so WebRTC never activates the audio unit on its own.
        XCTAssertTrue(fixture.manualAudio.useManualAudio)
        XCTAssertFalse(fixture.manualAudio.isAudioEnabled)
    }

    // MARK: Prepare guards

    func test_prepare_twice_is_rejected() async throws {
        let fixture = try await makeEngineFixture(media: .audio)

        do {
            try await fixture.engine.prepare(media: .audio)
            XCTFail("preparing twice must throw")
        } catch let error as CallEngineError {
            XCTAssertEqual(error, .alreadyPrepared)
        }
        XCTAssertEqual(fixture.connection.audioTracks.count, 1, "no second track set")
    }

    // MARK: Data channel guard

    func test_send_over_data_channel_requires_open_channel() async throws {
        let fixture = try await makeEngineFixture(media: .audio)

        // No channel at all (never started the call): refused.
        do {
            try await fixture.engine.sendOverDataChannel(Data("too-early".utf8))
            XCTFail("sending without a channel must throw")
        } catch let error as CallEngineError {
            XCTAssertEqual(error, .channelNotOpen)
        }

        // A created but not-yet-open channel: still refused.
        _ = try await fixture.engine.startCall()
        do {
            try await fixture.engine.sendOverDataChannel(Data("still-closed".utf8))
            XCTFail("sending over a closed channel must throw")
        } catch let error as CallEngineError {
            XCTAssertEqual(error, .channelNotOpen)
        }

        // Open: the payload reaches the channel.
        let channel = try XCTUnwrap(fixture.connection.channels.first)
        channel.simulateOpen()
        try await fixture.engine.sendOverDataChannel(Data("go".utf8))
        XCTAssertEqual(channel.sent, [Data("go".utf8)])
    }

    // MARK: Remote video track

    func test_remote_video_track_surfaces_from_delegate() async throws {
        let fixture = try await makeEngineFixture(media: .audio)
        let engine = fixture.engine

        let before = await engine.remoteVideoTrack
        XCTAssertNil(before)

        fixture.connection.fireRemoteVideoTrack(FakeVideoTrackHandle())
        try await waitUntil("the remote video track is surfaced") {
            let track = await engine.remoteVideoTrack
            return track != nil
        }
    }
}
