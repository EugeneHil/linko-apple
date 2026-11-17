import SwiftUI

/// One conversation bubble (spec 4.7): outgoing fills with the accent,
/// incoming with the incoming-bubble grey; the timestamp sits underneath.
public struct MessageBubble: View {
    public let text: String
    public let timestamp: String
    public var outgoing: Bool = false

    @Environment(\.colorScheme) private var scheme

    public init(text: String, timestamp: String, outgoing: Bool = false) {
        self.text = text
        self.timestamp = timestamp
        self.outgoing = outgoing
    }

    public var body: some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: Tokens.Spacing.s4) {
            Text(text)
                .font(.system(size: Tokens.Typography.FontSize.body))
                .foregroundStyle(textColor)
                .padding(.horizontal, Tokens.Spacing.s12)
                .padding(.vertical, Tokens.Spacing.s8)
                .background(RoundedRectangle(cornerRadius: Tokens.Radii.large).fill(bubbleColor))
            Text(timestamp)
                .font(.system(size: Tokens.Typography.FontSize.caption))
                .foregroundStyle(secondaryColor)
        }
    }

    private var bubbleColor: Color {
        if outgoing {
            return scheme == .dark ? Tokens.Colors.Dark.outgoingBubble : Tokens.Colors.Light.outgoingBubble
        }
        return scheme == .dark ? Tokens.Colors.Dark.incomingBubble : Tokens.Colors.Light.incomingBubble
    }

    private var textColor: Color {
        if outgoing {
            return scheme == .dark ? Tokens.Colors.Dark.background : Tokens.Colors.Light.background
        }
        return scheme == .dark ? Tokens.Colors.Dark.label : Tokens.Colors.Light.label
    }

    private var secondaryColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.secondaryLabel : Tokens.Colors.Light.secondaryLabel
    }
}

#Preview("Light") {
    VStack(spacing: Tokens.Spacing.s16) {
        MessageBubble(text: "Hello there!", timestamp: "14:02", outgoing: true)
        MessageBubble(text: "Hi! Call later?", timestamp: "14:03", outgoing: false)
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    VStack(spacing: Tokens.Spacing.s16) {
        MessageBubble(text: "Hello there!", timestamp: "14:02", outgoing: true)
        MessageBubble(text: "Hi! Call later?", timestamp: "14:03", outgoing: false)
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .dark)
}
