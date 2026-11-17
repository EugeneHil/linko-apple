// Invite link parsing (Plan 4 Task 5). The invite link is the only carrier
// of the SPKI pin and the invite code: pin and code are mandatory (a pin-less
// link would mean trust-on-first-use — rejected), the port must parse, and
// unknown query parameters are ignored (Review Focus 1).

@testable import ServerAPI
import XCTest

final class InviteLinkTests: XCTestCase {
    // MARK: - Plan test name: test_invite_link_parses_all_fields

    func test_invite_link_parses_all_fields() throws {
        // The pin is raw server-side base64 ("+", "/", "=" unescaped) —
        // parsing must not reinterpret "+" as a space.
        let link = try XCTUnwrap(InviteLink.parse(
            "linko://join?host=server.example&port=8443&pin=a+b/c=&code=K7Q2W9"
        ).get())
        XCTAssertEqual(link.host, "server.example")
        XCTAssertEqual(link.port, 8443)
        XCTAssertEqual(link.pin, "a+b/c=")
        XCTAssertEqual(link.code, "K7Q2W9")
    }

    // MARK: - Plan test name: test_invite_link_without_pin_rejected

    func test_invite_link_without_pin_rejected() {
        let result = InviteLink.parse("linko://join?host=server.example&port=8443&code=K7Q2W9")
        XCTAssertEqual(result, .failure(.missingPin))
    }

    // MARK: - Plan test name: test_invite_link_missing_code_rejected

    func test_invite_link_missing_code_rejected() {
        let result = InviteLink.parse("linko://join?host=server.example&port=8443&pin=a+b/c=")
        XCTAssertEqual(result, .failure(.missingCode))
    }

    // MARK: - Plan test name: test_invite_link_bad_port_rejected

    func test_invite_link_bad_port_rejected() {
        XCTAssertEqual(
            InviteLink.parse("linko://join?host=server.example&port=0&pin=p&code=c"),
            .failure(.badPort)
        )
        XCTAssertEqual(
            InviteLink.parse("linko://join?host=server.example&port=8443abc&pin=p&code=c"),
            .failure(.badPort)
        )
        XCTAssertEqual(
            InviteLink.parse("linko://join?host=server.example&port=70000&pin=p&code=c"),
            .failure(.badPort)
        )
    }

    // MARK: - Plan test name: test_invite_link_unknown_params_ignored

    func test_invite_link_unknown_params_ignored() throws {
        let link = try XCTUnwrap(InviteLink.parse(
            "linko://join?ttl=3600&flag&host=server.example&port=8443&pin=a+b/c=&code=K7Q2W9&extra=1"
        ).get())
        XCTAssertEqual(link.host, "server.example")
        XCTAssertEqual(link.port, 8443)
        XCTAssertEqual(link.pin, "a+b/c=")
        XCTAssertEqual(link.code, "K7Q2W9")
    }

    // MARK: - Extra coverage: hostile hosts and foreign schemes (Review Focus 1)

    func test_invite_link_junk_host_rejected() {
        XCTAssertEqual(
            InviteLink.parse("linko://join?host=&port=8443&pin=p&code=c"),
            .failure(.missingHost)
        )
        XCTAssertEqual(
            InviteLink.parse("linko://join?host=bad%20host&port=8443&pin=p&code=c"),
            .failure(.badHost)
        )
    }

    func test_invite_link_non_linko_scheme_rejected() {
        XCTAssertEqual(
            InviteLink.parse("https://join?host=server.example&port=8443&pin=p&code=c"),
            .failure(.notALinkoLink)
        )
    }
}
