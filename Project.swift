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
    ]
)
