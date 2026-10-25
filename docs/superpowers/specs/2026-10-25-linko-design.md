# Linko — 1:1 Messenger with Audio/Video Calls and File Transfer — Design

Date: 2026‑10‑25 · Status: approved

Decision tags: **[owner]** — product owner's decision; **[proposed]** — assistant's call, open to challenge; **[builder]** — left to the implementer.

---

## 1. What and why

**Linko** is a private 1:1 messenger for iPhone and Mac: text chat, audio and video calls, and file transfer, served by its own server. Calls are built on WebRTC with a custom signaling protocol over WebSocket; on iPhone they integrate with the system phone UI through CallKit.

The core of the product is call quality and transparency: the apps show live call statistics (bitrate, round‑trip time, packet loss, jitter, resolution, codec, ICE candidate type), adapt to the network and device state, and send a quality report for every call to the server. The signaling protocol and the call state machine live in a cross‑platform C++17 core shared by the server and both apps.

First release (v0.1): a small product with production‑grade architecture, aimed at **a few days of work [owner]**. Priority is quality, clean architecture and reliability over feature count **[owner]**: quality gates (TDD, coverage, warnings as errors, secret layers) are never relaxed to save time.

**If time runs short, scope is cut in this order [proposed]** (each cut item moves to the roadmap; nothing else in §10 changes): 1) server deployment on tag (deploy by hand with the documented script instead); 2) `calls list|show` CLI analytics (reports are still stored); 3) adaptation policy beyond the cellular bitrate cap; 4) Mac ↔ Mac calls as a tested scenario.

**v0.1 is done when** the acceptance scenario in §10 passes end‑to‑end on real devices (iPhone + Mac + VPS), all three repositories have green CI, the design system is in place, and each README contains an architecture diagram and a roadmap.

## 2. Goals, non‑goals, anti‑goals

**Goals**
- 1:1 audio and video calls between iPhone and Mac (and Mac ↔ Mac) through the own server; WebRTC media, own signaling **[owner]**.
- iPhone: incoming and outgoing calls go through **CallKit**; audio is managed with `AVAudioSession` in step with CallKit (routes: receiver, speaker, Bluetooth, wired; interruptions; mute from the system UI) **[owner]**.
- A real messenger **[owner]**: server‑side history, delivery to offline recipients, "delivered" / "read" receipts, local cache on the device, offline send queue.
- File transfer **[owner]**: during a call peer‑to‑peer over a WebRTC data channel; outside a call through the server (upload, then delivery as a message).
- Call statistics **[proposed]**: live overlay in the call screen; a per‑call quality summary uploaded to the server; adaptive behaviour (bitrate caps on cellular / Low Data Mode, resolution drop on thermal pressure, ICE restart on network change, audio‑only fallback).
- A single C++17 core shared by the server (Windows) and the apps (iOS, macOS) **[proposed]**.
- TDD, strict rules, maximum automation of the development process **[owner]**.
- Private keys and other secrets never leave the host they belong to and never reach a repository (§6) **[owner]**.

**Non‑goals for v0.1** (listed as roadmap in the README)
- Group chats and group calls (needs an SFU) **[owner]**.
- End‑to‑end encryption of messages and files (v0.1: TLS to the server, DTLS‑SRTP for media and data channels between devices) **[owner]**.
- PushKit / APNs: incoming calls while the app is closed, message pushes **[owner]** — requires the paid Apple Developer Program. The code keeps an `IncomingCallSource` abstraction so PushKit plugs in later.
- Web client, Android, Windows desktop client **[owner]**.
- Passwords, e‑mail, phone numbers, Sign in with Apple; open self‑registration **[owner]**.
- Screen sharing, call recording, voicemail, message editing/deletion, reactions, typing indicators, stickers.
- Building libwebrtc from source (a prebuilt binary is used, §4.4) **[owner]**.
- Admin web panel — administration is a server CLI **[proposed]**.

