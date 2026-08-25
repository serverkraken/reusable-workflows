#!/usr/bin/env bash
# lock-orphans.sh — files the catalog used to render but no longer does.
#
# Usage:  lock-orphans.sh <old-lock.json> <new-lock.json> [work-dir]
#
# Prints one line per orphan:
#   SAFE<TAB><path>      still byte-identical to what the old lock recorded
#   MODIFIED<TAB><path>  the adopter changed it since; do not touch
#   GONE<TAB><path>      already absent from the tree
#
# Why: onboard's PR A stages exactly the files the NEW lock lists. A template
# the catalog renamed or dropped therefore stays in the adopter forever — PR A
# adds the replacement and never removes the original, and PR B only deletes
# legacy CI it detected, which this is not. The adopter ends up running both.
#
# Drift already reports this class since the staleFiles fix; onboarding is
# where it gets repaired. The hash check mirrors legacy-ci-fingerprint.sh: a
# file the adopter edited is theirs now, and removing it silently would be the
# same mistake in the other direction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hash-lib.sh
source "$SCRIPT_DIR/lib/hash-lib.sh"

OLD="${1:-}"
NEW="${2:-}"
WORK="${3:-.}"

if [[ -z "$OLD" || -z "$NEW" ]]; then
  echo "usage: $0 <old-lock.json> <new-lock.json> [work-dir]" >&2
  exit 1
fi

# No previous lock means a first onboard: nothing was ever rendered, so
# nothing can be orphaned.
[[ -f "$OLD" ]] || exit 0
[[ -f "$NEW" ]] || { echo "::error::new lock not found: $NEW" >&2; exit 1; }

cd "$WORK"

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  # The lock never tracks itself, and release-please rewrites the manifest on
  # every release — neither is the catalog's to remove.
  [[ "$path" == ".github/onboard.lock.json" ]] && continue
  [[ "$path" == ".release-please-manifest.json" ]] && continue

  if [[ ! -f "$path" ]]; then
    printf 'GONE\t%s\n' "$path"
    continue
  fi

  expected=$(jq -r --arg k "$path" '.files[$k] // ""' "$OLD")
  actual="sha256:$(sha256_of "$path")"
  if [[ "$expected" == "$actual" ]]; then
    printf 'SAFE\t%s\n' "$path"
  else
    printf 'MODIFIED\t%s\n' "$path"
  fi
done < <(
  comm -23 \
    <(jq -r '.files | keys[]' "$OLD" | LC_ALL=C sort) \
    <(jq -r '.files | keys[]' "$NEW" | LC_ALL=C sort)
)
