// RootGraph (Plan 4 Task 13 part 2, LNK-39): the composition root shared by
// both apps — every dependency is built once here and injected by
// initializer; no container, no try!, no force unwraps. A malformed
// persisted config (or an unopenable store) fails the graph build and the
// app stays on onboarding — fail-soft, disclosed in the PR.
//
// The stream discipline (each AsyncStream has exactly one consumer):
//   SignalingClient.events     → EventMultiplexer → [coordinator (via the
//                                ForegroundWebSocketSource split), transfers]
//   coordinator.callState      → EventMultiplexer → [CallLayoutState, the
//                                call view model]
//   engine.dataChannelMessages → EventMultiplexer → [coordinator (via the
//                                split-decorator engine), transfers]
//   engine.dataChannelStates   → EventMultiplexer → [coordinator (same
//                                decorator), the channel-attach pump]
//   MessagingService.events    → EventMultiplexer → [chats, conversation
//                                (per selection), settings]
//   TransferCoordinator.events → EventMultiplexer → [conversation (per
//                                selection)]
//   MissedCallRecorder.calls   → fanoutMap → the chats view model
// The build wiring lives in SessionGraphBuild.swift (same module).

import Call
import CallEngine
import CallKitIntegration
import Calls
import Chats
import Conversation
import CoreBridge
import FileTransfer
import Foundation
import Messaging
import ServerAPI
import Settings
import Signaling

/// The signaling client speaks every send seam: one actor method matches
/// each protocol's requirement (composition-root conformances, app-scope).
extension SignalingClient: @retroactive CallSignalingSending, @retroactive SignalingSending, @retroactive TransferSignaling {}

// MARK: - Adapters

/// ReportsClient behind the coordinator's upload seam (one throw, never
/// retried — the coordinator's contract).
struct ReportsUploader: CallReportUploading {
    let client: ReportsClient

    func post(callId: String, report: String) async throws {
        try await client.post(callId: callId, report: report)
    }
}

/// Completed transfers record into the outbox (the msg.send envelope the
/// transfer coordinator built, filed with its seq lifecycle) and go out
/// over signaling.
struct OutboxTransferRecorder: CompletedTransferRecording {
    let outbox: Outbox
    let signaling: any TransferSignaling

    func record(_ envelope: LKEnvelope) async {
        let messageId = (try? LKMsgSend.from(bodyJSON: envelope.bodyJSON))?.identifier
            ?? envelope.identifier
        await outbox.enqueue(messageId: messageId, envelope: envelope)
        try? await signaling.send(envelope)
    }
}

/// The engine's data channel behind the TransferChannel seam (the engine
/// actor is the channel; the buffered count is unknown on this surface).
struct EngineTransferChannel: TransferChannel {
    let engine: DefaultCallEngine

    var bufferedAmount: Int {
        0
    }

    func send(_ data: Data) async throws {
        try await engine.sendOverDataChannel(data)
    }
}

// MARK: - Session graph

/// Everything one registered session builds. Built and owned on the main
/// actor (its view models and the layout state are MainActor surfaces);
/// the graph's loops run in its own tasks until the state tears them down.
@MainActor
final class SessionGraph {
    let config: SessionConfig
    let deviceId: String
    let configStore: SessionConfigStore
    let defaults: any DefaultsWriting
    let engine: DefaultCallEngine
    let signaling: SignalingClient
    let store: MessageStore
    let outbox: Outbox
    let messaging: MessagingService
    let transfers: TransferCoordinator
    let coordinator: CallCoordinator
    let callLayout = CallLayoutState()
    let chatsViewModel: ChatsViewModel
    let settingsViewModel: SettingsViewModel
    let callViewModel: CallViewModel

    /// The ForegroundWebSocketSource split; retained for explicit lifetime
    /// parity with the coordinator's event loop.
    private let split: SignalingEventSplit

    /// The messaging-events multiplexer: a fresh conversation branch per
    /// selection (each AsyncStream has exactly one consumer).
    private let messagingEventsMultiplexer: EventMultiplexer<MessagingEvent>
    /// The transfer-events multiplexer: the conversation branch per
    /// selection.
    private let transferEventsMultiplexer: EventMultiplexer<TransferEvent>
    /// The signaling-events multiplexer: the transfers branch (the
    /// coordinator's copy comes from the ForegroundWebSocketSource split).
    private let signalingEventsMultiplexer: EventMultiplexer<SignalingEvent>
    /// The engine data-channel multiplexers (coordinator + transfers).
    private let dataChannelMessagesMultiplexer: EventMultiplexer<Data>
    private let dataChannelStatesMultiplexer: EventMultiplexer<Bool>

