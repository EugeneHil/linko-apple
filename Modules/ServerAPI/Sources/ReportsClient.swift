// Call reports (Plan 4 Task 8): POST /api/v1/calls/{callId}/report with the
// device token as Bearer. The server stores the JSON body verbatim behind
// its 8 KiB gate and answers 204 No Content; a 4xx answer is a typed error
// the caller must not retry blindly (report_handler.cpp).
//
// Plan deviation note: the plan lists ReportsClient.swift under "Modify",
// but Task 5 never created it — it is created here following the
// TurnClient/UsersClient pattern (PinnedHTTPClient transport, Bearer via
// TokenStoring).

import Foundation

public struct ReportsClient: Sendable {
    private let requester: AuthorizedPost

    public init(baseURL: URL, transport: HTTPTransport, tokens: TokenStoring) {
        requester = AuthorizedPost(baseURL: baseURL, transport: transport, tokens: tokens)
    }

    /// Uploads the serialized report JSON for the call. Returns on 204; any
    /// other status is `APIError.server`, thrown once — never retried.
    public func post(callId: String, report: String) async throws {
        let (_, http) = try await requester.data(
            path: "api/v1/calls/\(callId)/report",
            body: Data(report.utf8)
        )
        guard http.statusCode == 204 else {
            throw APIError.server(http.statusCode)
        }
    }
}

/// Shared plumbing for the authenticated POST clients (reports): loads the
/// token through `TokenStoring`, attaches it as a Bearer header and posts
/// the JSON body.
struct AuthorizedPost: Sendable {
    let baseURL: URL
    let transport: HTTPTransport
    let tokens: TokenStoring

    func data(path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        guard let token = try await tokens.load() else {
            throw APIError.notAuthenticated
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformedResponse
        }
        return (data, http)
    }
}
