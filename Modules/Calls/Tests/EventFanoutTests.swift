// EventFanoutTests (Plan 4 Task 13 part 2, LNK-39): the composition
// fan-out — one single-consumer stream fanned out to several branches (the
// app roots' view models and call-layout watcher), the missed-call recorder
// over the CallReporting seam, and the live network monitor's initial state.

@testable import Calls
import CallStats
import CoreBridge
import Foundation
import XCTest

final class EventFanoutTests: XCTestCase {
    func test_multiplexer_delivers_every_element_to_every_branch() async {
        let (source, sourceContinuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        let multiplexer = EventMultiplexer(source)
        let first = multiplexer.subscribe()
        let second = multiplexer.subscribe()

        sourceContinuation.yield(1)
        sourceContinuation.yield(2)

        var received: [Int] = []
        for await element in first {
            received.append(element)
            if element == 2 {
                break
            }
        }
        var receivedSecond: [Int] = []
        for await element in second {
            receivedSecond.append(element)
            if element == 2 {
                break
            }
        }
        XCTAssertEqual(received, [1, 2])
        XCTAssertEqual(receivedSecond, [1, 2])
    }

    func test_multiplexer_detached_branch_does_not_starve_the_rest() async {
        let (source, sourceContinuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        let multiplexer = EventMultiplexer(source)
        let detached = multiplexer.subscribe()
        let remaining = multiplexer.subscribe()

        // One element reaches both branches; then the detached branch's
        // iteration is abandoned (the break cancels its task, which
        // detaches the branch through onTermination).
        sourceContinuation.yield(1)
        var firstValue: Int?
        for await element in detached {
            firstValue = element
            break
        }
        XCTAssertEqual(firstValue, 1)

        sourceContinuation.yield(7)
        var received: [Int] = []
        for await element in remaining {
            received.append(element)
            if element == 7 {
                break
            }
        }
        XCTAssertEqual(
            received,
            [1, 7],
            "the surviving branch keeps flowing after the detachment (its pre-detachment element stays buffered)"
        )
    }

    func test_multiplexer_finishes_branches_with_the_source() async {
        let (source, sourceContinuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        let multiplexer = EventMultiplexer(source)
        let branch = multiplexer.subscribe()

        sourceContinuation.yield(1)
        sourceContinuation.finish()

        var received: [Int] = []
        for await element in branch {
            received.append(element)
        }
        XCTAssertEqual(received, [1], "the branch drains buffered elements, then finishes")

        let late = multiplexer.subscribe()
        var lateReceived: [Int] = []
        for await element in late {
            lateReceived.append(element)
        }
        XCTAssertTrue(lateReceived.isEmpty, "a late subscriber sees the finished source")
    }

    func test_fanout_map_transforms_elements() async {
        let (source, sourceContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let mapped = fanoutMap(source) { Int($0) ?? 0 }

        sourceContinuation.yield("12")
        sourceContinuation.yield("nope")
        sourceContinuation.finish()

        var received: [Int] = []
        for await element in mapped {
            received.append(element)
        }
        XCTAssertEqual(received, [12, 0])
    }

    func test_missed_call_recorder_records_missed_incoming_calls() async {
        let recorder = MissedCallRecorder()
        let primary = FakeCallReporting()
        recorder.setPrimary(primary)

        await recorder.reportIncoming(callId: "c1", peer: "bob", video: true)
        await recorder.reportEnded(callId: "c1", reason: .cancelled)
        await recorder.reportIncoming(callId: "c2", peer: "carol", video: false)
        await recorder.reportEnded(callId: "c2", reason: .missed)

        var notices: [MissedCallNotice] = []
        for await notice in recorder.calls {
            notices.append(notice)
            break
        }
        XCTAssertEqual(notices.first, MissedCallNotice(peer: "carol", ts: notices.first?.ts ?? 0))
        XCTAssertEqual(primary.incoming.count, 2, "every report forwards to the platform reporter")
        XCTAssertEqual(primary.ended.count, 2)
        XCTAssertEqual(primary.ended.last?.reason, .missed)
    }

    func test_missed_call_recorder_without_primary_never_crashes() async {
        let recorder = MissedCallRecorder()
        await recorder.startRinging()
        await recorder.reportIncoming(callId: "c1", peer: "bob", video: false)
        await recorder.reportEnded(callId: "c1", reason: .normal)
        await recorder.stopRinging()

        let primary = FakeCallReporting()
        recorder.setPrimary(primary)
        XCTAssertEqual(primary.incoming.count, 0, "reports before the binding are not replayed")
    }
}
