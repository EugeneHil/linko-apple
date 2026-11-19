// Token and session-config persistence (Plan 4 Task 5). The token lives
// only in the Keychain (spec 6): the seam round-trips, the real store is
// exercised on the macOS host, and no persistence write ever carries the
// token into defaults (Review Focus 5).

@testable import ServerAPI
import XCTest

final class TokenStoreTests: XCTestCase {
    // MARK: - Plan test name: test_token_roundtrip_through_seam

    func test_token_roundtrip_through_seam() async throws {
        let store = KeychainTokenStore(
            service: "io.github.eugenehil.linko.tests.seam",
            adapter: InMemoryKeychain()
        )

        try await store.save("tok-first")
        let first = try await store.load()
        XCTAssertEqual(first, "tok-first")

        // A second save updates the single entry instead of duplicating it.
        try await store.save("tok-second")
        let second = try await store.load()
        XCTAssertEqual(second, "tok-second")

        try await store.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    // MARK: - Plan test name: test_keychain_roundtrip_real_store (macOS host)

    #if os(macOS)
        func test_keychain_roundtrip_real_store() async throws {
            let store = KeychainTokenStore(
                service: "io.github.eugenehil.linko.tests.\(UUID().uuidString)"
            )

            try await store.save("tok-real")
            let loaded = try await store.load()
            XCTAssertEqual(loaded, "tok-real")

            try await store.clear()
            let cleared = try await store.load()
            XCTAssertNil(cleared)
        }
    #endif

    // MARK: - SessionConfig persistence through the DefaultsWriting seam

    func test_config_roundtrip_through_defaults() {
        let defaults = DefaultsWritingFake()
        let store = SessionConfigStore(defaults: defaults)
        let config = SessionConfig(
            host: "server.example", port: 8443, pin: "a+b/c=", username: "alice"
        )

        XCTAssertNoThrow(try store.persist(config))
        XCTAssertEqual(store.load(), config)
        XCTAssertFalse(defaults.writes.isEmpty)

        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - Plan test name: test_token_never_written_to_defaults

    func test_token_never_written_to_defaults() async throws {
        let defaults = DefaultsWritingFake()
        let configStore = SessionConfigStore(defaults: defaults)
        let tokens = TokenStoreFake()

        // The post-registration persistence flow exactly as the composition
        // root (Task 13) will run it: non-secret config into defaults, the
        // token only into the token store.
        let config = SessionConfig(
            host: "server.example", port: 8443, pin: "a+b/c=", username: "alice"
        )
        XCTAssertNoThrow(try configStore.persist(config))
        try await tokens.save("SECRET-TOKEN-VALUE")

        XCTAssertTrue(defaults.writes.contains { $0.key == SessionConfigStore.storageKey })
        for write in defaults.writes {
            let body = String(bytes: write.data, encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("SECRET-TOKEN-VALUE"), "write \(write.key) leaked the token")
        }
    }

    // MARK: - Device id persistence (part 2 / LNK-39; Task 14 coverage backfill)

    func test_device_id_roundtrip_through_defaults() {
        let defaults = DefaultsWritingFake()
        let store = SessionConfigStore(defaults: defaults)

        store.persistDeviceId(42)
        XCTAssertEqual(store.loadDeviceId(), "42", "the decimal device id rides as its string form")
        XCTAssertTrue(
            defaults.writes.contains { $0.key == SessionConfigStore.deviceIdKey },
            "the device id lives under its own defaults key"
        )
    }

    func test_load_device_id_missing_is_nil() {
        let store = SessionConfigStore(defaults: DefaultsWritingFake())

        XCTAssertNil(store.loadDeviceId(), "fail-soft: the app stays on onboarding without one")
    }

    func test_load_device_id_survives_config_writes() {
        let defaults = DefaultsWritingFake()
        let store = SessionConfigStore(defaults: defaults)
        let config = SessionConfig(
            host: "server.example", port: 8443, pin: "a+b/c=", username: "alice"
        )

        XCTAssertNoThrow(try store.persist(config))
        store.persistDeviceId(7)
        XCTAssertEqual(store.loadDeviceId(), "7", "the config blob and the device id are separate keys")
    }

    // MARK: - UserDefaultsWriter round-trip (Task 14 coverage backfill)

    func test_user_defaults_writer_roundtrip() throws {
        let suiteName = "io.github.eugenehil.linko.tests.user-defaults-writer"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = UserDefaultsWriter(defaults: defaults)
        let payload = Data("non-secret-config".utf8)
        let key = "io.github.eugenehil.linko.tests.writer-key"

        XCTAssertNil(writer.data(forKey: key))
        writer.setData(payload, forKey: key)
        XCTAssertEqual(writer.data(forKey: key), payload)
        writer.removeObject(forKey: key)
        XCTAssertNil(writer.data(forKey: key))
    }
}
