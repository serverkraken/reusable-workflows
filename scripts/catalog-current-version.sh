#!/usr/bin/env bash
# Emit GitHub-output-compatible current catalog version fields.
#
# current_version is the floating major (for example v4).
# current_minor is the latest reachable patch tag (for example v4.9.0).

set -euo pipefail

if [[ -n "${CATALOG_ROOT:-}" ]]; then
  repo_root="$CATALOG_ROOT"
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

tag=$(git -C "$repo_root" describe \
  --tags \
  --match 'v[0-9]*.[0-9]*.[0-9]*' \
  --abbrev=0 2>/dev/null || echo "v0.0.0")

major=$(printf '%s\n' "$tag" | sed -E 's/^v([0-9]+)\.[0-9]+\.[0-9]+$/v\1/')

printf 'current_version=%s\n' "$major"
printf 'current_minor=%s\n' "$tag"
