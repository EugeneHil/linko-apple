# Linko Server Implementation Plan (Plan 3 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `linko-server` — the Windows signaling/messaging server: invite-only accounts, HTTPS + WSS on one port, chat with offline delivery and receipts, call routing through a registry on the core state machine, server-side file transfer, TURN credentials, call reports, and the admin CLI.

**Architecture:** One Boost.Beast/Asio TLS listener serves `/api/v1/*` and upgrades `/ws` to WebSocket. Protocol handling is thin: every frame goes through `linko-core`'s `parseEnvelope` and typed bodies, and call-lifecycle decisions come from the core state machine — the server adds routing, storage, timers and auth around the pure core. Storage is SQLite behind one `Store` class with versioned migrations; the TLS key and TURN secret exist only on the host (env / gitignored local config). `linko-core` is consumed as a submodule pinned to tag `v0.1.0`.

**Tech Stack:** C++17, Boost.Beast/Asio, OpenSSL, SQLite3, nlohmann/json and the protocol/state machine via the `linko-core` submodule, GoogleTest, CMake ≥ 3.28 with presets, vcpkg manifest on Windows / Homebrew on macOS, vendored qrcodegen for terminal QR codes.

**Spec:** `linko-apple/docs/superpowers/specs/2026-10-25-linko-design.md` (§4.5 linko-server, §4.6 TURN, §6 secrets, §7 quality gates, §8 automation).

**Plan series:** 1 Foundation (done) → 2 linko-core (done) → **3 linko-server (this)** → 4 linko-apple (after, or in parallel with, this plan).

**Tickets:** this plan document is LNK-14; Tasks 1–11 are LNK-15…LNK-25.

## Global Constraints

- C++17. Boost.Beast/Asio, OpenSSL, SQLite3 via vcpkg manifest on Windows (exact versions, `builtin-baseline` pinned) and Homebrew on macOS — ADR-0003 records the split and the macOS version-exactness trade-off.
- `linko-core` as submodule `external/linko-core` pinned to tag `v0.1.0` (released from develop HEAD 7763608 in Task 1).
- Warnings are errors: `-Wall -Wextra -Wpedantic -Werror`, MSVC `/W4 /WX`; clang-format + clang-tidy (spec §7).
- TDD: the failing test is written and watched first. Coverage gate: ≥ 80 % lines of server logic (`src/`) (spec §7).
- Secrets: TLS key and TURN shared secret only via env / gitignored local config; `config.example.json` committed with placeholders. Never log tokens, invite codes, `Authorization`, message bodies, SDP or ICE credentials; the request log line is address, method, path without query, status, duration (spec §6, §4.5).
- No WinAPI outside thin wrappers for the file ACL and the Windows service (spec §4.5).
- Accounts: invite-only, one device per user; registering for an existing username revokes the previous device and closes its socket (spec §4.5).
- Every endpoint except `POST /api/v1/register` requires `Authorization: Bearer <device token>`; tokens are stored only as SHA-256 hashes (core `linko::sha256Hex`).
- Branches `feature/LNK-<n>-<slug>` → PR to `develop`; Conventional Commits; English docs; new dependencies need ADR-0003.
- Scope cuts applied per spec §1 order: deployment by hand via the documented script (tag-triggered CI deploy is roadmap); the `calls` CLI is kept but marked cut candidate #2.

## Review Focus

1. Hostile HTTP/WS input — oversized frames (> 64 KiB), malformed JSON, wrong field types, missing Content-Length — must produce 4xx / `session.error` / close, never a crash or hang. *(Task 4: `test_register_rejects_malformed_json`; Task 5: `test_oversized_frame_closes`, `test_malformed_envelope_answered_with_error`)*
2. Auth abuse — guessed tokens, a revoked device holding an open socket, repeated failed registers — throttled per address, revoked sockets closed immediately. *(Task 4: `test_throttled_after_repeated_failures`; Task 5: `test_bad_token_rejected`, `test_revoked_device_socket_closed`)*
3. Duplicates and replays — the same `msg.send` id twice, a second `call.accept`, a late `call.hangup` after Ended — idempotent handling, forwarded at most once, no state corruption. *(Task 6: `test_duplicate_accept_forwarded_once`, `test_late_hangup_after_ended_ignored`; Task 7: `test_duplicate_send_returns_original_seq`)*
4. Drops mid-flight — a socket dropping during a call or mid-delivery — the peer is notified, the registry cleans up, messages are redelivered in seq order on reconnect. *(Task 6: `test_socket_drop_ends_calls_and_notifies_peer`; Task 7: `test_offline_delivered_in_seq_order_on_connect`)*
5. Resource exhaustion — a file over 100 MB, quota exceeded, files older than 30 days, rate/idle limits — enforced and cleaned, never accumulating. *(Task 5: `test_rate_limited_connection_closed`, `test_idle_connection_closed`; Task 8: `test_file_over_cap_rejected_413`, `test_quota_exceeded_507`, `test_expired_files_removed`)*

