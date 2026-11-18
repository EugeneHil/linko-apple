// AppRoot (Plan 4 Task 13 part 2, LNK-39): the iOS composition root. The
// app builds exactly one session graph (one DefaultCallEngine, one
// SignalingClient, one CallCoordinator) per registered session — every
// dependency injected by initializer, no container, no try!/force unwraps.
// Onboarding stands until a config + device id exist; the graph replaces
// the stub's "Text("Linko")" shell with the chats screen, the conversation
// on row tap, the Settings sheet, and the call screen whenever the layout
// watcher says a call is live.

import Call
import CallEngine
import CallKitIntegration
import Calls
import Chats
import Conversation
import DesignSystem
import Onboarding
import ServerAPI
import Settings
import SwiftUI

@main
struct LinkoiOSApp: App {
    @State private var root = RootState()

    var body: some Scene {
        WindowGroup {
            RootView(root: root)
        }
    }
}

/// The app's root state: onboarding or the composed session.
@MainActor
@Observable
final class RootState {
    enum Phase: Equatable {
        case onboarding
        case chats
    }

    /// The launched app's instance — the launch smoke test reads it (the
    /// test host runs in the app's process).
    static var shared: RootState?

    private(set) var phase: Phase = .onboarding
    private(set) var onboarding: OnboardingViewModel?
    private(set) var graph: SessionGraph?
    private(set) var conversationViewModel: ConversationViewModel?

    private let inviteBox = InvitePinBox()
    private let defaults: any DefaultsWriting = UserDefaultsWriter()

    private var configStore: SessionConfigStore {
        SessionConfigStore(defaults: defaults)
    }

    init() {
        Self.shared = self
        if Self.isRunningUnderTestHost {
            Self.seedTestSession(defaults: defaults)
        }
    }

    static var isRunningUnderTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The smoke-test session: a synthetic config (an unroutable host — the
    /// signaling client's background reconnect loop is harmless) so the
    /// test host boots straight to the chats screen.
    static func seedTestSession(defaults: any DefaultsWriting) {
        let store = SessionConfigStore(defaults: defaults)
        try? store.persist(SessionConfig(
            host: "smoke.linko.test",
            port: 443,
            pin: "c21va2Rldg==",
            username: "smoke-user"
        ))
        store.persistDeviceId(42)
    }

    /// Builds the session graph when a config + device id exist. Safe to
    /// call again; a failed build (malformed config, unopenable store)
    /// leaves the app on onboarding.
    func bootstrap() async {
        guard graph == nil, phase == .onboarding else { return }
        guard let config = configStore.load(), let deviceId = configStore.loadDeviceId() else {
            onboarding = makeOnboarding()
            return
        }
        graph = await SessionGraph.build(
            config: config,
            deviceId: deviceId,
            defaults: defaults,
            configStore: configStore,
            makeReporting: makePlatformReporting
        )
        if graph != nil {
            #if os(iOS)
                // The audio route surface (spec §10 item 6): the monitor's
                // streams are single-consumer — the call screen binds them.
                graph?.callViewModel.bindAudioRoutes(
                    monitor: RouteChangeMonitor.live(),
                    switcher: LiveAudioRouteSwitcher()
                )
            #endif
            phase = .chats
        } else {
            onboarding = makeOnboarding()
        }
    }

    /// Registration succeeded: rebuild the graph from the fresh config.
    func registered() async {
        onboarding = nil
        await bootstrap()
    }

    private func makeOnboarding() -> OnboardingViewModel {
        OnboardingViewModel(
            register: RegisterService(transport: InvitePinnedTransport(box: inviteBox)),
            tokens: KeychainTokenStore(),
            configStore: configStore
        )
    }

    /// The onboarding view model parsed an invite: its pin becomes the
    /// bootstrap transport's trust anchor.
    func noteInviteParsed() {
        inviteBox.set(onboarding?.parsedInvite?.pin)
    }

    func select(peer: String) {
        guard let graph else { return }
        conversationViewModel = graph.makeConversationViewModel(peer: peer)
    }

    func deselect() {
        conversationViewModel = nil
    }
}

struct RootView: View {
    let root: RootState
    @State private var settingsPresented = false

    var body: some View {
        Group {
            if let graph = root.graph, root.phase == .chats {
                if graph.callLayout.showsCallScreen {
                    CallScreen(viewModel: graph.callViewModel)
                } else if let conversation = root.conversationViewModel {
                    conversationView(conversation)
                } else {
                    chatsView(graph)
                }
            } else if let onboarding = root.onboarding {
                onboardingView(onboarding)
            } else {
                // The pre-bootstrap frame (and the failed-build frame).
                Text("Linko")
            }
        }
        .task {
            await root.bootstrap()
        }
    }

    private func chatsView(_ graph: SessionGraph) -> some View {
        var chats = ChatsView(viewModel: graph.chatsViewModel)
        chats.onSelect = { peer in root.select(peer: peer) }
        return chats
            .overlay(alignment: .topTrailing) {
                Button {
                    settingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .padding(LKTokens.Spacing.s12)
                }
                .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $settingsPresented) {
                SettingsView(viewModel: graph.settingsViewModel)
            }
    }

    private func conversationView(_ conversation: ConversationViewModel) -> some View {
        VStack(spacing: 0) {
            Button {
                root.deselect()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .padding(LKTokens.Spacing.s12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ConversationView(viewModel: conversation)
        }
    }

    private func onboardingView(_ onboarding: OnboardingViewModel) -> some View {
        OnboardingView(viewModel: onboarding)
            .onChange(of: onboarding.phase) { _, phase in
                // The invite's pin arms the bootstrap transport the moment
                // the link parses; registration success composes the app.
                root.noteInviteParsed()
                if phase == .registered {
                    Task { await root.registered() }
                }
            }
    }
}
