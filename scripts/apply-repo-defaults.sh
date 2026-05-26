#!/usr/bin/env bash
# apply-repo-defaults.sh — apply catalog repo-level defaults to a target.
#
# Usage: apply-repo-defaults.sh --repo <owner/repo> --target-path <dir>
#                               [--prev-marker <iso-timestamp>] [--dry-run]
#
# Reads catalog/onboard-defaults.json (relative to repo root containing this
# script), applies Tier 1 every run, Tier 2 only when --prev-marker is empty,
# mutates <target-path>/.github/onboard.lock.json to record defaults_applied_at
# and bump schema_version to 2.
#
# Requires GH_TOKEN env var with administration:write scope.
#
# Outputs (key=value lines, sink-friendly for $GITHUB_OUTPUT):
#   defaults_applied=true|false
#   tier_2_applied=true|false
#   modified=<csv of field-categories that were mutated>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/apply-defaults-lib.sh
source "$SCRIPT_DIR/lib/apply-defaults-lib.sh"

usage() {
  cat <<'EOF'
usage: apply-repo-defaults.sh --repo <owner/repo> --target-path <dir>
                              [--prev-marker <iso-timestamp>] [--dry-run] [--help]

Applies catalog repo-level defaults to a target repository. Reads the catalog's
onboard-defaults.json, calls GitHub API to apply Tier 1 (always) and Tier 2
(first-onboard-only) fields, then mutates the target's onboard.lock.json to
record defaults_applied_at and schema_version=2.

Env:
  GH_TOKEN  Required. Token with administration:write on the target.
EOF
}

REPO=""
TARGET_PATH=""
PREV_MARKER=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --target-path) TARGET_PATH="$2"; shift 2 ;;
    --prev-marker) PREV_MARKER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "::error::--repo is required" >&2
  usage >&2
  exit 1
fi
if [[ -z "$TARGET_PATH" ]]; then
  echo "::error::--target-path is required" >&2
  usage >&2
  exit 1
fi
if [[ ! -d "$TARGET_PATH" ]]; then
  echo "::error::--target-path does not exist: $TARGET_PATH" >&2
  exit 1
fi

CONFIG="$CATALOG_ROOT/catalog/onboard-defaults.json"
if [[ ! -f "$CONFIG" ]]; then
  echo "::error::config not found: $CONFIG" >&2
  exit 1
fi
if ! jq -e . "$CONFIG" > /dev/null 2>&1; then
  echo "::error::invalid JSON in $CONFIG" >&2
  exit 1
fi

# Tier 2 decision: apply only when no marker is preserved from the snapshot.
APPLY_TIER_2=0
if [[ -z "$PREV_MARKER" ]]; then
  APPLY_TIER_2=1
fi

MODIFIED_CATEGORIES=()

# --- Tier 1 + Tier 2 logic implemented in later tasks ---

# --- Lock mutation implemented in Task 12 ---

# Outputs
modified_csv=$(IFS=,; echo "${MODIFIED_CATEGORIES[*]:-}")
echo "defaults_applied=true"
if (( APPLY_TIER_2 )); then
  echo "tier_2_applied=true"
else
  echo "tier_2_applied=false"
fi
echo "modified=$modified_csv"