**Anti‑goals** (failure even if everything "works")
- A private key or secret (TLS key, TURN shared secret, device token, deploy key) lands in a repository, a log, a crash report or on a client that should not have it.
- A call that silently has no audio (audio session not activated in step with CallKit), echo, or the app holding the microphone after a call.
- Messages lost or duplicated across reconnects.
- Muddled architecture: WebRTC or CallKit callbacks carrying business logic, god objects, view models that talk to sockets, no tests.
- Battery or CPU drain when idle (busy reconnect loops, capture left running).

## 3. Constraints
- **No paid Apple Developer Program for v0.1 [owner].** The apps are signed with the free Personal Team: the iOS app is installed from Xcode onto the owner's iPhone, its profile expires after 7 days and is refreshed by rebuilding. Consequences: no APNs/PushKit, so **an incoming call reaches the iPhone only while the app is running and holds its WebSocket** (foreground, or the short window after backgrounding); CallKit is still used for the incoming/outgoing call UI and audio. Background modes used: `audio`, `voip` is declared only when it does not break free provisioning **[builder: verify in the day‑one spike]**.
- **Devices:** one iPhone (iPhone SE 3rd gen), one MacBook Pro, one Windows VPS **[owner]**. The second party for iPhone tests is the Mac (and a second Mac account / the iOS Simulator for chat only — the Simulator has no camera).
- **Server runs on the Windows VPS [owner].** No domain → self‑signed certificate; the apps validate it with SPKI pinning **[proposed]**.
- **TURN is required** for calls across NATs (iPhone on cellular). See §4.6.
- **AI tooling budget:** Claude subscription + $100 of cloud session credits valid until Nov 5; no budget beyond that **[owner]**.
- **Platforms:** iOS 18+ and macOS 15+ apps **[proposed]**; server on Windows; `linko-core` and `linko-server` also build on Linux as an **unofficial dev build only**, so cloud sessions can work on them; Linux is not in CI **[proposed]**.
- **GitHub, private repositories on the Free plan [owner].** Consequences: GitHub secret scanning / push protection are not available (paid add‑on), so secret protection relies on the three local and CI layers in §6; server‑side branch rulesets may not be enforceable, so branch rules are enforced by the local guard hook and by process (§5); Actions minutes are limited (2,000/month, macOS minutes count at a multiplier), so CI is budgeted (§8). Repositories can be made public later without changes.

## 4. Architecture

```
┌──────────────────────── iPhone / Mac (one Tuist workspace) ───────────────────────┐
│ LinkoiOS app / LinkoMac app (SwiftUI, MVVM)                                       │
│   Feature modules: Onboarding · Chats · Conversation · Call · Settings            │
│   ├─ Messaging (repository, GRDB store, outbox, sync)                             │
│   ├─ Calls: CallCoordinator ─► CallEngine (WebRTC) ─► CallStats                    │
│   │         └─ CallKitIntegration + AudioSession (iOS only)                        │
│   ├─ FileTransfer (data channel P2P / HTTPS via server)                           │
│   ├─ Signaling: WSS client, reconnect, SPKI pinning                               │
│   ├─ CoreBridge (Obj‑C++) ─► LinkoCore (C++17)                                    │
│   └─ DesignSystem (generated tokens + components)                                 │
└───────────────┬──────────────── WSS + HTTPS :443 ──────────────┬──────────────────┘
                │                                                │ media / data (DTLS‑SRTP):
                │                                                │ direct P2P, or relayed via TURN
┌───────────────▼──────────────── Windows VPS ───────────────────▼──────────────────┐
│ linko-server (C++17) ─► LinkoCore (same code)          TURN server (§4.6)          │
│   ├─ /ws: signaling, chat, receipts, presence           UDP/TCP 3478 + relay ports │
│   ├─ /api/v1/*: register, files, call reports, TURN credentials                   │
│   ├─ SQLite: users, devices, invites, messages, files, call reports               │
│   └─ CLI: invite, device, user, cert, calls                                       │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Repositories and modules
- `linko-core` — C++17 core + design tokens (§4.2, §4.8).
- `linko-server` — signaling/messaging server and CLI (§4.5); `linko-core` as a git submodule pinned to a tag.
- `linko-apple` — one Tuist workspace for the iOS and macOS apps (§4.3); `linko-core` as a git submodule pinned to a tag. This document lives in `linko-apple/docs/superpowers/specs/`; the other repos link to it from their README.

### 4.2 LinkoCore (C++17)
Pure C++17, no platform dependencies, CMake, GoogleTest, nlohmann/json via FetchContent at a pinned tag **[proposed]**.

**Protocol v1** — JSON envelopes over WebSocket **[proposed; schema is extensible]**:
```json
{ "v": 1, "type": "call.offer", "id": "6f1c…", "ts": 1792877416123,
  "body": { "callId": "c7a2…", "to": "anna", "media": "video", "sdp": "v=0…" } }
