#!/usr/bin/env bash
# onboard-drift.sh — compute drift status for a single adopter checkout.
#
# Compares the SHA-256 hashes in <target>/.github/onboard.lock.json against
# the working-tree contents of the same paths, plus catalog-version freshness.
# When lock-comparison says "clean", additionally re-renders the catalog
# templates at the current catalog state and byte-compares the result — if
# the renderer would now produce different files than what the lock recorded
# — or net-new files the lock has no entry for (templates added after the
# adopter onboarded) — emits status=stale-lock. This catches within-major
# template evolution that pure lock-comparison cannot see.
#
# Skipped from both compare loops (by-design adopter mutation):
#   - .github/onboard.lock.json     lock never self-tracks (defensive)
#   - .release-please-manifest.json release-please rewrites it on every release
#
# Adopter manifest (.github/onboard.yml) is Go-CLI-only: this Bash engine has
# no parser for it, so a target that carries one short-circuits immediately
# with status=error (see the manifest check right after arg validation)
# instead of attempting lock-comparison or a render-and-compare that would
# either fail or mis-detect the layout the manifest exists to correct.
#
# Usage:   onboard-drift.sh <target-path> <catalog-path>
# Env:     CATALOG_CURRENT_VERSION   string, e.g. "v3" or "v3.0.1"
#                                    Empty → only modified/no-lock/stale-lock
#                                    can fire, behind is suppressed.
#
# Stdout (key=value, sink-friendly for GITHUB_OUTPUT):
#   status=<clean|behind|modified|behind+modified|no-lock|stale-lock|error>
#   modified=<comma-separated paths>      empty when clean (without re-render)
#                                         lists stale paths when stale-lock
#   lock_version=<value from lock>        absent when no-lock
#   current_version=<value from env>      absent when env unset
#   render_error=<phase:truncated-stderr> empty when render OK or skipped
#                                         explanatory text when status=error
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

