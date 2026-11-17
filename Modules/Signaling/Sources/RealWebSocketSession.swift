// Production WebSocket transport (Plan 4 Task 4): URLSessionWebSocketTask
// wrapped once behind the WebSocketSession seam — text frames in, frames and
// close codes out, TLS pinned through SPKIPinValidator (fail closed).

import Foundation
import Synchronization

// MARK: - Production transport

/// URLSessionWebSocketTask wrapped once: sends text frames, streams inbound
/// frames, and fails closed on TLS through the SPKIPinValidator delegate.
final class RealWebSocketSession: NSObject, WebSocketSession, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let urlSession: URLSession
    private let closeCode = Mutex<Int?>(nil)

    init(request: URLRequest, expectedPin: String) {
        let validator = SPKIPinValidator(expectedPin: expectedPin)
        let session = URLSession(configuration: .default, delegate: validator, delegateQueue: nil)
        urlSession = session
        task = session.webSocketTask(with: request)
        super.init()
        task.resume()
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> WebSocketInbound {
        do {
            let message = try await task.receive()
            switch message {
            case let .string(text):
                return .text(text)
            case let .data(data):
                return .text(String(data: data, encoding: .utf8) ?? "")
            @unknown default:
                return .text("")
            }
        } catch {
            // The server's close frame surfaces in the delegate; when it
            // arrived, the close code is the inbound result, otherwise the
            // transport died without one.
            if let code = closeCode.withLock({ $0 }) {
                return .closed(code: code)
            }
            throw error
        }
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith code: URLSessionWebSocketTask.CloseCode,
        reason _: Data?
    ) {
        closeCode.withLock { $0 = Int(code.rawValue) }
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        (urlSession.delegate as? SPKIPinValidator)?
            .handleChallenge(challenge, completionHandler: completionHandler)
    }
}