```
- Message families: `session.*` (hello/auth, ping/pong, error), `presence.*`, `call.*` (invite, ringing, accept, reject, busy, cancel, offer, answer, ice, ice-restart, hangup), `msg.*` (send, stored, deliver, ack‑delivered, ack‑read, sync), `file.*` (offer/accept/cancel for in‑call transfers; metadata only — bytes go over the data channel).
- **In‑call files in history [proposed]:** a P2P transfer is also recorded as a normal message (name, size, SHA‑256, `transport: p2p`) with `seq` and receipts; the bytes exist only on the two devices. If the call ends mid‑transfer the transfer fails and the UI offers "Send via server"; resume works only within the same call.
- **In‑call control fallback [proposed]:** while the data channel is open, `call.hangup` and `file.*` are also sent over it, so hanging up and in‑call files keep working while the server is down; ICE restart and new calls need the server.
- API: `parseEnvelope(std::string_view) -> Result<Envelope>` with a list of validation errors carrying JSON paths (`body.sdp: missing`), `serialize(const Envelope&)`, per‑type typed structs. Size limits (envelope ≤ 64 KiB, SDP ≤ 32 KiB), strict UTF‑8, nesting limit, unknown fields ignored but unknown `type` rejected, `v` mismatch → `session.error{code:"unsupported_version"}`.
- **Call state machine** — a pure value type: `(State, Event) -> (State, std::vector<Effect>)`. States: `idle, outgoingRinging, incomingRinging, connecting, active, reconnecting, ended(reason)`. Events: local actions, remote signaling messages, ICE connection state changes, timers. Effects: "send message X", "start/stop ringing", "start timer T", "report to CallKit", "start ICE restart". Covers timeouts (ring 45 s, connect 20 s, reconnect 15 s **[proposed]**), reject, busy, cancel, crossed calls (glare: both sides call each other — the call with the lexicographically smaller `callId` survives **[proposed]**), duplicate and late messages, ICE restart on network change. Exhaustively tested; the same machine drives the apps and the server's call registry.
- **File chunking:** manifest (name, size, SHA‑256, chunk size 16 KiB **[proposed]**), chunk framing for the data channel, reassembly with integrity check, resume from the last acknowledged chunk.
- **Message sync rules:** client‑generated message ids (UUID) make sends idempotent; the server assigns a per‑conversation monotonically increasing `seq`; a client syncs with "everything after seq N". Pure helpers for ordering, dedup and receipt state are in the core and shared.
- Builds on macOS, Windows and (dev only) Linux via CMake presets.

### 4.3 linko-apple — Tuist workspace [proposed]
Multi‑module, every module is a framework with its own test target, built for iOS and macOS unless noted. DI via protocols and initializer injection (no DI container); a composition root per app wires everything.

| Module | Responsibility |
|---|---|
| `LinkoCore` | prebuilt static library from the `linko-core` submodule (CMake pre‑build step or xcframework **[builder]**) |
| `CoreBridge` | Objective‑C++; the only place where Swift meets C++. Exposes `LKEnvelope`, `LKCallStateMachine`, `LKFileChunker` as Objective‑C types |
| `Signaling` | WebSocket client over `URLSessionWebSocketTask`, SPKI pinning, auth, heartbeat, reconnect with jittered exponential backoff, `AsyncStream` of decoded envelopes |
| `Messaging` | conversations and messages repository, local store (GRDB/SQLite **[proposed]**), outbox with retry, sync after reconnect, receipts |
| `CallEngine` | wraps WebRTC: peer connection factory, camera capture, audio/video tracks, data channel, codec and bitrate settings; exposes protocol `CallMediaEngine` so everything above it is testable without WebRTC |
| `Calls` | `CallCoordinator`: drives the C++ state machine, connects Signaling, CallEngine, CallKit and stats; one active call at a time |
| `CallKitIntegration` | iOS only: `CXProvider`/`CXCallController`, `AudioSession` (category `.playAndRecord`, mode `.videoChat`/`.voiceChat`, WebRTC manual audio activated in `provider(_:didActivate:)`), route changes, interruptions. macOS: an own incoming‑call window and notification instead |
| `CallStats` | polls `getStats` every 1 s, derives bitrate, RTT, loss, jitter, fps, resolution, codec, candidate pair type; feeds the overlay, the adaptation policy and the end‑of‑call report |
| `FileTransfer` | in‑call P2P via the data channel (backpressure on `bufferedAmount`, progress, cancel, SHA‑256 check), outside calls via HTTPS upload/download |
| `DesignSystem` | generated `Tokens.swift` + components (§4.8) |
| Features: `Onboarding`, `Chats`, `Conversation`, `Call`, `Settings` | SwiftUI views + `@Observable @MainActor` view models; shared between platforms, platform‑specific views only where the platforms differ |
| Apps: `LinkoiOS`, `LinkoMac` | composition roots, entitlements, Info.plist |

- **Adaptation policy [proposed]:** a pure, unit‑tested function from (network type, Low Data Mode, thermal state, measured loss/RTT) to (max bitrate, max resolution/fps, audio‑only); applied through `RTCRtpSender` encoding parameters.
- **Network changes:** `NWPathMonitor` → ICE restart via the state machine; the call should survive a Wi‑Fi ↔ cellular switch.
- Logging via `Logger` (subsystem `…linko`); SDP, ICE credentials, tokens and message bodies are never logged.

### 4.4 WebRTC dependency [owner]
Prebuilt binary `stasel/WebRTC` (xcframework for iOS and macOS) via Swift Package Manager, **pinned to an exact version with the SPM checksum** (no `latest` branch); upgrades go through a PR with an ADR note. Supported codecs: Opus for audio; VP8 default, H.264 where hardware encoding helps battery **[builder: measure]**.

### 4.5 linko-server (C++17)
- **Stack [proposed]:** Boost.Beast/Asio (HTTPS and WSS on one port), OpenSSL, SQLite, nlohmann/json; vcpkg manifest on Windows. Code avoids WinAPI except where a store or service wrapper requires it.
- **Port:** 443 if free on the VPS, otherwise a configured port **[builder: check the VPS]**.
- **Accounts [owner]:** invite codes only. `linko-server invite create [--user <name>]` prints a one‑time code (expires in 24 h **[proposed]**). The app registers with code + username and receives a random device token (shown once, stored hashed with SHA‑256 on the server, in the Keychain on the device). Contacts are found by username. **One device per user in v0.1 [proposed]:** registering with a new invite for an existing username revokes the previous device (its socket is closed); the new device syncs the full history from `seq 0`. Multi‑device fan‑out is roadmap.
- **Invite link and pin [proposed]:** `invite create` prints one `linko://join?host=…&port=…&pin=<SPKI>&code=…` link (and a QR in the terminal). Onboarding accepts only this link (paste or scan), so the very first request is already pinned; there is no trust‑on‑first‑use. `device list/revoke`, `user list` in the CLI; revocation takes effect immediately (open sockets are closed).
- **Endpoints:**

  | Path | Caller | Purpose |
  |---|---|---|
  | `POST /api/v1/register` | app (invite code) | create user/device, return device token |
  | `GET /ws` (upgrade) | app (`Authorization: Bearer`) | signaling, chat, receipts, presence |
  | `GET /api/v1/turn` | app | short‑lived TURN credentials (§4.6) |
  | `PUT /api/v1/files` / `GET /api/v1/files/{id}` | app | upload/download outside calls; ≤ 100 MB per file **[proposed]**, per‑user quota; files are deleted 30 days after upload **[proposed]** |
  | `POST /api/v1/calls/{callId}/report` | app | end‑of‑call quality summary |
  | `GET /api/v1/users?prefix=` | app | find contacts by username |

