#!/usr/bin/env bash
set -euo pipefail

BRANCH="${1:-}"
SHORT_SHA="${2:-}"

if [[ -z "$BRANCH" ]] || [[ -z "$SHORT_SHA" ]]; then
  echo "usage: $0 <branch> <short-sha>" >&2
  exit 1
fi

# Lowercase the SHA too (git short SHAs are hex, lowercase is canonical)
SHORT_SHA=$(echo "$SHORT_SHA" | tr '[:upper:]' '[:lower:]')

# Lowercase, replace non-alphanumeric with dashes, collapse, trim
sanitized=$(echo "$BRANCH" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g' \
  | sed 's/--*/-/g' \
  | sed 's/^-//;s/-$//')

# OCI tag spec: ≤128 chars, but we cap moving tag at 64 for readability
moving_tag="${sanitized:0:64}"
moving_tag="${moving_tag%-}"   # don't end on dash if truncated mid-word

if [[ -z "$moving_tag" ]]; then
  echo "branch '$BRANCH' produced empty tag after sanitization" >&2
  exit 1
fi

tag_with_sha="${moving_tag}-${SHORT_SHA}"

echo "tag_with_sha=${tag_with_sha}"
echo "moving_tag=${moving_tag}"
