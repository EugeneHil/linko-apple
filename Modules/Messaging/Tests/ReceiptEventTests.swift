// The receiptsUpdated emission (e2e-rehearsal fix): the peer's ack
// envelopes advance the watermarks AND surface as events, so the
// conversation screen refreshes its receipt lines live.

import CoreBridge
import Foundation
@testable import Messaging
import XCTest

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MessagingEvent] = []

    func add(_ event: MessagingEvent) {
        lock.withLock {
            items.append(event)
        }
    }

    func contains(_ event: MessagingEvent) -> Bool {
        lock.withLock {
            items.contains(event)
        }
    }
}

@MainActor
final class ReceiptEventTests: XCTestCase {
    private let alice = "alice"
    private let bob = "bob"

    func test_ack_yields_receipts_updated_event() async throws {
        let store = try Fixtures.inMemoryStore()
        let service = MessagingService(
            localUser: alice, store: store, outbox: Outbox(), signaling: SignalingSendingFake()
        )

        let collector = Collector()
        let stream = await service.events
        let run = Task {
            for await event in stream {
                collector.add(event)
            }
        }

        let conversation = ConversationKey.key(alice, bob)
        let ack = Fixtures.ackEnvelope(
            type: LKTypes.msgAckRead,
            conversation: conversation,
            uptoSeq: 4
        )
        await service.handle(.envelope(ack))

        let deadline = Date().addingTimeInterval(2)
        var seen = false
        while Date() < deadline {
            if collector.contains(.receiptsUpdated(conversation: conversation)) {
                seen = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(seen, "the ack surfaces as receiptsUpdated so the UI refreshes live")
        run.cancel()
    }
}
