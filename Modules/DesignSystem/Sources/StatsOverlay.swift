import SwiftUI

/// Top-left call statistics overlay on the call screen (spec 4.7); metrics
/// stay hidden until the 1 s stats stream produces them.
public struct StatsOverlay: View {
    public var bitrateKbps: Double?
    public var rttMs: Double?
    public var lossPercent: Double?

    @Environment(\.colorScheme) private var scheme

    public init(bitrateKbps: Double? = nil, rttMs: Double? = nil, lossPercent: Double? = nil) {
        self.bitrateKbps = bitrateKbps
        self.rttMs = rttMs
        self.lossPercent = lossPercent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
            if let bitrateKbps {
                row("Bitrate", "\(Int(bitrateKbps)) kbps")
            }
            if let rttMs {
                row("RTT", "\(Int(rttMs)) ms")
            }
            if let lossPercent {
                row("Loss", String(format: "%.1f %%", lossPercent))
            }
        }
        .padding(Tokens.Spacing.s8)
        .background(RoundedRectangle(cornerRadius: Tokens.Radii.small).fill(.ultraThinMaterial))
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: Tokens.Spacing.s8) {
            Text(label)
                .font(.system(size: Tokens.Typography.FontSize.caption, weight: Tokens.Typography.FontWeight.medium))
                .foregroundStyle(secondaryColor)
            Text(value)
                .font(.system(size: Tokens.Typography.FontSize.caption))
                .foregroundStyle(labelColor)
        }
    }

    private var labelColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.label : Tokens.Colors.Light.label
    }

    private var secondaryColor: Color {
        scheme == .dark ? Tokens.Colors.Dark.secondaryLabel : Tokens.Colors.Light.secondaryLabel
    }
}

#Preview("Light") {
    StatsOverlay(bitrateKbps: 1200, rttMs: 42, lossPercent: 0.5)
        .padding(Tokens.Spacing.s24)
        .environment(\.colorScheme, .light)
}

#Preview("Dark") {
    StatsOverlay(bitrateKbps: 1200, rttMs: 42, lossPercent: 0.5)
        .padding(Tokens.Spacing.s24)
        .environment(\.colorScheme, .dark)
}
