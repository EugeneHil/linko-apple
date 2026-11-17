// Shared test doubles for the ServerAPI test targets (Plan 4 Task 5):
// a canned-transport fake that records every request, an in-memory
// TokenStoring, a recording DefaultsWriting for the hygiene assertions, a
// recording logger for the never-log assertion, and an in-memory Keychain
// adapter for the hermetic token-store tests. Lock-guarded classes:
// recording is synchronous, and `NSLock.withLock` is the async-safe scoped
// form Swift 6 accepts from async contexts.

import Foundation
@testable import ServerAPI
import XCTest

/// Answers every request with a canned status/body and records what arrived.
final class TransportFake: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responder: @Sendable (URLRequest) -> (status: Int, body: Data)
    private var recorded: [URLRequest] = []

    init(status: Int, body: Data = Data()) {
        responder = { _ in (status, body) }
    }

    init(responder: @escaping @Sendable (URLRequest) -> (status: Int, body: Data)) {
        self.responder = responder
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            recorded.append(request)
        }
        let answer = responder(request)
        let responseURL = request.url ?? URL(fileURLWithPath: "/nonexistent")
        guard let http = HTTPURLResponse(
            url: responseURL,
            statusCode: answer.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            throw APIError.malformedResponse
        }
        return (answer.body, http)
    }

    var requests: [URLRequest] {
        lock.withLock {
            recorded
        }
    }
}

/// In-memory `TokenStoring` for flows that must not touch the Keychain.
final class TokenStoreFake: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func save(_ token: String) async throws {
        lock.withLock {
            stored = token
        }
    }

    func load() async throws -> String? {
        lock.withLock {
            stored
        }
    }

    func clear() async throws {
        lock.withLock {
            stored = nil
        }
    }
}

/// In-memory `DefaultsWriting` that records every write so the hygiene
/// assertions can scan them (Review Focus 5: the token never lands in
/// defaults) while behaving like real storage for the round-trip tests.
final class DefaultsWritingFake: DefaultsWriting, @unchecked Sendable {
    struct Write: Equatable {
        let key: String
        let data: Data
    }

    private let lock = NSLock()
    private var written: [Write] = []
    private var storage: [String: Data] = [:]

    var writes: [Write] {
        lock.withLock {
            written
        }
    }

    func setData(_ data: Data, forKey key: String) {
        lock.withLock {
            written.append(Write(key: key, data: data))
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
            storage[key] = nil
        }
    }
}

/// Records every log line so the never-log assertions can scan them.
final class LoggingFake: HTTPLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func info(_ message: String) {
        lock.withLock {
            recorded.append("info: \(message)")
        }
    }

    func error(_ message: String) {
        lock.withLock {
            recorded.append("error: \(message)")
        }
    }

    var messages: [String] {
        lock.withLock {
            recorded
        }
    }
}

/// In-memory `KeychainAdapting` for the hermetic token-store tests.
final class InMemoryKeychain: KeychainAdapting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    private func key(service: String, account: String) -> String {
        "\(service)/\(account)"
    }

    func save(service: String, account: String, data: Data) -> OSStatus {
        lock.withLock {
            storage[key(service: service, account: account)] = data
            return errSecSuccess
        }
    }

    func read(service: String, account: String) -> Data? {
        lock.withLock {
            storage[key(service: service, account: account)]
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            storage.removeValue(forKey: key(service: service, account: account)) != nil
                ? errSecSuccess
                : errSecItemNotFound
        }
    }
}