    private var loops: [Task<Void, Never>] = []

    /// Wires the built pieces together (the construction order is
    /// SessionGraphBuild's affair; this is plain assignment).
    init(
        config: SessionConfig,
        deviceId: String,
        configStore: SessionConfigStore,
        defaults: any DefaultsWriting,
        engine: DefaultCallEngine,
        signaling: SignalingClient,
        store: MessageStore,
        outbox: Outbox,
        messaging: MessagingService,
        transfers: TransferCoordinator,
        coordinator: CallCoordinator,
        chatsViewModel: ChatsViewModel,
        settingsViewModel: SettingsViewModel,
        callViewModel: CallViewModel,
        split: SignalingEventSplit,
        messagingEventsMultiplexer: EventMultiplexer<MessagingEvent>,
        transferEventsMultiplexer: EventMultiplexer<TransferEvent>,
        signalingEventsMultiplexer: EventMultiplexer<SignalingEvent>,
        dataChannelMessagesMultiplexer: EventMultiplexer<Data>,
        dataChannelStatesMultiplexer: EventMultiplexer<Bool>
    ) {
        self.config = config
        self.deviceId = deviceId
        self.configStore = configStore
        self.defaults = defaults
        self.engine = engine
        self.signaling = signaling
        self.store = store
        self.outbox = outbox
        self.messaging = messaging
        self.transfers = transfers
        self.coordinator = coordinator
        self.chatsViewModel = chatsViewModel
        self.settingsViewModel = settingsViewModel
        self.callViewModel = callViewModel
        self.split = split
        self.messagingEventsMultiplexer = messagingEventsMultiplexer
        self.transferEventsMultiplexer = transferEventsMultiplexer
        self.signalingEventsMultiplexer = signalingEventsMultiplexer
        self.dataChannelMessagesMultiplexer = dataChannelMessagesMultiplexer
        self.dataChannelStatesMultiplexer = dataChannelStatesMultiplexer
    }

    /// A fresh conversation view model for one selected chat; each
    /// selection subscribes its own branches (the view model stops them on
    /// disappear, which detaches the branches).
    func makeConversationViewModel(peer: String) -> ConversationViewModel {
        let messagingMux = messagingEventsMultiplexer
        let transferMux = transferEventsMultiplexer
        return ConversationViewModel(
            localUser: config.username,
            peer: peer,
            store: store,
            messaging: messaging,
            events: { messagingMux.subscribe() },
            transfers: { transferMux.subscribe() }
        )
    }

    /// Starts every graph loop: the coordinator's own consumers, the
    /// messaging service and transfer coordinator over their signaling
    /// branches, the data-channel pumps, and the layout watcher.
    func start(layoutBranch: AsyncStream<CallState>) {
        coordinator.start()
        loops.append(Task { await messaging.run(signalingEventsMultiplexer.subscribe()) })
        loops.append(Task { [transfers] in
            for await event in signalingEventsMultiplexer.subscribe() {
                await transfers.handle(event)
            }
        })
        loops.append(Task { [transfers] in
            for await data in dataChannelMessagesMultiplexer.subscribe() {
                await transfers.handleInboundFrame(data)
            }
        })
        loops.append(Task { [transfers, coordinator, engine] in
            for await open in dataChannelStatesMultiplexer.subscribe() {
                guard open else { continue }
                let state = coordinator.currentState
                guard state.kind == .active || state.kind == .connecting else { continue }
                await transfers.attach(channel: EngineTransferChannel(engine: engine), for: state.callId)
            }
        })
        // The layout watcher: the shell reads showsCallScreen from here,
        // and each live call registers its peer with the transfer
        // coordinator (the msg.send recorder needs the recipient).
        loops.append(Task { [callLayout, transfers] in
            for await state in layoutBranch {
                callLayout.update(state)
                if state.kind == .connecting || state.kind == .active {
                    await transfers.bindPeer(callId: state.callId, peer: state.peer)
                }
            }
        })
    }

    /// Stops the coordinator, the view models and the graph's own loops.
    func stop() {
        coordinator.stop()
        callViewModel.stop()
        chatsViewModel.stop()
        settingsViewModel.stop()
        for loop in loops {
            loop.cancel()
        }
        loops = []
    }
}
