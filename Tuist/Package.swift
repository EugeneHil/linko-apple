// swift-tools-version: 5.9
// External Swift Package dependencies, declared for Tuist (ADR-0004).
// Declared now, consumed by their own tasks: WebRTC by the CallEngine task,
// GRDB by the Messaging task.
import PackageDescription

#if TUIST
    import ProjectDescription

    let packageSettings = PackageSettings(
        // WebRTC ships as a prebuilt binary xcframework; GRDB is a source
        // package. Neither needs a product-type override yet.
        productTypes: [:]
    )
#endif

let package = Package(
    name: "LinkoAppleDependencies",
    dependencies: [
        // stasel/WebRTC 155.0.0, exact pin. Revision of the 155.0.0 tag:
        // 44f36788497f701bc8c0306de3a1c2511d56019d. Binary artifact
        // WebRTC-M155.xcframework.zip checksum:
        // cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe
        // (recorded in docs/adr/0004-apple-dependencies.md).
        .package(url: "https://github.com/stasel/WebRTC", exact: "155.0.0"),
        // GRDB 7.12.0, exact pin (latest stable at task time, 2026-11).
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
    ]
)
