// OnboardingViewModel (Plan 4 Task 12): the registration flow — paste the
// invite link (QR scan is cut #4), validate the username client-side (the
// same rule the server applies, checked before any network call), register
// through RegisterService, store the device token via TokenStoring and
// persist the non-secret SessionConfig. States cover the spec 4.7 failures:
// invite invalid/expired (typed RegisterError), permission denied
// (local network / mic / camera, reported by the composition root) and
// offline (the transport's connectivity error).

import Foundation
import ServerAPI

@MainActor
@Observable
public final class OnboardingViewModel {
    /// Flat flow phases; the view maps each phase to its step and error
    /// copy (invite failures keep the invite step, username failures keep
    /// the username step).
    public enum Phase: Equatable {
        case enterInvite
        case inviteInvalid
        case enterUsername
        case registering
        case registered
        case invalidUsername
        case throttled
        case offline
        case permissionDenied
        case unexpected
    }

    public var inviteText = ""
    public var usernameText = ""
    public private(set) var phase: Phase = .enterInvite

    private let register: RegisterService
    private let tokens: any TokenStoring
    private let configStore: SessionConfigStore
    private var link: InviteLink?

    public init(
        register: RegisterService,
        tokens: any TokenStoring,
        configStore: SessionConfigStore
    ) {
        self.register = register
        self.tokens = tokens
        self.configStore = configStore
    }

    /// Parses the pasted link; a link that does not parse (foreign scheme,
    /// missing pin/code, bad port) shows the invite-invalid state.
    public func submitInvite() {
        switch InviteLink.parse(inviteText) {
        case let .success(parsed):
            link = parsed
            phase = .enterUsername
        case .failure:
            link = nil
            phase = .inviteInvalid
        }
    }

    public func submitUsername() async {
        // The client-side rule mirrors register_handler.cpp; checked before
        // any network call (RegisterService re-checks defensively).
        guard RegisterService.isValidUsername(usernameText) else {
            phase = .invalidUsername
            return
        }
        guard let link else {
            phase = .inviteInvalid
            return
        }
        phase = .registering
        do {
            let session = try await register.register(link: link, username: usernameText)
            try await tokens.save(session.token)
            try configStore.persist(
                SessionConfig(
                    host: link.host,
                    port: link.port,
                    pin: link.pin,
                    username: session.user
                )
            )
            phase = .registered
        } catch let error as RegisterError {
            phase = Self.phase(for: error)
        } catch is URLError {
            phase = .offline
        } catch {
            phase = .unexpected
        }
    }

    /// The composition root reports a denied local-network/mic/camera
    /// permission prompt from the first-run attempts.
    public func reportPermissionDenied() {
        phase = .permissionDenied
    }

    private static func phase(for error: RegisterError) -> Phase {
        switch error {
        case .invalidUsername: .invalidUsername
        case .inviteInvalid: .inviteInvalid
        case .throttled: .throttled
        case .unexpected: .unexpected
        }
    }
}
