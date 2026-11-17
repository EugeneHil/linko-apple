import SwiftUI

/// Circular avatar with the peer's initials (spec 4.7 chats list).
///
/// All colors and sizes come from the generated tokens — nothing hard-coded.
public struct Avatar: View {
    public let name: String

    @Environment(\.colorScheme) private var scheme

    public init(name: String) {
        self.name = name
    }

    public var body: some View {
        Text(Self.initials(of: name))
            .font(.system(size: Tokens.Typography.FontSize.subheadline, weight: Tokens.Typography.FontWeight.semibold))
            .foregroundStyle(scheme == .dark ? Tokens.Colors.Dark.label : Tokens.Colors.Light.label)
            .frame(width: Tokens.Spacing.s32, height: Tokens.Spacing.s32)
            .background(
                Circle().fill(scheme == .dark ? Tokens.Colors.Dark.secondaryBackground : Tokens.Colors.Light.secondaryBackground)
            )
            .accessibilityLabel("Avatar for \(name)")
    }

    /// Up to two initials, one per word; an empty name renders an empty circle.
    private static func initials(of name: String) -> String {
        let letters = name.split(separator: " ").compactMap(\.first)
        return String(letters.prefix(2)).uppercased()
    }
}

#Preview("Light") {
    Avatar(name: "Anna Petrova")
        .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    Avatar(name: "Anna Petrova")
        .environment(\.colorScheme, .dark)
}
