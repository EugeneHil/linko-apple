// Registration (Plan 4 Task 5): POST /api/v1/register with the invite code
// and the username. The username is validated exactly like the server's
// register_handler.cpp before any network call; the wire's `{"error":
// code}` replies map onto typed RegisterError values by their code; and
// unexpected bodies — malformed or wrongly-typed 201 JSON included —
// surface as .unexpected and never crash (Review Focus 1).

import Foundation

/// The registration reply `201 {"user","device","token"}` (spec 4.5).
public struct Session: Equatable, Sendable {
    public let user: String
    public let deviceId: Int64
    public let token: String
}

public enum RegisterError: Error, Sendable, Equatable {
    /// The username fails the server's rule (checked locally, before any
    /// network call, and mirrored from the server's 400 invalid_username).
    case invalidUsername
    /// The invite code was rejected (403 invalid_invite).
    case inviteInvalid
    /// The address budget is exhausted (429 too_many_attempts).
    case throttled
    /// Anything else: malformed replies, wrong types, unknown error codes.
    case unexpected
}

public struct RegisterService: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// Mirrors register_handler.cpp `isValidUsername`: 1–32 chars of
    /// [a-z0-9_.-]. ASCII-only, so character count and byte count agree.
    public static func isValidUsername(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32 else { return false }
        return name.allSatisfy { character in
            ("a" ... "z").contains(character) ||
                ("0" ... "9").contains(character) ||
                character == "_" || character == "." || character == "-"
        }
    }

    public func register(link: InviteLink, username: String) async throws -> Session {
        // Rejected before any network call — the fake transport in
        // test_username_validated_before_network asserts zero requests.
        guard Self.isValidUsername(username) else {
            throw RegisterError.invalidUsername
        }
        // The host passed InviteLink.parse's charset rule, so the
        // interpolation is ASCII-safe; a nil URL is a typed error, not a
        // crash.
        guard let url = URL(string: "https://\(link.host):\(link.port)/api/v1/register") else {
            throw RegisterError.unexpected
        }

        struct RegisterRequest: Encodable {
            let code: String
            let username: String
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RegisterRequest(code: link.code, username: username)
        )

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RegisterError.unexpected
        }
        switch http.statusCode {
        case 201:
            return try Self.decodeSession(from: data)
        case 400 ... 599:
            // Error envelopes map by their wire code; anything unknown —
            // including a missing or unparsable code — is .unexpected.
            switch Self.errorCode(in: data) {
            case "invalid_username":
                throw RegisterError.invalidUsername
            case "invalid_invite":
                throw RegisterError.inviteInvalid
            case "too_many_attempts":
                throw RegisterError.throttled
            default:
                throw RegisterError.unexpected
            }
        default:
            throw RegisterError.unexpected
        }
    }

    /// Total: anything that is not exactly the pinned reply shape is
    /// .unexpected — malformed JSON, wrong types, extra noise.
    private static func decodeSession(from data: Data) throws -> Session {
        struct SessionReply: Decodable {
            let user: String
            let device: Int64
            let token: String
        }
        guard let reply = try? JSONDecoder().decode(SessionReply.self, from: data) else {
            throw RegisterError.unexpected
        }
        return Session(user: reply.user, deviceId: reply.device, token: reply.token)
    }

    private static func errorCode(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return body["error"]
    }
}