- **Server logic:** routes signaling between the two parties of a call and keeps a call registry built on the core state machine (busy detection, ring timeout, cleanup when a socket drops); stores messages and assigns `seq`; delivers on connect; tracks presence (online if a socket is open).
- **Calls analytics [proposed]:** `linko-server calls list|show <id>` prints duration, setup time, candidate type, average/peak RTT, loss, bitrate and end reason from the stored reports.
- **Storage:** SQLite file in the data directory; files on disk under the data directory, named by id; schema migrations versioned.
- **Limits:** frames ≤ 64 KiB, per‑connection message rate limit, failed‑auth throttling per address, max sockets per device.
- **Config:** JSON file + environment variables (env wins); only `config.example.json` is committed (§6).

### 4.6 TURN / STUN [proposed]
- A TURN server on the same VPS provides STUN and relay (UDP 3478, TCP 3478, a small relay port range). Authentication uses the **TURN REST API scheme**: the TURN server and `linko-server` share a static secret; the app receives only `username = "<expiry>:<user>"`, `credential = base64(HMAC‑SHA1(secret, username))` with a short lifetime (1 h).
- Candidate: **coturn** with `use-auth-secret`/`static-auth-secret`. coturn ships no Windows binaries but documents a native MSVC/CMake build; the day‑one spike decides how it runs on the VPS (native MSVC build via vcpkg first, WSL2 as the fallback) **[builder: spike]**.
- TLS for TURN (`turns:` on 5349) is roadmap.

