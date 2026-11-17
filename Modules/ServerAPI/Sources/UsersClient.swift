// User search (Plan 4 Task 5): GET /api/v1/users?prefix=… with the device
// token as Bearer. The server caps matches at 20 and iterates its store
// order; the client sorts so the "≤ 20 sorted matches" contract holds
// regardless of store order.

import Foundation

public struct UsersClient: Sendable {
    private let requester: AuthorizedGet

    public init(baseURL: URL, transport: HTTPTransport, tokens: TokenStoring) {
        requester = AuthorizedGet(baseURL: baseURL, transport: transport, tokens: tokens)
    }

    public func search(prefix: String) async throws -> [String] {
        let (data, http) = try await requester.data(
            path: "api/v1/users",
            query: [URLQueryItem(name: "prefix", value: prefix)]
        )
        guard http.statusCode == 200 else {
            throw APIError.server(http.statusCode)
        }
        struct UsersReply: Decodable {
            let users: [String]
        }
        guard let reply = try? JSONDecoder().decode(UsersReply.self, from: data) else {
            throw APIError.malformedResponse
        }
        return reply.users.sorted()
    }
}
