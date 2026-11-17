import SwiftUI

/// One round glass control in the call tray (spec 4.7). Its diameter comes
/// from Tokens.ControlSizes.button — about 24 pt, never smaller.
public struct CallControlButton: View {
    public let systemImage: String
    public let accessibilityLabel: String
    public var isActive: Bool = false
    public var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    public init(systemImage: String, accessibilityLabel: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Tokens.Typography.FontSize.body, weight: Tokens.Typography.FontWeight.medium))
                .foregroundStyle(foregroundColor)
                .frame(width: Tokens.ControlSizes.button, height: Tokens.ControlSizes.button)
                .background {
                    if isActive {
                        Circle().fill(scheme == .dark ? Tokens.Colors.Dark.accent : Tokens.Colors.Light.accent)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var foregroundColor: Color {
        if isActive {
            return scheme == .dark ? Tokens.Colors.Dark.background : Tokens.Colors.Light.background
        }
        return scheme == .dark ? Tokens.Colors.Dark.label : Tokens.Colors.Light.label
    }
}

#Preview("Light") {
    HStack(spacing: Tokens.ControlSizes.gap) {
        CallControlButton(systemImage: "mic.fill", accessibilityLabel: "Mute", action: {})
        CallControlButton(systemImage: "video.fill", accessibilityLabel: "Camera", isActive: true, action: {})
        CallControlButton(systemImage: "phone.down.fill", accessibilityLabel: "Hang up", action: {})
    }
    .padding(Tokens.Spacing.s24)
    .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    HStack(spacing: Tokens.ControlSizes.gap) {
        CallControlButton(systemImage: "mic.fill", accessibilityLabel: "Mute", action: {})
        CallControlButton(systemImage: "video.fill", accessibilityLabel: "Camera", isActive: true, action: {})
        CallControlButton(systemImage: "phone.down.fill", accessibilityLabel: "Hang up", action: {})
    }
    .padding(Tokens.Spacing.s24)
    .environment(\.colorScheme, .dark)
}
