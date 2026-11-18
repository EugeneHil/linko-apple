# linko-apple

iOS and macOS apps of **Linko**, a private 1:1 messenger for iPhone and Mac: text chat, audio and video calls (WebRTC; CallKit on iPhone), and file transfer — served by its own [linko-server](https://github.com/EugeneHil/linko-server). One Tuist workspace, shared Swift modules, and the [linko-core](https://github.com/EugeneHil/linko-core) C++17 core vendored as a submodule behind a single Objective-C++ bridge. Call quality is a first-class citizen: a live stats overlay in the call screen and a per-call quality report uploaded to the server.

Design: [docs/superpowers/specs/2026-10-25-linko-design.md](docs/superpowers/specs/2026-10-25-linko-design.md) (§4.3 is the module map's source of truth). Plans: [docs/superpowers/plans/](docs/superpowers/plans/). Decisions: [docs/adr/](docs/adr/) — ADR-0001 (WebRTC/CallKit/TURN spike), ADR-0004 (this repo's dependencies). E2E checklist: [docs/e2e-checklist.md](docs/e2e-checklist.md) — the device-side rows of the v0.1 acceptance scenario, recorded at LNK-41.

## Architecture (apps side)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│  LinkoiOS / LinkoMac (SwiftUI, MVVM) — one composition root per app            │
│    Feature modules: Onboarding · Chats · Conversation · Call · Settings        │
│      ├─ Messaging (GRDB store, outbox, sync, receipts)                         │
│      ├─ Calls: CallCoordinator ─► CallEngine (WebRTC) ─► CallStats             │
│      │     └─ CallKitIntegration (iOS) / Mac incoming-call presenter           │
│      ├─ FileTransfer (data-channel P2P in-call, HTTPS via server)              │
│      ├─ ServerAPI (register, users, TURN, files, reports; SPKI pinning)        │
│      ├─ Signaling (WSS client, heartbeat, reconnect with backoff)              │
│      ├─ CoreBridge (Objective-C++) ─► LinkoCore (C++17, git submodule)         │
│      └─ DesignSystem (generated tokens + SwiftUI components)                   │
└──────────────────── WSS + HTTPS :443 ──────────────── media / data (DTLS-SRTP) ┘
            to linko-server                 direct P2P or TURN-relayed
```

Everything above `CoreBridge` is Swift 6 (strict concurrency, warnings as errors): signaling, chat and receipts are JSON envelopes (linko-core protocol v1) over the server's WSS; media and in-call file bytes flow peer-to-peer (DTLS-SRTP) or via TURN, never through the server; outside calls, file bytes go through the server's HTTPS API. `CoreBridge` is the only Swift↔C++ seam — the protocol parsing, the call state machine and the file chunking stay in the vendored core, exhaustively tested there. Callback/delegate Apple APIs (WebRTC, CallKit, `URLSessionWebSocketTask`, `NWPathMonitor`, `AVAudioSession`) are wrapped once at the boundary into `AsyncStream`s. DI via protocols and initializer injection; one composition root per app (no DI container).

## Module map

| Module | Responsibility | State |
|---|---|---|
| `LinkoCore` | Vendored C++17 core (`external/linko-core` submodule, tag `v0.1.0`): protocol envelopes, call state machine, file chunking, sync helpers. Built into a static library by `Scripts/build-core.sh` (CMake, arm64) | on develop |
| `CoreBridge` | Objective-C++; the only place where Swift meets C++. Exposes `LKEnvelope`, `LKCallStateMachine`, the file chunker/reassembler/ack tracker and `LKConversationHistory` as Objective-C types. No business logic — every C++ error path returns nil/error, no exception crosses the boundary | on develop |
| `Signaling` | WebSocket client over `URLSessionWebSocketTask` (`actor SignalingClient`): SPKI pinning that fails closed (no trust-on-first-use), bearer-token auth, 60 s heartbeat, reconnect with jittered exponential backoff, `AsyncStream` of decoded envelopes | on develop |
| `ServerAPI` | SPKI-pinned `URLSession` shared by the HTTP surface: invite link parsing, registration, contact search, TURN credentials, end-of-call report upload, Keychain token store (device-only, never synchronizable), session config. Added beyond the spec §4.3 table — the HTTP half of Signaling's pinning world; the file upload/download client lands with FileTransfer | on develop |
| `Messaging` | GRDB/SQLite local store, conversation keys matching the server's ordering, outbox that re-sends until the server confirms, sync on gap detection after reconnect, monotonic delivered/read receipts | on develop |
| `CallEngine` | WebRTC wrapper behind the `CallMediaEngine` protocol (stasel/WebRTC 155.0.0, exact pin): peer connection, tracks and capture where available, data channel, TURN credentials → ICE servers, bitrate plan, 1 s statistics stream. Everything above it is testable without WebRTC | on develop |
| `CallStats` | Derives bitrate, RTT, loss, jitter, fps, resolution, codec and candidate pair type from raw `getStats` deltas; pure adaptation policy (cellular / Low-Data-Mode bitrate cap); end-of-call quality report | on develop |
| `Calls` | `CallCoordinator`: drives the core state machine (the machine's effects are its only outputs), connects Signaling, CallEngine, CallKit and stats; exactly one active call; timers (ring 45 s / connect 20 s / reconnect 15 s); glare, duplicates and crossed calls handled by the machine | on develop |
| `CallKitIntegration` | iOS: `CXProvider`/`CXCallController` adapter, audio session in step with CallKit activation (WebRTC manual audio), route changes and interruptions. macOS: own incoming-call window plus a user notification instead | on develop |
| `FileTransfer` | In-call P2P over the data channel (16 KiB chunks, backpressure on `bufferedAmount`, resume from the last acknowledged chunk, SHA-256 verified); outside calls via the server (100 MB cap). Every completed transfer is recorded as a normal message, so it lands in history with receipts | on develop |
| `Features`: `Onboarding`, `Chats`, `Conversation`, `Call`, `Settings` | SwiftUI views + `@Observable @MainActor` view models, shared between platforms with platform-specific views only where the platforms differ | on develop |
| Apps: `LinkoiOS`, `LinkoMac` | Composition roots wiring Keychain → Signaling → Messaging → Calls → FileTransfer → features; entitlements, Info.plist | on develop |

## Incoming calls without PushKit

v0.1 signs with the free Apple Personal Team — no APNs/PushKit (spec §2, §3). Incoming calls reach the iPhone only while the app is running and holds its WebSocket. The `IncomingCallSource` protocol keeps PushKit pluggable: v0.1 ships the foreground-WebSocket implementation only, and a PushKit-backed source drops in later behind the same protocol. The `voip` background mode is declared next to `audio` (spike-proven, ADR-0001).

## Build and test

- **Toolchain:** Xcode 27, Tuist 4.212.0 via mise (pinned in `.mise.toml`) — always `mise exec -- tuist …`.
- **Submodule:** `git submodule update --init --recursive` after clone (`external/linko-core` pinned to tag `v0.1.0`).
- **One command:** `Scripts/ci-local.sh` — SwiftFormat `--lint`, SwiftLint `--strict`, the design-token freshness check, `tuist generate`, and every module test target on the iOS simulator and macOS. Every test invocation is hollow-gate hardened: a suite whose output says "no tests to run" or lacks an `Executed N tests` summary fails the script instead of passing silently (the PR-#24 incident).
- **Core:** `Scripts/build-core.sh <macosx|iphoneos|iphonesimulator>` builds `external/linko-core` into `Derived/core/<destination>/liblinko_core.a`; it runs automatically as a Tuist pre-build action on `CoreBridge`. Delete `Derived/core/` after bumping the submodule pin.
- **Coverage gate:** ≥ 80 % line coverage per logic target, measured over the logic sources only (SwiftUI `*View`/`*Screen` files are device-tested surfaces and stay out of the metric) — `Calls` (the coordinator), `CallStats`, `Messaging`, `ServerAPI` and the five feature modules (spec §7's Swift logic: view models, coordinators, services, policy/stats; `CoreBridge`, the generated `DesignSystem` tokens and the app shells stay outside the gate). `Scripts/ci-local.sh --coverage` re-runs the logic suites with code coverage on the iOS simulator, prints the per-target `xccov` table and fails under the threshold (macOS coverage is deliberately not collected — the gated targets are shared multiplatform code already exercised by that run). The `coverage` job in [.github/workflows/ci.yml](.github/workflows/ci.yml) runs the same gate; CI runs its macOS jobs only on pull requests to `develop`/`main` (Actions minutes budget, spec §8).
- **Signing:** free Personal Team; the iOS app installs from Xcode onto the owner's iPhone, and provisioning profiles expire after 7 days — refresh by rebuilding.

## Status

Merged on `develop`: workspace skeleton, `CoreBridge`, `DesignSystem`, `Signaling`, `ServerAPI`, `Messaging`, `CallEngine`, `CallStats` (plan tasks 1–8), then `Calls`, `CallKitIntegration`, `FileTransfer`, the feature modules and the composition roots (tasks 9–13). The CI battery with the hollow-gate hardening, the 80 % logic coverage gate, lint and the token freshness check is this README's owning task (LNK-40). Then the on-device e2e run ([docs/e2e-checklist.md](docs/e2e-checklist.md)) and the `v0.1.0` release (LNK-41, owner-in-loop). Tracker: [docs/superpowers/plans/2026-11-17-linko-04-apple.md](docs/superpowers/plans/2026-11-17-linko-04-apple.md).

## Roadmap

Items cut from v0.1 with the plan's rationale — each ships when its precondition lands:

- **PushKit incoming calls** — requires the paid Apple Developer Program; the `IncomingCallSource` abstraction keeps it a drop-in (spec §2).
- **Adaptation beyond the cellular / Low-Data-Mode bitrate cap** — thermal resolution drop and audio-only fallback; the `BitratePlan` shape already keeps room for them (spec §1 cut order item 3, applied in Task 8).
- **H.264 hardware codec path** — VP8-only ships; spec §4.4 asks for an on-device battery measurement before hardware encoding is enabled (Task 13).
- **Mac ↔ Mac e2e as a tested scenario** — the Mac call stack ships fully; the acceptance rows cover iPhone ↔ Mac only (spec §1 cut order item 4).
- **QR onboarding** — paste-only invite links ship; camera scanning is a simulator-untestable surface (Task 13, spec §4.5).
- **Multi-device** — one device per user in v0.1: registering with a new invite revokes the previous device server-side, which the app sees as a 4001 close and reconnects. App-side device management stays with the server CLI (no client-facing devices endpoint in server v0.1); Settings shows the local device id only.
