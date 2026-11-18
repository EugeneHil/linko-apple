// AudioSessionCoordinatorTests (Plan 4 Task 10 / LNK-36): the audio session
// configuration pinned by ADR-0001 (playAndRecord, videoChat/voiceChat,
// HFP + A2DP + defaultToSpeaker, never the deprecated .allowBluetooth) and
// the manual-audio handover CallKit drives in didActivate/didDeactivate.

#if os(iOS)
    import AVFAudio
    import CallKit
    @testable import CallKitIntegration
    import Foundation
    import XCTest

    final class AudioSessionCoordinatorTests: XCTestCase {
        func test_audio_session_options_video_chat() throws {
            let fixture = makeAudioFixture()

            fixture.audio.configure(video: true)

            let configuration = try XCTUnwrap(fixture.configurator.configurations.last)
            XCTAssertEqual(configuration.category, .playAndRecord)
            XCTAssertEqual(configuration.mode, .videoChat)
            XCTAssertEqual(
                configuration.options,
                [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
        }

        func test_audio_session_options_voice_chat() throws {
            let fixture = makeAudioFixture()

            fixture.audio.configure(video: false)

            let configuration = try XCTUnwrap(fixture.configurator.configurations.last)
            XCTAssertEqual(configuration.category, .playAndRecord)
            XCTAssertEqual(configuration.mode, .voiceChat)
            XCTAssertEqual(
                configuration.options,
                [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
        }

        func test_did_activate_enables_manual_audio() {
            let fixture = makeAdapterFixture()
            let provider = CXProvider(configuration: CXProviderConfiguration())

            fixture.adapter.provider(provider, didActivate: AVAudioSession.sharedInstance())

            XCTAssertTrue(fixture.manual.useManualAudio)
            XCTAssertTrue(fixture.manual.isAudioEnabled)
        }

        func test_did_deactivate_disables_and_deactivates() {
            let fixture = makeAdapterFixture()
            let provider = CXProvider(configuration: CXProviderConfiguration())

            fixture.adapter.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

            XCTAssertFalse(fixture.manual.isAudioEnabled)
            XCTAssertEqual(fixture.configurator.activations, [false])
        }
    }
#endif