---

### Task 1: linko-core v0.1.0 release, server skeleton, ADR-0003 (LNK-15)

**Files:**
- linko-core: release PR `develop → main` + tag `v0.1.0`
- linko-apple: Create `docs/adr/0003-server-dependencies.md`
- linko-server: Create `CMakeLists.txt`, `CMakePresets.json`, `vcpkg.json`, `tests/CMakeLists.txt`, `tests/test_smoke.cpp`, `scripts/ci-local.sh`, `.clang-format`, `.clang-tidy`, `.editorconfig`, `src/main.cpp`, `src/cli.cpp` (usage stub)
- linko-server: Modify `CLAUDE.md` (stack section), `.gitmodules` (submodule add)

**Interfaces:**
- Produces: CMake targets `server_lib` (static, all server logic), `linko-server` (exe, links `server_lib`), `linko_server_tests` (GoogleTest); presets `macos`, `windows`, `linux` (dev), `coverage`; helper `linko_add_test(<name> <sources…>)`; submodule `external/linko-core` at tag `v0.1.0`; `int runCli(int argc, char **argv)` in `src/cli.cpp` (prints usage, exit 2, until real commands land); `scripts/ci-local.sh` (configure + build + ctest, clang-format/clang-tidy checks, coverage on macOS).

- [ ] **Step 1: Release linko-core v0.1.0** — open PR `develop → main` in linko-core ("chore: release linko-core v0.1.0"); after the owner approves the merge, merge, tag the merge commit `v0.1.0`, push the tag.
- [ ] **Step 2: Write ADR-0003** (`docs/adr/0003-server-dependencies.md`, branch `docs/LNK-15-adr-0003` in linko-apple): Context — the server needs HTTP/WebSocket/TLS/SQLite beyond core's deps; Decision — Boost.Beast (brings Asio), OpenSSL, SQLite3 via vcpkg manifest on Windows with exact versions + `builtin-baseline`, Homebrew on macOS (bottles, versions tracked by brew — accepted trade-off, the product runs on Windows); vendored qrcodegen (Task 3) recorded in Consequences like core's vendored SHA-256 in ADR-0002; nlohmann/json arrives transitively via `linko_core` (PUBLIC link). PR to develop.
- [ ] **Step 3: Write the failing smoke test** — `tests/test_smoke.cpp`: `TEST(Smoke, GoogleTestRuns) { SUCCEED(); }` via `linko_add_test(smoke test_smoke.cpp)`.
- [ ] **Step 4: Run** — `cmake --preset macos && cmake --build --preset macos && ctest --preset macos` → Expected: FAIL (no `CMakeLists.txt`).
- [ ] **Step 5: Implement the skeleton** — `git submodule add https://github.com/EugeneHil/linko-core.git external/linko-core`, checkout `v0.1.0`; root `CMakeLists.txt` (C++17, warnings-as-errors per compiler, `add_subdirectory(external/linko-core)` — core's own suites build and run here too and must stay green; `add_subdirectory(src)` building `server_lib` + the exe, `add_subdirectory(tests)`); `vcpkg.json` (boost-beast, openssl, sqlite3; exact versions verified on the vcpkg registry in this step); presets (`windows` uses the vcpkg toolchain via `VCPKG_ROOT`; `macos` adds Homebrew prefix hints for openssl/sqlite/boost; `coverage` adds llvm-cov flags); `linko_add_test` in `tests/CMakeLists.txt` reusing core's GoogleTest; `src/main.cpp` → `runCli`; `.clang-format`/`.clang-tidy` copied from linko-core's; executable `scripts/ci-local.sh`.
- [ ] **Step 6: Run** — presets `macos` and `linux` (Windows exercised in Task 11 CI) → Expected: smoke PASS, core's suites PASS. `scripts/ci-local.sh` green.
- [ ] **Step 7: Append the stack section to linko-server `CLAUDE.md`** — targets, presets, submodule update command, `scripts/ci-local.sh`, ADR-0003 pointer.
- [ ] **Step 8: Commit and PR** — branch `feature/LNK-15-skeleton`; `git add -A && git commit -m "build: server skeleton with linko-core submodule and pinned vcpkg manifest"`; PR to `develop`.

### Task 2: Config, logging, SQLite store with migrations (LNK-16)

**Files:**
- Create: `include/server/config.hpp`, `src/config.cpp`, `include/server/log.hpp`, `src/log.cpp`, `include/server/store.hpp`, `src/store.cpp`, `config.example.json`
- Test: `tests/test_config.cpp`, `tests/test_store.cpp`

**Interfaces:**
- Produces (namespace `server`): `struct Config` — `bind="0.0.0.0"`, `port=443`, `dataDir="data"`, `certFile`, `keyFile`, `turnSecret`, `publicHost="localhost"`, `turnUris` (default `{"turn:<publicHost>:3478?transport=udp","turn:<publicHost>:3478?transport=tcp"}`), `Limits{maxFileBytes=100 MiB, userQuotaBytes=1 GiB, fileTtlDays=30, maxSocketsPerDevice=1, envelopesPerMinute=600, authFailsPerMinute=10, idleTimeoutSec=300, turnTtlSec=3600}` · `auto loadConfig(const std::string &path) -> Config` (unknown key → error naming it; env wins: `LINKO_BIND`, `LINKO_PORT`, `LINKO_DATA_DIR`, `LINKO_TLS_CERT`, `LINKO_TLS_KEY`, `LINKO_TURN_SECRET`, `LINKO_PUBLIC_HOST`).
- `void logRequest(address, method, path, status, durationMs)` / `void logEvent(what, detail)` — write to a swappable sink (tests inject one); the request line is exactly `addr method path status duration_ms`, path without query.
- `class Store { explicit Store(const std::string &dbPath); void migrate(); … }` — SQLite C API only, no exceptions out: `struct Invite { std::string code; std::int64_t expiresAt; }` · `Invite createInvite(std::optional<std::string> user, std::int64_t ttlSeconds)` (code returned once; only `sha256Hex(code)` stored) · `enum class InviteResult { Ok, NotFound, Expired, Used, UserMismatch }` · `InviteResult consumeInvite(code, user)` · `struct Device { std::int64_t id; std::string user; }` · `struct RegisterResult { Device device; std::vector<std::int64_t> revokedDeviceIds; }` · `RegisterResult registerDevice(user, tokenHash, nowMs)` (creates the user if absent; revokes previous devices — one device per user) · `std::optional<Device> deviceByTokenHash(tokenHash)` (absent when revoked) · `bool revokeDevice(user, deviceId, nowMs)` · `std::vector<std::string> listUsers()` · `std::vector<Device> listDevices(user)`.
- Migration runner: embedded numbered SQL applied once, `schema_version` table; migration v1 creates `invites`, `users`, `devices`.

- [ ] **Step 1: Write the failing tests** — config: `test_config_example_parses`, `test_unknown_key_rejected_with_name`, `test_env_overrides_file` (port + turnSecret); log: `test_request_log_line_shape` (exact `addr method path status duration_ms`, query stripped); store: `test_migrate_creates_schema_and_is_idempotent`, `test_invite_roundtrip`, `test_invite_expired`, `test_invite_single_use`, `test_invite_user_mismatch`, `test_register_creates_user_and_device`, `test_register_revokes_previous_device`, `test_device_by_token_hash_revoked_absent`, `test_revoke_device`, `test_invite_stored_hashed_not_plaintext` (raw db file contains no code).
- [ ] **Step 2: Run** — `ctest --preset macos -R "config|store|log"` → Expected: FAIL.
- [ ] **Step 3: Implement** — config parse with nlohmann; store opens SQLite with `SQLITE_OPEN_FULLMUTEX`, `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON`; invite code = `randomHex` (Task 3) — until then a `std::function<std::string()> codeGen` ctor parameter keeps Store testable and non-crypto.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-16-config-store`; `feat: config, structured logging and SQLite store with migrations`.

### Task 3: Crypto helpers, CLI with invites, users and devices (LNK-17)

**Files:**
- Create: `include/server/crypto.hpp`, `src/crypto.cpp`, `vendor/qrcodegen.hpp`, `vendor/qrcodegen.cpp`, `tests/util/test_cert.hpp`
- Modify: `src/cli.cpp` (real commands), `tests/CMakeLists.txt`
- Test: `tests/test_crypto.cpp`, `tests/test_cli.cpp`

**Interfaces:**
- Produces (namespace `server`): `std::string randomHex(std::size_t bytes)` (OpenSSL `RAND_bytes`; throws only if the OS entropy source fails) · `std::string spkiPinOfCertFile(const std::string &pemPath)` — base64(SHA-256(SPKI DER)), the pin apps and invite links carry. Hashing reuses `linko::sha256Hex`; there is deliberately no second digest implementation.
- Vendored `vendor/qrcodegen` (Nayuki QR-Code-generator, MIT, exact release pinned; recorded in ADR-0003 Consequences).
- `runCli` grows real subcommands against `Store`: `invite create [--user <name>] [--ttl-hours N=24] [--host h] [--port p] [--cert <pem>]` → prints `linko://join?host=<host>&port=<port>&pin=<spki>&code=<code>` plus a terminal QR (UTF-8 half-blocks); `user list`; `device list <user>`; `device revoke <user> <id>`. Exit 2 + usage on bad args. `--config` (default `config.json`) selects the db.
- `tests/util/test_cert.hpp`: builds an ephemeral self-signed cert/key pair into a temp dir via the OpenSSL API (no key files ever committed).

- [ ] **Step 1: Write the failing tests** — crypto: `test_random_hex_length_and_charset`, `test_sha256_delegates_to_core` (KAT "abc" via `linko::sha256Hex`), `test_spki_pin_matches_openssl` (pin of the test cert equals `openssl`-recomputed value); cli: `test_invite_create_prints_link_and_qr`, `test_invite_create_stores_hash_only`, `test_invite_ttl_flag`, `test_user_list_prints_users`, `test_device_list_and_revoke`, `test_unknown_command_exits_2`.
- [ ] **Step 2: Run** — `ctest -R "crypto|cli"` → Expected: FAIL.
- [ ] **Step 3: Implement** — vendor qrcodegen at its pinned release; QR rendered as half-block text; every secret printed once to stdout only.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-17-crypto-cli`; `feat: crypto helpers and invite, user and device CLI`.

### Task 4: TLS listener, router and registration endpoint (LNK-18)

**Files:**
- Create: `include/server/http.hpp`, `src/http/router.cpp`, `src/http/listener.cpp`, `src/http/register_handler.cpp`, `include/server/throttle.hpp`, `src/throttle.cpp`
- Modify: `src/cli.cpp` (`run [--config]` starts the server), `tests/CMakeLists.txt`
- Test: `tests/test_http.cpp` (integration: real listener on 127.0.0.1 ephemeral port, ephemeral test cert)

**Interfaces:**
- Produces (namespace `server`): `struct HttpRequest { std::string method, target, body, authorization, address; }` · `struct HttpResponse { int status = 200; std::string body; }` · `using HttpHandler = std::function<HttpResponse(const HttpRequest &)>` · `class Router { void add(method, path, handler); HttpResponse dispatch(const HttpRequest &); }` (404 unknown path, 405 wrong method) · `class Throttle { Throttle(int perMinute, std::function<std::int64_t()> nowMs); bool allow(const std::string &key); }` (sliding window) · `class Listener { Listener(asio::io_context &, ssl::context, Router &); void listen(bind, port); }` (TLS everywhere; one strand per connection; request body cap 64 KiB) · `HttpResponse handleRegister(Store &, Throttle &, const HttpRequest &)` — `POST /api/v1/register` `{"code","username"}`; username = 1–32 chars of `[a-z0-9_.-]`; happy path consumes the invite, `registerDevice(user, sha256Hex(token))` with `token = randomHex(32)`, replies `201 {"user","device","token"}` (token shown this once); `400` malformed JSON / bad username; `403` invite invalid; `429` throttled per address.
- `linko-server run` starts the listener with only `/api/v1/register` wired; every request goes through `logRequest`.

- [ ] **Step 1: Write the failing tests** — `test_register_roundtrip_and_device_can_authenticate` (hash of the returned token resolves via `deviceByTokenHash`), `test_register_rejects_malformed_json`, `test_register_bad_invite_403`, `test_register_bad_username_400`, `test_throttled_after_repeated_failures`, `test_unknown_path_404`, `test_wrong_method_405`, `test_request_log_strips_query`, `test_tls_only_listener` (plain HTTP handshake fails).
- [ ] **Step 2: Run** — `ctest -R http` → Expected: FAIL.
- [ ] **Step 3: Implement** — Beast `ssl_stream` accept loop; handlers are plain functions registered on `Router` with captures; async ops use Asio `awaitable`s or callbacks, one style throughout.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-18-https-register`; `feat: TLS listener, router and invite registration endpoint`.

### Task 5: WebSocket sessions, hub, presence, users and TURN endpoints (LNK-19)

**Files:**
- Create: `include/server/ws_session.hpp`, `include/server/hub.hpp`, `include/server/wire.hpp`, `src/ws/session.cpp`, `src/ws/hub.cpp`, `src/wire.cpp`, `src/http/users_handler.cpp`, `src/http/turn_handler.cpp`
- Modify: `src/cli.cpp` (wire into `run`), `tests/CMakeLists.txt`
- Test: `tests/test_ws.cpp`, `tests/test_turn_users.cpp`

**Interfaces:**
- Produces: `auto makeEnvelope(std::string_view type, nlohmann::json body, std::int64_t nowMs) -> linko::Envelope` (id = `randomHex(16)`, `v = kCurrentVersion`) · `auto toWire(const linko::Envelope &) -> std::string` (`linko::serialize`).
- `class Hub` — `void attach(const Device &, WsSession *)`, `void detach(const Device &)`, `bool send(const std::string &user, std::string_view wire)`, `bool isOnline(user)`, `std::vector<std::string> onlineUsers()`; `attach` closes a previous socket of the same device (close code 4001, `maxSocketsPerDevice=1`).
- `class WsSession` — upgrade on `GET /ws` after `Authorization: Bearer <token>` check (`sha256Hex(token)` → `deviceByTokenHash`, else HTTP 401); text frames only; frame > `linko::kMaxEnvelopeBytes` → close 1009; per-connection window `envelopesPerMinute` → `session.error` + close 4002; idle > `idleTimeoutSec` → close 1000; `session.ping` → `session.pong` (fresh envelope); parse errors → `session.error{code:"invalid_envelope", detail:"<first path>: <message>"}`; `unsupportedVersion` → `session.error{code:"unsupported_version"}` + close; `session.hello` validated against the token's user, mismatch → `session.error` + close 4003; `presence.changed` from a client is ignored (server-owned).
- `class ProtocolSink { virtual void onEnvelope(const std::string &fromUser, const linko::Envelope &, std::int64_t deviceId) = 0; virtual void onSocketDrop(const std::string &user) = 0; }` — the session dispatches `call.*`/`file.*` to the registry sink and `msg.*` to the messaging sink (injected; until Tasks 6–7 land, both default to a drop-all sink).
- Presence: `attach`/`detach` broadcast `presence.changed{user, online}` to every online user (v0.1 has a single-digit user base; conversation scoping is roadmap).
- `GET /api/v1/users?prefix=` (Bearer) → `{"users":[…]}` prefix match, max 20, sorted; `GET /api/v1/turn` (Bearer) → `{"username":"<unix-expiry>:<user>","credential":base64(HMAC-SHA1(turnSecret, username)),"ttlSec":…,"urls":[…]}` (TURN REST scheme, spec §4.6; expiry = now + `turnTtlSec`).

- [ ] **Step 1: Write the failing tests** — `test_ws_auth_and_presence_broadcast`, `test_bad_token_rejected`, `test_revoked_device_socket_closed` (re-register via HTTP while the old socket is open → old socket gets 4001), `test_ping_gets_pong`, `test_oversized_frame_closes`, `test_rate_limited_connection_closed`, `test_idle_connection_closed` (injected clock), `test_unsupported_version_gets_error_and_close`, `test_malformed_envelope_answered_with_error`, `test_hello_mismatch_closes`, `test_users_prefix_search`, `test_users_requires_auth`, `test_turn_credential_verifies` (recompute the HMAC in the test), `test_turn_secret_from_env`.
- [ ] **Step 2: Run** — `ctest -R "ws|turn|users"` → Expected: FAIL.
- [ ] **Step 3: Implement** — Beast websocket over the TLS stream; one `WsSession` per upgraded connection; timers via `asio::steady_timer` with an injectable clock for tests.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-19-ws-sessions`; `feat: websocket sessions, presence, users search and TURN credentials`.

### Task 6: Call registry and signaling router (LNK-20)

**Files:**
- Create: `include/server/call_registry.hpp`, `src/call_registry.cpp`
- Modify: `src/cli.cpp` (sink wiring), `tests/CMakeLists.txt`
- Test: `tests/test_call_registry.cpp`

**Interfaces:**
- Consumes: `Hub::send`, `ProtocolSink`, core `applyEvent`/`CallEvent`/`Effect`, `kType*` names, `kRingTimeoutMs`/`kConnectTimeoutMs`.
- Produces: `class CallRegistry : public ProtocolSink { CallRegistry(Hub &, Config::Limits, std::function<std::int64_t()> nowMs, asio::any_io_executor timers); void onEnvelope(fromUser, env, deviceId) override; void onSocketDrop(user) override; }`.
- Semantics: one core `CallState` per `callId` (caller perspective: the caller's `call.invite` feeds `LocalInvite`). Wire→event mapping: `call.ringing`→`RemoteRinging`, `call.accept`→`RemoteAccept`, `call.reject`→`RemoteReject`, `call.busy`→`RemoteBusy`, `call.cancel`→`RemoteCancel`, `call.hangup`→`RemoteHangup`; `call.offer`/`call.answer`/`call.ice`/`call.ice-restart` and `file.*` are forwarded to the peer unchanged without machine input (the server never sees ICE state). Effects: `SendMessage` → forward the original wire bytes to the peer; `StartTimer`/`CancelTimer` → `asio::steady_timer` per call feeding `TimerRingExpired`/`TimerConnectExpired` (`TimerReconnectExpired` is client-side only); the CallKit/ringing/ICE-restart effects are client-side and ignored here. The header comment documents the effect→callId host mapping: effects carry no `callId`; every host addresses them to its own machine's `callId`.
- Busy: an invite to a user in a live call (their state ∉ {Idle, Ended}) → `call.busy{callId}` back to the caller, nothing forwarded. Ring timeout: the machine ends (Missed) and the registry itself sends `call.cancel{callId}` (server-built envelope) to the callee. Socket drop: every live call of that user gets a synthesized `RemoteHangup`, the peer receives `call.hangup`, timers disarm.

- [ ] **Step 1: Write the failing tests** — `test_invite_routed_to_callee`, `test_ringing_accept_reach_caller`, `test_duplicate_accept_forwarded_once`, `test_no_glare_on_caller_side` (the registry holds one machine per call; the caller never emits `call.accept`), `test_busy_rejected_when_callee_in_call`, `test_ring_timeout_sends_cancel_and_cleans_up` (injected clock), `test_socket_drop_ends_calls_and_notifies_peer`, `test_late_hangup_after_ended_ignored`, `test_sdp_and_file_messages_forwarded_byte_identical`, `test_events_for_unknown_call_ignored`.
- [ ] **Step 2: Run** — `ctest -R call_registry` → Expected: FAIL.
- [ ] **Step 3: Implement** — a `std::unordered_map<std::string /*callId*/, Call>` where `Call{ CallState state; std::string caller, callee; std::optional<steady_timer> ring, connect; }`; forwarding reuses the exact received `Envelope` (`toWire` of the parsed one) — no rebuilding of peer-authored bodies.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-20-call-registry`; `feat: call registry on the core state machine with timers and cleanup`.

### Task 7: Messaging: seq assignment, offline delivery, receipts, sync (LNK-21)

**Files:**
- Create: `include/server/messaging.hpp`, `src/messaging.cpp`
- Modify: `include/server/store.hpp`, `src/store.cpp` (migration v2), `src/cli.cpp`, `tests/CMakeLists.txt`
- Test: `tests/test_messaging.cpp`

**Interfaces:**
- Consumes: `ProtocolSink`, `Hub`, `linko::MsgSend/MsgStored/MsgDeliver/MsgAck/MsgSync/MessageRecord`.
- Produces: `auto conversationKey(a, b) -> std::string` (lexicographic `min + '\x1f' + max`) · `class Messaging : public ProtocolSink { Messaging(Store &, Hub &, std::function<std::int64_t()> nowMs); void onEnvelope(…) override; void onConnect(const std::string &user); }`.
- Store grows (migration v2: `messages` with `UNIQUE(conv, seq)` and `PRIMARY KEY(id)`, `receipts(conv, holder, counterpart, delivered_upto, read_upto)`): `std::optional<MessageRecord> storeMessage(MessageRecord)` (nullopt + the original record on a duplicate id — idempotent sends) · `std::vector<MessageRecord> messagesAfter(conv, afterSeq)` · `void advanceReceipts(conv, holder, counterpart, deliveredUpto, readUpto)` (monotonic; lower values ignored) · `std::pair<std::int64_t, std::int64_t> receiptsOf(conv, holder, counterpart)`.
- `msg.send`: unknown recipient → `session.error{code:"user_not_found"}` to the sender, not stored; otherwise seq = `MAX(seq)+1` per conversation inside one `BEGIN IMMEDIATE` transaction, `ts` = server time, `msg.stored{id, seq, ts}` to the sender (original seq/ts on duplicates), `msg.deliver{message}` to the peer when online. `msg.ack-delivered`/`msg.ack-read`: advance the holder's watermarks and forward the envelope unchanged to the counterpart. `msg.sync`: one `msg.deliver` per stored message after `afterSeq`, in seq order. `onConnect(user)`: per conversation, everything above the holder's delivered watermark is pushed in seq order.

- [ ] **Step 1: Write the failing tests** — `test_send_stored_and_delivered_online`, `test_duplicate_send_returns_original_seq`, `test_seq_monotonic_across_directions` (both users share one sequence), `test_offline_delivered_in_seq_order_on_connect`, `test_ack_forwarded_and_watermarks_advance`, `test_receipts_never_regress`, `test_sync_after_seq`, `test_send_to_unknown_user_rejected`.
- [ ] **Step 2: Run** — `ctest -R messaging` → Expected: FAIL.
- [ ] **Step 3: Implement** — `Messaging` is transport-agnostic logic over `Store` + `Hub`; no SQL outside `Store`.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-21-messaging`; `feat: message storage, seq assignment, offline delivery and receipts`.

### Task 8: File storage over HTTPS and TTL cleanup (LNK-22)

**Files:**
- Create: `include/server/file_store.hpp`, `src/file_store.cpp`, `src/http/files_handler.cpp`, `src/cleanup.cpp`
- Modify: `include/server/store.hpp`, `src/store.cpp` (migration v3), `src/call_registry.cpp` (file.offer cap), `src/cli.cpp`, `tests/CMakeLists.txt`
- Test: `tests/test_files.cpp`

**Interfaces:**
- Consumes: `Config::Limits.maxFileBytes/userQuotaBytes/fileTtlDays`, `Store`, `Hub`.
- Produces: Store migration v3 `files(id, owner, size, sha256, created_at, path)` with `std::optional<FileRow> fileInfo(id)`, `void addFile(FileRow)`, `std::vector<std::string> filesOlderThan(cutoffMs)`, `void deleteFile(id)`, `std::uint64_t quotaUsed(user)` · `class FileStore { FileStore(dataDir); void write(id, sink of body); std::ifstream open(id); void remove(id); }` (disk under `dataDir/files/<id>`) · handlers: `PUT /api/v1/files` (Bearer; requires Content-Length — 411 absent, 413 over `maxFileBytes`, 507 over `userQuotaBytes`; streams to disk computing SHA-256 on the fly; replies `201 {"fileId","sha256","size"}` — the client puts these into the message's `FileMeta{transport:"server"}`) · `GET /api/v1/files/{id}` (Bearer; 404 unknown; streams bytes with `X-Linko-Sha256`) · cleanup at startup and every 24 h deletes rows + files older than `fileTtlDays`.
- `file.offer` cap in the registry: `manifest.size > maxFileBytes` → `session.error{code:"file_too_large"}` to the sender, nothing forwarded — the same cap makes `chunkCount` at 100 MB equal 6400 (16 KiB chunks), far below `UINT32_MAX`, closing the Plan-2 wrap note.

- [ ] **Step 1: Write the failing tests** — `test_upload_download_roundtrip`, `test_upload_returns_sha256_and_size`, `test_file_over_cap_rejected_413`, `test_upload_without_length_411`, `test_quota_exceeded_507`, `test_get_unknown_404`, `test_upload_requires_auth`, `test_expired_files_removed` (injected clock), `test_file_offer_over_cap_rejected` (registry), `test_chunk_count_at_cap_fits_uint32` (6400 via `linko::makeManifest`).
- [ ] **Step 2: Run** — `ctest -R files` → Expected: FAIL.
- [ ] **Step 3: Implement** — streaming reads (no whole-file buffering; `read_some` loop into the digest + disk); upload ids are `randomHex(16)`.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-22-files`; `feat: server-side file storage with quota and TTL cleanup`.

### Task 9: Call reports endpoint and calls CLI (LNK-23) *(cut candidate #2)*

**Files:**
- Create: `src/http/report_handler.cpp`
- Modify: `include/server/store.hpp`, `src/store.cpp` (migration v4), `src/cli.cpp`, `tests/CMakeLists.txt`
- Test: `tests/test_reports.cpp`

**Interfaces:**
- Produces: Store migration v4 `call_reports(call_id, from_user, received_at, report_json)` with `void addCallReport(callId, fromUser, nowMs, json)`, `std::vector<CallReportRow> callReports()` · handler `POST /api/v1/calls/{callId}/report` (Bearer; body must be a JSON object ≤ 8 KiB; `204` on success, `400` non-JSON/oversized) · CLI `calls list` (rows: callId, from, received, duration/setupMs/candidate/endReason read from the stored JSON) and `calls show <callId>` (full JSON).

- [ ] **Step 1: Write the failing tests** — `test_report_stored`, `test_report_requires_auth`, `test_report_rejects_non_json`, `test_report_rejects_oversized`, `test_calls_list_prints_rows`, `test_calls_show_prints_report`.
- [ ] **Step 2: Run** — `ctest -R reports` → Expected: FAIL.
- [ ] **Step 3: Implement** — reports are stored as-is after validation; the CLI derives its columns with nlohmann lookups.
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-23-reports`; `feat: call quality reports endpoint and calls CLI`.

### Task 10: cert generate, deploy runbook and e2e checklist (LNK-24) *(owner-in-loop)*

**Files:**
- Create: `src/cert.cpp`, `scripts/deploy.ps1`, `docs/deploy.md`, `docs/e2e-checklist.md`
- Modify: `src/cli.cpp`, `tests/CMakeLists.txt`
- Test: `tests/test_cert.cpp`

**Interfaces:**
- Produces: `cert generate [--out <dir>]` — ECDSA P-256 self-signed certificate (CN=linko, 3650 days) via OpenSSL; the key is written owner-only (POSIX 0600; on Windows a thin ACL wrapper — the one allowed WinAPI use); the certificate is world-readable; the SPKI pin is printed to stdout. `scripts/deploy.ps1` runs **on the VPS**: configure + build (`cmake --preset windows`, vcpkg), (re)register the `LinkoServer` Windows service via `sc.exe`, restart it. `docs/deploy.md`: firewall (server port, TURN UDP/TCP 3478, relay 49160–49200 per ADR-0001), vcpkg bootstrap, cert generation on the VPS (the key never leaves it), first invite, service config, log location. `docs/e2e-checklist.md`: the server-side rows of spec §10 items 1, 2, 7, 8, 9. Tag-triggered CI deploy stays roadmap (applied cut #1).
- The VPS steps are executed together with the owner; nothing here auto-touches the VPS.

- [ ] **Step 1: Write the failing tests** — `test_cert_generate_creates_owner_only_key`, `test_cert_is_self_signed_p256`, `test_cert_pin_printed` (recompute `spkiPinOfCertFile` and compare with stdout).
- [ ] **Step 2: Run** — `ctest -R cert` → Expected: FAIL.
- [ ] **Step 3: Implement** the CLI command + docs + `deploy.ps1` (PowerShell, no secrets in it — paths and config only).
- [ ] **Step 4: Run** — Expected: PASS; `scripts/ci-local.sh` green.
- [ ] **Step 5: Commit** — branch `feature/LNK-24-cert-deploy`; `feat: certificate generation, deploy runbook and e2e checklist`.

### Task 11: CI, coverage gate and README (LNK-25)

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md` (linko-server)

**Interfaces:**
- Consumes: presets and `scripts/ci-local.sh` (Task 1), all suites (Tasks 2–10).

- [ ] **Step 1: Write `ci.yml`** — jobs `windows` (vcpkg cache, preset `windows`, ctest) and `macos` (Homebrew deps with cache, preset `macos`, ctest), both `pull_request` against `develop`/`main` only; `coverage` (macOS, llvm-cov line coverage of `server_lib` sources, fail under 80 %); `lint` (`ubuntu-latest`: `clang-format --dry-run --Werror`, clang-tidy). The gitleaks workflow stays untouched.
- [ ] **Step 2: Verify locally** — `scripts/ci-local.sh` fully green; push branch, draft PR, all jobs green, mark ready.
- [ ] **Step 3: Rewrite `README.md`** — purpose, architecture text diagram (from spec §4), module map (listener/router, ws sessions/hub, call registry, messaging, files, store, CLI), configuration table (JSON keys + `LINKO_*` env), ops pointers (`docs/deploy.md`, linko-apple `docs/turn-setup.md`), wire-contract notes (hex digests are lowercase by core convention — pinned here for any future third-party client), roadmap (tag-triggered deploy, conversation-scoped presence, multi-device).
- [ ] **Step 4: Commit and PR** — branch `feature/LNK-25-ci-readme`; `ci: windows and macos builds, coverage gate and lint`; PR to `develop` after `ci-local.sh` and the PR checklist pass.

---

## Self-review notes

- Spec §4.5 coverage: endpoints table — register (T4), `/ws` (T5), turn (T5), files (T8), calls report (T9), users (T5); server logic (T6–T7); storage + migrations (T2, T7–T9); limits (T2 config, T5 rate/idle, T8 cap/quota/TTL); CLI invite/device/user (T3), calls (T9), cert (T10); config JSON + env (T2). §4.6 TURN REST credentials (T5). §6 secret rules (T2 example config, T4 auth, T10 cert/ACL + deploy docs). §7 coverage ≥ 80 % + warnings (T1, T11). §8 deploy (T10, cut #1 applied; CI T11). §10 server-side items 1, 2, 7, 8, 9 (T7 offline delivery, T10 checklist).
- Plan-2 handoff checklist: registry glare echo (T6 `test_no_glare_on_caller_side`, one machine per call), effect→callId host mapping documented (T6 header), socket drop → synthesized `RemoteHangup` (T6), 100 MB cap incl. the chunkCount wrap note (T8), lowercase-hex wire contract pinned in the README (T11).
- Task 1 spans three repos by necessity (release tag → submodule pin); Tasks 2–11 stay inside linko-server except ADR PRs.
- Proportion: interfaces, semantics tables and test names are the contract; bodies stay with the implementers.
