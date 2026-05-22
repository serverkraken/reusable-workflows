#!/usr/bin/env bash
# onboard-drift.sh — compute drift status for a single adopter checkout.
#
# Compares the SHA-256 hashes in <target>/.github/onboard.lock.json against
# the working-tree contents of the same paths, plus catalog-version freshness.
# Does NOT re-render templates — the reproducibility guarantee tested in bats
# (tests/shell/onboard-drift.bats) means a clean target's hashes equal what a
# re-render at the locked catalog_version would emit.
#
# Usage:   onboard-drift.sh <target-path> <catalog-path>
# Env:     CATALOG_CURRENT_VERSION   string, e.g. "v3" or "v3.0.1"
#                                    Empty → only modified/no-lock can fire,
#                                    behind is suppressed.
#
# Stdout (key=value, sink-friendly for GITHUB_OUTPUT):
#   status=<clean|behind|modified|behind+modified|no-lock>
#   modified=<comma-separated paths>      empty when clean
#   lock_version=<value from lock>        absent when no-lock
#   current_version=<value from env>      absent when env unset
set -euo pipefail

# Resolve script directory so we can source siblings even when called via $PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/hash-lib.sh"

TARGET="${1:-}"
CATALOG="${2:-}"
CURRENT="${CATALOG_CURRENT_VERSION:-}"

if [[ -z "$TARGET" || -z "$CATALOG" || ! -d "$TARGET" || ! -d "$CATALOG" ]]; then
  echo "::error::usage: $0 <target-path> <catalog-path>" >&2
  exit 1
fi

LOCK="$TARGET/.github/onboard.lock.json"
if [[ ! -f "$LOCK" ]]; then
  echo "status=no-lock"
  exit 0
fi

lock_version=$(jq -r '.catalog_version' "$LOCK")
echo "lock_version=$lock_version"
[[ -n "$CURRENT" ]] && echo "current_version=$CURRENT"

behind=0
[[ -n "$CURRENT" && "$lock_version" != "$CURRENT" ]] && behind=1

modified_files=()
while IFS= read -r f; do
  if [[ ! -f "$TARGET/$f" ]]; then
    modified_files+=("$f(missing)")
    continue
  fi
  expected=$(jq -r --arg k "$f" '.files[$k]' "$LOCK")
  actual="sha256:$(sha256_of "$TARGET/$f")"
  [[ "$expected" != "$actual" ]] && modified_files+=("$f")
done < <(jq -r '.files | keys[]' "$LOCK")

is_mod=0
[[ ${#modified_files[@]} -gt 0 ]] && is_mod=1

if   (( behind && is_mod )); then status="behind+modified"
elif (( behind ));            then status="behind"
elif (( is_mod ));             then status="modified"
else                                status="clean"
fi

echo "status=$status"
if (( is_mod )); then
  # IFS local to subshell so we don't pollute caller.
  echo "modified=$(IFS=,; echo "${modified_files[*]}")"
else
  echo "modified="
fi
