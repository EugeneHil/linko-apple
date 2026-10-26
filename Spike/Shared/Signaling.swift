import Foundation

/// Throwaway signaling message, relayed verbatim to the other peer.
struct Signal: Codable {
    var type: String // call | accept | offer | answer | ice | hangup
    var sdp: String?
    var candidate: String?
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

@MainActor
final class SignalingClient {
    private var task: URLSessionWebSocketTask?
    var onSignal: ((Signal) -> Void)?
    var onState: ((String) -> Void)?

    func connect(_ url: URL) {
        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        onState?("connecting \(url.absoluteString)")
        Task { await receiveLoop(task) }
    }

    func send(_ signal: Signal) {
        guard let task, let data = try? JSONEncoder().encode(signal),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await task.send(.string(text)) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        onState?("connected")
        while true {
            do {
                let message = try await task.receive()
                if case let .string(text) = message,
                   let signal = try? JSONDecoder().decode(Signal.self, from: Data(text.utf8)) {
                    onSignal?(signal)
                }
            } catch {
                onState?("disconnected: \(error.localizedDescription)")
                return
            }
        }
    }
}
