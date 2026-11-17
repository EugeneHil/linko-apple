#!/usr/bin/env bash
# Builds the linko-core submodule (tag v0.1.0) into a static library for one
# Apple destination (ADR-0004; xcframework alternative rejected there).
#
# Usage: Scripts/build-core.sh <macosx|iphoneos|iphonesimulator>
#   (the Tuist pre-build action on CoreBridge passes "$(PLATFORM_NAME)")
#
# Output: Derived/core/<destination>/liblinko_core.a, plus the FetchContent
# _deps/nlohmann_json-src/single_include headers the core's envelope.hpp
# pulls in and CoreBridge's Objective-C++ sources need.
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
core="$repo/external/linko-core"
destination=${1:-}

# Xcode script phases run with a minimal PATH; cmake and ninja come from
# Homebrew when they are not already on PATH (both prefixes probed).
if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  for brew_bin in /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$brew_bin" ]; then
      PATH="$brew_bin:$PATH"
      export PATH
    fi
  done
fi
command -v cmake >/dev/null 2>&1 || { echo "build-core.sh: cmake not found" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "build-core.sh: ninja not found" >&2; exit 1; }

case "$destination" in
  macosx | iphoneos | iphonesimulator) ;;
  *)
    echo "usage: Scripts/build-core.sh <macosx|iphoneos|iphonesimulator>" >&2
    exit 2
    ;;
esac

if [ ! -f "$core/CMakeLists.txt" ]; then
  echo "build-core.sh: external/linko-core is missing" >&2
  echo "  run: git submodule update --init external/linko-core" >&2
  exit 1
fi

outdir="$repo/Derived/core/$destination"
mkdir -p "$outdir"

# Configure once per destination, then rebuild incrementally. Only the static
# library is built: the core's tests run in the submodule's own repository.
if [ ! -f "$outdir/CMakeCache.txt" ]; then
  cmake -S "$core" -B "$outdir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$destination" \
    -DCMAKE_OSX_ARCHITECTURES=arm64
fi

cmake --build "$outdir" --target linko_core

test -f "$outdir/liblinko_core.a"
echo "build-core.sh: $outdir/liblinko_core.a up to date"
