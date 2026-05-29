#!/usr/bin/env bash
# onboard-detect.sh — detect target repo language + version.
#
# Three modes:
#   onboard-detect.sh <repo-path> [language-override]
#     → emits key=value lines (language, release_type, current_version, default_branch)
#       LEGACY format consumed by onboard.yml's add-PR step. Kept for back-compat.
#
#   onboard-detect.sh --profile-json <repo-path>
#     → emits a JSON profile (schema_version + components + signals + legacy_ci + warnings)
#       NEW format consumed by the gomplate-based renderer in Phase 3.
#
#   onboard-detect.sh --emit-both <repo-path> [language-override]
#     → emits BOTH the legacy key=value lines AND a profile_json<<DELIM
#       multiline block in a single invocation. Used by the onboard-detect
#       composite action to halve gh-api roundtrips. Output is
#       GITHUB_OUTPUT-compatible — callers redirect to $GITHUB_OUTPUT directly.
#
# When TARGET_REPO env is set, both modes call `gh` for default_branch and latest release.
# When unset (local/test mode), emits defaults: current_version=0.0.0, default_branch=main.
#
# Legacy-mode outputs (stdout, key=value, GitHub-Actions friendly):
#   language=<go|python|rust|helm|node|simple>
#   release_type=<same as language>
#   current_version=<X.Y.Z, no leading v>
#   default_branch=<branch>
#
# Exits 1 on:
#   - repo path missing
#   - ambiguous language signals (more than one match, no override) — legacy mode only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dispatch on --emit-both before --profile-json. Used by the onboard-detect
# composite action to produce both legacy key=value outputs AND a
# profile_json<<DELIM multiline block in a single invocation — halves the
# gh api roundtrips and avoids the second shell-startup cost.
if [[ "${1:-}" == "--emit-both" ]]; then
  # shellcheck source=lib/onboard-detect-lib.sh
  source "$SCRIPT_DIR/lib/onboard-detect-lib.sh"
  shift
  REPO_PATH="${1:-}"
  LANG_OVERRIDE="${2:-auto}"
  if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    echo "::error::usage: $0 --emit-both <repo-path> [language-override]" >&2
    exit 1
  fi

  # Language detection — mirrors the legacy fallthrough below. We could share
  # this code via a helper, but the duplication is small and the existing
  # legacy path is intentionally self-contained for back-compat.
  if [[ "$LANG_OVERRIDE" != "auto" ]]; then
    language="$LANG_OVERRIDE"
  else
    matches=()
    [[ -f "$REPO_PATH/go.mod" ]]         && matches+=(go)
    [[ -f "$REPO_PATH/pyproject.toml" ]] && matches+=(python)
    [[ -f "$REPO_PATH/Cargo.toml" ]]     && matches+=(rust)
    [[ -f "$REPO_PATH/Chart.yaml" ]]     && matches+=(helm)
    _component_is_flutter "$REPO_PATH"   && matches+=(flutter)
    [[ -f "$REPO_PATH/package.json" ]]   && matches+=(node)
    if (( ${#matches[@]} == 0 )); then
      language=simple
    elif (( ${#matches[@]} == 1 )); then
      language="${matches[0]}"
    else
      echo "::error::ambiguous language signals: ${matches[*]}; rerun with explicit language input" >&2
      exit 1
    fi
  fi
  release_type="$language"

  current_version="0.0.0"
  default_branch="main"
  if [[ -n "${TARGET_REPO:-}" ]]; then
    if ! default_branch=$(gh api "/repos/${TARGET_REPO}" -q '.default_branch' 2>/dev/null); then
      echo "::error::repo not accessible: $TARGET_REPO" >&2
      exit 1
    fi
    raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    if [[ -n "$raw_tag" && "$raw_tag" != "null" ]]; then
      current_version="${raw_tag#v}"
    fi
  fi

  # Emit legacy key=value lines.
  printf 'language=%s\n' "$language"
  printf 'release_type=%s\n' "$release_type"
  printf 'current_version=%s\n' "$current_version"
  printf 'default_branch=%s\n' "$default_branch"

  # Emit profile_json as a GITHUB_OUTPUT-compatible multiline block. The
  # OVERRIDE_* env vars tell emit_profile_json to use these cached values
  # instead of doing its own gh-api roundtrip.
  delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
  printf 'profile_json<<%s\n' "$delim"
  OVERRIDE_DEFAULT_BRANCH="$default_branch" OVERRIDE_CURRENT_VERSION="$current_version" \
    emit_profile_json "$REPO_PATH"
  printf '%s\n' "$delim"
  exit 0
fi

# Dispatch on --profile-json before any positional parsing.
if [[ "${1:-}" == "--profile-json" ]]; then
  # shellcheck source=lib/onboard-detect-lib.sh
  source "$SCRIPT_DIR/lib/onboard-detect-lib.sh"
  shift
  REPO_PATH="${1:-}"
  if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    echo "::error::usage: $0 --profile-json <repo-path>" >&2
    exit 1
  fi
  emit_profile_json "$REPO_PATH"
  exit 0
fi

# === Legacy key=value path (existing behavior — unchanged) ===

REPO_PATH="${1:-}"
LANG_OVERRIDE="${2:-auto}"

if [[ -z "$REPO_PATH" ]]; then
  echo "::error::usage: $0 <repo-path> [language-override]" >&2
  exit 1
fi

if [[ ! -d "$REPO_PATH" ]]; then
  echo "::error::repo path does not exist: $REPO_PATH" >&2
  exit 1
fi

if [[ "$LANG_OVERRIDE" != "auto" ]]; then
  language="$LANG_OVERRIDE"
else
  matches=()
  [[ -f "$REPO_PATH/go.mod" ]]         && matches+=(go)
  [[ -f "$REPO_PATH/pyproject.toml" ]] && matches+=(python)
  [[ -f "$REPO_PATH/Cargo.toml" ]]     && matches+=(rust)
  [[ -f "$REPO_PATH/Chart.yaml" ]]     && matches+=(helm)
  { [[ -f "$REPO_PATH/pubspec.yaml" ]] && grep -qE 'sdk:[[:space:]]*flutter' "$REPO_PATH/pubspec.yaml"; } && matches+=(flutter)
  [[ -f "$REPO_PATH/package.json" ]]   && matches+=(node)

  if (( ${#matches[@]} == 0 )); then
    language=simple
  elif (( ${#matches[@]} == 1 )); then
    language="${matches[0]}"
  else
    echo "::error::ambiguous language signals: ${matches[*]}; rerun with explicit language input" >&2
    exit 1
  fi
fi

release_type="$language"

current_version="0.0.0"
default_branch="main"

if [[ -n "${TARGET_REPO:-}" ]]; then
  if ! default_branch=$(gh api "/repos/${TARGET_REPO}" -q '.default_branch' 2>/dev/null); then
    echo "::error::repo not accessible: $TARGET_REPO" >&2
    exit 1
  fi
  # --exclude-pre-releases: seed release-please-manifest.json with the latest STABLE
  # version, not a prerelease tag like 0.14.2-pre.<sha>. Prereleases as the manifest
  # baseline confuse release-please's version-bump math on the next release.
  raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
  # jq -q '.[0].tagName' returns the literal string "null" (exit 0) when the
  # release list is empty. Treat "null" as no-release-found and keep current_version=0.0.0.
  if [[ -n "$raw_tag" && "$raw_tag" != "null" ]]; then
    current_version="${raw_tag#v}"
  fi
fi

printf 'language=%s\n' "$language"
printf 'release_type=%s\n' "$release_type"
printf 'current_version=%s\n' "$current_version"
printf 'default_branch=%s\n' "$default_branch"
