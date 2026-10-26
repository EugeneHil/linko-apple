import AVFoundation
import CallKit
import SwiftUI
import WebRTC

@main
struct SpikeiOSApp: App {
    @StateObject private var call = CallController()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(call).environmentObject(call.session) }
    }
}

/// CallKit callee: the Mac calls, CallKit shows the incoming UI, audio is activated by CallKit.
@MainActor
final class CallController: NSObject, ObservableObject {
    let session = PeerSession()
    private let provider: CXProvider
    private let controller = CXCallController()
    private var currentCall: UUID?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)

        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.useManualAudio = true
        rtcAudio.isAudioEnabled = false

        session.signaling.onSignal = { [weak self] signal in self?.handle(signal) }
        session.signaling.onState = { [weak self] state in self?.session.note(state) }
        session.onRemoteHangup = { [weak self] in self?.reportEnded(.remoteEnded) }
    }

    func connect() {
        if let url = SettingsForm.apply(to: session) { session.signaling.connect(url) }
    }

    @Published var muted = false

    func toggleMute() {
        guard let currentCall else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: currentCall, muted: !muted))) { _ in }
    }

    func hangup() {
        guard let currentCall else { session.hangup(); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: currentCall))) { _ in }
    }

    private func handle(_ signal: Signal) {
        if signal.type == "call" {
            let uuid = UUID()
            currentCall = uuid
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "Mac")
            update.localizedCallerName = "Linko Mac"
            update.hasVideo = true
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                Task { @MainActor in self?.session.note("reportNewIncomingCall: \(error?.localizedDescription ?? "ok")") }
            }
        } else {
            session.handle(signal)
        }
    }

    private func reportEnded(_ reason: CXCallEndedReason) {
        guard let currentCall else { return }
        provider.reportCall(with: currentCall, endedAt: Date(), reason: reason)
        self.currentCall = nil
    }

    fileprivate func configureAudioSession() {
        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.lockForConfiguration()
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.videoChat.rawValue
        config.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        do { try rtcAudio.setConfiguration(config) } catch { session.note("audio config: \(error)") }
        rtcAudio.unlockForConfiguration()
    }
}

extension CallController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.session.stop() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            configureAudioSession()
            session.start(isCaller: false)
            session.signaling.send(Signal(type: "accept"))
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            session.hangup()
            currentCall = nil
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let muted = action.isMuted
        MainActor.assumeIsolated { session.setMuted(muted); self.muted = muted; session.note("muted \(muted)") }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        MainActor.assumeIsolated { session.note("audio activated, route \(audioSession.currentRoute.outputs.first?.portType.rawValue ?? "?")") }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}

struct ContentView: View {
    @EnvironmentObject var call: CallController
    @EnvironmentObject var session: PeerSession

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoView(track: session.remoteVideo).ignoresSafeArea().background(.black)
            VStack(alignment: .leading, spacing: 8) {
                Text(session.status).font(.headline)
                Text(session.stats).font(.caption.monospaced())
                ForEach(Array(session.log.enumerated()), id: \.offset) { Text($0.element).font(.caption2) }
                SettingsForm()
                HStack {
                    Button("Connect") { call.connect() }.buttonStyle(.borderedProminent)
                    Button(call.muted ? "Unmute" : "Mute") { call.toggleMute() }.buttonStyle(.bordered)
                    Button("Hang up", role: .destructive) { call.hangup() }.buttonStyle(.bordered)
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            VideoView(track: session.localVideo).frame(width: 90, height: 130).clipShape(RoundedRectangle(cornerRadius: 10)).padding()
        }
    }
}
