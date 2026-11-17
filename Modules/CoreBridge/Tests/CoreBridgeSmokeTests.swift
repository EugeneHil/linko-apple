// TDD smoke test (Plan 4 Task 1 / LNK-27, Step 1): the minimal LKEnvelope
// wrapper must round-trip the spec 4.2 example envelope through the C++ core.

import CoreBridge
import XCTest

final class CoreBridgeSmokeTests: XCTestCase {
    // Spec 4.2 protocol v1 example, concrete ids in place of the elisions:
    // {"v":1,"type":"call.offer","id":"6f1c…","ts":1792877416123,
    //  "body":{"callId":"c7a2…","to":"anna","media":"video","sdp":"v=0…"}}
    private let wireEnvelope =
        #"{"v":1,"type":"call.offer","id":"6f1c","ts":1792877416123,"body":{"callId":"c7a2","to":"anna","media":"video","sdp":"v=0"}}"#

    func test_envelope_roundtrip_through_core_bridge() throws {
        let parsed = try XCTUnwrap(
            LKEnvelope.parse(jsonString: wireEnvelope).envelope,
            "the spec 4.2 example envelope must parse"
        )

        XCTAssertEqual(parsed.v, 1)
        XCTAssertEqual(parsed.type, "call.offer")
        XCTAssertEqual(parsed.identifier, "6f1c")
        XCTAssertEqual(parsed.ts, 1_792_877_416_123)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(parsed.bodyJSON.utf8)) as? [String: Any],
            "bodyJSON must be valid JSON"
        )
        XCTAssertEqual(body["callId"] as? String, "c7a2")
        XCTAssertEqual(body["to"] as? String, "anna")
        XCTAssertEqual(body["media"] as? String, "video")
        XCTAssertEqual(body["sdp"] as? String, "v=0")

        let serialized = parsed.wireJSON
        let reparsed = try XCTUnwrap(
            LKEnvelope.parse(jsonString: serialized).envelope,
            "the serialized envelope must parse again"
        )
        XCTAssertEqual(reparsed.v, parsed.v)
        XCTAssertEqual(reparsed.type, parsed.type)
        XCTAssertEqual(reparsed.identifier, parsed.identifier)
        XCTAssertEqual(reparsed.ts, parsed.ts)
        XCTAssertEqual(reparsed.bodyJSON, parsed.bodyJSON)
        XCTAssertEqual(reparsed.wireJSON, serialized, "serialize(parse(serialize(e))) is stable")
    }
}
