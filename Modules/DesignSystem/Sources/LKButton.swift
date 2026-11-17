import SwiftUI

/// The primary Linko button: accent fill, token typography and radii — the
/// default action style shared by onboarding, chat and call surfaces.
public struct LKButton: View {
    public let title: String
    public var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Tokens.Typography.FontSize.body, weight: Tokens.Typography.FontWeight.semibold))
                .foregroundStyle(scheme == .dark ? Tokens.Colors.Dark.background : Tokens.Colors.Light.background)
                .padding(.horizontal, Tokens.Spacing.s24)
                .padding(.vertical, Tokens.Spacing.s12)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radii.medium)
                        .fill(scheme == .dark ? Tokens.Colors.Dark.accent : Tokens.Colors.Light.accent)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#Preview("Light") {
    LKButton(title: "Join") {}
        .padding(Tokens.Spacing.s24)
        .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    LKButton(title: "Join") {}
        .padding(Tokens.Spacing.s24)
        .environment(\.colorScheme, .dark)
}
