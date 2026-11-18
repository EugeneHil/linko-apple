// SessionGraphBuild (Plan 4 Task 13 part 2, LNK-39): the construction half
// of the composition root — services, the coordinator assembly (fan-outs
// plus the platform reporting composite) and the view models, then the
// SessionGraph that ties them together. Fail-soft: malformed URLs or an
// unopenable store build no graph (the app stays on onboarding).

import Call
import CallEngine
import CallKitIntegration
import Calls
import Chats
import Conversation
import FileTransfer
import Foundation
import Messaging
import ServerAPI
import Settings
import Signaling

/// The long-lived services one session runs on (no UI objects).
struct GraphServices {
    let apiBase: URL
    let tokens: KeychainTokenStore
    let transport: PinnedHTTPClient
    let outbox: Outbox
    let store: MessageStore
    let signaling: SignalingClient
    let messaging: MessagingService
    let transfers: TransferCoordinator
    let engine: DefaultCallEngine
}

/// The coordinator's wiring: the fan-outs feeding it and the reporter.
struct CoordinatorAssembly {
    let coordinator: CallCoordinator
    let missedRecorder: MissedCallRecorder
    let split: SignalingEventSplit
    let signalingFanout: EventMultiplexer<SignalingEvent>
    let messagesFanout: EventMultiplexer<Data>
    let statesFanout: EventMultiplexer<Bool>
}

/// The registration-scoped values the view models need at construction.
struct SessionBuildContext {
    let config: SessionConfig
    let configStore: SessionConfigStore
    let deviceId: String
    let defaults: any DefaultsWriting
}

/// The UI wiring over the assembly's streams.
struct GraphFans {
    let callViewModel: CallViewModel
    let chatsViewModel: ChatsViewModel
    let settingsViewModel: SettingsViewModel
    let callStateFanout: EventMultiplexer<CallState>
    let messagingFanout: EventMultiplexer<MessagingEvent>
    let transferFanout: EventMultiplexer<TransferEvent>
}

extension SessionGraph {
    /// Builds the graph, or nil when the environment cannot support a
    /// session (malformed host/port, unopenable store) — the app then stays
    /// on onboarding rather than crashing.
    @MainActor
    static func build(
        config: SessionConfig,
        deviceId: String,
        defaults: any DefaultsWriting,
        configStore: SessionConfigStore,
        makeReporting: @escaping @MainActor (CallCoordinator) -> any CallReporting
    ) async -> SessionGraph? {
        guard let services = await makeServices(config: config, deviceId: deviceId) else {
            return nil
        }
        let context = SessionBuildContext(
            config: config,
            configStore: configStore,
            deviceId: deviceId,
            defaults: defaults
        )
        let assembly = await makeAssembly(services: services, makeReporting: makeReporting)
        let fans = await makeViewModels(services: services, assembly: assembly, context: context)
        let graph = SessionGraph(
            config: config,
            deviceId: deviceId,
            configStore: configStore,
            defaults: defaults,
            engine: services.engine,
            signaling: services.signaling,
            store: services.store,
            outbox: services.outbox,
            messaging: services.messaging,
            transfers: services.transfers,
            coordinator: assembly.coordinator,
            chatsViewModel: fans.chatsViewModel,
            settingsViewModel: fans.settingsViewModel,
            callViewModel: fans.callViewModel,
            split: assembly.split,
            messagingEventsMultiplexer: fans.messagingFanout,
            transferEventsMultiplexer: fans.transferFanout,
            signalingEventsMultiplexer: assembly.signalingFanout,
            dataChannelMessagesMultiplexer: assembly.messagesFanout,
            dataChannelStatesMultiplexer: assembly.statesFanout
        )
        graph.start(layoutBranch: fans.callStateFanout.subscribe())
        return graph
    }

