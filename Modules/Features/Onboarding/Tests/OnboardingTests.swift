// Onboarding (Plan 4 Task 12): client-side username validation before any
// network call, the typed invite-invalid state, and the success path
// persisting the device token (TokenStoring seam) plus the SessionConfig
// (SessionConfigStore over the defaults seam). All fakes are in TestSupport.

import Foundation
@testable import Onboarding
import ServerAPI
import XCTest

@MainActor
final class OnboardingTests: XCTestCase {
    private let link = "linko://join?host=chat.example&port=8443&pin=AAAA&code=invite-code"

    private func makeViewModel(
        transport: TransportFake,
        tokens: TokenStoreFake,
        defaults: DefaultsFake
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            register: RegisterService(transport: transport),
            tokens: tokens,
            configStore: SessionConfigStore(defaults: defaults)
        )
    }

    /// Paste + accept the invite, then take the flow to the username step.
    private func acceptInvite(_ viewModel: OnboardingViewModel) {
        viewModel.inviteText = link
        viewModel.submitInvite()
    }

    func test_onboarding_rejects_invalid_username_before_network() async {
        let transport = TransportFake(reply: Replies.json("{}", status: 201))
        let viewModel = makeViewModel(transport: transport, tokens: TokenStoreFake(), defaults: DefaultsFake())

        acceptInvite(viewModel)
        viewModel.usernameText = "Bad Name!"
        await viewModel.submitUsername()

        XCTAssertEqual(viewModel.phase, .invalidUsername)
        XCTAssertEqual(transport.requests.count, 0, "an invalid username must never reach the network")
    }

    func test_onboarding_invite_invalid_state_shown() async {
        let transport = TransportFake(reply: Replies.json(#"{"error":"invalid_invite"}"#, status: 403))
        let tokens = TokenStoreFake()
        let defaults = DefaultsFake()
        let viewModel = makeViewModel(transport: transport, tokens: tokens, defaults: defaults)

        acceptInvite(viewModel)
        viewModel.usernameText = "anna"
        await viewModel.submitUsername()

        XCTAssertEqual(viewModel.phase, .inviteInvalid, "the typed RegisterError.inviteInvalid must show")
        XCTAssertTrue(tokens.tokens.isEmpty, "nothing persists on a rejected invite")
        XCTAssertNil(defaults.data(forKey: SessionConfigStore.storageKey))
    }

    func test_onboarding_success_persists_config_and_token() async {
        let transport = TransportFake(
            reply: Replies.json(#"{"user":"anna","device":7,"token":"device-token-1"}"#, status: 201)
        )
        let tokens = TokenStoreFake()
        let defaults = DefaultsFake()
        let viewModel = makeViewModel(transport: transport, tokens: tokens, defaults: defaults)

        acceptInvite(viewModel)
        viewModel.usernameText = "anna"
        await viewModel.submitUsername()

        XCTAssertEqual(viewModel.phase, .registered)
        XCTAssertEqual(tokens.tokens, ["device-token-1"], "the device token goes to the Keychain seam")
        let config = SessionConfigStore(defaults: defaults).load()
        XCTAssertEqual(
            config,
            SessionConfig(host: "chat.example", port: 8443, pin: "AAAA", username: "anna"),
            "the non-secret registration outcome is persisted as SessionConfig"
        )
    }

    func test_onboarding_offline_state_on_transport_failure() async {
        let transport = TransportFake(reply: { _ in throw URLError(.notConnectedToInternet) })
        let viewModel = makeViewModel(transport: transport, tokens: TokenStoreFake(), defaults: DefaultsFake())

        acceptInvite(viewModel)
        viewModel.usernameText = "anna"
        await viewModel.submitUsername()

        XCTAssertEqual(viewModel.phase, .offline)
    }

    func test_onboarding_permission_denied_state() {
        let transport = TransportFake(reply: Replies.json("{}", status: 201))
        let viewModel = makeViewModel(transport: transport, tokens: TokenStoreFake(), defaults: DefaultsFake())

        viewModel.reportPermissionDenied()

        XCTAssertEqual(viewModel.phase, .permissionDenied)
    }
}
