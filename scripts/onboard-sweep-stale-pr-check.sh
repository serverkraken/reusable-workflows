#!/usr/bin/env bash
# onboard-sweep-stale-pr-check.sh — decide whether an open bot onboard PR's
# content is already at the current catalog minor.
#
# Usage:   onboard-sweep-stale-pr-check.sh <owner/repo> <current_minor>
# Env:     GH_TOKEN — read access to the target repo's PRs + contents.
# Stdout:  one of {skip|stale|no-pr}
#
# Decision tree (fail-open):
#   no open bot PR on chore/onboard-reusable-workflows         → "no-pr"
#   PR-listing API error (rate-limit, 403, network)            → "no-pr"  (safe: sweep re-onboards)
#   open PR + lock.rendered_against == current_minor           → "skip"
#   open PR + lock missing / field absent / API error / mismatch → "stale"
#
# The sweep treats "skip" as `skipped:open-pr` and "no-pr" / "stale" as
# "fall through to drift-status / fresh-onboard".
set -euo pipefail

TARGET="${1:-}"
CURRENT_MINOR="${2:-}"

if [[ -z "$TARGET" || -z "$CURRENT_MINOR" ]]; then
  echo "::error::usage: $0 <owner/repo> <current_minor>" >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "::error::GH_TOKEN env var required to call GitHub API" >&2
  exit 1
fi

BRANCH="chore/onboard-reusable-workflows"

# Step 1: does an open bot PR exist on the onboard branch?
exists=$(gh api -X GET "/repos/$TARGET/pulls" -f state=open \
  -q "[.[] | select(.user.login == \"serverkraken-release-bot[bot]\")
            | select(.head.ref == \"$BRANCH\")
      ] | length" 2>/dev/null || echo 0)

if [[ "$exists" -eq 0 ]]; then
  echo "no-pr"
  exit 0
fi

# Step 2: fetch lock from the bot branch and compare rendered_against.
# gh api returns base64 content; decode and read the field.
lock_b64=$(gh api \
  "/repos/$TARGET/contents/.github/onboard.lock.json?ref=$BRANCH" \
  -q '.content' 2>/dev/null || true)

lock_rendered=$(printf '%s' "$lock_b64" | base64 -d 2>/dev/null \
                | jq -r '.rendered_against // empty' 2>/dev/null || true)

if [[ "$lock_rendered" == "$CURRENT_MINOR" ]]; then
  echo "skip"
else
  echo "stale"
fi
