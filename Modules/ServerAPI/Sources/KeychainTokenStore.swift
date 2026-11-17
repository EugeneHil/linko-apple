// The device token lives only in the Keychain (spec 6):
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, never synchronizable,
// never UserDefaults, never files. The Security calls sit behind the
// `KeychainAdapting` seam so the store's routing is testable hermetically;
// the real store is exercised on the macOS host (Task 5's
// test_keychain_roundtrip_real_store).

import Foundation
import Security

/// How the register flow and the authenticated clients read and keep the
/// device token; the production implementation is `KeychainTokenStore`.
public protocol TokenStoring: Sendable {
    func save(_ token: String) async throws
    func load() async throws -> String?
    func clear() async throws
}

public enum KeychainError: Error, Sendable, Equatable {
    case osStatus(OSStatus)
}

/// The Security operations the store needs, in Data terms. Public because
/// the store's public initializer takes an adapter (hermetic tests inject
/// an in-memory one).
public protocol KeychainAdapting: Sendable {
    func save(service: String, account: String, data: Data) -> OSStatus
    func read(service: String, account: String) -> Data?
    func delete(service: String, account: String) -> OSStatus
}

/// The real Keychain: update the existing generic password, add it when
/// missing, read it back, delete it. Every query pins
/// kSecAttrSynchronizable = false and the add also pins
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (spec 6).
public struct SecurityKeychain: KeychainAdapting {
    public init() {}

    public func save(service: String, account: String, data: Data) -> OSStatus {
        let lookup = Self.itemAttributes(service: service, account: account)
        let status = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess {
            return errSecSuccess
        }
        if status != errSecItemNotFound {
            return status
        }
        var add = lookup
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    public func read(service: String, account: String) -> Data? {
        var query = Self.itemAttributes(service: service, account: account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(Self.itemAttributes(service: service, account: account) as CFDictionary)
    }

    /// The shared generic-password attributes. Built key by key: SwiftFormat's
    /// trailingCommas and SwiftLint's trailing_comma disagree on multi-line
    /// literals (the DesignSystem lesson), so the repo avoids them.
    private static func itemAttributes(service: String, account: String) -> [String: Any] {
        var attributes: [String: Any] = [:]
        attributes[kSecClass as String] = kSecClassGenericPassword
        attributes[kSecAttrService as String] = service
        attributes[kSecAttrAccount as String] = account
        attributes[kSecAttrSynchronizable as String] = false
        return attributes
    }
}

public struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String
    private let keychain: any KeychainAdapting

    public init(
        service: String = "io.github.eugenehil.linko",
        account: String = "device-token",
        adapter: any KeychainAdapting = SecurityKeychain()
    ) {
        self.service = service
        self.account = account
        keychain = adapter
    }

    public func save(_ token: String) async throws {
        let status = keychain.save(
            service: service,
            account: account,
            data: Data(token.utf8)
        )
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    public func load() async throws -> String? {
        guard let data = keychain.read(service: service, account: account) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    public func clear() async throws {
        let status = keychain.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}
