// The authenticated clients (Plan 4 Task 5): users search and TURN
// credentials over the server's wire shapes (`{"users": [string]}` and
// `{"username","credential","ttlSec","urls"}`).

@testable import ServerAPI
import XCTest

final class ServerAPIClientsTests: XCTestCase {
    private let tokens = TokenStoreFake()

    // MARK: - Plan test name: test_users_search_encodes_prefix

    func test_users_search_encodes_prefix() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 200, body: Data(#"{"users":["eugene"]}"#.utf8))
        let client = UsersClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        let matches = try await client.search(prefix: "eug")
        XCTAssertEqual(matches, ["eugene"])

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/users")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertTrue(request.url?.query?.hasPrefix("prefix=eug") ?? false)

        // A prefix that must survive percent-encoding: no literal space in
        // the query, and the server sees the original value back.
        _ = try await client.search(prefix: "eu g")
        let second = try XCTUnwrap(fake.requests.last)
        XCTAssertEqual(second.url?.query, "prefix=eu%20g")
    }

    func test_users_search_sorts_matches() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(
            status: 200,
            body: Data(#"{"users":["zeta","alpha","mike"]}"#.utf8)
        )
        let client = UsersClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        let matches = try await client.search(prefix: "")
        XCTAssertEqual(matches, ["alpha", "mike", "zeta"])
    }

    func test_users_search_without_token_is_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 200, body: Data(#"{"users":[]}"#.utf8))
        let client = UsersClient(baseURL: baseURL, transport: fake, tokens: tokens)

        do {
            _ = try await client.search(prefix: "eug")
            XCTFail("expected notAuthenticated")
        } catch let error as APIError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(fake.requests.isEmpty, "no token means no request")
    }

    func test_users_search_non_200_is_server_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        let client = UsersClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        do {
            _ = try await client.search(prefix: "eug")
            XCTFail("expected server(401)")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(401))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_users_search_malformed_body_is_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 200, body: Data(#"{"wrong":"shape"}"#.utf8))
        let client = UsersClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        do {
            _ = try await client.search(prefix: "eug")
            XCTFail("expected malformedResponse")
        } catch let error as APIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Plan test name: test_turn_credentials_decode_shape

    func test_turn_credentials_decode_shape() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let turnJSON = #"{"username":"1750000000:alice","credential":"abc123=","ttlSec":3600,"# +
            #""urls":["turn:turn.example:3478?transport=udp","turns:turn.example:5349?transport=tcp"]}"#
        let fake = TransportFake(status: 200, body: Data(turnJSON.utf8))
        let client = TurnClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        let credentials = try await client.credentials()
        XCTAssertEqual(credentials.username, "1750000000:alice")
        XCTAssertEqual(credentials.credential, "abc123=")
        XCTAssertEqual(credentials.ttlSec, 3600)
        XCTAssertEqual(
            credentials.urls,
            ["turn:turn.example:3478?transport=udp", "turns:turn.example:5349?transport=tcp"]
        )

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/turn")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }
}
