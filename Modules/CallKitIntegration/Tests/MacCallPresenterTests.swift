// MacCallPresenterTests (Plan 4 Task 10 / LNK-36): the macOS reporting
// surface — an own incoming-call window and a user notification when the
// window is not key (spec §4.3). Accept/reject closures route into the
// coordinator.

#if os(macOS)
    @testable import CallKitIntegration
    import Calls
    import Foundation
    import XCTest

    final class MacCallPresenterTests: XCTestCase {
        func test_mac_presenter_reports_incoming_window() async {
            let fixture = makePresenterFixture(windowIsKey: true)

            await fixture.presenter.reportIncoming(callId: "c1", peer: "bob", video: true)

            XCTAssertEqual(fixture.window.shown, [ShownIncoming(callId: "c1", peer: "bob", video: true)])
            XCTAssertTrue(fixture.notifier.posted.isEmpty)

            // The window's buttons route into the coordinator.
            await fixture.window.fireAccept()
            await fixture.window.fireReject()
            XCTAssertEqual(fixture.routing.acceptCount, 1)
            XCTAssertEqual(fixture.routing.rejectCount, 1)
        }

        func test_mac_presenter_notification_when_not_key() async throws {
            let fixture = makePresenterFixture(windowIsKey: false)

            await fixture.presenter.reportIncoming(callId: "c1", peer: "bob", video: false)

            try await waitUntil("the user notification is posted") {
                !fixture.notifier.posted.isEmpty
            }
            XCTAssertEqual(fixture.notifier.posted.first, PostedNotification(callId: "c1", peer: "bob"))
        }

        func test_stop_ringing_hides_the_incoming_window() async throws {
            let fixture = makePresenterFixture(windowIsKey: true)

            await fixture.presenter.reportIncoming(callId: "c1", peer: "bob", video: false)
            await fixture.presenter.stopRinging()

            try await waitUntil("the incoming window is hidden") {
                fixture.window.hidden.contains("c1")
            }
        }

        func test_report_ended_hides_the_incoming_window() async throws {
            let fixture = makePresenterFixture(windowIsKey: true)

            await fixture.presenter.reportIncoming(callId: "c1", peer: "bob", video: false)
            await fixture.presenter.reportEnded(callId: "c1", reason: .cancelled)

            try await waitUntil("the incoming window is hidden") {
                fixture.window.hidden.contains("c1")
            }
        }
    }
#endif
