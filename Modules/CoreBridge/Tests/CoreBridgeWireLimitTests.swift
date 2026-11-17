// TDD test (Plan 4 Task 4 / LNK-30, Step 1): the wire limit the Signaling
// client checks oversized server frames against must come from the core's
// single source of truth (kMaxEnvelopeBytes), not a duplicated literal.

import CoreBridge
import XCTest

final class CoreBridgeWireLimitTests: XCTestCase {
    func test_max_envelope_bytes_matches_wire_limit() {
        XCTAssertEqual(
            LKTypes.maxEnvelopeBytes, 65536,
            "the wire limit is pinned in the design spec 4.2: envelopes <= 64 KiB"
        )
    }
}
