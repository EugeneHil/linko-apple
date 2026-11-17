# linko-apple

iOS and macOS apps of **Linko**, a private 1:1 messenger with audio/video calls (WebRTC, CallKit) and file transfer. One Tuist workspace with shared modules; `linko-core` provides the protocol and the call state machine.

Design: [docs/superpowers/specs/2026-10-25-linko-design.md](docs/superpowers/specs/2026-10-25-linko-design.md). Plans: [docs/superpowers/plans/](docs/superpowers/plans/). Decisions: [docs/adr/](docs/adr/).

## Status

Workspace skeleton (Plan 4 Task 1): the `Linko` Tuist workspace with the `LinkoiOS` / `LinkoMac` app stubs, the `CoreBridge` framework over the `linko-core` submodule (tag `v0.1.0`), and the toolchain pins. Build and test locally with `Scripts/ci-local.sh`. Modules, features and CI automation land task by task (see the plan).