### 4.7 UI [owner: direction A "Native Calm"]
Mockup A "Native Calm" (Apple‑native greys, iOS blue accent, glass controls), refined:
- **iPhone:** Chats list (avatar, last message or "📞 Missed call", unread badge); Conversation (bubbles, file bubble with progress and "peer‑to‑peer"/"via server" label, "Read 14:02"); Incoming call — the CallKit system screen; Call screen (remote video full screen, local preview top right, stats overlay top left, controls at the bottom).
- **Call controls tray [owner]:** controls sit in an inset glass tray with clear spacing — about 24 pt buttons, ≥ 8 pt gaps between them, ≥ 12 pt from the screen edges and above the home indicator. Controls must never touch each other or the screen edges.
- **Mac:** one window: sidebar with chats; the call view in the middle with the same tray; the conversation as a sidebar during a call.
- Onboarding: server address + invite code + username; Settings: server, SPKI pin, account, devices, stats overlay on/off.
- States: offline/reconnecting banner, call reconnecting, permission denied (camera/microphone), invite invalid/expired.

### 4.8 Design system [owner]
- Single source of truth: `linko-core/design-tokens/tokens.json` — semantic colors (light/dark), typography, spacing, radii, control sizes.
- Generator `generate.py` (Python 3, stdlib only) → `Tokens.swift` in `DesignSystem`; the generated file is committed and CI checks it is up to date.
- SwiftUI components with `#Preview` in light and dark mode: `Avatar`, `ChatRow`, `MessageBubble`, `FileBubble`, `ReceiptLabel`, `CallControlsTray`, `CallControlButton`, `StatsOverlay`, `Banner`, `LKButton`.

## 5. Repositories & branching [owner]
- `linko-core` — CI: macOS + Windows. `linko-apple` — CI: macOS (iOS Simulator + macOS tests). `linko-server` — CI: Windows + macOS.
- Branches: `main`, `develop`. Work goes into `feature/LNK-<n>-<slug>` (also `fix/…`, `chore/…`, `docs/…`, `spike/…`); PRs target **`develop`**, never `main`. Releases: PR `develop → main` + tag `vX.Y.Z`.
- Protection on `main`/`develop`: PR only, green CI required, linear history on `develop`, no force push, no deletion. Enforced by the guard hook (no commit/push to `main`/`develop`, no force push, no skipped hooks) and by merging only through `gh pr merge` after green checks. The bootstrap script also tries to apply GitHub rulesets and reports clearly if the plan does not allow them **[proposed]**.
- Conventional Commits (checked by a commit‑msg hook), PR template, CODEOWNERS, Dependabot.

