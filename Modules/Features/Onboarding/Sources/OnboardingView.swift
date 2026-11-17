// OnboardingView (Plan 4 Task 12): the thin onboarding — invite paste,
// username entry, the in-flight state and the typed failure states (invite
// invalid/expired, invalid username, throttled, offline, permission
// denied). All state lives in OnboardingViewModel; the view only maps it.

import DesignSystem
import SwiftUI

public struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        switch viewModel.phase {
        case .enterInvite, .inviteInvalid:
            inviteStep
        case .enterUsername, .registering, .invalidUsername, .throttled, .offline, .unexpected:
            usernameStep
        case .registered:
            registeredView
        case .permissionDenied:
            permissionDeniedView
        }
    }

    private var inviteStep: some View {
        step(title: "Join your Linko server") {
            TextField("linko://join?…", text: $viewModel.inviteText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            errorText(inviteError)
            LKButton(title: "Continue") {
                viewModel.submitInvite()
            }
        }
    }

    private var usernameStep: some View {
        step(title: "Pick your username") {
            TextField("username", text: $viewModel.usernameText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            if viewModel.phase == .registering {
                ProgressView()
            } else {
                LKButton(title: "Register") {
                    Task { await viewModel.submitUsername() }
                }
            }
            errorText(usernameError)
        }
    }

    private var registeredView: some View {
        step(title: "Welcome") {
            Text("Registered — opening chats…")
        }
    }

    private var permissionDeniedView: some View {
        step(title: "Permission needed") {
            Banner(
                message: "Linko needs microphone, camera and local network access",
                systemImage: "lock.shield"
            )
        }
    }

    private var inviteError: String? {
        viewModel.phase == .inviteInvalid ? "This invite link is invalid or expired" : nil
    }

    private var usernameError: String? {
        switch viewModel.phase {
        case .invalidUsername: "Usernames are 1–32 chars of a–z, 0–9, _ . -"
        case .throttled: "Too many attempts — try again later"
        case .offline: "You are offline — check your connection"
        case .unexpected: "Registration failed — try again"
        default: nil
        }
    }

    @ViewBuilder
    private func errorText(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func step(
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: LKTokens.Spacing.s16) {
            Text(title)
                .font(.title2)
            content()
        }
        .padding(LKTokens.Spacing.s24)
    }
}
