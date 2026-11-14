# ADR-0002: linko-core dependencies (GoogleTest, nlohmann/json)

- Status: accepted
- Date: 2026-11-14

## Context

`linko-core` is the pure C++17 core shared by the Windows server and the Apple apps (design spec §4.2). It needs a JSON parser for the protocol envelopes and a test framework, and the same tree must build on macOS, Windows and (dev only) Linux via CMake presets without a platform package manager in the loop.

## Decision

Fetch both dependencies with CMake `FetchContent`, pinned to GitHub release tarballs (`URL` + `URL_HASH SHA256=...`) in `linko-core/cmake/Dependencies.cmake` (no vcpkg, no Swift Package Manager in this repo):

- GoogleTest `v1.18.0` (latest stable release at the time of writing, verified on GitHub)
  - URL: `https://github.com/google/googletest/archive/refs/tags/v1.18.0.tar.gz`
  - SHA256: `6e3191c1455468b3fc35a417fb565c1c5071aee1b7e7f85e30cf48a98d37d8b5`
- nlohmann/json `v3.12.0` (latest stable release at the time of writing, verified on GitHub)
  - URL: `https://github.com/nlohmann/json/archive/refs/tags/v3.12.0.tar.gz`
  - SHA256: `4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187`

Both hashes were computed from the actual archives (`curl -L <url> | shasum -a 256`, cross-checked against a file download with `gzip -t`).

Both are declared `EXCLUDE_FROM_ALL` and `SYSTEM`, so only what `linko_core` and its tests actually link against gets built, and the dependency headers never trip the repo's warnings-as-errors flags.

### Tarballs instead of git clones (2026-11-14 update)

The first version of this decision pinned `GIT_REPOSITORY`/`GIT_TAG` with `GIT_SHALLOW`. That was switched to release tarballs with `URL_HASH` because:

- Fetching a tarball is a single HTTP download per dependency; a `git clone` spawned by FetchContent hung in local runs, while the tarball fetch takes seconds.
- `URL_HASH` is the strongest pinning CMake offers: configure fails with a hash mismatch if a single downloaded byte differs from the recorded SHA256 (verified by intentionally corrupting the hash and watching configure fail). Git tags, in contrast, are mutable pointers.

## Consequences

- No transitive dependency manager: the dependency set is exactly the two pins above, and builds are reproducible from the pinned tarball hashes.
- Upgrades go through a PR that changes the `URL` (new tag) and `URL_HASH` (new SHA256) plus a note in this ADR.
- The first configure downloads the dependency archives, so it needs network access (HTTP to github.com; no git required); CI should cache the build tree.
- GitHub's auto-generated release archives are byte-stable in practice but not contractually guaranteed; if GitHub ever regenerates an archive, configure fails loudly on the hash mismatch and the fix is to re-record the new SHA256 here and in `cmake/Dependencies.cmake` — sources can never change silently.
