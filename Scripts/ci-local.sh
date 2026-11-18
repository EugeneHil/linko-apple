#!/usr/bin/env bash
# Local CI for linko-apple (Plan 4 Task 1): SwiftFormat lint, SwiftLint
# strict, then tuist generate and the module test targets on the iOS
# simulator and on macOS. Task 3 (LNK-29) added the design-token freshness
# check and the DesignSystem test targets.
#
# Task 14 (LNK-40) hardens every test invocation against the hollow gate:
# in the verified PR-#24 run all 15 suites printed "The scheme X's test
# action has no tests to run, finishing early." and this script still
# exited 0. run_suite now inspects each invocation's captured output and
# fails loudly on (a) "no tests to run", (b) a missing "Executed N tests"
# summary, (c) an "Executed 0 tests" summary or (d) any failures. It also
# adds the coverage step: the logic-target suites run again with code
# coverage enabled and every gated target must reach 80 % line coverage
# (spec 7). macOS coverage is deliberately not collected — the gated logic
# targets are shared multiplatform code already exercised by the iOS run,
# and one coverage-enabled simulator run keeps the minutes budget sane.
#
# Usage: Scripts/ci-local.sh [--coverage] [--no-lint]
#   --coverage: only tuist generate plus the coverage-enabled logic-target
#     run and the 80 % gate (what the CI coverage job runs); without it the
#     full battery above runs.
#   --no-lint: skip the SwiftFormat/SwiftLint checks (what the CI macos job
#     runs — lint is gated by the pinned ubuntu lint job, so the macOS job
#     does not duplicate it with an unpinned brew toolchain).
#   IOS_SIMULATOR_UDID env var overrides the picked device (default: the
#   first available iPhone simulator).
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
cd "$repo"

# Per-invocation logs live in a fresh temp dir; a failing run keeps its
# logs for debugging (the messages below name the file), a passing run
# deletes them at the end.
log_dir=$(mktemp -d "${TMPDIR:-/tmp}/ci-local.XXXXXX")

run_suite() {
  local scheme=$1
  shift
  local log="$log_dir/$scheme.log"
  # pipefail: the pipeline (and the if) fails when tuist test fails.
  if ! mise exec -- tuist test "$scheme" "$@" 2>&1 | tee "$log"; then
    echo "ci-local: FAIL: 'tuist test $scheme' exited non-zero (log: $log)" >&2
    exit 1
  fi
  if grep -q "no tests to run" "$log"; then
    echo "ci-local: HOLLOW GATE: $scheme ran no tests (\"no tests to run\") (log: $log)" >&2
    exit 1
  fi
  # The last summary line is the final "All tests" verdict, e.g.
  # "Executed 12 tests, with 0 failures (0 unexpected) in 3.4 (12.3) seconds".
  local executed
  executed=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$log" | tail -n 1 || true)
  if [ -z "$executed" ]; then
    echo "ci-local: NO EXECUTION EVIDENCE: $scheme printed no 'Executed N tests' summary (log: $log)" >&2
    exit 1
  fi
  local count failures
  count=$(printf '%s' "$executed" | sed -nE 's/.*Executed ([0-9]+) tests?, with .*/\1/p')
  failures=$(printf '%s' "$executed" | sed -nE 's/.*, with ([0-9]+) failures?.*/\1/p')
  if [ -z "$count" ] || [ "$count" -eq 0 ]; then
    echo "ci-local: HOLLOW GATE: $scheme executed no tests ($executed)" >&2
    exit 1
  fi
  if [ -z "$failures" ]; then
    echo "ci-local: FAIL: $scheme — unparseable summary line: $executed" >&2
    exit 1
  fi
  if [ "$failures" -ne 0 ]; then
    echo "ci-local: FAIL: $scheme — $executed" >&2
    exit 1
  fi
  printf 'ci-local: %s: %s\n' "$scheme" "$executed"
}

pick_ios_simulator() {
  ios_udid=${IOS_SIMULATOR_UDID:-}
  if [ -z "$ios_udid" ]; then
    ios_udid=$(xcrun simctl list devices available |
      sed -n 's/^ *iPhone[^)]* (\([0-9A-F-]*\)) (Shutdown) */\1/p' | head -n 1)
  fi
  if [ -z "$ios_udid" ]; then
    echo "ci-local: no available iPhone simulator found" >&2
    exit 1
  fi
}

