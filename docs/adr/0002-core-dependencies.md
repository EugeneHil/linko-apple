# ADR-0002: linko-core dependencies (GoogleTest, nlohmann/json)

- Status: accepted
- Date: 2026-11-14

## Context

`linko-core` is the pure C++17 core shared by the Windows server and the Apple apps (design spec §4.2). It needs a JSON parser for the protocol envelopes and a test framework, and the same tree must build on macOS, Windows and (dev only) Linux via CMake presets without a platform package manager in the loop.

## Decision

Fetch both dependencies with CMake `FetchContent`, pinned to exact release tags in `linko-core/cmake/Dependencies.cmake` (no vcpkg, no Swift Package Manager in this repo):

- GoogleTest `v1.18.0` (latest stable release at the time of writing, verified on GitHub)
- nlohmann/json `v3.12.0` (latest stable release at the time of writing, verified on GitHub)

Both are declared `EXCLUDE_FROM_ALL` and `SYSTEM`, so only what `linko_core` and its tests actually link against gets built, and the dependency headers never trip the repo's warnings-as-errors flags.

## Consequences

- No transitive dependency manager: the dependency set is exactly the two pins above, and builds are reproducible from the pinned tags.
- Upgrades go through a PR that changes the `GIT_TAG` plus a note in this ADR.
- The first configure downloads the dependency sources, so it needs network access; CI should cache the build tree.