## 6. Secrets, private keys & `.gitignore` [owner]
**Rule: a private key or secret never leaves the host it belongs to and never enters a repository, a log, a crash report or a client that does not need it.**

| Secret | Where it lives | Never |
|---|---|---|
| Server TLS private key | generated **on the VPS** by `linko-server cert generate`; file ACL owner‑only; path via config/env | copied off the VPS, committed, logged |
| TURN shared secret | VPS only: env var / gitignored local config of the server and the TURN server | sent to apps (apps get only short‑lived HMAC credentials) |
| Device tokens | device Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable); server stores only SHA‑256 hashes | `UserDefaults`, files, logs, crash reports |
| Invite codes | printed once by the CLI; stored hashed; single use; expire | committed or logged |
| Deploy SSH key (CI → VPS) | GitHub Actions secret in a protected environment, used only on release tags; key restricted to the deploy user | used on PR builds, echoed |
| Apple signing identity (free Personal Team) | the owner's login keychain, managed by Xcode | exported as `.p12`, committed |

- **Layers against leaks:** `.gitignore`; Claude Code `PreToolUse` guard hook blocking the agent from reading/writing `.env*`, `*.pem`, `*.key`, `*.p12`, `*.p8`, `*.cer`, `*.mobileprovision`, `config.local.json` and from committing/pushing on `main`/`develop` or skipping hooks; pre-commit with gitleaks; gitleaks in CI (required check). GitHub secret scanning + push protection are not available for private repositories on the Free plan; they are switched on if a repository becomes public. A fake‑secret push test verifies the remaining layers block a leak.
- **Apps:** SPKI pinning of the server certificate; ATS stays on (only the pinned self‑signed server is trusted via the delegate); no secrets in `Info.plist`, xcconfig or source.
- **Server logs:** address, method, path (no query), status, duration; never tokens, invite codes, `Authorization`, message bodies, SDP or ICE credentials.
- **`.gitignore`:** `.DS_Store`; `DerivedData/`, `xcuserdata/`, `*.xcuserstate`, Tuist‑generated `*.xcodeproj`/`*.xcworkspace`, `Derived/`; `build/`, `cmake-build-*/`, `out/`; `.vs/`, `*.user`; `vcpkg_installed/`; `.env*`, `*.pem`, `*.key`, `*.p12`, `*.p8`, `*.cer`, `*.mobileprovision`, `config.local.json`, `data/`; `.superpowers/`; `*.profraw`, `coverage/`.

