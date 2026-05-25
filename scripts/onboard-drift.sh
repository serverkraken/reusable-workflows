#!/usr/bin/env bash
# onboard-drift.sh — compute drift status for a single adopter checkout.
#
# Compares the SHA-256 hashes in <target>/.github/onboard.lock.json against
# the working-tree contents of the same paths, plus catalog-version freshness.
# When lock-comparison says "clean", additionally re-renders the catalog
# templates at the current catalog state and byte-compares the result — if
# the renderer would now produce different files than what the lock recorded,
# emits status=stale-lock. This catches within-major template evolution that
# pure lock-comparison cannot see.
#
# Skipped from both compare loops (by-design adopter mutation):
#   - .github/onboard.lock.json     lock never self-tracks (defensive)
#   - .release-please-manifest.json release-please rewrites it on every release
#
# Usage:   onboard-drift.sh <target-path> <catalog-path>
# Env:     CATALOG_CURRENT_VERSION   string, e.g. "v3" or "v3.0.1"
#                                    Empty → only modified/no-lock/stale-lock
#                                    can fire, behind is suppressed.
#
# Stdout (key=value, sink-friendly for GITHUB_OUTPUT):
#   status=<clean|behind|modified|behind+modified|no-lock|stale-lock>
#   modified=<comma-separated paths>      empty when clean (without re-render)
#                                         lists stale paths when stale-lock
#   lock_version=<value from lock>        absent when no-lock
#   current_version=<value from env>      absent when env unset
#   render_error=<phase:truncated-stderr> empty when render OK or skipped
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
  # .release-please-manifest.json is by-design mutated by release-please-action
  # on every release (rewrites the version-state object). Skip from compare so
  # active-release adopters don't show as perpetually modified.
  [[ "$f" == ".release-please-manifest.json" ]] && continue
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

# Render-and-compare check — only when lock-comparison says "clean".
# Catches within-major template evolution: the lock's stored hashes match the
# working tree, but the catalog renderer has since evolved and would now
# produce different output. Conservative on failure: if the re-render itself
# breaks (detect or render exits non-zero), status stays "clean" and we record
# the reason in render_error so it surfaces in the drift-check Issue.
render_error=""
if [[ "$status" == "clean" ]]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT

  # Step 1: re-detect the adopter's profile from its source files.
  if ! "$CATALOG/scripts/onboard-detect.sh" --profile-json "$TARGET" \
       > "$scratch/profile.json" 2>"$scratch/detect.err"; then
    render_error="detect-failed:$(tr '\n' ' ' < "$scratch/detect.err" | cut -c1-80)"
  fi

  # Step 2: re-render templates against current catalog state.
  if [[ -z "$render_error" ]]; then
    if ! "$CATALOG/scripts/onboard-render.sh" "$CATALOG" "$scratch/rendered" \
         "$scratch/profile.json" "$CURRENT" 2>"$scratch/render.err"; then
      render_error="render-failed:$(tr '\n' ' ' < "$scratch/render.err" | cut -c1-80)"
    fi
  fi

  # Step 3: byte-compare each lock-tracked file between target and rendered scratch.
  if [[ -z "$render_error" ]]; then
    stale_files=()
    while IFS= read -r f; do
      # Lock should never track itself, but guard defensively.
      [[ "$f" == ".github/onboard.lock.json" ]] && continue
      # .release-please-manifest.json mutates by-design (see lock-compare loop).
      # Skip here too so the render-compare doesn't surface stale-lock for the
      # same reason.
      [[ "$f" == ".release-please-manifest.json" ]] && continue
      # If the rendered tree doesn't contain this path (profile-conditional
      # template), skip — we can't compare what doesn't exist on both sides.
      [[ -f "$scratch/rendered/$f" ]] || continue
      if ! cmp -s "$TARGET/$f" "$scratch/rendered/$f"; then
        stale_files+=("$f")
      fi
    done < <(jq -r '.files | keys[]' "$LOCK")

    if (( ${#stale_files[@]} > 0 )); then
      status="stale-lock"
      modified_files=("${stale_files[@]}")
      is_mod=1
    fi
  fi
fi

echo "status=$status"
if (( is_mod )); then
  # IFS local to subshell so we don't pollute caller.
  echo "modified=$(IFS=,; echo "${modified_files[*]}")"
else
  echo "modified="
fi
echo "render_error=$render_error"