    /// The long-lived services: transport, outbox, store, signaling,
    /// messaging, transfers and the one engine per app.
    private static func makeServices(
        config: SessionConfig,
        deviceId: String
    ) async -> GraphServices? {
        guard let apiBase = URL(string: "https://\(config.host):\(config.port)"),
              let wsURL = URL(string: "wss://\(config.host):\(config.port)/ws")
        else {
            return nil
        }
        let tokens = KeychainTokenStore()
        let transport = PinnedHTTPClient(expectedPin: config.pin)
        let outbox = Outbox()
        // Fail-soft: an unopenable store cannot back chats or messaging.
        guard let store = try? MessageStore() else {
            return nil
        }
        let signaling = SignalingClient(
            url: wsURL,
            expectedPin: config.pin,
            user: config.username,
            deviceId: deviceId,
            tokenProvider: { try? await tokens.load() }
        )
        let messaging = MessagingService(
            localUser: config.username,
            store: store,
            outbox: outbox,
            signaling: signaling
        )
        let files = FilesClient(baseURL: apiBase, transport: transport, tokens: tokens)
        let transfers = TransferCoordinator(
            signaling: signaling,
            recorder: OutboxTransferRecorder(outbox: outbox, signaling: signaling),
            server: ServerFileTransfer(files: files)
        )
        // Fail-soft: a refused TURN fetch yields an empty relay list — ICE
        // still works host-to-host, relayed calls degrade (disclosed).
        let turn = try? await TurnClient(baseURL: apiBase, transport: transport, tokens: tokens)
            .credentials()
        let engine = DefaultCallEngine(credentials: turn ?? TurnCredentials(
            username: "",
            credential: "",
            ttlSec: 0,
            urls: []
        ))
        return GraphServices(
            apiBase: apiBase,
            tokens: tokens,
            transport: transport,
            outbox: outbox,
            store: store,
            signaling: signaling,
            messaging: messaging,
            transfers: transfers,
            engine: engine
        )
    }

    /// The coordinator over the fan-outs, the missed-call recorder and the
    /// late-bound platform reporter.
    private static func makeAssembly(
        services: GraphServices,
        makeReporting: @escaping @MainActor (CallCoordinator) -> any CallReporting
    ) async -> CoordinatorAssembly {
        let network = LiveNetworkMonitor()
        let reports = ReportsClient(
            baseURL: services.apiBase,
            transport: services.transport,
            tokens: services.tokens
        )

        // Fan the single-consumer signaling stream: the ForegroundWebSocket
        // split (coordinator copy + invite source) and the transfers branch.
        let signalingFanout = await EventMultiplexer(services.signaling.events)
        let split = ForegroundWebSocketSource.split(signalingFanout.subscribe())

        // The data-channel split: the coordinator reads branches through the
        // decorator; the transfers pump reads its own branches.
        let messagesFanout = EventMultiplexer(services.engine.dataChannelMessages)
        let statesFanout = EventMultiplexer(services.engine.dataChannelStates)
        let splitEngine = SplitDataChannelEngine(
            inner: services.engine,
            messages: messagesFanout.subscribe(),
            states: statesFanout.subscribe()
        )

        let missedRecorder = MissedCallRecorder()
        let coordinator = CallCoordinator(
            signaling: services.signaling,
            signalingEvents: split.events,
            engine: splitEngine,
            reporting: missedRecorder,
            source: split.source,
            network: network,
            uploader: ReportsUploader(client: reports)
        )
        let reporting = makeReporting(coordinator)
        missedRecorder.setPrimary(reporting)

        return CoordinatorAssembly(
            coordinator: coordinator,
            missedRecorder: missedRecorder,
            split: split,
            signalingFanout: signalingFanout,
            messagesFanout: messagesFanout,
            statesFanout: statesFanout
        )
    }

    /// The UI wiring over the call-state, messaging-events and
    /// transfer-events fan-outs; the missed-call stream maps into the
    /// chats stream.
    private static func makeViewModels(
        services: GraphServices,
        assembly: CoordinatorAssembly,
        context: SessionBuildContext
    ) async -> GraphFans {
        // The call-state fan-out: the layout watcher and the call view
        // model are two consumers of the single-consumer stream.
        let callStateFanout = EventMultiplexer(assembly.coordinator.callState)
        let callViewModel = CallViewModel(
            coordinator: assembly.coordinator,
            defaults: context.defaults,
            stateStream: callStateFanout.subscribe()
        )
        let messagingFanout = await EventMultiplexer(services.messaging.events)
        let missedCalls = fanoutMap(assembly.missedRecorder.calls) { notice in
            MissedCallEvent(peer: notice.peer, ts: notice.ts)
        }
        let chatsViewModel = ChatsViewModel(
            localUser: context.config.username,
            store: services.store,
            events: messagingFanout.subscribe(),
            missedCalls: missedCalls
        )
        let settingsViewModel = SettingsViewModel(
            configStore: context.configStore,
            defaults: context.defaults,
            deviceId: context.deviceId,
            events: messagingFanout.subscribe()
        )
        let transferFanout = await EventMultiplexer(services.transfers.events)

        return GraphFans(
            callViewModel: callViewModel,
            chatsViewModel: chatsViewModel,
            settingsViewModel: settingsViewModel,
            callStateFanout: callStateFanout,
            messagingFanout: messagingFanout,
            transferFanout: transferFanout
        )
    }
}
