# ADR-0003: linko-server dependencies (Boost.Beast, OpenSSL, SQLite3)

- Status: accepted
- Date: 2026-11-15

## Context

`linko-server` needs HTTP + WebSocket with TLS on one port, storage, and crypto helpers — capabilities `linko-core` deliberately does not carry (design spec §4.5). The server product runs on Windows (the VPS); macOS and Linux are development hosts only. `linko-core` arrives as a git submodule pinned to tag `v0.1.0` and brings its own dependency set via FetchContent (ADR-0002: GoogleTest `v1.18.0`, nlohmann/json `v3.12.0`).

## Decision

Boost.Beast (which brings Boost.Asio), OpenSSL and SQLite3, resolved per host:

- **Windows (product): vcpkg manifest** (`linko-server/vcpkg.json`) with exact version pins and a pinned `builtin-baseline`:

  | Dependency | Version | Port-version |
  |---|---|---|
  | boost-beast | 1.92.0 | 0 |
  | openssl | 3.6.5 | 2 |
  | sqlite3 | 3.54.1 | 0 |

  `builtin-baseline`: `4702e381dbbd9b54d3f7e1eb565cd8981c1814cd` (microsoft/vcpkg `master`). Versions were read from the port manifests at exactly that baseline commit, so the manifest and the baseline pin each other.
- **macOS / Linux (dev): Homebrew** (`boost`, `openssl@3`, `sqlite`), wired into the `macos` CMake preset via prefix hints. Homebrew bottles move underneath us — versions are not pinned exactly there. **Trade-off, accepted:** dev-host builds may pick up slightly newer dependency versions than the product; the authoritative, byte-pinned build is the Windows one, which is the only one that ships.

### Why these libraries

- **Boost.Beast/Asio** — HTTP + WebSocket + async I/O from one source tree, no second event loop; TLS composes through `asio::ssl::stream`.
- **OpenSSL** — TLS termination, `RAND_bytes` for tokens/ids, HMAC-SHA1 for the TURN REST credentials (spec §4.6), and the self-signed certificate generator (`cert generate`, spec §6).
- **SQLite3** — embedded storage with WAL; the C API is used directly behind the server's `Store` class (no ORM layer).

## Consequences

- **No new package-manager surface on Windows beyond vcpkg itself**; the manifest mode (`vcpkg.json` + `builtin-baseline`) makes CI and local builds resolve identical versions.
- **nlohmann/json is not re-declared** here: it arrives transitively through the `linko_core` CMake target, which links it `PUBLIC` (ADR-0002). The server's headers may keep using it without a second copy in `vcpkg.json`.
- **qrcodegen is vendored**, not packaged: the terminal QR code for `invite create` links (spec §4.5) comes from a vendored single-purpose copy of Nayuki's QR-Code-generator (MIT) under `linko-server/vendor/`, pinned to an exact release — same pattern as `linko-core`'s vendored SHA-256 (recorded in ADR-0002's consequences). No vcpkg port needed.
- **Hashing stays with the core**: device tokens and invite codes are hashed with `linko::sha256Hex`; the server does not introduce a second digest implementation.
- Upgrading any of the three libraries goes through a PR that updates `vcpkg.json` (and this ADR's table).
