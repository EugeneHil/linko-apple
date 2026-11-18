// ProviderAdapter (Plan 4 Task 10 / LNK-36, iOS only): the CallKit boundary.
// Reports incoming calls onto CXProvider (fed from the IncomingCallSource
// through the coordinator's ReportIncoming effect), fulfills or fails every
// CXCallAction synchronously in the delegate (spec §7: the boundary adapter
// does exactly that and nothing more), and routes the user's actions into
// the coordinator: answer → accept() + audio configuration, mute →
// toggleMute(), end → reject()/hangup(), remote end → the machine's
// ReportEnded effect lands here as an ended report (ADR-0001: the spike
// proved provider.reportCall(.remoteEnded) for remote hangups).

#if os(iOS)
    import AVFAudio
    import CallEngine
    import CallKit
    import Calls
    import Foundation
    import Synchronization

    /// The CXProvider report surface (the live reporter owns the provider;
    /// tests record instead).
    public protocol IncomingCallReporting: Sendable {
        /// Reports a new incoming call; returns whether CallKit accepted it.
        func reportIncoming(uuid: UUID, handle: String, video: Bool) async -> Bool
        /// Reports the call ended with the machine's end reason.
        func reportEnded(uuid: UUID, reason: CallEndReason)
    }

    /// The synchronous action completion surface (spec §7: a CallKit action
    /// must be fulfilled or failed right at the boundary).
    public protocol CallActionCompleting: Sendable {
        func fulfill(_ action: CXCallAction)
        func fail(_ action: CXCallAction)
    }

    /// The CallKit boundary adapter. One reported call at a time per
    /// coordinator; the registry maps CallKit's UUIDs to the coordinator's
    /// call identities.
    public final class ProviderAdapter: NSObject, CXProviderDelegate, CallReporting {
        /// One registered call: the CallKit identity plus what the answer
        /// and end routing need.
        private struct RegisteredCall {
            let callId: String
            let video: Bool
            let incoming: Bool
        }

        private let coordinator: any CallCoordinating
        private let audio: AudioSessionCoordinator
        private let reporter: any IncomingCallReporting
        private let actions: any CallActionCompleting
        private let registry = Mutex<[UUID: RegisteredCall]>([:])
        private let muted = Mutex(false)

        public init(
            coordinator: any CallCoordinating,
            audio: AudioSessionCoordinator,
            reporter: any IncomingCallReporting,
            actions: any CallActionCompleting = LiveCallActionCompleter()
        ) {
            self.coordinator = coordinator
            self.audio = audio
            self.reporter = reporter
            self.actions = actions
            super.init()
        }

        // MARK: CallReporting

        /// ReportIncoming: the machine is ringing an incoming call for the
        /// user. When CallKit refuses the presentation, the ringing state
        /// cannot stand — the reject ends the call on the wire and releases
        /// the machine.
        public func reportIncoming(callId: String, peer: String, video: Bool) async {
            let uuid = UUID()
            registry.withLock { $0[uuid] = RegisteredCall(callId: callId, video: video, incoming: true) }
            let accepted = await reporter.reportIncoming(uuid: uuid, handle: peer, video: video)
            if !accepted {
                registry.withLock { $0[uuid] = nil }
                await coordinator.reject()
            }
        }

        /// ReportEnded: the call ended for `reason`. Only calls this adapter
        /// reported to CallKit carry an ended report; the boundary stays
        /// silent about what it never presented.
        public func reportEnded(callId: String, reason: CallEndReason) async {
            let removed = registry.withLock { registry -> (UUID, RegisteredCall)? in
                guard let (uuid, entry) = registry.first(where: { $0.value.callId == callId }) else {
                    return nil
                }
                registry[uuid] = nil
                return (uuid, entry)
            }
            guard let (uuid, _) = removed else { return }
            reporter.reportEnded(uuid: uuid, reason: reason)
        }

        /// StartRinging: CallKit plays the incoming ringtone itself.
        public func startRinging() async {}

        /// StopRinging: CallKit owns the ringtone lifecycle.
        public func stopRinging() async {}

        // MARK: CXProviderDelegate

        /// The user answered from the system UI: fulfill synchronously,
        /// configure the audio session for the call's media and route the
        /// accept into the coordinator.
        public func provider(_: CXProvider, perform action: CXAnswerCallAction) {
            guard let call = registry.withLock({ $0[action.callUUID] }) else {
                actions.fail(action)
                return
            }
            actions.fulfill(action)
            audio.configure(video: call.video)
            Task { await coordinator.accept() }
        }

        /// The user ended or declined from the system UI: fulfill
        /// synchronously and route the state-appropriate action into the
        /// coordinator.
        public func provider(_: CXProvider, perform action: CXEndCallAction) {
            guard let call = registry.withLock({ $0[action.callUUID] }) else {
                actions.fail(action)
                return
            }
            actions.fulfill(action)
            let incoming = call.incoming
            Task {
                if incoming {
                    await coordinator.reject()
                } else {
                    await coordinator.hangup()
                }
            }
        }

        /// Mute from the system UI: fulfill synchronously and toggle only
        /// when the request differs from the adapter's own state.
        public func provider(_: CXProvider, perform action: CXSetMutedCallAction) {
            guard registry.withLock({ $0[action.callUUID] }) != nil else {
                actions.fail(action)
                return
            }
            actions.fulfill(action)
            let shouldToggle = muted.withLock { state in
                guard state != action.isMuted else { return false }
                state = action.isMuted
                return true
            }
            guard shouldToggle else { return }
            Task { await coordinator.toggleMute() }
        }

        /// CallKit activated the audio session: WebRTC's audio unit may run.
        public func provider(_: CXProvider, didActivate _: AVAudioSession) {
            audio.activate()
        }

        /// CallKit deactivated the audio session: the microphone indicator
        /// dies here.
        public func provider(_: CXProvider, didDeactivate _: AVAudioSession) {
            audio.deactivate()
        }

        /// CallKit lost its own state (e.g. a rejected transaction): nothing
        /// of ours can stand either.
        public func providerDidReset(_: CXProvider) {
            registry.withLock { $0.removeAll() }
        }

        // MARK: Composition root (Task 13)

        /// The live wiring: builds the adapter over the shared manual-audio
        /// controller and binds it as the provider's delegate.
        public static func live(coordinator: any CallCoordinating) -> (adapter: ProviderAdapter, provider: CXProvider) {
            let reporter = LiveIncomingCallReporter()
            let adapter = ProviderAdapter(coordinator: coordinator, audio: .live(), reporter: reporter)
            reporter.provider.setDelegate(adapter, queue: nil)
            return (adapter, reporter.provider)
        }
    }

    /// The live CXProvider reporter: the provider the delegate binds to and
    /// the plain CallKit reports.
    public final class LiveIncomingCallReporter: IncomingCallReporting, @unchecked Sendable {
        /// The provider the adapter binds itself to (composition root).
        public let provider: CXProvider

        public init(configuration: CXProviderConfiguration = CXProviderConfiguration()) {
            provider = CXProvider(configuration: configuration)
        }

        public func reportIncoming(uuid: UUID, handle: String, video: Bool) async -> Bool {
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: handle)
            update.localizedCallerName = handle
            update.hasVideo = video
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            return await withCheckedContinuation { continuation in
                provider.reportNewIncomingCall(with: uuid, update: update) { error in
                    continuation.resume(returning: error == nil)
                }
            }
        }

        public func reportEnded(uuid: UUID, reason: CallEndReason) {
            provider.reportCall(with: uuid, endedAt: Date(), reason: Self.endReason(reason))
        }

        /// The machine's end reason mapped to CallKit's.
        static func endReason(_ reason: CallEndReason) -> CXCallEndedReason {
            switch reason {
            case .normal, .cancelled: .remoteEnded
            case .rejected: .declinedElsewhere
            case .busy, .missed, .timeout: .unanswered
            case .error: .failed
            }
        }
    }

    /// The live action completer: CallKit's own fulfill/fail.
    public struct LiveCallActionCompleter: CallActionCompleting {
        public init() {}

        public func fulfill(_ action: CXCallAction) {
            action.fulfill()
        }

        public func fail(_ action: CXCallAction) {
            action.fail()
        }
    }
#endif
