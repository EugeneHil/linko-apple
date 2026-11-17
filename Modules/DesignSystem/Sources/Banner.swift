import SwiftUI

/// The offline/reconnecting banner pinned above the content (spec 4.7
/// states); the caller decides the state text, the icon travels with it.
public struct Banner: View {
    public let message: String
    public var systemImage: String = "wifi.slash"

    @Environment(\.colorScheme) private var scheme

    public init(message: String, systemImage: String = "wifi.slash") {
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: Tokens.Spacing.s8) {
            Image(systemName: systemImage)
                .font(.system(size: Tokens.Typography.FontSize.footnote))
            Text(message)
                .font(.system(size: Tokens.Typography.FontSize.footnote, weight: Tokens.Typography.FontWeight.medium))
        }
        .foregroundStyle(labelColor)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Tokens.Spacing.s12)
        .padding(.vertical, Tokens.Spacing.s8)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radii.medium)
                .fill(scheme == .dark ? Tokens.Colors.Dark.secondaryBackground : Tokens.Colors.Light.secondaryBackground)
        )
    }

    private var labelColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.label : Tokens.Colors.Light.label
    }
}

#Preview("Light") {
    VStack(spacing: Tokens.Spacing.s8) {
        Banner(message: "Offline — messages send when you are back")
        Banner(message: "Reconnecting…", systemImage: "wifi.exclamationmark")
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    VStack(spacing: Tokens.Spacing.s8) {
        Banner(message: "Offline — messages send when you are back")
        Banner(message: "Reconnecting…", systemImage: "wifi.exclamationmark")
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .dark)
}
