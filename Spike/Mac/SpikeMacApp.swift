import SwiftUI
import WebRTC

@main
struct SpikeMacApp: App {
    @StateObject private var session = PeerSession()
    var body: some Scene {
        WindowGroup { MacView().environmentObject(session).frame(minWidth: 820, minHeight: 560) }
    }
}

/// Caller: sends "call", waits for "accept", then creates the offer.
struct MacView: View {
    @EnvironmentObject var session: PeerSession

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoView(track: session.remoteVideo).background(.black)
                VideoView(track: session.localVideo).frame(width: 160, height: 120).padding()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(session.status).font(.headline)
                Text(session.stats).font(.caption.monospaced())
                SettingsForm()
                HStack {
                    Button("Connect") { connect() }
                    Button("Call") { session.signaling.send(Signal(type: "call")); session.note("call sent") }
                        .buttonStyle(.borderedProminent)
                    Button("Hang up", role: .destructive) { session.hangup() }
                }
                ForEach(Array(session.log.enumerated()), id: \.offset) { Text($0.element).font(.caption2) }
                Spacer()
            }
            .padding()
            .frame(width: 300)
        }
    }

    private func connect() {
        session.signaling.onState = { [weak session] in session?.note($0) }
        session.signaling.onSignal = { [weak session] signal in
            guard let session else { return }
            if signal.type == "accept" { session.start(isCaller: true) } else { session.handle(signal) }
        }
        if let url = SettingsForm.apply(to: session) { session.signaling.connect(url) }
    }
}