# Adopter manifest (.github/onboard.yml) is Go-CLI-only (internal/manifest).
# This Bash engine has no parser for it, and re-detecting such a repo below
# would either fail outright or — worse — silently mis-detect the layout the
# manifest exists to correct. Fail loud with status=error up front rather
# than letting the render-and-compare step swallow the failure into
# render_error while status stays "clean" (an operator would then have to
# notice a render_error hiding behind a clean status). This must run before
# the lock check too: a manifest repo the Bash engine can't evaluate is not
# meaningfully "no-lock" either.
MANIFEST="$TARGET/.github/onboard.yml"
if [[ -f "$MANIFEST" ]]; then
  echo "::error::$MANIFEST: adopter manifest present — the Bash engine cannot evaluate it; dispatch onboard.yml with use_go_cli=true (sk-workflows detect)" >&2
  echo "status=error"
  if [[ -f "$TARGET/.github/onboard.lock.json" ]]; then
    echo "lock_version=$(jq -r '.catalog_version' "$TARGET/.github/onboard.lock.json")"
  fi
  [[ -n "$CURRENT" ]] && echo "current_version=$CURRENT"
  echo "modified="
  echo "render_error=adopter manifest present; the Bash engine cannot evaluate it — dispatch with use_go_cli=true"
  exit 0
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
# produce different output. If the re-render itself breaks (detect or render
# exits non-zero), the reason lands in render_error and the status becomes
# "error" — see the guard right after this block for why "clean" was wrong.
render_error=""
if [[ "$status" == "clean" ]]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT

  # Derive TARGET_REPO from the adopter's git origin when callers don't set
  # it explicitly. Without target_repo in the profile, onboard-render.sh falls
  # back to ${TARGET##*/} (a tmpdir basename like "rendered") for $REPO
  # substitution in release.yml/prerelease.yml, producing files that byte-
  # diverge from the adopter's real lock-tracked output — surfacing every
  # Docker-atom adopter as false-positive stale-lock. drift-check.yml and
  # onboard-sweep-drift-status.sh both hit this path; deriving here fixes
  # both callers and keeps fixture-based callers (no origin) untouched.
  if [[ -z "${TARGET_REPO:-}" ]]; then
    origin=$(git -C "$TARGET" config --get remote.origin.url 2>/dev/null || true)
    if [[ -n "$origin" ]]; then
      norm="${origin#*github.com[:/]}"
      norm="${norm%.git}"
      [[ -n "$norm" ]] && export TARGET_REPO="$norm"
    fi
  fi

  # Step 1: re-detect the adopter's profile from its source files.
  # Drift vergleicht ein bereits onboardetes Repo mit dem, was dort eingecheckt
  # ist, und laeuft in Jobs ohne GitHub-Token. Ein fehlgeschlagener
  # Metadaten-Aufruf darf hier degradieren statt abzubrechen - beim ONBOARDING
  # nicht, dort wuerde geraten (Audit H-5, H-10). Derselbe Schnitt wie im
  # Go-Pfad, wo godetect.tolerantMetadata nur `drift` umschliesst.
  export ONBOARD_METADATA_OPTIONAL=1
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
      # Ein lock-getrackter Pfad, den der Renderer nicht mehr ausgibt, IST
      # Drift: der Adopter traegt weiterhin einen Workflow, den der Katalog
      # fallengelassen hat, und der feuert dort auch weiter. Dieses Ueber-
      # springen (frueher: `|| continue`) hat genau das verdeckt. Parallel zu
      # staleFiles() im Go-Pfad, damit beide Engines dasselbe melden.
      if [[ ! -f "$scratch/rendered/$f" ]]; then
        stale_files+=("$f")
        continue
      fi
      if ! cmp -s "$TARGET/$f" "$scratch/rendered/$f"; then
        stale_files+=("$f")
      fi
    done < <(jq -r '.files | keys[]' "$LOCK")

    # Step 4: detect net-new rendered files — paths the current renderer emits
    # that the lock has no entry for. An adopter onboarded before a
    # profile-conditional template existed carries a lock without that key, so
    # the lock-keyed loops above can never see the file. Scan the rendered
    # scratch tree (it contains exactly the rendered output plus the lock the
    # renderer writes) and flag anything untracked as stale.
    while IFS= read -r f; do
      f="${f#"$scratch/rendered/"}"
      # Lock never self-tracks (defensive, mirrors step 3).
      [[ "$f" == ".github/onboard.lock.json" ]] && continue
      # .release-please-manifest.json mutates by-design (see lock-compare loop).
      [[ "$f" == ".release-please-manifest.json" ]] && continue
      if ! jq -e --arg k "$f" '.files | has($k)' "$LOCK" >/dev/null; then
        stale_files+=("$f")
      fi
    done < <(find "$scratch/rendered" -type f | sort)

    if (( ${#stale_files[@]} > 0 )); then
      status="stale-lock"
      modified_files=("${stale_files[@]}")
      is_mod=1
    fi
  fi
fi

# Ein Render-Fehler ist kein sauberer Befund. Bis hierher ueberlebte schlicht
# der Status "clean", waehrend der Grund in render_error steckte — und der
# woechentliche Sweep greppt nur auf ^status=, verwarf den Grund also komplett.
# Betroffene Repos blieben unbegrenzt gruen und ungeprueft. Die Manifest-
# Abkuerzung ganz oben hat sich dem schon verweigert und status=error gemeldet;
# der allgemeine Fall zieht jetzt nach. Parallel zum Go-Pfad (service.go).
if [[ -n "$render_error" && "$status" == "clean" ]]; then
  status="error"
fi

echo "status=$status"
if (( is_mod )); then
  # IFS local to subshell so we don't pollute caller.
  echo "modified=$(IFS=,; echo "${modified_files[*]}")"
else
  echo "modified="
fi
echo "render_error=$render_error"
