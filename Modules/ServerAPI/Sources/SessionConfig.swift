// SessionConfig (Plan 4 Task 5): the non-secret registration outcome the
// app needs at every launch — host, port, pin, username — persisted as one
// JSON blob through the `DefaultsWriting` seam. The device token never
// passes through here (spec 6: Keychain only, see KeychainTokenStore;
// Review Focus 5 pins that no defaults write carries the token).

import Foundation

public struct SessionConfig: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let pin: String
    public let username: String

    public init(host: String, port: Int, pin: String, username: String) {
        self.host = host
        self.port = port
        self.pin = pin
        self.username = username
    }
}

/// The UserDefaults seam; tests record every write so the hygiene
/// assertions can scan them.
public protocol DefaultsWriting: Sendable {
    func setData(_ data: Data, forKey key: String)
    func data(forKey key: String) -> Data?
    func removeObject(forKey key: String)
}

/// The production writer against `.standard` (or any explicit defaults).
/// `@unchecked`: UserDefaults is thread-safe by contract but not marked
/// Sendable.
public struct UserDefaultsWriter: DefaultsWriting, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func setData(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

public struct SessionConfigStore: Sendable {
    public static let storageKey = "io.github.eugenehil.linko.session-config"
    /// The device id under its own defaults key (part 2 / LNK-39): the
    /// registration's `Session.deviceId`, needed at every launch to build
    /// the SignalingClient and the Settings screen. Non-secret; the token
    /// stays in the Keychain (Review Focus 5).
    public static let deviceIdKey = "io.github.eugenehil.linko.device-id"

    private let defaults: any DefaultsWriting

    public init(defaults: any DefaultsWriting) {
        self.defaults = defaults
    }

    public func persist(_ config: SessionConfig) throws {
        try defaults.setData(JSONEncoder().encode(config), forKey: Self.storageKey)
    }

    /// Fail-soft: a corrupt blob is no config, not a crash.
    public func load() -> SessionConfig? {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionConfig.self, from: data)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Persists the decimal device id from `Session.deviceId` at
    /// onboarding; loaded again at every launch.
    public func persistDeviceId(_ id: Int64) {
        defaults.setData(Data(String(id).utf8), forKey: Self.deviceIdKey)
    }

    /// Fail-soft: a missing or corrupt entry reads as nil (the app then
    /// cannot build the signaling graph and stays on onboarding).
    public func loadDeviceId() -> String? {
        guard let data = defaults.data(forKey: Self.deviceIdKey) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
