// SettingsViewModel (Plan 4 Task 12): the settings state — server, SPKI
// pin and account read from the persisted SessionConfig, the local device
// id row (no client-facing devices endpoint in server v0.1 — cut), the
// stats overlay toggle persisted through the defaults seam, and the
// offline banner from connection events.

import Foundation
import Messaging
import ServerAPI

@MainActor
@Observable
public final class SettingsViewModel {
    /// The stats overlay preference key (follows the SessionConfigStore
    /// storage-key convention).
    public static let statsOverlayKey = "io.github.eugenehil.linko.stats-overlay"

    public private(set) var online = true

    public var showOfflineBanner: Bool {
        !online
    }

    private let configStore: SessionConfigStore
    private let defaults: any DefaultsWriting
    private let deviceId: String
    private let makeEvents: @Sendable () -> AsyncStream<MessagingEvent>
    private var config: SessionConfig?
    private var eventsTask: Task<Void, Never>?
    private var statsOverlay: Bool = false

    public init(
        configStore: SessionConfigStore,
        defaults: any DefaultsWriting,
        deviceId: String,
        events: @escaping @Sendable () -> AsyncStream<MessagingEvent>
    ) {
        self.configStore = configStore
        self.defaults = defaults
        self.deviceId = deviceId
        makeEvents = events
    }

    /// Reads the persisted state: the SessionConfig and the stats overlay.
    public func load() {
        config = configStore.load()
        statsOverlay = Self.decode(
            defaults.data(forKey: Self.statsOverlayKey)
        ) ?? false
    }

    /// Begins consuming the injected events stream (composition fan-out of
    /// the messaging service events). Safe to call again.
    /// Subscribes a fresh stream per start (the composition's multiplexer
    /// hands out a new branch each call): the settings sheet appears and
    /// disappears freely without stranding the view model on a finished
    /// one-shot stream. Safe to call again.
    public func start() {
        if eventsTask == nil {
            eventsTask = Task { [weak self] in
                guard let stream = self?.makeEvents() else { return }
                for await event in stream {
                    guard let self else { break }
                    handle(event)
                }
            }
        }
    }

    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    public func handle(_ event: MessagingEvent) {
        if case let .connectionChanged(isOnline) = event {
            online = isOnline
        }
    }

    /// The stats overlay preference; every write persists immediately.
    public var statsOverlayEnabled: Bool {
        get { statsOverlay }
        set {
            statsOverlay = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.setData(data, forKey: Self.statsOverlayKey)
            }
        }
    }

    public var serverText: String {
        guard let config else { return "—" }
        return "\(config.host):\(config.port)"
    }

    public var pinText: String {
        config?.pin ?? "—"
    }

    public var accountText: String {
        config?.username ?? "—"
    }

    /// v0.1 shows the local device id only (no client-facing devices
    /// endpoint in server v0.1 — cut, see the plan).
    public var deviceIdText: String {
        deviceId
    }

    private static func decode(_ data: Data?) -> Bool? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: data)
    }
}
