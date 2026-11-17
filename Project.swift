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

private let iosApp = Target.target(
    name: "LinkoiOS",
    destinations: [.iPhone],
    product: .app,
    bundleId: "io.github.eugenehil.linko",
    deploymentTargets: .iOS("18.0"),
    infoPlist: .default,
    sources: ["Apps/LinkoiOS/**"],
    settings: .settings(base: signingSettings.merging(sharedSettings) { _, shared in shared })
)

private let macApp = Target.target(
    name: "LinkoMac",
    destinations: [.mac],
    product: .app,
    bundleId: "io.github.eugenehil.linko.mac",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .default,
    sources: ["Apps/LinkoMac/**"],
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
    ]
)
