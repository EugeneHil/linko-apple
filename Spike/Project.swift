import ProjectDescription

// Throwaway day-one spike (LNK-3): WebRTC call iPhone <-> Mac with CallKit.
// Never merged; findings go to docs/adr/0001.

let team: SettingsDictionary = [
    "DEVELOPMENT_TEAM": "36TFR2RP3U",
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_VERSION": "5.0", // spike only: product code is Swift 6 strict

]

let project = Project(
    name: "Spike",
    packages: [
        .remote(url: "https://github.com/stasel/WebRTC.git", requirement: .exact("155.0.0")),
    ],
    targets: [
        .target(
            name: "SpikeiOS",
            destinations: [.iPhone],
            product: .app,
            bundleId: "io.github.eugenehil.linko.spike",
            deploymentTargets: .iOS("18.0"),
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                "NSCameraUsageDescription": "Video calls",
                "NSMicrophoneUsageDescription": "Calls",
                "NSLocalNetworkUsageDescription": "Signaling relay on the local network",
                "UIBackgroundModes": ["audio", "voip"],
                "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
            ]),
            sources: ["Shared/**", "iOS/**"],
            dependencies: [.package(product: "WebRTC")],
            settings: .settings(base: team)
        ),
        .target(
            name: "SpikeMac",
            destinations: [.mac],
            product: .app,
            bundleId: "io.github.eugenehil.linko.spike.mac",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "NSCameraUsageDescription": "Video calls",
                "NSMicrophoneUsageDescription": "Calls",
                "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
            ]),
            sources: ["Shared/**", "Mac/**"],
            entitlements: .dictionary([
                "com.apple.security.app-sandbox": false,
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ]),
            dependencies: [.package(product: "WebRTC")],
            settings: .settings(base: team.merging(["ENABLE_HARDENED_RUNTIME": "NO"]))
        ),
    ]
)
