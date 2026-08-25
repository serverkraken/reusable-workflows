#!/usr/bin/env bash
set -euo pipefail

BRANCH="${1:-}"
SHORT_SHA="${2:-}"

if [[ -z "$BRANCH" ]] || [[ -z "$SHORT_SHA" ]]; then
  echo "usage: $0 <branch> <short-sha>" >&2
  exit 1
fi

# printf, not echo. `echo "$X"` eats a leading -n/-e/-E as a flag, so a SHA of
# "-n" produced an EMPTY sha component and tag_with_sha collapsed to
# "<branch>-" — identical for every commit on that branch, which defeats the
# entire purpose of a per-commit tag: two builds would overwrite each other's
# manifest under one name.
SHORT_SHA=$(printf '%s' "$SHORT_SHA" | tr '[:upper:]' '[:lower:]')

# A short SHA is hex. Anything else means the caller passed the wrong thing,
# and guessing produces a tag that looks plausible and points nowhere.
if [[ ! "$SHORT_SHA" =~ ^[0-9a-f]+$ ]]; then
  echo "short-sha '$2' is not hexadecimal" >&2
  exit 1
fi

# Lowercase, replace non-alphanumeric with dashes, collapse, trim
sanitized=$(printf '%s' "$BRANCH" \
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

# Final gate against the OCI tag grammar. A sanitizer that can still emit an
# invalid tag is not doing its job — and the failure would otherwise surface
# far downstream as an opaque registry rejection mid-release.
oci_tag='^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$'
for t in "$moving_tag" "$tag_with_sha"; do
  if [[ ! "$t" =~ $oci_tag ]]; then
    echo "computed tag '$t' is not a valid OCI tag" >&2
    exit 1
  fi
done

echo "tag_with_sha=${tag_with_sha}"
echo "moving_tag=${moving_tag}"
