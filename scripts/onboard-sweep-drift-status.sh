#!/usr/bin/env bash
# onboard-sweep-drift-status.sh <owner/repo> <current_major>
# Clones the adopter to a tmpdir, runs scripts/onboard-drift.sh against the
# clone, emits the status value (e.g. "clean", "behind", "stale-lock") to
# stdout. Used by .github/workflows/onboard-sweep.yml's enumerate job to
# bucket onboarded repos into update vs skipped.
#
# Requires GH_TOKEN env var with read access to the target repo.
# When env var ONBOARD_SWEEP_TARGET_PATH is set, skips the clone and runs
# drift against that path directly — used by bats tests to avoid network.
set -euo pipefail

TARGET="${1:-}"
CURRENT="${2:-}"

if [[ -z "$TARGET" || -z "$CURRENT" ]]; then
  echo "::error::usage: $0 <owner/repo> <current_major>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${ONBOARD_SWEEP_TARGET_PATH:-}" ]]; then
  # Test mode — caller already prepared the target tree.
  target_path="$ONBOARD_SWEEP_TARGET_PATH"
else
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN env var required to clone $TARGET" >&2
    exit 1
  fi
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  if ! git clone --depth=1 --quiet \
       "https://x-access-token:${GH_TOKEN}@github.com/${TARGET}.git" \
       "$tmpdir/target" 2>/dev/null; then
    # Clone failure → emit "error" so the caller can bucket it as skipped.
    echo "error"
    exit 0
  fi
  target_path="$tmpdir/target"
fi

output=$(CATALOG_CURRENT_VERSION="$CURRENT" \
  "$SCRIPT_DIR/onboard-drift.sh" "$target_path" "$CATALOG_ROOT")
echo "$output" | grep '^status=' | cut -d= -f2-
