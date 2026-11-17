// ReportsClient tests (Plan 4 Task 8 / LNK-34): POST /api/v1/calls/{callId}/
// report with the device token as Bearer — 204 is success (void), a 4xx
// answer is a typed error and never retried blindly, no token means no
// request at all.

@testable import ServerAPI
import XCTest

final class ReportsClientTests: XCTestCase {
    private let tokens = TokenStoreFake()

    // MARK: - Plan test name: test_report_sends_bearer_and_returns_void_on_204

    func test_report_sends_bearer_and_returns_void_on_204() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 204)
        let client = ReportsClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")
        let report = #"{"callId":"call-abc","avgRttMs":40}"#

        try await client.post(callId: "call-abc", report: report)

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/calls/call-abc/report")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, Data(report.utf8))
    }

    func test_report_4xx_is_typed_error_and_never_retried() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 400, body: Data(#"{"error":"invalid_report"}"#.utf8))
        let client = ReportsClient(baseURL: baseURL, transport: fake, tokens: tokens)
        try await tokens.save("tok-123")

        do {
            try await client.post(callId: "call-abc", report: "{}")
            XCTFail("expected server(400)")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(400))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(fake.requests.count, 1, "a 4xx answer is never retried blindly")
    }

    func test_report_without_token_is_error() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://server.example"))
        let fake = TransportFake(status: 204)
        let client = ReportsClient(baseURL: baseURL, transport: fake, tokens: tokens)

        do {
            try await client.post(callId: "call-abc", report: "{}")
            XCTFail("expected notAuthenticated")
        } catch let error as APIError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(fake.requests.isEmpty, "no token means no request")
    }
}
