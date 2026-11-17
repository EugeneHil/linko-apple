import SwiftUI

/// A file-message bubble (spec 4.7): file name, size, the transport label
/// ("peer-to-peer" or "via server") and an in-flight progress bar.
public struct FileBubble: View {
    /// How the file traveled: peer-to-peer over the data channel or via the
    /// server (spec 4.7 file bubble labels).
    public enum Transport {
        case peerToPeer
        case server

        public var label: String {
            switch self {
            case .peerToPeer: "peer-to-peer"
            case .server: "via server"
            }
        }
    }

    public let fileName: String
    public let sizeText: String
    public var progress: Double?
    public var transport: Transport

    @Environment(\.colorScheme) private var scheme

    public init(fileName: String, sizeText: String, progress: Double? = nil, transport: Transport = .server) {
        self.fileName = fileName
        self.sizeText = sizeText
        self.progress = progress
        self.transport = transport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s8) {
            HStack(spacing: Tokens.Spacing.s8) {
                Image(systemName: "doc")
                    .font(.system(size: Tokens.Typography.FontSize.title3))
                    .foregroundStyle(accentColor)
                VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
                    Text(fileName)
                        .font(.system(size: Tokens.Typography.FontSize.subheadline, weight: Tokens.Typography.FontWeight.medium))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                    Text("\(transport.label) · \(sizeText)")
                        .font(.system(size: Tokens.Typography.FontSize.caption))
                        .foregroundStyle(secondaryColor)
                }
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(accentColor)
            }
        }
        .padding(Tokens.Spacing.s12)
        .background(RoundedRectangle(cornerRadius: Tokens.Radii.large).fill(bubbleColor))
    }

    private var bubbleColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.incomingBubble : Tokens.Colors.Light.incomingBubble
    }

    private var textColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.label : Tokens.Colors.Light.label
    }

    private var secondaryColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.secondaryLabel : Tokens.Colors.Light.secondaryLabel
    }

    private var accentColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.accent : Tokens.Colors.Light.accent
    }
}

#Preview("Light") {
    VStack(spacing: Tokens.Spacing.s16) {
        FileBubble(fileName: "report.pdf", sizeText: "20 MB", progress: 0.4, transport: .peerToPeer)
        FileBubble(fileName: "photo.jpg", sizeText: "3 MB", transport: .server)
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    VStack(spacing: Tokens.Spacing.s16) {
        FileBubble(fileName: "report.pdf", sizeText: "20 MB", progress: 0.4, transport: .peerToPeer)
        FileBubble(fileName: "photo.jpg", sizeText: "3 MB", transport: .server)
    }
    .padding(Tokens.Spacing.s16)
    .environment(\.colorScheme, .dark)
}
