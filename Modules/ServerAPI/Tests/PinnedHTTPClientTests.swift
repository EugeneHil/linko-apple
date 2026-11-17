// PinnedHTTPClient (Plan 4 Task 5): the shared pinned URLSession. The
// never-log rule (Review Focus 5) is pinned hermetically: the request
// carries the Authorization header onto the wire (the stub protocol sees
// it) while no log line ever contains the token. The production
// initializer wires Signaling's SPKIPinValidator as the session's
// URLSessionDelegate; the stubbed protocol never reaches TLS, so the
// request path itself must work with the pinner attached.

import Foundation
@testable import ServerAPI
import XCTest

/// Answers requests locally so no network is touched.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    // Accessed only under `lock`; `nonisolated(unsafe)` silences the global
    // mutable state check that cannot see the guard.
    private nonisolated(unsafe) static var status = 200
    private nonisolated(unsafe) static var body = Data()
    private nonisolated(unsafe) static var seen: [URLRequest] = []

    static func reset() {
        lock.lock()
        status = 200
        body = Data()
        seen = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.record(request)
        guard let client else { return }
        let responseURL = request.url ?? URL(fileURLWithPath: "/nonexistent")
        guard let response = HTTPURLResponse(
            url: responseURL,
            statusCode: Self.currentStatus(),
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Self.currentBody())
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func record(_ request: URLRequest) {
        lock.lock()
        seen.append(request)
        lock.unlock()
    }

    private static func currentStatus() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    private static func currentBody() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return body
    }
}

final class PinnedHTTPClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    // MARK: - Plan test name: test_http_client_never_logs_authorization

    func test_http_client_never_logs_authorization() async throws {
        let logger = LoggingFake()
        let client = PinnedHTTPClient(session: URLSession(configuration: stubConfiguration()), logger: logger)

        let url = try XCTUnwrap(URL(string: "https://server.example/api/v1/turn"))
        var request = URLRequest(url: url)
        request.setValue("Bearer SECRET-TOKEN", forHTTPHeaderField: "Authorization")

        let (_, response) = try await client.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        // The header reached the wire (the stub protocol saw it)…
        let seen = try XCTUnwrap(StubURLProtocol.recordedRequests().first)
        XCTAssertEqual(
            seen.value(forHTTPHeaderField: "Authorization"),
            "Bearer SECRET-TOKEN"
        )
        // …while no log line carries the token. The non-empty check proves
        // the logging seam is actually exercised by this request.
        XCTAssertFalse(logger.messages.isEmpty)
        XCTAssertTrue(
            logger.messages.allSatisfy { !$0.contains("SECRET-TOKEN") },
            "a log line leaked the token: \(logger.messages)"
        )
    }

    // MARK: - The production initializer wires the SPKI pinner and works

    func test_pinned_init_serves_stubbed_requests() async throws {
        let client = PinnedHTTPClient(
            expectedPin: TestPins.stub,
            configuration: stubConfiguration(),
            logger: LoggingFake()
        )

        let url = try XCTUnwrap(URL(string: "https://server.example/api/v1/users"))
        let (_, response) = try await client.data(for: URLRequest(url: url))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
    }
}

/// A syntactically valid pin constant for the offline request-path test;
/// the pin matching itself is SPKIPinValidator's contract (Task 4 tests).
private enum TestPins {
    static let stub = "NOFwaottIq6/ZIaAYKJd2bIZ/YcjL5v5wd9mwgAOJIs="
}
