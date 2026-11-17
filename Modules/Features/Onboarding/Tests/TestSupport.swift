// Shared fakes for the Onboarding test target (Plan 4 Task 12): a recording
// HTTP transport (counts requests, scripted replies), an in-memory token
// store and an in-memory defaults writer for the session config.

import Foundation
import ServerAPI

/// Records every request and answers with the scripted result; lets tests
/// assert "no network happened" and hand back typed replies.
final class TransportFake: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let reply: @Sendable (URLRequest) throws -> (Data, URLResponse)

    init(reply: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.reply = reply
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            recorded.append(request)
        }
        return try reply(request)
    }

    var requests: [URLRequest] {
        lock.withLock {
            recorded
        }
    }
}

/// Records saved tokens in memory (the real Keychain store is exercised by
/// the ServerAPI suite).
final class TokenStoreFake: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String] = []

    func save(_ token: String) async throws {
        lock.withLock {
            saved.append(token)
        }
    }

    func load() async throws -> String? {
        lock.withLock {
            saved.last
        }
    }

    func clear() async throws {
        lock.withLock {
            saved.removeAll()
        }
    }

    var tokens: [String] {
        lock.withLock {
            saved
        }
    }
}

/// In-memory DefaultsWriting: pre-seed with `setData`, assert reads with
/// `data(forKey:)`.
final class DefaultsFake: DefaultsWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func setData(_ data: Data, forKey key: String) {
        lock.withLock {
            storage[key] = data
        }
    }

    func data(forKey key: String) -> Data? {
        lock.withLock {
            storage[key]
        }
    }

    func removeObject(forKey key: String) {
        lock.withLock {
            _ = storage.removeValue(forKey: key)
        }
    }
}

/// Scripted transport replies.
enum Replies {
    /// A JSON body with the given HTTP status, answered for any request.
    static func json(_ body: String, status: Int) -> @Sendable (URLRequest) throws -> (Data, URLResponse) {
        { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url, statusCode: status, httpVersion: nil, headerFields: nil
                  )
            else {
                throw APIError.malformedResponse
            }
            return (Data(body.utf8), response)
        }
    }
}
