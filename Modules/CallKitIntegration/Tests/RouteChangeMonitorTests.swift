// RouteChangeMonitorTests (Plan 4 Task 10 / LNK-36): route changes and
// interruptions observed through the seamed notification center surface as
// typed AsyncStream values for the call screen (spec §10 item 6).

#if os(iOS)
    import AVFAudio
    @testable import CallKitIntegration
    import Foundation
    import XCTest

    final class RouteChangeMonitorTests: XCTestCase {
        func test_route_change_surfaced() async {
            let center = FakeNotificationCenter()
            let monitor = RouteChangeMonitor(center: center)
            var iterator = monitor.routeChanges.makeAsyncIterator()

            center.push(AVAudioSession.routeChangeNotification, userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ])

            let change = await iterator.next()
            XCTAssertEqual(change?.reason, .oldDeviceUnavailable)
        }

        func test_interruption_surfaced() async {
            let center = FakeNotificationCenter()
            let monitor = RouteChangeMonitor(center: center)
            var iterator = monitor.interruptions.makeAsyncIterator()

            center.push(AVAudioSession.interruptionNotification, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ])

            let interruption = await iterator.next()
            XCTAssertEqual(interruption?.kind, .began)
            XCTAssertFalse(interruption?.shouldResume ?? true)
        }
    }
#endif
