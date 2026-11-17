#!/usr/bin/env bash
# Design-token freshness check (Plan 4 Task 3 / LNK-29, spec 4.8): the
# committed Modules/DesignSystem/Sources/Tokens.swift must byte-match the
# deterministic output the linko-core generator produces from
# external/linko-core/design-tokens/tokens.json. Exits non-zero with a diff
# when the committed file is stale; nothing is ever regenerated in place.
#
# Usage: Scripts/check-tokens.sh
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
cd "$repo"

python3 external/linko-core/design-tokens/generate.py \
  --swift-out Modules/DesignSystem/Sources/Tokens.swift \
  --check
