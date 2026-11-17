// TDD tests (Plan 4 Task 3 / LNK-29, Step 1): the committed Tokens.swift must
// stay byte-fresh against the linko-core source of truth, the call-controls
// tray geometry must honor the spec 4.7 minimums through Tokens.ControlSizes,
// and every component in the DesignSystem contract must render in both color
// schemes with a non-zero layout (honest render smoke, no snapshot dependency).

// @testable is required for the generated `enum Tokens` (internal, fixed by
// the linko-core generator); the components themselves are public API.
@testable import DesignSystem
import SwiftUI
import XCTest

@MainActor
final class DesignSystemTests: XCTestCase {
    // MARK: - Token freshness (spec 4.8: CI checks the generated file is up to date)

    func test_generated_tokens_fresh() throws {
        #if canImport(AppKit)
            let script = try Self.repoRoot().appendingPathComponent("Scripts/check-tokens.sh")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: script.path),
                "Scripts/check-tokens.sh must exist — it is the single entry point for the freshness gate"
            )

            let process = Process()
            process.executableURL = script
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let captured = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(bytes: captured, encoding: .utf8) ?? "<non-UTF8 output>"

            XCTAssertEqual(
                process.terminationStatus, 0,
                "Tokens.swift is stale or the token check failed: \(message)"
            )
        #else
            // Foundation's Process (NSTask) is unavailable on the iOS SDK. The
            // freshness gate still runs in the macOS test target here and as a
            // dedicated shell step in Scripts/ci-local.sh on every run.
            throw XCTSkip("Process is unavailable on the iOS SDK; the freshness gate runs on macOS")
        #endif
    }

    // MARK: - Tray geometry (spec 4.7 minimums, driven by Tokens.ControlSizes)

    func test_tray_rules_match_tokens() {
        XCTAssertGreaterThanOrEqual(Tokens.ControlSizes.button, 24, "controls must be at least 24 pt")
        XCTAssertGreaterThanOrEqual(Tokens.ControlSizes.gap, 8, "gaps between controls must be at least 8 pt")
        let edgeMessage = "the tray must keep at least 12 pt from the screen edges and the home indicator"
        XCTAssertGreaterThanOrEqual(Tokens.ControlSizes.screenEdge, 12, edgeMessage)
    }

    // MARK: - Render smoke: every component, light and dark, non-zero layout

    func test_every_component_renders_light_and_dark() {
        let components = Self.contractComponents()
        XCTAssertEqual(components.map(\.name), Self.contractNames, "the component list is the contract: one entry per component name")

        for component in components {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: AnyView(component.view.environment(\.colorScheme, scheme)))
                renderer.proposedSize = ProposedViewSize(width: 320, height: 480)
                renderer.scale = 1
                let image = renderer.cgImage
                XCTAssertNotNil(image, "\(component.name) rendered nothing in \(scheme)")
                if let image {
                    XCTAssertGreaterThan(image.width, 0, "\(component.name) has a zero-width layout in \(scheme)")
                    XCTAssertGreaterThan(image.height, 0, "\(component.name) has a zero-height layout in \(scheme)")
                }
            }
        }
    }

    /// The expected component names, one entry per component — the list is
    /// the contract (plan Task 3). Built with append calls together with the
    /// view factories below: SwiftFormat's trailingCommas wants trailing
    /// commas in multi-line literals while SwiftLint's trailing_comma forbids
    /// them, so this test avoids multi-line literals entirely.
    private static var contractNames: [String] {
        var names: [String] = []
        names.append("Avatar")
        names.append("ChatRow")
        names.append("MessageBubble")
        names.append("FileBubble")
        names.append("ReceiptLabel")
        names.append("CallControlsTray")
        names.append("CallControlButton")
        names.append("StatsOverlay")
        names.append("Banner")
        names.append("LKButton")
        return names
    }

    private static func contractComponents() -> [(name: String, view: AnyView)] {
        var components: [(name: String, view: AnyView)] = []
        components.append(("Avatar", AnyView(Avatar(name: "Anna Petrova"))))
        components.append(("ChatRow", AnyView(ChatRow(name: "Anna", preview: "See you tomorrow", timestamp: "14:02", unreadCount: 2))))
        components.append(("MessageBubble", AnyView(MessageBubble(text: "Hello there!", timestamp: "14:02", outgoing: true))))
        components.append(("FileBubble", AnyView(FileBubble(fileName: "report.pdf", sizeText: "20 MB", progress: 0.4, transport: .peerToPeer))))
        components.append(("ReceiptLabel", AnyView(ReceiptLabel(state: .delivered, timestamp: "14:02"))))
        components.append(("CallControlsTray", AnyView(CallControlsTray(isMuted: false, isCameraOn: true, onToggleMute: {}, onToggleCamera: {}, onHangup: {}))))
        components.append(("CallControlButton", AnyView(CallControlButton(systemImage: "mic.fill", accessibilityLabel: "Mute", action: {}))))
        components.append(("StatsOverlay", AnyView(StatsOverlay(bitrateKbps: 1200, rttMs: 42, lossPercent: 0.5))))
        components.append(("Banner", AnyView(Banner(message: "Reconnecting…", systemImage: "wifi.exclamationmark"))))
        components.append(("LKButton", AnyView(LKButton(title: "Join", action: {}))))
        return components
    }

    /// This file lives at <repo>/Modules/DesignSystem/Tests/: four deletions
    /// land on the repository root (deterministic on the build host).
    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
