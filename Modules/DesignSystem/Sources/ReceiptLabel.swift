import SwiftUI

/// Delivery receipt line under a conversation bubble ("Delivered 14:02" /
/// "Read 14:02", spec 4.7); read receipts carry the accent color.
public struct ReceiptLabel: View {
    /// The receipt watermark the message has reached.
    public enum State {
        case sent
        case delivered
        case read
    }

    public let state: State
    public let timestamp: String

    @Environment(\.colorScheme) private var scheme

    public init(state: State, timestamp: String) {
        self.state = state
        self.timestamp = timestamp
    }

    public var body: some View {
        Text(label)
            .font(.system(size: Tokens.Typography.FontSize.footnote))
            .foregroundStyle(state == .read ? accentColor : secondaryColor)
    }

    private var label: String {
        switch state {
        case .sent: "Sent \(timestamp)"
        case .delivered: "Delivered \(timestamp)"
        case .read: "Read \(timestamp)"
        }
    }

    private var accentColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.accent : Tokens.Colors.Light.accent
    }

    private var secondaryColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.secondaryLabel : Tokens.Colors.Light.secondaryLabel
    }
}

#Preview("Light") {
    VStack(alignment: .leading, spacing: Tokens.Spacing.s8) {
        ReceiptLabel(state: .sent, timestamp: "14:01")
        ReceiptLabel(state: .delivered, timestamp: "14:02")
        ReceiptLabel(state: .read, timestamp: "14:02")
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    VStack(alignment: .leading, spacing: Tokens.Spacing.s8) {
        ReceiptLabel(state: .sent, timestamp: "14:01")
        ReceiptLabel(state: .delivered, timestamp: "14:02")
        ReceiptLabel(state: .read, timestamp: "14:02")
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .dark)
}