coverage_mode=false
no_lint=false
for arg in "$@"; do
  case "$arg" in
    --coverage) coverage_mode=true ;;
    --no-lint) no_lint=true ;;
    *)
      echo "ci-local: unknown flag: $arg (expected --coverage or --no-lint)" >&2
      exit 2
      ;;
  esac
done

echo "== Design tokens freshness"
Scripts/check-tokens.sh

echo "== tuist install"
# Fetches the Tuist/Package.swift external dependencies (WebRTC, GRDB) into
# the SwiftPM cache; without it a fresh checkout fails generate with "We
# could not find external dependencies" (the first CI round did exactly
# that). A resolved cache makes this a fast confirmation.
mise exec -- tuist install

echo "== tuist generate"
mise exec -- tuist generate --no-open

pick_ios_simulator

if $coverage_mode; then
  # Task 14 (LNK-40): one coverage-enabled run per gated logic suite on the
  # iOS simulator. The gate targets are the Swift logic modules — view
  # models, coordinators, services and policy/stats (spec 7): Calls,
  # CallStats, Messaging, ServerAPI and the five feature modules. Outside
  # the gate: CoreBridge (the ObjC++ seam around the vendored C++ core,
  # exercised by its own exhaustive suites), DesignSystem (generated
  # tokens), the app shells and the test bundles themselves.
  gate_targets="Calls CallStats Messaging ServerAPI Onboarding Chats Conversation Call Settings"
  coverage_dir=${COVERAGE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/linko-coverage.XXXXXX")}
  mkdir -p "$coverage_dir"

  for target in $gate_targets; do
    suite="${target}Tests"
    echo "== Coverage run: $suite on the iOS simulator ($ios_udid)"
    run_suite "$suite" -T "$coverage_dir/$suite.xcresult" -- \
      -destination "id=$ios_udid" -enableCodeCoverage YES
  done

  echo "== Coverage gate (>= 80 % lines per logic target)"
  report="$coverage_dir/coverage-report.txt"
  python3 - "$coverage_dir" "$report" <<'PY'
import json, os, subprocess, sys

cov_dir, report_path = sys.argv[1], sys.argv[2]
targets = ["Calls", "CallStats", "Messaging", "ServerAPI",
           "Onboarding", "Chats", "Conversation", "Call", "Settings"]
threshold = 80.0

rows, failures = [], []
for target in targets:
    bundle = os.path.join(cov_dir, f"{target}Tests.xcresult")
    raw = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", bundle],
                         capture_output=True, text=True, check=True).stdout
    found = {t["name"]: t for t in json.loads(raw)["targets"]}
    stats = found.get(target)
    if stats is None:
        failures.append(f"{target}: no coverage row (xcresult had: {', '.join(sorted(found)) or 'none'})")
        rows.append(f"{target:<14} MISSING")
        continue
    pct = stats["lineCoverage"] * 100.0
    covered, total = stats["coveredLines"], stats["lineCount"]
    verdict = "OK" if pct >= threshold else "UNDER"
    rows.append(f"{target:<14} {covered:>5}/{total:<5} lines  {pct:6.2f} %  {verdict}")
    if pct < threshold:
        failures.append(f"{target}: {pct:.2f} % line coverage (gate {threshold:.0f} %)")

table = "\n".join(["target          lines            coverage"] + rows)
print(table)
with open(report_path, "w") as f:
    f.write(table + "\n")
if failures:
    for f in failures:
        print(f"ci-local: COVERAGE GATE FAILED: {f}")
    sys.exit(1)
print(f"ci-local: coverage gate passed for all {len(targets)} logic targets")
PY

  rm -rf "$log_dir"
  echo "ci-local: OK (coverage gate; report: $report)"
  exit 0
fi

if ! $no_lint; then
  echo "== SwiftFormat lint"
  swiftformat --lint .

  echo "== SwiftLint strict"
  swiftlint --strict
fi

echo "== CoreBridge tests on the iOS simulator ($ios_udid)"
# The UDID form avoids the multi-runtime name ambiguity and survives Tuist's
# destination forwarding (name-based destinations are filtered out).
run_suite CoreBridgeTests -- -destination "id=$ios_udid"

