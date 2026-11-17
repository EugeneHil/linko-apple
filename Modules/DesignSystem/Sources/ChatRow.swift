import SwiftUI

/// One chats-list row: avatar, name, last-message preview, time and the
/// unread badge (spec 4.7).
public struct ChatRow: View {
    public let name: String
    public let preview: String
    public let timestamp: String
    public var unreadCount: Int = 0

    @Environment(\.colorScheme) private var scheme

    public init(name: String, preview: String, timestamp: String, unreadCount: Int = 0) {
        self.name = name
        self.preview = preview
        self.timestamp = timestamp
        self.unreadCount = unreadCount
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s12) {
            Avatar(name: name)
            VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
                Text(name)
                    .font(.system(size: Tokens.Typography.FontSize.body, weight: Tokens.Typography.FontWeight.medium))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                Text(preview)
                    .font(.system(size: Tokens.Typography.FontSize.subheadline))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: Tokens.Spacing.s4) {
                Text(timestamp)
                    .font(.system(size: Tokens.Typography.FontSize.caption))
                    .foregroundStyle(secondaryColor)
                if unreadCount > 0 {
                    Text(String(unreadCount))
                        .font(.system(size: Tokens.Typography.FontSize.caption, weight: Tokens.Typography.FontWeight.semibold))
                        .foregroundStyle(badgeTextColor)
                        .padding(.horizontal, Tokens.Spacing.s8)
                        .padding(.vertical, Tokens.Spacing.s4)
                        .background(Capsule().fill(accentColor))
                }
            }
        }
        .padding(Tokens.Spacing.s12)
    }

    private var labelColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.label : Tokens.Colors.Light.label
    }

    private var secondaryColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.secondaryLabel : Tokens.Colors.Light.secondaryLabel
    }

    private var accentColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.accent : Tokens.Colors.Light.accent
    }

    private var badgeTextColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.background : Tokens.Colors.Light.background
    }
}

#Preview("Light") {
    ChatRow(name: "Anna", preview: "See you tomorrow", timestamp: "14:02", unreadCount: 2)
        .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    ChatRow(name: "Anna", preview: "See you tomorrow", timestamp: "14:02", unreadCount: 0)
        .environment(\.colorScheme, .dark)
}
