// Registration (Plan 4 Task 5). The client validates the username exactly
// like the server before any network call, maps the wire's `{"error": code}`
// replies onto typed errors, and never crashes on unexpected 201 bodies
// (Review Focus 1).

@testable import ServerAPI
import XCTest

final class RegisterServiceTests: XCTestCase {
    private let link = InviteLink(
        host: "server.example", port: 8443, pin: "a+b/c=", code: "K7Q2W9"
    )

    // MARK: - Username validation (mirrors register_handler.cpp)

    func test_username_validation_matches_server() {
        XCTAssertTrue(RegisterService.isValidUsername("a"))
        XCTAssertTrue(RegisterService.isValidUsername(String(repeating: "a", count: 32)))
        XCTAssertTrue(RegisterService.isValidUsername("a_b.c-d"))
        XCTAssertTrue(RegisterService.isValidUsername("eugene.mac"))

        XCTAssertFalse(RegisterService.isValidUsername(""))
        XCTAssertFalse(RegisterService.isValidUsername(String(repeating: "a", count: 33)))
        XCTAssertFalse(RegisterService.isValidUsername("Alice"))
        XCTAssertFalse(RegisterService.isValidUsername("spa ce"))
        XCTAssertFalse(RegisterService.isValidUsername("юзер"))
    }

    // MARK: - Plan test name: test_username_validated_before_network

    func test_username_validated_before_network() async {
        let fake = TransportFake(status: 201)
        let service = RegisterService(transport: fake)

        for invalid in ["", "Alice", "spa ce", String(repeating: "a", count: 33)] {
            do {
                _ = try await service.register(link: link, username: invalid)
                XCTFail("expected invalidUsername for \(invalid)")
            } catch let error as RegisterError {
                XCTAssertEqual(error, .invalidUsername, invalid)
            } catch {
                XCTFail("unexpected error \(error) for \(invalid)")
            }
        }
        XCTAssertTrue(fake.requests.isEmpty, "an invalid username must never reach the network")
    }

    // MARK: - The 201 happy path (wire shape: {"user","device","token"})

    func test_register_decodes_201_session() async throws {
        let fake = TransportFake(
            status: 201,
            body: Data(#"{"user":"alice","device":42,"token":"tok-123"}"#.utf8)
        )
        let service = RegisterService(transport: fake)

        let session = try await service.register(link: link, username: "alice")
        XCTAssertEqual(session.user, "alice")
        XCTAssertEqual(session.deviceId, 42)
        XCTAssertEqual(session.token, "tok-123")

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/register")
        XCTAssertEqual(request.url?.host, "server.example")
        XCTAssertEqual(request.url?.port, 8443)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(sent["code"], "K7Q2W9")
        XCTAssertEqual(sent["username"], "alice")
    }

    // MARK: - Plan test name: test_register_maps_invite_invalid_403

    func test_register_maps_invite_invalid_403() async {
        let fake = TransportFake(status: 403, body: Data(#"{"error":"invalid_invite"}"#.utf8))
        let service = RegisterService(transport: fake)

        do {
            _ = try await service.register(link: link, username: "alice")
            XCTFail("expected inviteInvalid")
        } catch let error as RegisterError {
            XCTAssertEqual(error, .inviteInvalid)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Plan test name: test_register_maps_throttled_429

    func test_register_maps_throttled_429() async {
        let fake = TransportFake(status: 429, body: Data(#"{"error":"too_many_attempts"}"#.utf8))
        let service = RegisterService(transport: fake)

        do {
            _ = try await service.register(link: link, username: "alice")
            XCTFail("expected throttled")
        } catch let error as RegisterError {
            XCTAssertEqual(error, .throttled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - The server's own invalid_username code maps too

    func test_register_maps_server_invalid_username_400() async {
        let fake = TransportFake(status: 400, body: Data(#"{"error":"invalid_username"}"#.utf8))
        let service = RegisterService(transport: fake)

        do {
            _ = try await service.register(link: link, username: "alice")
            XCTFail("expected invalidUsername")
        } catch let error as RegisterError {
            XCTAssertEqual(error, .invalidUsername)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Plan test name: test_register_unexpected_response_is_error

    func test_register_unexpected_response_is_error() async {
        let service = RegisterService(transport: TransportFake(
            status: 201,
            body: Data("this is not json".utf8)
        ))

        do {
            _ = try await service.register(link: link, username: "alice")
            XCTFail("expected unexpected for a malformed 201 body")
        } catch let error as RegisterError {
            XCTAssertEqual(error, .unexpected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_register_wrong_types_in_201_is_unexpected() async {
        let service = RegisterService(transport: TransportFake(
            status: 201,
            body: Data(#"{"user":1,"device":"not-a-number","token":null}"#.utf8)
        ))

        do {
            _ = try await service.register(link: link, username: "alice")
            XCTFail("expected unexpected for wrong 201 types")
        } catch let error as RegisterError {
            XCTAssertEqual(error, .unexpected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_register_unknown_error_status_is_unexpected() async {
        let service = RegisterService(transport: TransportFake(
            status: 500,
            body: Data(#"{"error":"registration_failed"}"#.utf8)
        ))

        do {
            _ = try await service.register(link: link, username: "alice")
            XCTFail("expected unexpected for a 500")
        } catch let error as RegisterError {
            XCTAssertEqual(error, .unexpected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
