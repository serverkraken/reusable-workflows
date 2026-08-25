#!/usr/bin/env bash
# legacy-ci-fingerprint.sh — hash the legacy CI files a profile marks for removal.
#
# Reads a detection profile on stdin, prints one `<sha256>\t<path>` line per
# entry of `.legacy_ci` that has a non-empty `replaced_by` AND exists in the
# working directory. Output is sorted, so two runs can be intersected with
# `comm` directly.
#
# Why this exists: onboard's PR B deletes legacy workflows using a profile that
# was computed earlier in the job, then hard-resets to a FRESHLY FETCHED
# default branch before deleting. Between those two points a human can change
# or replace any of those files. The old guard only asked whether the path
# still existed, so a file whose contents had been rewritten in the meantime
# was deleted anyway — the check confirmed the name, never the thing.
#
# Running this before and after the reset and deleting only the intersection
# means a file has to be byte-identical to the one that was actually
# classified. Anything else is left in place for a human to look at.
#
# Usage:  legacy-ci-fingerprint.sh [work-dir]   # profile JSON on stdin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hash-lib.sh
source "$SCRIPT_DIR/lib/hash-lib.sh"

WORK_DIR="${1:-.}"
cd "$WORK_DIR"

profile="$(cat)"

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  [[ -f "$path" ]] || continue
  printf '%s\t%s\n' "$(sha256_of "$path")" "$path"
done < <(
  printf '%s' "$profile" | jq -r '
    .legacy_ci // []
    | map(select((.replaced_by // "") | length > 0))
    | .[].path // empty
  '
) | LC_ALL=C sort
