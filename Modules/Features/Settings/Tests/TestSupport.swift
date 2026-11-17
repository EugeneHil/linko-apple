// Shared fakes for the Settings test target (Plan 4 Task 12): an in-memory
// defaults writer so both the SessionConfig persistence and the stats
// overlay toggle are observed hermetically.

import Foundation
import ServerAPI

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

/// Decodes a persisted Bool the way SettingsViewModel stores it.
func persistedBool(_ defaults: DefaultsFake, key: String) -> Bool? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(Bool.self, from: data)
}

/// Polls until `condition` holds (bounded); the pumped stream drains within
/// ticks because AsyncStream buffers. MainActor-isolated: view model state
/// the conditions read is MainActor-confined.
@MainActor
func waitFor(
    timeoutSeconds: Double = 2,
    _ condition: @autoclosure () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
