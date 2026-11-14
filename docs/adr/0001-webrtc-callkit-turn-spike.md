# ADR-0001: WebRTC, CallKit and TURN spike findings

- Status: accepted
- Date: 2026-11-14

## Context

Plan 1 (Tasks 6–7) required a day-one proof that a WebRTC call works between the owner's iPhone and Mac — directly on the LAN and over cellular through a TURN server on the Windows VPS — before any product code is written. The spike lives on `spike/LNK-3-webrtc-callkit` in `linko-apple` (throwaway, never merged); this ADR and `docs/turn-setup.md` are the only merged output.

## Decision

Build the product on `stasel/WebRTC` (SPM binary, exact pin) with CallKit on iOS, and deploy coturn on the Windows VPS with REST-style short-lived TURN credentials. TURN is a fallback, not a requirement: ICE keeps the default policy and picks direct pairs whenever reachable.

## Findings

### Spike A — WebRTC call with CallKit (Task 6)

- `stasel/WebRTC` pinned to exactly **155.0.0** (revision `44f36788…`), Tuist 4.212.0, targets iOS 18 / macOS 15, bundle IDs `io.github.eugenehil.linko.spike(.mac)`. Free Personal Team provisioning was sufficient; declaring the `voip` background mode next to `audio` did **not** break installation.
- Signaling is JSON over WebSocket with the message types `call | accept | offer | answer | ice | hangup | turn`; the relay forwards frames verbatim.
- CallKit: `CXProvider` reports the incoming call; answering fulfills `CXAnswerCallAction`, configures `RTCAudioSession` and starts the session. `useManualAudio = true` with `isAudioEnabled` toggled in `provider(_:didActivate:)` / `didDeactivate:` works; mute goes through `CXSetMutedCallAction`; a remote hangup reports `.remoteEnded`.
- Audio session: `playAndRecord` + `videoChat` with `.allowBluetoothHFP` (the deprecated `.allowBluetooth` must not be used), `.allowBluetoothA2DP`, `.defaultToSpeaker`.
- A stats overlay built on `getStats` (nominated succeeded candidate-pair: pair type, RTT, outgoing bitrate, resolution) was enough to verify path selection without extra tooling.

### Spike B — TURN on the Windows VPS and calls over LTE (Task 7)

- coturn builds natively on the VPS with MSVC via CMake + a dedicated vcpkg instance; PostgreSQL support dropped. Working dependency set: libevent (core, extra, openssl), OpenSSL 3, libmicrohttpd, SQLite3, pthreads-win32 (`pthreadVC3.dll`); the build also produces `turnutils_uclient.exe`. No WSL2 needed.
- coturn on Windows does not resolve a drive-letter absolute path after `-c`; it must be started with a config name relative to its working directory.
- REST credentials (`username = <unix-expiry>:spike`, HMAC-SHA1 → Base64) are generated **on the VPS** from the config; the shared secret (32-byte hex from a CSPRNG) never leaves the VPS and the config gets an owner-only ACL. Copy credentials via clipboard over RDP — retyping Base64 silently breaks the HMAC.
- The Mac forwards the short-lived credentials to the iPhone over signaling (the `turn` message carries URL, username, credential and a `relayOnly` flag); TURN URLs without an explicit `?transport=` are used twice (UDP and TCP).
- A relay-only call (`iceTransportPolicy = .relay`, public STUN dropped) over MTS LTE (iPhone, Wi-Fi off) ↔ home Wi-Fi (Mac) connected through the VPS coturn.
- With relay-only off, the same LTE call selected a direct pair: `pair host`, RTT ~1 ms, outgoing ~226 kbps at 320x240 on the Mac and ~2107 kbps on the iPhone; the iPhone gathered `udp host` and `udp srflx` candidates. Direct P2P works on MTS LTE; TURN stays as the fallback for networks where it does not.
- A pure-PowerShell WebSocket relay (`HttpListener`, no Python on the VPS) was enough for signaling; it logs only the message type and size — a raw prefix could leak SDP or TURN credentials since JSON key order is not fixed.

Exact coturn configuration and operating steps: `docs/turn-setup.md`.

## Not recorded

- The exact CMake/vcpkg command sequence of the coturn build (outcomes and the working DLL set above are preserved on the owner's machine).
- WebRTC binary checksum, app binary sizes.
- `turnutils_uclient` allocation and loss numbers; RTT/bitrate of the relay-only LTE run.
- Windows Server version; whether port 443 is free for the product server.
- CallKit UI behavior when the app was backgrounded for more than ~30 s; `AVAudioSession` errors in the console during the calls.

## Consequences for Plans 2–4

- Pin `stasel/WebRTC` exactly; wrap RTC/CallKit/WebSocket callback APIs once at the boundary (spec §7), as the spike did.
- TURN credentials must reach clients without the shared secret ever leaving the VPS: REST-style short-lived credentials issued server-side keep that property; the product server inherits the relay's logging rule (type and size only, never SDP, ICE credentials or tokens).
- The signaling server on Windows needs no Python runtime: an HTTP API with WebSocket upgrade (HTTP.SYS family) covers it.
- The VPS keeps ports open for TURN fallback: UDP/TCP 3478 and UDP 49160–49200; coturn ran with `no-tls` for the spike — the product must revisit TLS before real traffic.
- ICE stays on the default transport policy; relay-only remains a diagnostics mode.