echo "== CoreBridge tests on macOS"
run_suite CoreBridgeMacTests -- -destination "platform=macOS"

echo "== DesignSystem tests on the iOS simulator ($ios_udid)"
run_suite DesignSystemTests -- -destination "id=$ios_udid"

echo "== DesignSystem tests on macOS"
run_suite DesignSystemMacTests -- -destination "platform=macOS"

echo "== Messaging tests on the iOS simulator ($ios_udid)"
run_suite MessagingTests -- -destination "id=$ios_udid"

echo "== Messaging tests on macOS"
run_suite MessagingMacTests -- -destination "platform=macOS"

echo "== Signaling tests on the iOS simulator ($ios_udid)"
run_suite SignalingTests -- -destination "id=$ios_udid"

echo "== Signaling tests on macOS"
run_suite SignalingMacTests -- -destination "platform=macOS"

echo "== ServerAPI tests on the iOS simulator ($ios_udid)"
run_suite ServerAPITests -- -destination "id=$ios_udid"

echo "== ServerAPI tests on macOS"
run_suite ServerAPIMacTests -- -destination "platform=macOS"

echo "== CallEngine tests on the iOS simulator ($ios_udid)"
run_suite CallEngineTests -- -destination "id=$ios_udid"

echo "== CallEngine tests on macOS"
run_suite CallEngineMacTests -- -destination "platform=macOS"

echo "== CallStats tests on the iOS simulator ($ios_udid)"
run_suite CallStatsTests -- -destination "id=$ios_udid"

echo "== CallStats tests on macOS"
run_suite CallStatsMacTests -- -destination "platform=macOS"

echo "== Calls tests on the iOS simulator ($ios_udid)"
run_suite CallsTests -- -destination "id=$ios_udid"

echo "== Calls tests on macOS"
run_suite CallsMacTests -- -destination "platform=macOS"

echo "== CallKitIntegration tests on the iOS simulator ($ios_udid)"
run_suite CallKitIntegrationTests -- -destination "id=$ios_udid"

echo "== CallKitIntegration tests on macOS"
run_suite CallKitIntegrationMacTests -- -destination "platform=macOS"

echo "== FileTransfer tests on the iOS simulator ($ios_udid)"
run_suite FileTransferTests -- -destination "id=$ios_udid"

echo "== FileTransfer tests on macOS"
run_suite FileTransferMacTests -- -destination "platform=macOS"

echo "== Onboarding tests on the iOS simulator ($ios_udid)"
run_suite OnboardingTests -- -destination "id=$ios_udid"

echo "== Onboarding tests on macOS"
run_suite OnboardingMacTests -- -destination "platform=macOS"

echo "== Chats tests on the iOS simulator ($ios_udid)"
run_suite ChatsTests -- -destination "id=$ios_udid"

echo "== Chats tests on macOS"
run_suite ChatsMacTests -- -destination "platform=macOS"

echo "== Conversation tests on the iOS simulator ($ios_udid)"
run_suite ConversationTests -- -destination "id=$ios_udid"

echo "== Conversation tests on macOS"
run_suite ConversationMacTests -- -destination "platform=macOS"

echo "== Settings tests on the iOS simulator ($ios_udid)"
run_suite SettingsTests -- -destination "id=$ios_udid"

echo "== Settings tests on macOS"
run_suite SettingsMacTests -- -destination "platform=macOS"

# Task 13 part 1 (LNK-39): the Call feature module.
echo "== Call tests on the iOS simulator ($ios_udid)"
run_suite CallTests -- -destination "id=$ios_udid"

echo "== Call tests on macOS"
run_suite CallMacTests -- -destination "platform=macOS"

# Task 13 part 2 (LNK-39): the app smoke targets — the launch smoke boots
# the real apps on the simulator / macOS, the composition smoke builds the
# full session graph.
echo "== LinkoiOS smoke tests on the iOS simulator ($ios_udid)"
run_suite LinkoiOSTests -- -destination "id=$ios_udid"

echo "== LinkoMac smoke tests on macOS"
run_suite LinkoMacTests -- -destination "platform=macOS"

rm -rf "$log_dir"
echo "ci-local: OK"
