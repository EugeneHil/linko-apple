// BootstrapTransport (Plan 4 Task 13 part 2, LNK-39): the onboarding
// transport and the platform reporting composite. The registration
// transport's trust anchor is the pasted invite's pin — knowable only
// after the user submits the link. The box is written by the root state
// when the onboarding view model parses an invite; challenges read the pin
// from here and reuse Signaling's SPKI pipeline (fail closed: no box pin,
// no match — cancelled).

import CallKitIntegration
import Calls
import Foundation
import ServerAPI
import Signaling
import Synchronization

final class InvitePinBox: @unchecked Sendable {
    private let pin = Mutex<String?>(nil)

    func set(_ value: String?) {
        pin.withLock { $0 = value }
    }

    var current: String? {
        pin.withLock { $0 }
    }
}

final class InvitePinValidator: NSObject, URLSessionDelegate {
    private let box: InvitePinBox

    init(box: InvitePinBox) {
        self.box = box
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let pin = box.current,
              let trust = challenge.protectionSpace.serverTrust,
              SPKIPinValidator(expectedPin: pin).isPinned(trust)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// The onboarding transport: same pinned-session discipline as
/// PinnedHTTPClient, with the pin supplied per challenge from the invite
/// box instead of a fixed value.
struct InvitePinnedTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(box: InvitePinBox) {
        let validator = InvitePinValidator(box: box)
        session = URLSession(
            configuration: .default,
            delegate: validator,
            delegateQueue: nil
        )
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - Platform reporting

#if os(iOS)
    /// The iOS reporting composite: CallKit's provider adapter (the audio
    /// session coordinator rides inside ProviderAdapter.live).
    @MainActor
    func makePlatformReporting(coordinator: CallCoordinator) -> any CallReporting {
        let (adapter, _) = ProviderAdapter.live(coordinator: coordinator)
        return adapter
    }
#else
    /// The macOS reporting composite: the incoming-call window plus the
    /// user-notification fallback (spec §4.3) — no CallKit on macOS.
    @MainActor
    func makePlatformReporting(coordinator: CallCoordinator) -> any CallReporting {
        MacCallPresenter(
            window: IncomingCallWindow(),
            notifier: LiveMacNotifier(),
            coordinator: coordinator
        )
    }
#endif
