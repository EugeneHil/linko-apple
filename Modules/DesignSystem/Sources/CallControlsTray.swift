import SwiftUI

/// The inset glass tray of call controls (spec 4.7): buttons sized by
/// Tokens.ControlSizes.button, gaps by Tokens.ControlSizes.gap, and at least
/// Tokens.ControlSizes.screenEdge from the screen edges and above the home
/// indicator — safeAreaPadding guarantees that minimum on every device.
public struct CallControlsTray: View {
    public var isMuted: Bool = false
    public var isCameraOn: Bool = true
    public var onToggleMute: () -> Void
    public var onToggleCamera: () -> Void
    public var onHangup: () -> Void

    public init(
        isMuted: Bool = false,
        isCameraOn: Bool = true,
        onToggleMute: @escaping () -> Void,
        onToggleCamera: @escaping () -> Void,
        onHangup: @escaping () -> Void
    ) {
        self.isMuted = isMuted
        self.isCameraOn = isCameraOn
        self.onToggleMute = onToggleMute
        self.onToggleCamera = onToggleCamera
        self.onHangup = onHangup
    }

    public var body: some View {
        HStack(spacing: Tokens.ControlSizes.gap) {
            CallControlButton(
                systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                accessibilityLabel: isMuted ? "Unmute microphone" : "Mute microphone",
                isActive: isMuted,
                action: onToggleMute
            )
            CallControlButton(
                systemImage: isCameraOn ? "video.fill" : "video.slash.fill",
                accessibilityLabel: isCameraOn ? "Turn camera off" : "Turn camera on",
                isActive: !isCameraOn,
                action: onToggleCamera
            )
            CallControlButton(
                systemImage: "phone.down.fill",
                accessibilityLabel: "Hang up",
                action: onHangup
            )
        }
        .padding(Tokens.Spacing.s16)
        .background(Capsule().fill(.ultraThinMaterial))
        .safeAreaPadding(.horizontal, Tokens.ControlSizes.screenEdge)
        .safeAreaPadding(.bottom, Tokens.ControlSizes.screenEdge)
    }
}

#Preview("Light") {
    CallControlsTray(isMuted: false, isCameraOn: true, onToggleMute: {}, onToggleCamera: {}, onHangup: {})
        .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    CallControlsTray(isMuted: true, isCameraOn: false, onToggleMute: {}, onToggleCamera: {}, onHangup: {})
        .environment(\.colorScheme, .dark)
}
