// The pinned HTTP transport shared by every ServerAPI client (Plan 4
// Task 5). The production session's TLS trust decisions come from
// Signaling's SPKIPinValidator — wired once here as the URLSession
// delegate (fail closed, never trust-on-first-use, spec 4.3). Logging goes
// through an injectable seam and emits method, URL and status only — never
// headers or bodies (Review Focus 5: Authorization and token values are
// never logged).

import Foundation
import os
import Signaling

/// The transport seam every API client speaks over; tests inject fakes,
/// production uses `PinnedHTTPClient`.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Typed errors for the authenticated clients (users search, TURN).
public enum APIError: Error, Sendable, Equatable {
    /// No token is available in the `TokenStoring` seam.
    case notAuthenticated
    /// The server answered with a non-200 status.
    case server(Int)
    /// The reply is not an HTTP response or its body has an unexpected shape.
    case malformedResponse
}

/// The logging seam; production lines carry method, URL and status only.
public protocol HTTPLogging: Sendable {
    func info(_ message: String)
    func error(_ message: String)
}

/// os.Logger-backed default (subsystem from spec 4.3).
public struct OSLogHTTPLogging: HTTPLogging {
    private let logger = Logger(
        subsystem: "io.github.eugenehil.linko",
        category: "server-api"
    )

    public init() {}

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// The pinned `URLSession` shared by all API clients. The session is kept
/// alive for the client's lifetime and invalidated on deinit (the same
/// ownership pattern as Signaling's RealWebSocketSession).
public final class PinnedHTTPClient: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let logger: HTTPLogging

    /// Production: an HTTP session whose every TLS trust challenge is
    /// answered by Signaling's SPKIPinValidator — pinned to the SPKI pin
    /// carried by the invite link, failing closed on any mismatch.
    public convenience init(
        expectedPin: String,
        configuration: URLSessionConfiguration = .default,
        logger: HTTPLogging = OSLogHTTPLogging()
    ) {
        let validator = SPKIPinValidator(expectedPin: expectedPin)
        self.init(
            session: URLSession(configuration: configuration, delegate: validator, delegateQueue: nil),
            logger: logger
        )
    }

    /// The test seam: a caller-built session (e.g. URLProtocol-backed).
    public init(session: URLSession, logger: HTTPLogging = OSLogHTTPLogging()) {
        self.session = session
        self.logger = logger
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Method, URL and status only — never headers, never bodies, so the
    /// Authorization value and the token cannot appear in any log line.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "(no url)"
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("\(method) \(url) -> \(status)")
            return (data, response)
        } catch {
            logger.error("\(method) \(url) failed")
            throw error
        }
    }
}

/// Shared plumbing for the authenticated GET clients (users, TURN): loads
/// the token through `TokenStoring` and attaches it as a Bearer header.
struct AuthorizedGet: Sendable {
    let baseURL: URL
    let transport: HTTPTransport
    let tokens: TokenStoring

    func data(path: String, query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        guard let token = try await tokens.load() else {
            throw APIError.notAuthenticated
        }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.malformedResponse
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformedResponse
        }
        return (data, http)
    }
}
