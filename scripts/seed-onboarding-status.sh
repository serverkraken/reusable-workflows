#!/usr/bin/env bash
# seed-onboarding-status.sh — populate docs/onboarding-status.md with one row
# per serverkraken/* repo. Existing rows are preserved; only new repos are appended.
#
# Usage: scripts/seed-onboarding-status.sh
# Requires: gh, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DOC="$REPO_ROOT/docs/onboarding-status.md"

if ! command -v gh >/dev/null; then
  echo "gh CLI required" >&2
  exit 1
fi

stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ ! -f "$DOC" ]]; then
  cat > "$DOC" <<EOF
# Onboarding Status

_Last updated by the onboarding workflow: ${stamp}_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
EOF
fi

repos=$(gh repo list serverkraken --limit 200 --json nameWithOwner -q '.[].nameWithOwner' | sort)

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  esc=$(printf '%s' "$repo" | sed 's|/|\\/|g')
  if grep -qE "^\\| ${esc} \\|" "$DOC"; then
    continue
  fi
  echo "| ${repo} | — | — | — | — | not onboarded |" >> "$DOC"
done <<< "$repos"

echo "Seeded $DOC. Review with git diff before committing."
