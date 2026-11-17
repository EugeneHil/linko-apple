// TURN credentials (Plan 4 Task 5): GET /api/v1/turn with the device token
// as Bearer. The reply shape `{"username","credential","ttlSec","urls"}` is
// pinned by turn_handler.cpp and feeds CallEngine's RTCIceServer
// construction (Task 7).

import Foundation

public struct TurnCredentials: Equatable, Sendable {
    public let username: String
    public let credential: String
    public let ttlSec: Int
    public let urls: [String]

    public init(username: String, credential: String, ttlSec: Int, urls: [String]) {
        self.username = username
        self.credential = credential
        self.ttlSec = ttlSec
        self.urls = urls
    }
}

public struct TurnClient: Sendable {
    private let requester: AuthorizedGet

    public init(baseURL: URL, transport: HTTPTransport, tokens: TokenStoring) {
        requester = AuthorizedGet(baseURL: baseURL, transport: transport, tokens: tokens)
    }

    public func credentials() async throws -> TurnCredentials {
        let (data, http) = try await requester.data(path: "api/v1/turn")
        guard http.statusCode == 200 else {
            throw APIError.server(http.statusCode)
        }
        struct TurnReply: Decodable {
            let username: String
            let credential: String
            let ttlSec: Int
            let urls: [String]
        }
        guard let reply = try? JSONDecoder().decode(TurnReply.self, from: data) else {
            throw APIError.malformedResponse
        }
        return TurnCredentials(
            username: reply.username,
            credential: reply.credential,
            ttlSec: reply.ttlSec,
            urls: reply.urls
        )
    }
}