## 7. TDD, quality, strict rules [owner]
- TDD is mandatory (superpowers:test-driven-development): test first, then code.
- Coverage gates in CI: `linko-core` ≥ 90 % lines; Swift logic (view models, coordinators, repositories, adaptation policy, stats derivation) ≥ 80 %; server logic ≥ 80 %.
- **Swift Concurrency only [owner]:** async/await, actors, `AsyncStream`/`AsyncSequence`, `Task`, structured concurrency. No GCD, `OperationQueue`, completion handlers or Combine in our own code. Callback/delegate APIs (WebRTC delegates on WebRTC's own threads, `CXProviderDelegate`, `URLSessionWebSocketTask`, `NWPathMonitor`, `AVAudioSession` notifications) are wrapped once at the boundary into `AsyncStream`s or continuations. Shared mutable state lives in actors or `Synchronization.Mutex`. UI state is `@MainActor`. Where an Apple API demands a synchronous answer (e.g. a CallKit action must be fulfilled or failed), the boundary adapter does exactly that and nothing more.
- Warnings are errors: Swift 6 language mode, strict concurrency `complete`; `-Wall -Wextra -Wpedantic -Werror` (MSVC `/W4 /WX`); clang-tidy + clang-format; SwiftLint `--strict` + SwiftFormat `--lint`.
- Each repo has a `CLAUDE.md`: stack, build/test commands, rules (TDD, branching, no secrets, no new dependencies without an ADR, no force unwraps / `try!`). Short ADRs in `docs/adr/`.
- Manual on‑device checklist `docs/e2e-checklist.md`; the §10 scenario runs before every release.

## 8. Automation
- **Local:** superpowers pipeline — writing-plans → subagent-driven-development (each task on its own branch) → code review → PR to `develop` via `gh`.
- **Models [proposed]:** implementation by Sonnet; planning and review by Opus.
- **Cloud sessions [proposed]:** only `linko-core` and `linko-server` tasks (Linux dev build).
- **GitHub Actions:** build, tests, coverage, linters, gitleaks, design‑token freshness, `tuist graph` artifact; Dependabot for Actions and submodules.
- **CI minutes budget [proposed]:** gitleaks and Linux‑able jobs run on `ubuntu-latest` (cheapest); macOS jobs run only on pull requests to `develop`/`main` (not on every push), with Tuist/SPM/CMake caches and path filters; Windows jobs only for `linko-core` and `linko-server`. Full local test runs (`scripts/ci-local.sh` per repo) are required before opening a PR so CI rarely has to rerun.
- **VPS preparation (plan task, done together with the owner):** firewall rules for the server port, TURN 3478 UDP/TCP and the relay range; TLS cert generated on the VPS and SPKI pin computed; server and TURN registered as Windows services.
- **Server deployment:** on tag `vX.Y.Z` in `linko-server` → build on `windows-latest` → deploy over SSH with the deploy key from the protected environment → restart the service. No self‑hosted runner.

## 9. Plan series [proposed]
1. **Foundation:** three repos, rulesets, secret‑guard layers, CI skeletons, `CLAUDE.md`s, ADR‑0000, and a **day‑one spike**: WebRTC video call iPhone ↔ Mac with CallKit on free provisioning, via a throwaway signaling relay, plus TURN on the VPS. Findings go into an ADR.
2. **linko-core:** protocol, state machine, chunking, sync helpers, design tokens.
3. **linko-server** and 4. **linko-apple** — in parallel after 2.

## 10. v0.1 acceptance scenario [proposed]
1. **Setup:** on the VPS `invite create` twice; the Mac registers as `eugene`, the iPhone as `anna`. They find each other by username.
2. **Offline delivery:** the iPhone app is closed; the Mac sends two messages. Opening the iPhone app delivers them in order; the Mac shows "Delivered", then "Read" once the conversation is opened.
3. **Call over cellular:** iPhone on LTE (Wi‑Fi off), app open. The Mac starts a video call → the iPhone shows the CallKit incoming screen → answer → two‑way video and audio. The stats overlay shows a `relay` candidate pair, bitrate and RTT.
4. **In‑call chat and file:** the Mac sends a message and a 20 MB file during the call → it arrives peer‑to‑peer with progress; SHA‑256 verified; opens on the iPhone.
5. **Network change:** the iPhone turns Wi‑Fi on mid‑call → ICE restart; media resumes within ≤ 5 s without hanging up.
6. **Audio:** switch to speaker and back from the call screen; mute from the CallKit screen is reflected in the app; after hangup the microphone indicator turns off.
7. **File via server:** with the iPhone app closed, the Mac sends a file; it is delivered when the app opens.
8. **Server failure mid‑call:** stop the `linko-server` service (TURN keeps running) during a call → media continues; hangup still works via the data channel; after restart the apps reconnect (backoff) and pending messages flow.
9. **Analytics:** `linko-server calls list` shows both calls with setup time, candidate type, RTT, loss and end reason.
10. **Code walkthrough:** Tuist module graph, green CI in all three repos, README with diagram and roadmap.

## 11. Left to the builder
- How the CMake build of `LinkoCore` plugs into Tuist (pre‑build script vs. xcframework).
- Exact layout of Settings, Onboarding and the Mac window within mockup A.
- Concrete dependency versions — latest stable at start time, pinned.
- Bundle ID prefix (owner's GitHub handle) and the `LNK` ticket numbering.
- Day‑by‑day breakdown and task order — in the plans, starting with the day‑one spike.
