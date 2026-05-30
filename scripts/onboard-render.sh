#!/usr/bin/env bash
# onboard-render.sh — render adopter templates via gomplate, write lock file.
#
# Usage:
#   onboard-render.sh <catalog-path> <target-path> <profile-json-path> <pin-version>
#
# Reads profile.json (emitted by onboard-detect --profile-json) and produces:
#   .github/workflows/{ci,release,prerelease,cleanup}.yml
#   release-please-config.json     (monorepo: from .monorepo.json.tmpl)
#   .release-please-manifest.json
#   .github/onboard.lock.json      (schema_version=1, sha256 of each file)
#
# The lock file is the contract drift-check (Phase 5) compares against.

set -euo pipefail

# Resolve script directory so we can source siblings even when called via $PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/hash-lib.sh"

if [[ $# -lt 4 ]]; then
  echo "::error::usage: $0 <catalog> <target> <profile-json-path> <pin-version>" >&2
  exit 2
fi

CATALOG="$1"
TARGET="$2"
PROFILE="$3"
PIN="$4"

if ! command -v gomplate >/dev/null 2>&1; then
  echo "::error::gomplate not installed; see scripts/install-gomplate.sh" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required" >&2
  exit 1
fi

if [[ ! -f "$PROFILE" ]]; then
  echo "::error::profile not found: $PROFILE" >&2
  exit 1
fi

MONOREPO=$(jq -r '.monorepo' "$PROFILE")

SKELETONS="$CATALOG/docs/adopter-templates/skeletons"
CONFIGS="$CATALOG/docs/adopter-templates/configs"

mkdir -p "$TARGET/.github/workflows"

# Build a single gomplate context: {pin, profile}. This lets templates access
# .pin and .profile.X uniformly. gomplate v5 no longer accepts inline literal
# values via -c, so we materialise the context to a temp JSON. The .json
# suffix is load-bearing — gomplate uses it to decide the parser, and
# extensionless files default to plain text (yielding "can't evaluate field
# X in type string" errors at template execution).
CTX_DIR=$(mktemp -d)
CTX="$CTX_DIR/ctx.json"
trap 'rm -rf "$CTX_DIR"' EXIT
jq -n --slurpfile p "$PROFILE" --arg pin "$PIN" \
  '{pin: $pin, profile: $p[0]}' > "$CTX"

render() {
  local src="$1" dst="$2"
  if [[ ! -f "$src" ]]; then
    echo "::error::template missing: $src" >&2
    exit 1
  fi
  gomplate -c ".=$CTX" -f "$src" -o "$dst"
  normalize_trailing_newline "$dst"
}

# Strip trailing blank lines; ensure exactly one trailing \n.
#
# gomplate preserves the template's EOF \n unconditionally. When a per-component
# range body emits no visible output — e.g., a Dockerfile-only repo whose
# primary_language is "generic", which matches none of the language branches
# in ci.yml.tmpl/release.yml.tmpl — the EOF \n stacks on top of the preceding
# secscan line's \n and yamllint fails the rendered file with empty-lines
# max-end > 0. The trim gymnastics required template-side are fragile across
# all language branches; normalizing the rendered output is simpler and
# template-independent.
normalize_trailing_newline() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # $(<file) strips all trailing \n; printf '%s\n' re-adds exactly one.
  local content
  content=$(<"$f")
  printf '%s\n' "$content" > "$f"
}

# Workflow skeletons (same set for all variants; conditionals inside templates
# decide which jobs are emitted).
render "$SKELETONS/ci.yml.tmpl"         "$TARGET/.github/workflows/ci.yml"
render "$SKELETONS/release.yml.tmpl"    "$TARGET/.github/workflows/release.yml"
render "$SKELETONS/prerelease.yml.tmpl" "$TARGET/.github/workflows/prerelease.yml"
render "$SKELETONS/cleanup.yml.tmpl"    "$TARGET/.github/workflows/cleanup.yml"

# prerelease-on-push.yml — opt-in: rendered only when the repo carries the
# `sk-prerelease-on-push` topic. Tracked in the lock + $REPO loop below only
# when actually rendered.
RENDER_ON_PUSH=0
if jq -e '(.topics // []) | index("sk-prerelease-on-push")' "$PROFILE" >/dev/null 2>&1; then
  render "$SKELETONS/prerelease-on-push.yml.tmpl" "$TARGET/.github/workflows/prerelease-on-push.yml"
  RENDER_ON_PUSH=1
fi

# release-please config: single vs monorepo.
if [[ "$MONOREPO" == "true" ]]; then
  render "$CONFIGS/release-please-config.monorepo.json.tmpl" "$TARGET/release-please-config.json"
else
  render "$CONFIGS/release-please-config.json.tmpl"          "$TARGET/release-please-config.json"
fi
render "$CONFIGS/release-please-manifest.json.tmpl" "$TARGET/.release-please-manifest.json"

# Substitute $REPO placeholder in image names. Detection emits "$REPO-api"
# style names; the renderer resolves $REPO from the profile's `target_repo`
# (a full `<owner>/<name>` string) so downstream callers get a fully-qualified
# GHCR image path like `ghcr.io/serverkraken/skytrack-ui-dev`.
#
# Historical note: previously this read `${TARGET##*/}`, the basename of the
# filesystem checkout path. Under `onboard.yml` that path is literally `target`
# (see actions/checkout's `path: target` input), so every adopter ended up
# with `image_name: target-<suffix>` and any release-please-driven build
# failed at GHCR push with `400 Bad Request` on the malformed image path.
# The bug was latent until skytrack-ui shipped the first real release that
# went through docker-build-multi.
REPO_FULL=$(jq -r '.target_repo // ""' "$PROFILE")
if [[ -z "$REPO_FULL" || "$REPO_FULL" == "null" ]]; then
  # Fallback for callers that omit target_repo (e.g. local fixture runs).
  REPO_FULL="${TARGET##*/}"
  if [[ "$REPO_FULL" == "." || -z "$REPO_FULL" ]]; then
    REPO_FULL="$(basename "$(pwd)")"
  fi
fi
for f in "$TARGET/.github/workflows/release.yml" "$TARGET/.github/workflows/prerelease.yml" "$TARGET/.github/workflows/prerelease-on-push.yml"; do
  if [[ -f "$f" ]] && grep -q '\$REPO' "$f" 2>/dev/null; then
    # macOS/BSD sed -i needs an explicit backup suffix; we delete it after.
    # $REPO_FULL contains a forward-slash (`owner/name`); use a sed delimiter
    # that won't collide.
    sed -i.bak "s|\\\$REPO|${REPO_FULL}|g" "$f" && rm -f "$f.bak"
  fi
done

# Lock file — sha256 every rendered path, write schema 1.
LOCK="$TARGET/.github/onboard.lock.json"
RENDERED=(
  ".github/workflows/ci.yml"
  ".github/workflows/release.yml"
  ".github/workflows/prerelease.yml"
  ".github/workflows/cleanup.yml"
  "release-please-config.json"
  ".release-please-manifest.json"
)
if [[ "$RENDER_ON_PUSH" == "1" ]]; then
  RENDERED+=(".github/workflows/prerelease-on-push.yml")
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

files_entries=()
for f in "${RENDERED[@]}"; do
  if [[ ! -f "$TARGET/$f" ]]; then
    echo "::error::expected rendered file missing: $f" >&2
    exit 1
  fi
  sha=$(sha256_of "$TARGET/$f")
  files_entries+=("$(jq -nc --arg k "$f" --arg v "sha256:$sha" '{($k): $v}')")
done
if [[ ${#files_entries[@]} -eq 0 ]]; then
  files_json='{}'
else
  files_json=$(printf '%s\n' "${files_entries[@]}" | jq -cs 'add')
fi

jq -n \
  --argjson schema_version 1 \
  --arg catalog_version "$PIN" \
  --arg rendered_against "${RENDERED_AGAINST:-$PIN}" \
  --arg rendered_at "$NOW" \
  --argjson files "$files_json" \
  '{schema_version: $schema_version,
    catalog_version: $catalog_version,
    rendered_against: $rendered_against,
    rendered_at: $rendered_at,
    files: $files}' \
  > "$LOCK"
