#!/usr/bin/env bash
# Local CI for linko-apple (Plan 4 Task 1): SwiftFormat lint, SwiftLint
# strict, then tuist generate and the module test targets on the iOS
# simulator and on macOS. Task 3 (LNK-29) added the design-token freshness
# check and the DesignSystem test targets; Task 14 (LNK-40) extends this
# script with the coverage gate.
#
# Usage: Scripts/ci-local.sh
#   IOS_SIMULATOR_UDID env var overrides the picked device (default: the
#   first available iPhone simulator).
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
cd "$repo"

echo "== SwiftFormat lint"
swiftformat --lint .

echo "== SwiftLint strict"
swiftlint --strict

echo "== Design tokens freshness"
Scripts/check-tokens.sh

echo "== tuist generate"
mise exec -- tuist generate

ios_udid=${IOS_SIMULATOR_UDID:-}
if [ -z "$ios_udid" ]; then
  ios_udid=$(xcrun simctl list devices available |
    sed -n 's/^ *iPhone[^)]* (\([0-9A-F-]*\)) (Shutdown) */\1/p' | head -n 1)
fi
if [ -z "$ios_udid" ]; then
  echo "ci-local: no available iPhone simulator found" >&2
  exit 1
fi

echo "== CoreBridge tests on the iOS simulator ($ios_udid)"
# The UDID form avoids the multi-runtime name ambiguity and survives Tuist's
# destination forwarding (name-based destinations are filtered out).
mise exec -- tuist test CoreBridgeTests -- -destination "id=$ios_udid"

echo "== CoreBridge tests on macOS"
mise exec -- tuist test CoreBridgeMacTests -- -destination "platform=macOS"

echo "== DesignSystem tests on the iOS simulator ($ios_udid)"
mise exec -- tuist test DesignSystemTests -- -destination "id=$ios_udid"

echo "== DesignSystem tests on macOS"
mise exec -- tuist test DesignSystemMacTests -- -destination "platform=macOS"

echo "== Messaging tests on the iOS simulator ($ios_udid)"
mise exec -- tuist test MessagingTests -- -destination "id=$ios_udid"

echo "== Messaging tests on macOS"
mise exec -- tuist test MessagingMacTests -- -destination "platform=macOS"

echo "== Signaling tests on the iOS simulator ($ios_udid)"
mise exec -- tuist test SignalingTests -- -destination "id=$ios_udid"

echo "== Signaling tests on macOS"
mise exec -- tuist test SignalingMacTests -- -destination "platform=macOS"

echo "== ServerAPI tests on the iOS simulator ($ios_udid)"
mise exec -- tuist test ServerAPITests -- -destination "id=$ios_udid"

echo "== ServerAPI tests on macOS"
mise exec -- tuist test ServerAPIMacTests -- -destination "platform=macOS"

echo "== CallEngine tests on the iOS simulator ($ios_udid)"
mise exec -- tuist test CallEngineTests -- -destination "id=$ios_udid"

echo "== CallEngine tests on macOS"
mise exec -- tuist test CallEngineMacTests -- -destination "platform=macOS"

echo "ci-local: OK"
