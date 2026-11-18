// ProviderAdapterTests (Plan 4 Task 10 / LNK-36): the CallKit boundary —
// incoming reports land on CXProvider, every CXCallAction is fulfilled or
// failed synchronously in the delegate, and the user actions route into the
// coordinator. The fake CallKit seams keep CallKit itself out of the tests.

#if os(iOS)
    import CallKit
    @testable import CallKitIntegration
    import Calls
    import Foundation
    import XCTest

    final class ProviderAdapterTests: XCTestCase {
        func test_incoming_call_reported_and_answer_fulfills_action() async throws {
            let fixture = makeAdapterFixture()

            await fixture.adapter.reportIncoming(callId: "c1", peer: "bob", video: true)
            try await waitUntil("the incoming report reaches CallKit") {
                !fixture.reporter.incoming.isEmpty
            }
            let report = try XCTUnwrap(fixture.reporter.incoming.first)
            XCTAssertEqual(report.handle, "bob")
            XCTAssertTrue(report.video)

            let provider = CXProvider(configuration: CXProviderConfiguration())
            fixture.adapter.provider(provider, perform: CXAnswerCallAction(call: report.uuid))
            try await waitUntil("the answer action is fulfilled") {
                fixture.actions.fulfilled.contains(report.uuid)
            }
            try await waitUntil("the coordinator accepted") {
                fixture.routing.acceptCount == 1
            }
            try await waitUntil("the audio session is configured for video") {
                fixture.configurator.configurations.last?.mode == .videoChat
            }
            XCTAssertEqual(fixture.actions.failed, [])
        }

        func test_reject_fails_incoming_action() async throws {
            let fixture = makeAdapterFixture()

            await fixture.adapter.reportIncoming(callId: "c1", peer: "bob", video: false)
            try await waitUntil("the incoming report reaches CallKit") {
                !fixture.reporter.incoming.isEmpty
            }
            let uuid = try XCTUnwrap(fixture.reporter.incoming.first?.uuid)

            await fixture.adapter.reportEnded(callId: "c1", reason: .rejected)
            try await waitUntil("the rejected call is reported ended to CallKit") {
                fixture.reporter.ended.contains { $0.uuid == uuid && $0.reason == .rejected }
            }

            // A late answer action for the rejected call is failed synchronously.
            let provider = CXProvider(configuration: CXProviderConfiguration())
            fixture.adapter.provider(provider, perform: CXAnswerCallAction(call: uuid))
            try await waitUntil("the late answer action is failed") {
                fixture.actions.failed.contains(uuid)
            }
            XCTAssertFalse(fixture.actions.fulfilled.contains(uuid))
            XCTAssertEqual(fixture.routing.acceptCount, 0)
        }

        func test_mute_action_routes_to_coordinator() async throws {
            let fixture = makeAdapterFixture()

            await fixture.adapter.reportIncoming(callId: "c1", peer: "bob", video: false)
            try await waitUntil("the incoming report reaches CallKit") {
                !fixture.reporter.incoming.isEmpty
            }
            let uuid = try XCTUnwrap(fixture.reporter.incoming.first?.uuid)

            let provider = CXProvider(configuration: CXProviderConfiguration())
            fixture.adapter.provider(provider, perform: CXSetMutedCallAction(call: uuid, muted: true))
            try await waitUntil("the mute action is fulfilled") {
                fixture.actions.fulfilled.contains(uuid)
            }
            try await waitUntil("the coordinator toggled mute") {
                fixture.routing.toggleMuteCount == 1
            }
        }
    }
#endif
