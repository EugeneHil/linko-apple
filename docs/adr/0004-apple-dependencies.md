# ADR-0004: linko-apple dependencies

- Status: accepted
- Date: 2026-11-17

## Context

Plan 4 (Task 1, LNK-27) builds the `linko-apple` workspace. Beyond the `linko-core` submodule (tag `v0.1.0`, dependency set pinned by ADR-0002), the apps need three things the core does not provide:

- **WebRTC** for audio/video calls and the data channel (spec §4.4): a prebuilt binary — building libwebrtc is out of scope.
- **SQLite access** for the local message store (spec §4.3 Messaging).
- **A build system** that generates one workspace for two platforms with a C++ static library in the middle (spec §4.3, "LinkoCore"; spec §11 leaves CMake↔Tuist integration to the builder).

Versions must be pinned exactly and every new dependency needs this ADR (CLAUDE.md).

## Decision

### Tuist 4.212.0 via mise

- `.mise.toml` pins `tuist = "4.212.0"`; all Tuist invocations run as `mise exec -- tuist …` (documented in CLAUDE.md).
- Workspace `Linko`, root `Project.swift` with app targets `LinkoiOS` (iOS 18) and `LinkoMac` (macOS 15), bundle IDs `io.github.eugenehil.linko` / `io.github.eugenehil.linko.mac`, automatic signing with the owner's Personal Team (spike-proven, ADR-0001).
- Swift 6 language mode, strict concurrency `complete`, warnings-as-errors on every target.

### `stasel/WebRTC` 155.0.0 (SPM binary, exact pin + checksum)

- Exact pin in `Tuist/Package.swift`: `.package(url: "https://github.com/stasel/WebRTC", exact: "155.0.0")`; resolved revision **`44f36788497f701bc8c0306de3a1c2511d56019d`** (= tag `155.0.0`).
- Binary artifact `https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip`, SHA-256 checksum recorded in that revision's `Package.swift` and here — **`cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe`**. This closes the "not recorded" gap ADR-0001 left open.
- Unused until the CallEngine task (LNK-33); declared now so the pin is part of the skeleton.

### GRDB 7.12.0 (exact pin)

- Latest stable at task time (2026-11): **`v7.12.0`**, released 2026-11-01. Exact pin in `Tuist/Package.swift` and verified by resolution in this task (Package.resolved → checkout `v7.12.0`).
- Unused until the Messaging task (LNK-32).

### Core consumption: CMake pre-build script + static library

`Scripts/build-core.sh <destination>` configures and builds `external/linko-core` with CMake (Ninja, Release, `-DCMAKE_OSX_SYSROOT=<destination>` and `-DCMAKE_OSX_ARCHITECTURES=arm64`) into `Derived/core/<destination>/liblinko_core.a`; the script runs as a Tuist pre-build action on `CoreBridge`, which links the archive (`-llinko_core`) with header search path `external/linko-core/include` (plus the FetchContent `nlohmann/json` include path it requires). **xcframework alternative rejected**: it means assembling a three-platform artifact per core change for no benefit over two apps — the script rebuilds the static library incrementally per destination inside one machine-local `Derived/` tree, and the submodule pin already gives reproducibility.

## Consequences

- Every upgrade goes through a PR with an ADR note and re-records the exact pin (and, for binary targets, the artifact checksum).
- `Tuist/Package.resolved` is committed; SPM resolution happens only through pinned versions.
- `Scripts/ci-local.sh` runs lint, `tuist generate` and the tests — plain `tuist generate` suffices while no target consumes the packages; refresh `Tuist/Package.resolved` with `mise exec -- tuist install` when pins change. Known issue (2026-11, tuist 4.212.0 / Xcode 27 on this host): `tuist install` can stall in the swifterpm binary-artifact prefetch for `WebRTC-M155.xcframework.zip` (0-byte progress for tens of minutes while `curl` fetches the same URL fine); the artifact then downloads through Xcode's SwiftPM at first build. Revisit when the CallEngine task (LNK-33) makes the WebRTC slice load-bearing.
- Core changes require bumping the submodule pin (`git -C external/linko-core fetch --tags && git -C external/linko-core checkout vX.Y.Z`), rebuilding `Derived/core/` (delete it or touch the script to force reconfigure), and an ADR note if the core dependency set changes.
- CI machines need mise + Xcode 27; `Scripts/ci-local.sh` is the single entry point for lint, generate and tests.
