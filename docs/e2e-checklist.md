# App-side e2e checklist

> Prepared ahead of Task 14 (LNK-40); outcomes are recorded on the devices at
> LNK-41 (Task 15) and committed to this file there.

The app-side rows of the v0.1 acceptance scenario (design spec §10, items
1–10), complementing the server-side page in
`linko-server/docs/e2e-checklist.md` (items 1, 2, 7, 8, 9). Every row states
what the operator does on the device, what they see, and what gets recorded
(result + evidence: screenshot, noted value or timestamp). The scenario runs
twice: a Simulator rehearsal for the chat items (1, 2, 7 — the Simulator has
no camera, so no calls), then the real run on the iPhone (SE 3rd gen, LTE)
and the MacBook Pro against the released VPS server. Calls cover iPhone ↔ Mac
only; Mac ↔ Mac is not a tested scenario in v0.1 (plan cut #5). Failures loop
back through `fix/LNK-<n>-…` branches before the release (Task 15).

## Item 1 - Setup

Run: after `invite create` twice on the VPS (server-side rows), open Linko on
each device, paste the `linko://join?…` invite link, register the Mac as
`eugene` and the iPhone as `tatsiana`.

- [ ] iPhone: the pasted invite link is accepted (paste-only in v0.1; QR
      scan is cut, plan cut #4), the username step completes, registration
      succeeds and the app lands on the Chats list. Screenshot of the Chats
      list.
- [ ] Mac: the same flow lands on the Mac chat window. Screenshot.
- [ ] Each device finds the other by username through in-app user search:
      search `tatsiana` on the Mac and `eugene` on the iPhone; the peer appears
      and a conversation opens.
- [ ] iOS install recorded: built from Xcode with the free Personal Team;
      note the profile expiry date here (7 days) and the rebuild used to
      refresh it.

## Item 2 - Offline delivery

Run: force-quit the iPhone app; on the Mac send two messages into the
conversation; then open the iPhone app and the conversation.

- [ ] While the iPhone app is closed, nothing is delivered on the device and
      the Mac shows no "Delivered" yet (no APNs/PushKit in v0.1 — incoming
      messages arrive when the app next opens).
- [ ] iPhone, after opening the app: both messages are there in the order
      the Mac sent them — no gaps, no duplicates. Screenshot.
- [ ] Mac, after the iPhone is back online: both bubbles show
      "Delivered HH:MM" (ReceiptLabel).
- [ ] Mac, after the iPhone conversation is opened: both bubbles show
      "Read HH:MM". Screenshot.

## Item 3 - Call over cellular

Run: in Settings turn the stats overlay on; put the iPhone on LTE with Wi-Fi
off, Linko open in the foreground; from the Mac start a video call; answer on
the iPhone.

- [ ] iPhone: the CallKit full-screen incoming call appears with
      accept/decline (the first call also raises the camera/microphone
      permission prompts — grant them). Screenshot of the CallKit screen.
- [ ] Answer from the CallKit screen: the app call screen shows remote video
      full screen, local preview top right, stats overlay top left and the
      controls tray at the bottom (mute, camera, hangup).
- [ ] Two-way video and audio work on both sides.
- [ ] The stats overlay shows the ICE candidate pair plus live bitrate and
      RTT, with loss, jitter, fps, resolution and codec (VP8 in v0.1). On
      LTE the pair may be `relay` (via TURN) or a direct `host` pair — TURN
      is the fallback path, not a requirement (the LNK-3 spike saw a direct
      `host` pair on MTS LTE with relay-only off). Record which pair type
      the overlay shows. Screenshot of the overlay.
- [ ] Mac: the call view sits in the middle of the Mac window with the same
      overlay and tray; the conversation stays available as a sidebar during
      the call.
- [ ] Ending the call from either side returns both apps to the normal UI.

## Item 4 - In-call chat and file

Run: while the call is active, the Mac sends a text message and a 20 MB file
into the conversation.

- [ ] Mac: the file bubble shows transfer progress with the "peer-to-peer"
      label; the text message is visible in the in-call conversation sidebar.
- [ ] iPhone: the file bubble shows live progress and the "peer-to-peer"
      label while the 20 MB arrive over the data channel. Screenshot of the
      bubble mid-transfer and completed.
- [ ] iPhone: on completion the file opens from the bubble — SHA-256
      verified (a digest mismatch would surface as an error instead of a
      broken file).
- [ ] After the call the transfer stays in the history on both sides as a
      normal file message (name, size, transport label) with receipts.

## Item 5 - Network change

Run: during a call, turn the iPhone's Wi-Fi on mid-call (the phone moves off
LTE onto Wi-Fi).

- [ ] The call does not hang up: ICE restart runs automatically; the call
      screen may show its reconnecting state while it happens.
- [ ] Media (video and audio) resumes within ≤ 5 s of the switch, without a
      hangup. Note the observed gap: ________ s.
- [ ] The stats overlay keeps updating after the change; note the candidate
      pair type it shows now (expected to move off `relay` on Wi-Fi — the
      spec pins `relay` only for the LTE call).

## Item 6 - Audio

Run: in a call, on the iPhone call screen switch the audio route to speaker
and back; then mute from the CallKit screen (system call UI, e.g. from the
lock screen); then hang up.

- [ ] Switching to speaker and back from the call screen works; the route
      change is applied immediately and surfaced on the call screen.
- [ ] Mute toggled on the CallKit screen is reflected in the app's call
      screen (mute control state).
- [ ] After hangup the system microphone indicator (orange dot) turns off —
      the audio session is deactivated and the app holds no capture.

## Item 7 - File via server

Run: force-quit the iPhone app; on the Mac send a file (≤ 100 MB, within the
per-user quota); then open the iPhone app.

- [ ] Mac: the file bubble uploads with progress and carries the "via
      server" label; the message sits in the conversation with no
      "Delivered" while the iPhone is offline.
- [ ] iPhone, after opening the app: the file message is there; the download
      runs (progress on the bubble) and the file opens.
- [ ] The iPhone bubble also carries the "via server" label. Screenshot of
      both bubbles.
- [ ] The file opens cleanly — the download is digest-verified against the
      server's SHA-256 (a mismatch would surface as an error). Note the file
      size used: ________.

## Item 8 - Server failure mid-call

Run: during a call the owner stops the `linko-server` service on the VPS
(TURN keeps running); hang up from the call screen while the server is still
down; optionally send one message on the Mac during the outage; the owner
restarts the service.

- [ ] Media keeps flowing while the signaling service is down (video and
      audio continue — coturn relays independently).
- [ ] Hangup from the call screen still ends the call on both sides while
      the server is down (`call.hangup` goes over the open data channel).
- [ ] With the server still down, the chat surfaces show the
      offline/reconnecting banner.
- [ ] After the restart both apps reconnect on their own (jittered
      exponential backoff, no manual restart) and the banner clears.
- [ ] The message sent during the outage flows after the reconnect exactly
      once — no duplication, no loss (client-generated message ids, ordered
      sync).

## Item 9 - Analytics

Run: no device steps beyond ending each call through the UI; afterwards the
owner runs `linko-server calls list` and `calls show <callId>` on the VPS
(server-side rows).

- [ ] Both calls of the session were ended through the app UI, so the stored
      end reasons are real; note which side hung up each call.
- [ ] The values in `calls list` (setup time, candidate type, RTT, loss, end
      reason) match what the stats overlay showed live during the calls and
      the notes from items 3–5. Screenshot of the `calls list` output next to
      an overlay screenshot.

## Item 10 - Code walkthrough

Run: walkthrough with the owner; no device steps.

- [ ] The Tuist module graph matches the README module map (spec §4.3 rows
      plus the added `ServerAPI` module); the CI `macos` job uploads
      `tuist graph` as an artifact.
- [ ] linko-apple CI is green on `develop`: `macos` job (iOS simulator +
      macOS tests), coverage gate ≥ 80 % on logic targets, SwiftLint/
      SwiftFormat lint, design-token freshness check, gitleaks. Record the
      run links.
- [ ] The README contains the architecture text diagram and the roadmap
      (PushKit, adaptation beyond the bitrate cap, H.264, Mac ↔ Mac e2e,
      QR onboarding, multi-device).
- [ ] The generated `Tokens.swift` matches `linko-core`'s `tokens.json`
      (token freshness check green).

## Ambiguities in the spec (app side), resolved per the plan

- Onboarding input: spec §4.5 says "paste or scan"; plan Task 13 (cut #4)
  ships paste-only and flags QR scanning to the owner in the release notes.
  Item 1 is written for the paste flow.
- In-call message visibility on the iPhone: spec §10 item 4 says the Mac's
  message "arrives" during the call, but the in-call conversation sidebar is
  a Mac-only surface (spec §4.7). On the iPhone the message becomes visible
  in Chats/Conversation after the call screen closes; item 4 records it
  accordingly.
- Codec in the overlay: spec §4.4 leaves H.264 to a battery measurement;
  plan Task 13 (cut #3) ships VP8-only, so item 3 expects the overlay's
  codec field to read VP8.
- Candidate pair type after the item 5 network change: the spec pins
  `relay` only for the LTE call (item 3); after switching to Wi-Fi the pair
  type is whatever the network allows, so item 5 records the observed type.
- Item 9 is silent in the app UI: the end-of-call report upload happens
  automatically after hangup (plan Task 9), so the app-side row is a
  cross-check against the server's stored reports rather than a device-side
  observation.
- Whether the call screen shows anything while the signaling service is down
  (item 8) is unspecified; the offline/reconnecting banner is a chat surface
  (plan Task 12) and the call screen shows its own state only when ICE
  itself drops. Item 8 observes the banner after hangup.
