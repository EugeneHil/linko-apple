// Root Tuist project (Plan 4 Task 1): the two app stubs plus the CoreBridge
// framework with one test target per platform. Task 3 adds the DesignSystem
// module; later tasks add further module targets to this manifest.
import ProjectDescription

// Swift 6 language mode with strict concurrency `complete` and
// warnings-as-errors on every target (spec 7).
private let sharedSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
    "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
    // Scripts/build-core.sh writes into Derived/ outside the sandbox.
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
]

// Automatic signing with the owner's Personal Team, as spike-proven (ADR-0001).
private let signingSettings: SettingsDictionary = [
    "DEVELOPMENT_TEAM": "36TFR2RP3U",
    "CODE_SIGN_STYLE": "Automatic",
]

// The iOS app (Task 13 part 2, LNK-39): the composed root — one session
// graph (engine, signaling, coordinator) with the feature modules on top.
// The usage descriptions and background modes match the surfaces the
// modules actually touch (camera/mic capture, LAN reachability, CallKit
// voip + background audio).
private let iosApp = Target.target(
    name: "LinkoiOS",
    destinations: [.iPhone],
    product: .app,
    bundleId: "io.github.eugenehil.linko",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .extendingDefault(with: [
        "NSCameraUsageDescription": "Linko uses the camera for video calls.",
        "NSMicrophoneUsageDescription": "Linko uses the microphone for calls.",
        "NSLocalNetworkUsageDescription": "Linko connects to your Linko server on the local network.",
        "UIBackgroundModes": ["audio", "voip"],
    ]),
    sources: ["Apps/LinkoiOS/**", "Apps/Shared/**"],
    dependencies: [
        .target(name: "CallKitIntegration"),
        .target(name: "Call"),
        .target(name: "Chats"),
        .target(name: "Conversation"),
        .target(name: "Onboarding"),
        .target(name: "Settings"),
        .target(name: "Calls"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
        .target(name: "FileTransfer"),
        .target(name: "Messaging"),
        .target(name: "ServerAPI"),
        .target(name: "Signaling"),
        .target(name: "DesignSystem"),
        .target(name: "CoreBridge"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// The macOS app (Task 13 part 2, LNK-39): the composed root with
// MacCallPresenter reporting. Entitlements follow the ADR-0001 spike:
// sandbox off, camera + microphone access, hardened runtime off.
private let macApp = Target.target(
    name: "LinkoMac",
    destinations: [.mac],
    product: .app,
    bundleId: "io.github.eugenehil.linko.mac",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .extendingDefault(with: [
        "NSCameraUsageDescription": "Linko uses the camera for video calls.",
        "NSMicrophoneUsageDescription": "Linko uses the microphone for calls.",
    ]),
    sources: ["Apps/LinkoMac/**", "Apps/Shared/**"],
    entitlements: .dictionary([
        "com.apple.security.app-sandbox": .boolean(false),
        "com.apple.security.device.audio-input": .boolean(true),
        "com.apple.security.device.camera": .boolean(true),
    ]),
    dependencies: [
        .target(name: "CallKitIntegration"),
        .target(name: "Call"),
        .target(name: "Chats"),
        .target(name: "Conversation"),
        .target(name: "Onboarding"),
        .target(name: "Settings"),
        .target(name: "Calls"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
        .target(name: "FileTransfer"),
        .target(name: "Messaging"),
        .target(name: "ServerAPI"),
        .target(name: "Signaling"),
        .target(name: "DesignSystem"),
        .target(name: "CoreBridge"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let coreBridge = Target.target(
    name: "CoreBridge",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.CoreBridge",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/CoreBridge/Sources/**"],
    headers: .headers(
        public: [
            "Modules/CoreBridge/Sources/CoreBridge.h",
            "Modules/CoreBridge/Sources/LKEnvelope.h",
            "Modules/CoreBridge/Sources/LKTypes.h",
            "Modules/CoreBridge/Sources/LKFileTransfer.h",
            "Modules/CoreBridge/Sources/LKMessages.h",
            "Modules/CoreBridge/Sources/LKConversationHistory.h",
            "Modules/CoreBridge/Sources/LKCallStateMachine.h",
        ]
    ),
    scripts: [
        // Builds the linko-core submodule (tag v0.1.0) for this platform
        // into Derived/core/$(PLATFORM_NAME)/liblinko_core.a (ADR-0004).
        // CMake's own incremental state makes re-running this every build
        // cheap, so the script phase declares no dependency analysis.
        .pre(
            path: .path("Scripts/build-core.sh"),
            arguments: ["${PLATFORM_NAME}"],
            name: "Build linko-core",
            basedOnDependencyAnalysis: false
        ),
    ],
    settings: .settings(
        base: signingSettings
            .merging(sharedSettings) { _, shared in shared }
            .merging([
                // The core is C++17 (its headers use std::optional and
                // inline constexpr).
                "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
                // The core headers and the nlohmann/json headers the core's
                // envelope.hpp pulls in (populated by Scripts/build-core.sh).
                "HEADER_SEARCH_PATHS":
                    "$(inherited) $(SRCROOT)/external/linko-core/include $(SRCROOT)/Derived/core/$(PLATFORM_NAME)/_deps/nlohmann_json-src/single_include",
                // The CMake-built static library.
                "LIBRARY_SEARCH_PATHS": "$(inherited) $(SRCROOT)/Derived/core/$(PLATFORM_NAME)",
                "OTHER_LDFLAGS": "$(inherited) -llinko_core",
            ]) { _, override in override }
    )
)

private let coreBridgeTests = Target.target(
    name: "CoreBridgeTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CoreBridgeTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/CoreBridge/Tests/**"],
    dependencies: [.target(name: "CoreBridge")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let coreBridgeMacTests = Target.target(
    name: "CoreBridgeMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CoreBridgeMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/CoreBridge/Tests/**"],
    dependencies: [.target(name: "CoreBridge")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 3): the generated Tokens.swift plus the ten
// SwiftUI components — no headers and no CoreBridge dependency needed.
private let designSystem = Target.target(
    name: "DesignSystem",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.DesignSystem",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/DesignSystem/Sources/**"],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let designSystemTests = Target.target(
    name: "DesignSystemTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.DesignSystemTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/DesignSystem/Tests/**"],
    dependencies: [.target(name: "DesignSystem")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let designSystemMacTests = Target.target(
    name: "DesignSystemMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.DesignSystemMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/DesignSystem/Tests/**"],
    dependencies: [.target(name: "DesignSystem")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 4): the WSS client, SPKI pinning, heartbeat
// and backoff reconnect — consumes CoreBridge envelopes and CryptoKit only.
private let signaling = Target.target(
    name: "Signaling",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.Signaling",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/Signaling/Sources/**"],
    dependencies: [.target(name: "CoreBridge")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let signalingTests = Target.target(
    name: "SignalingTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.SignalingTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/Signaling/Tests/**"],
    dependencies: [.target(name: "Signaling"), .target(name: "CoreBridge")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let signalingMacTests = Target.target(
    name: "SignalingMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.SignalingMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/Signaling/Tests/**"],
    dependencies: [.target(name: "Signaling"), .target(name: "CoreBridge")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 6): the GRDB-backed message store, the
// outbox and the messaging service over Signaling events — consumes
// CoreBridge records and the pinned GRDB. Explicit modules are disabled
// here: the clang dependency scanner cannot consume the Signaling
// framework's modulemap, whose generated Signaling-Swift.h does not exist
// until Signaling compiles (first-consumer build-order bug, LNK-32).
private let messagingSettings = signingSettings
    .merging(sharedSettings) { _, shared in shared }
    .merging(["SWIFT_ENABLE_EXPLICIT_MODULES": "NO"]) { _, override in override }

private let messaging = Target.target(
    name: "Messaging",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.Messaging",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/Messaging/Sources/**"],
    // MessagingService imports Signaling (LNK-32 follow-up): without the
    // declared dependency the cold build races it at compile and link
    // (missing Signaling-Swift.h / framework binary) on both platforms.
    dependencies: [.target(name: "CoreBridge"), .target(name: "Signaling"), .external(name: "GRDB")],
    settings: .settings(base: messagingSettings)
)

private let messagingTests = Target.target(
    name: "MessagingTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.MessagingTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/Messaging/Tests/**"],
    dependencies: [.target(name: "Messaging"), .target(name: "CoreBridge"), .target(name: "Signaling")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let messagingMacTests = Target.target(
    name: "MessagingMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.MessagingMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/Messaging/Tests/**"],
    dependencies: [.target(name: "Messaging"), .target(name: "CoreBridge"), .target(name: "Signaling")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 5): the pinned HTTP client, invite links,
// registration, users search, TURN credentials and the Keychain token store.
// TLS trust decisions come from Signaling's SPKIPinValidator, which the
// PinnedHTTPClient wires as its URLSession delegate.
private let serverAPI = Target.target(
    name: "ServerAPI",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.ServerAPI",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/ServerAPI/Sources/**"],
    dependencies: [.target(name: "Signaling")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let serverAPITests = Target.target(
    name: "ServerAPITests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.ServerAPITests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/ServerAPI/Tests/**"],
    dependencies: [.target(name: "ServerAPI")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let serverAPIMacTests = Target.target(
    name: "ServerAPIMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.ServerAPIMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/ServerAPI/Tests/**"],
    dependencies: [.target(name: "ServerAPI")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 7): the WebRTC wrapper behind the
// CallMediaEngine protocol. Consumes stasel/WebRTC 155.0.0 (ADR-0004) and
// ServerAPI's TurnCredentials for RTCIceServer construction. Every WebRTC
// delegate callback is wrapped exactly once into an AsyncStream behind the
// EnginePeerConnection seam, so tests inject fakes and never touch live
// WebRTC objects.
private let callEngine = Target.target(
    name: "CallEngine",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.CallEngine",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/CallEngine/Sources/**"],
    dependencies: [
        .target(name: "ServerAPI"),
        .external(name: "WebRTC"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let callEngineTests = Target.target(
    name: "CallEngineTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallEngineTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/CallEngine/Tests/**"],
    dependencies: [
        .target(name: "CallEngine"),
        .external(name: "WebRTC"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let callEngineMacTests = Target.target(
    name: "CallEngineMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallEngineMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/CallEngine/Tests/**"],
    dependencies: [
        .target(name: "CallEngine"),
        .external(name: "WebRTC"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 8): the stats deriver, the adaptation
// policy (cut #3: cellular/Low-Data-Mode cap only) and the Task-based stats
// poller — pure logic over CallEngine's RawStatsReport/BitratePlan values.
// The report upload client lives in ServerAPI (ReportsClient); the
// coordinator (Task 9) wires the upload and the network inputs.
private let callStats = Target.target(
    name: "CallStats",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.CallStats",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/CallStats/Sources/**"],
    dependencies: [.target(name: "CallEngine")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let callStatsTests = Target.target(
    name: "CallStatsTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallStatsTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/CallStats/Tests/**"],
    dependencies: [.target(name: "CallStats"), .target(name: "CallEngine")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let callStatsMacTests = Target.target(
    name: "CallStatsMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallStatsMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/CallStats/Tests/**"],
    dependencies: [.target(name: "CallStats"), .target(name: "CallEngine")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 9): the call coordinator driving the core
// call state machine (LKCallStateMachine through CoreBridge), the timer
// actor behind the machine's StartTimer/CancelTimer effects and the
// reporting/incoming-source seams CallKit (Task 10) and the Mac presenter
// implement. Consumes Signaling envelopes and events, CallEngine's media
// surface and CallStats' report builder — every dependency is declared
// explicitly (LNK-34 lesson: an undeclared dependency breaks cold builds),
// and explicit modules are disabled because the Calls target imports
// Signaling (the Messaging precedent: the clang dependency scanner cannot
// consume Signaling's framework modulemap).
private let callsSettings = signingSettings
    .merging(sharedSettings) { _, shared in shared }
    .merging(["SWIFT_ENABLE_EXPLICIT_MODULES": "NO"]) { _, override in override }

private let calls = Target.target(
    name: "Calls",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.Calls",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/Calls/Sources/**"],
    dependencies: [
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
    ],
    settings: .settings(base: callsSettings)
)

private let callsTests = Target.target(
    name: "CallsTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallsTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/Calls/Tests/**"],
    dependencies: [
        .target(name: "Calls"),
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let callsMacTests = Target.target(
    name: "CallsMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallsMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/Calls/Tests/**"],
    dependencies: [
        .target(name: "Calls"),
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 10): the CallKit provider adapter, the audio
// session coordinator (ADR-0001 options), the route-change monitor, the
// foreground WebSocket invite source and the Mac incoming-call presenter.
// Consumes Calls (CallReporting/IncomingCallSource/coordinator), Signaling
// events, CoreBridge envelopes and CallEngine's ManualAudioControlling —
// every dependency is declared explicitly (LNK-34 lesson), and explicit
// modules are disabled because the target imports Signaling (the
// Messaging/Calls precedent: the clang dependency scanner cannot consume
// Signaling's framework modulemap).
private let callKitIntegrationSettings = signingSettings
    .merging(sharedSettings) { _, shared in shared }
    .merging(["SWIFT_ENABLE_EXPLICIT_MODULES": "NO"]) { _, override in override }

private let callKitIntegration = Target.target(
    name: "CallKitIntegration",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.CallKitIntegration",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/CallKitIntegration/Sources/**"],
    dependencies: [
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "Calls"),
        .target(name: "CallEngine"),
    ],
    settings: .settings(base: callKitIntegrationSettings)
)

private let callKitIntegrationTests = Target.target(
    name: "CallKitIntegrationTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallKitIntegrationTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/CallKitIntegration/Tests/**"],
    dependencies: [
        .target(name: "CallKitIntegration"),
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "Calls"),
        .target(name: "CallEngine"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let callKitIntegrationMacTests = Target.target(
    name: "CallKitIntegrationMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.CallKitIntegrationMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/CallKitIntegration/Tests/**"],
    dependencies: [
        .target(name: "CallKitIntegration"),
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "Calls"),
        .target(name: "CallEngine"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift module (Plan 4 Task 11): P2P file transfer over the call's data
// channel with ack framing and backpressure, plus the server transport
// fallback. Consumes CoreBridge chunking (LKFileChunker/LKFileReassembler/
// LKAckTracker), CallEngine's data channel, ServerAPI's FilesClient and
// Signaling events for the file.* envelopes. Explicit modules are disabled
// here as well: the clang dependency scanner cannot consume the Signaling
// framework's modulemap while Signaling is still compiling (LNK-32).
private let fileTransferSettings = signingSettings
    .merging(sharedSettings) { _, shared in shared }
    .merging(["SWIFT_ENABLE_EXPLICIT_MODULES": "NO"]) { _, override in override }

private let fileTransfer = Target.target(
    name: "FileTransfer",
    destinations: [.iPhone, .mac],
    product: .framework,
    bundleId: "io.github.eugenehil.linko.FileTransfer",
    deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
    infoPlist: .default,
    sources: ["Modules/FileTransfer/Sources/**"],
    dependencies: [
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "ServerAPI"),
        .target(name: "CallEngine"),
    ],
    settings: .settings(base: fileTransferSettings)
)

private let fileTransferTests = Target.target(
    name: "FileTransferTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.FileTransferTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Modules/FileTransfer/Tests/**"],
    dependencies: [
        .target(name: "FileTransfer"),
        .target(name: "CoreBridge"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let fileTransferMacTests = Target.target(
    name: "FileTransferMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.FileTransferMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Modules/FileTransfer/Tests/**"],
    dependencies: [
        .target(name: "FileTransfer"),
        .target(name: "CoreBridge"),
    ],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

// Pure-Swift feature modules (Plan 4 Task 12): view models (@Observable,
// @MainActor, all dependencies injected by initializer) plus thin SwiftUI
// views over DesignSystem components. Onboarding/Settings consume ServerAPI;
// Chats/Conversation consume Messaging (Conversation also FileTransfer).
// Chats and Conversation disable explicit modules: the clang dependency
// scanner cannot consume the Messaging framework's modulemap while it is
// still compiling (the LNK-32 first-consumer lesson, one hop further).
private let featuresSettings = signingSettings
    .merging(sharedSettings) { _, shared in shared }
    .merging(["SWIFT_ENABLE_EXPLICIT_MODULES": "NO"]) { _, override in override }

private func featureTarget(
    name: String,
    dependencies: [TargetDependency],
    settings: SettingsDictionary
) -> Target {
    Target.target(
        name: name,
        destinations: [.iPhone, .mac],
        product: .framework,
        bundleId: "io.github.eugenehil.linko.\(name)",
        deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
        infoPlist: .default,
        sources: ["Modules/Features/\(name)/Sources/**"],
        dependencies: dependencies,
        settings: .settings(base: settings)
    )
}

private func featureTestsTarget(
    name: String,
    destinations: Destinations,
    dependencies: [TargetDependency]
) -> Target {
    let isMac = destinations.contains(.mac)
    let suffix = isMac ? "MacTests" : "Tests"
    return Target.target(
        name: "\(name)\(suffix)",
        destinations: destinations,
        product: .unitTests,
        bundleId: "io.github.eugenehil.linko.\(name)\(suffix)",
        deploymentTargets: isMac ? .macOS("15.0") : .iOS("18.0"),
        infoPlist: .default,
        sources: ["Modules/Features/\(name)/Tests/**"],
        dependencies: [.target(name: name)] + dependencies,
        settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
    )
}

private let onboarding = featureTarget(
    name: "Onboarding",
    dependencies: [.target(name: "ServerAPI"), .target(name: "DesignSystem")],
    settings: signingSettings.merging(sharedSettings) { _, shared in shared }
)

private let chats = featureTarget(
    name: "Chats",
    dependencies: [.target(name: "Messaging"), .target(name: "DesignSystem")],
    settings: featuresSettings
)

private let conversation = featureTarget(
    name: "Conversation",
    dependencies: [
        .target(name: "Messaging"),
        .target(name: "FileTransfer"),
        .target(name: "DesignSystem"),
    ],
    settings: featuresSettings
)

private let settings = featureTarget(
    name: "Settings",
    dependencies: [
        .target(name: "ServerAPI"),
        .target(name: "Messaging"),
        .target(name: "DesignSystem"),
    ],
    settings: featuresSettings
)

// The call feature (Plan 4 Task 13 part 1, LNK-39): the call screen's view
// model, the StatsOverlay binding and the macOS IncomingCallView. Consumes
// Calls (the coordinator's UI-facing streams), CallStats (the derived
// sample), ServerAPI (the defaults seam) and DesignSystem (StatsOverlay,
// CallControlsTray) — explicit modules are disabled: the Calls target
// imports Signaling, so the first-consumer build-order lesson (LNK-32) one
// hop further applies here too.
private let call = featureTarget(
    name: "Call",
    dependencies: [
        .target(name: "Calls"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
        .target(name: "ServerAPI"),
        .target(name: "DesignSystem"),
        // CallViewModel imports CallKitIntegration under #if os(iOS); the
        // dependency was undeclared and only resolved implicitly against
        // build products that earlier suites happened to leave in
        // DerivedData — a cold coverage build (the CI coverage job runs the
        // logic suites alone) failed with "No such module
        // 'CallKitIntegration'" until it was declared (LNK-34 lesson).
        .target(name: "CallKitIntegration"),
        .external(name: "WebRTC"),
    ],
    settings: featuresSettings
)

private let onboardingTests = featureTestsTarget(
    name: "Onboarding",
    destinations: [.iPhone],
    dependencies: [.target(name: "ServerAPI")]
)

private let onboardingMacTests = featureTestsTarget(
    name: "Onboarding",
    destinations: [.mac],
    dependencies: [.target(name: "ServerAPI")]
)

private let chatsTests = featureTestsTarget(
    name: "Chats",
    destinations: [.iPhone],
    dependencies: [.target(name: "Messaging")]
)

private let chatsMacTests = featureTestsTarget(
    name: "Chats",
    destinations: [.mac],
    dependencies: [.target(name: "Messaging")]
)

private let conversationTests = featureTestsTarget(
    name: "Conversation",
    destinations: [.iPhone],
    dependencies: [
        .target(name: "Messaging"),
        .target(name: "FileTransfer"),
        .target(name: "CoreBridge"),
    ]
)

private let conversationMacTests = featureTestsTarget(
    name: "Conversation",
    destinations: [.mac],
    dependencies: [
        .target(name: "Messaging"),
        .target(name: "FileTransfer"),
        .target(name: "CoreBridge"),
    ]
)

private let settingsTests = featureTestsTarget(
    name: "Settings",
    destinations: [.iPhone],
    dependencies: [
        .target(name: "ServerAPI"),
        .target(name: "Messaging"),
    ]
)

private let settingsMacTests = featureTestsTarget(
    name: "Settings",
    destinations: [.mac],
    dependencies: [
        .target(name: "ServerAPI"),
        .target(name: "Messaging"),
    ]
)

// The call feature's test targets (Task 13 part 1): every imported module
// is declared explicitly (LNK-34's cold-build lesson) — the fakes drive
// Calls' coordinator over CallEngine/CallStats/CoreBridge/Signaling seams,
// the defaults assertions read ServerAPI and pin the key against Settings.
private let callTests = featureTestsTarget(
    name: "Call",
    destinations: [.iPhone],
    dependencies: [
        .target(name: "Calls"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "ServerAPI"),
        .target(name: "Settings"),
        // The audio-route tests bind the CallKitIntegration monitor through
        // its NotificationObserving seam.
        .target(name: "CallKitIntegration"),
    ]
)

private let callMacTests = featureTestsTarget(
    name: "Call",
    destinations: [.mac],
    dependencies: [
        .target(name: "Calls"),
        .target(name: "CallEngine"),
        .target(name: "CallStats"),
        .target(name: "CoreBridge"),
        .target(name: "Signaling"),
        .target(name: "ServerAPI"),
        .target(name: "Settings"),
    ]
)

// The app smoke targets (Task 13 part 2, LNK-39): unit test bundles hosted
// by the app targets — the launch smoke actually boots both apps (the host
// seeds a synthetic session under the test host), the composition smoke
// builds the full graph over the real composition root.
private let iosAppTests = Target.target(
    name: "LinkoiOSTests",
    destinations: [.iPhone],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.LinkoiOSTests",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Apps/LinkoiOSTests/**"],
    dependencies: [.target(name: "LinkoiOS")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let macAppTests = Target.target(
    name: "LinkoMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "io.github.eugenehil.linko.LinkoMacTests",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Apps/LinkoMacTests/**"],
    dependencies: [.target(name: "LinkoMac")],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

let project = Project(
    name: "Linko",
    targets: [
        iosApp,
        macApp,
        coreBridge,
        coreBridgeTests,
        coreBridgeMacTests,
        designSystem,
        designSystemTests,
        designSystemMacTests,
        signaling,
        signalingTests,
        signalingMacTests,
        messaging,
        messagingTests,
        messagingMacTests,
        serverAPI,
        serverAPITests,
        serverAPIMacTests,
        callEngine,
        callEngineTests,
        callEngineMacTests,
        callStats,
        callStatsTests,
        callStatsMacTests,
        calls,
        callsTests,
        callsMacTests,
        callKitIntegration,
        callKitIntegrationTests,
        callKitIntegrationMacTests,
        fileTransfer,
        fileTransferTests,
        fileTransferMacTests,
        onboarding,
        chats,
        conversation,
        settings,
        call,
        onboardingTests,
        onboardingMacTests,
        chatsTests,
        chatsMacTests,
        conversationTests,
        conversationMacTests,
        settingsTests,
        settingsMacTests,
        callTests,
        callMacTests,
        iosAppTests,
        macAppTests,
    ],
    schemes: [
        // One scheme per CoreBridge test target so both platforms can be
        // driven separately (Scripts/ci-local.sh).
        .scheme(
            name: "CoreBridgeTests",
            buildAction: .buildAction(targets: ["CoreBridgeTests"]),
            testAction: .targets(["CoreBridgeTests"])
        ),
        .scheme(
            name: "CoreBridgeMacTests",
            buildAction: .buildAction(targets: ["CoreBridgeMacTests"]),
            testAction: .targets(["CoreBridgeMacTests"])
        ),
        // Same pattern for the DesignSystem test targets (Task 3).
        .scheme(
            name: "DesignSystemTests",
            buildAction: .buildAction(targets: ["DesignSystemTests"]),
            testAction: .targets(["DesignSystemTests"])
        ),
        .scheme(
            name: "DesignSystemMacTests",
            buildAction: .buildAction(targets: ["DesignSystemMacTests"]),
            testAction: .targets(["DesignSystemMacTests"])
        ),
        // Same pattern for the Signaling test targets (Task 4).
        .scheme(
            name: "SignalingTests",
            buildAction: .buildAction(targets: ["SignalingTests"]),
            testAction: .targets(["SignalingTests"])
        ),
        .scheme(
            name: "SignalingMacTests",
            buildAction: .buildAction(targets: ["SignalingMacTests"]),
            testAction: .targets(["SignalingMacTests"])
        ),
        // Same pattern for the Messaging test targets (Task 6).
        .scheme(
            name: "MessagingTests",
            buildAction: .buildAction(targets: ["MessagingTests"]),
            testAction: .targets(["MessagingTests"])
        ),
        .scheme(
            name: "MessagingMacTests",
            buildAction: .buildAction(targets: ["MessagingMacTests"]),
            testAction: .targets(["MessagingMacTests"])
        ),
        // Same pattern for the ServerAPI test targets (Task 5).
        .scheme(
            name: "ServerAPITests",
            buildAction: .buildAction(targets: ["ServerAPITests"]),
            testAction: .targets(["ServerAPITests"])
        ),
        .scheme(
            name: "ServerAPIMacTests",
            buildAction: .buildAction(targets: ["ServerAPIMacTests"]),
            testAction: .targets(["ServerAPIMacTests"])
        ),
        // Same pattern for the CallEngine test targets (Task 7).
        .scheme(
            name: "CallEngineTests",
            buildAction: .buildAction(targets: ["CallEngineTests"]),
            testAction: .targets(["CallEngineTests"])
        ),
        .scheme(
            name: "CallEngineMacTests",
            buildAction: .buildAction(targets: ["CallEngineMacTests"]),
            testAction: .targets(["CallEngineMacTests"])
        ),
        // Same pattern for the CallStats test targets (Task 8).
        .scheme(
            name: "CallStatsTests",
            buildAction: .buildAction(targets: ["CallStatsTests"]),
            testAction: .targets(["CallStatsTests"])
        ),
        .scheme(
            name: "CallStatsMacTests",
            buildAction: .buildAction(targets: ["CallStatsMacTests"]),
            testAction: .targets(["CallStatsMacTests"])
        ),
        // Same pattern for the Calls test targets (Task 9).
        .scheme(
            name: "CallsTests",
            buildAction: .buildAction(targets: ["CallsTests"]),
            testAction: .targets(["CallsTests"])
        ),
        .scheme(
            name: "CallsMacTests",
            buildAction: .buildAction(targets: ["CallsMacTests"]),
            testAction: .targets(["CallsMacTests"])
        ),
        // Same pattern for the CallKitIntegration test targets (Task 10).
        .scheme(
            name: "CallKitIntegrationTests",
            buildAction: .buildAction(targets: ["CallKitIntegrationTests"]),
            testAction: .targets(["CallKitIntegrationTests"])
        ),
        .scheme(
            name: "CallKitIntegrationMacTests",
            buildAction: .buildAction(targets: ["CallKitIntegrationMacTests"]),
            testAction: .targets(["CallKitIntegrationMacTests"])
        ),
        // Same pattern for the FileTransfer test targets (Task 11).
        .scheme(
            name: "FileTransferTests",
            buildAction: .buildAction(targets: ["FileTransferTests"]),
            testAction: .targets(["FileTransferTests"])
        ),
        .scheme(
            name: "FileTransferMacTests",
            buildAction: .buildAction(targets: ["FileTransferMacTests"]),
            testAction: .targets(["FileTransferMacTests"])
        ),
        // Same pattern for the feature test targets (Task 12).
        .scheme(
            name: "OnboardingTests",
            buildAction: .buildAction(targets: ["OnboardingTests"]),
            testAction: .targets(["OnboardingTests"])
        ),
        .scheme(
            name: "OnboardingMacTests",
            buildAction: .buildAction(targets: ["OnboardingMacTests"]),
            testAction: .targets(["OnboardingMacTests"])
        ),
        .scheme(
            name: "ChatsTests",
            buildAction: .buildAction(targets: ["ChatsTests"]),
            testAction: .targets(["ChatsTests"])
        ),
        .scheme(
            name: "ChatsMacTests",
            buildAction: .buildAction(targets: ["ChatsMacTests"]),
            testAction: .targets(["ChatsMacTests"])
        ),
        .scheme(
            name: "ConversationTests",
            buildAction: .buildAction(targets: ["ConversationTests"]),
            testAction: .targets(["ConversationTests"])
        ),
        .scheme(
            name: "ConversationMacTests",
            buildAction: .buildAction(targets: ["ConversationMacTests"]),
            testAction: .targets(["ConversationMacTests"])
        ),
        .scheme(
            name: "SettingsTests",
            buildAction: .buildAction(targets: ["SettingsTests"]),
            testAction: .targets(["SettingsTests"])
        ),
        .scheme(
            name: "SettingsMacTests",
            buildAction: .buildAction(targets: ["SettingsMacTests"]),
            testAction: .targets(["SettingsMacTests"])
        ),
        // Same pattern for the Call feature test targets (Task 13 part 1).
        .scheme(
            name: "CallTests",
            buildAction: .buildAction(targets: ["CallTests"]),
            testAction: .targets(["CallTests"])
        ),
        .scheme(
            name: "CallMacTests",
            buildAction: .buildAction(targets: ["CallMacTests"]),
            testAction: .targets(["CallMacTests"])
        ),
        // The app smoke schemes (Task 13 part 2): the test host boots the
        // real app on the simulator / macOS.
        .scheme(
            name: "LinkoiOSTests",
            buildAction: .buildAction(targets: ["LinkoiOSTests"]),
            testAction: .targets(["LinkoiOSTests"])
        ),
        .scheme(
            name: "LinkoMacTests",
            buildAction: .buildAction(targets: ["LinkoMacTests"]),
            testAction: .targets(["LinkoMacTests"])
        ),
        // The app build schemes (e2e rehearsal + future CI): explicit
        // schemes so the app targets are buildable without a test host.
        .scheme(
            name: "LinkoiOS",
            buildAction: .buildAction(targets: ["LinkoiOS"])
        ),
        .scheme(
            name: "LinkoMac",
            buildAction: .buildAction(targets: ["LinkoMac"])
        ),
    ]
)
