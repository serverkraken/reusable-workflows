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
#   language=<go|python|rust|helm|flutter|node|gitops|simple>
#   release_type=<same as language>
#   current_version=<X.Y.Z, no leading v>
#   default_branch=<branch>
#
# Exits 1 on:
#   - repo path missing
#   - ambiguous language signals (more than one match, no override) — both modes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The Bash engine has no manifest parser by design (see
# docs/operations.md § Adopter Manifest). Fail loud instead of rendering a
# wrong layout; onboard.yml's use_go_cli=true routes such repos to sk-workflows.
refuse_manifest() {
  if [[ -f "$1/.github/onboard.yml" ]]; then
    echo "::error::$1/.github/onboard.yml: adopter manifest present — the Bash detector does not support manifests; dispatch with use_go_cli=true (sk-workflows detect)" >&2
    exit 1
  fi
}

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
  refuse_manifest "$REPO_PATH"

  # Language detection. Die Signalliste stand hier als DRITTE woertliche Kopie
  # ("die Duplikation ist klein" sagte der Kommentar) - #319 hat den
  # Legacy-Block und die JSON-Pruefung auf root_language_signals zusammengefuehrt
  # und diese hier uebersehen. Genau die Sorte Zwilling, an der
  # `# onboard:image=` und `# onboard:release=` auseinandergelaufen sind.
  if [[ "$LANG_OVERRIDE" != "auto" ]]; then
    language="$LANG_OVERRIDE"
  else
    mapfile -t matches < <(root_language_signals "$REPO_PATH")
    if (( ${#matches[@]} == 0 )); then
      if detect_gitops_kubernetes "$REPO_PATH"; then language=gitops; else language=simple; fi
    elif (( ${#matches[@]} == 1 )); then
      language="${matches[0]}"
    else
      echo "::error::ambiguous language signals: ${matches[*]}; rerun with explicit language input" >&2
      exit 1
    fi
  fi
  case "$language" in
    flutter) release_type="dart" ;;
    gitops)  release_type="simple" ;;
    *)       release_type="$language" ;;
  esac

  current_version="0.0.0"
  default_branch="main"
  if [[ -n "${TARGET_REPO:-}" ]]; then
    if ! default_branch=$(gh api "/repos/${TARGET_REPO}" -q '.default_branch' 2>/dev/null); then
      echo "::error::repo not accessible: $TARGET_REPO" >&2
      exit 1
    fi
    # `|| echo ""` verschluckte jeden API-Fehler und liess current_version auf
    # 0.0.0 stehen (Audit H-5). Daraus wird .release-please-manifest.json
    # geseedet - ein Repo auf 1.10.0 haette dort 0.0.0 bekommen und beim
    # naechsten Release rueckwaerts versioniert. rc trennt die Faelle sauber:
    # ein Repo OHNE Releases antwortet mit rc=0 und leerer Ausgabe.
    if ! raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null); then
      echo "::error::could not list releases for $TARGET_REPO; refusing to seed the version from a failed API call" >&2
      exit 1
    fi
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
  # Der erzwungene Release-Typ muss ins Profil, nicht nur in die Legacy-Zeilen
  # (Audit H-6). Nur bei echtem Override: bei `auto` stimmt der Wert je
  # Komponente ohnehin, und ihn repo-weit zu ueberschreiben wuerde im Monorepo
  # richtige Werte zerstoeren.
  rt_override=""
  [[ "$LANG_OVERRIDE" != "auto" ]] && rt_override="$release_type"
  OVERRIDE_DEFAULT_BRANCH="$default_branch" OVERRIDE_CURRENT_VERSION="$current_version" \
  ONBOARD_RELEASE_TYPE_OVERRIDE="$rt_override" \
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
  refuse_manifest "$REPO_PATH"
  # Mehrdeutige Wurzelsignale brechen hier ab, genau wie im Legacy-Modus.
  #
  # Bisher tat das nur der Legacy-Modus ("legacy mode only" stand sogar im
  # Kopf dieser Datei). Der JSON-Modus nahm still `.[0]` der erkannten Sprachen.
  # Gemessen an einem Repo mit go.mod UND pyproject.toml im Wurzelverzeichnis:
  #
  #   Legacy-Modus     rc=1, "ambiguous language signals: go python"
  #   --profile-json   rc=0, primary_language=go, warnings=[]
  #
  # Und die gerenderte ci.yml traegt dann lint-go-root und test-go-root - die
  # Python-Haelfte faellt ersatzlos weg, ohne ein Wort. Der Go-Detektor bricht
  # an derselben Stelle ab; zwei Engines waren sich uneinig, ob so ein Repo
  # ueberhaupt onboardbar ist.
  #
  # Der Weg heraus ist fuer beide Engines derselbe: die Sprache im Manifest
  # deklarieren (`components[].language`). Diese Engine lehnt Manifeste ab und
  # verweist dafuer auf die Go-CLI - siehe refuse_manifest oben.
  refuse_ambiguous_root_language "$REPO_PATH"
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
refuse_manifest "$REPO_PATH"

# shellcheck source=lib/onboard-detect-lib.sh
source "$SCRIPT_DIR/lib/onboard-detect-lib.sh"

if [[ "$LANG_OVERRIDE" != "auto" ]]; then
  language="$LANG_OVERRIDE"
else
  # Geteilt mit dem --profile-json-Pfad, damit beide Modi dieselbe Liste sehen.
  mapfile -t matches < <(root_language_signals "$REPO_PATH")

  if (( ${#matches[@]} == 0 )); then
    if detect_gitops_kubernetes "$REPO_PATH"; then language=gitops; else language=simple; fi
  elif (( ${#matches[@]} == 1 )); then
    language="${matches[0]}"
  else
    echo "::error::ambiguous language signals: ${matches[*]}; rerun with explicit language input" >&2
    exit 1
  fi
fi

case "$language" in
  flutter) release_type="dart" ;;
  gitops)  release_type="simple" ;;
  *)       release_type="$language" ;;
esac

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
  # Fehler nicht verschlucken, siehe oben (Audit H-5).
  if ! raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null); then
    echo "::error::could not list releases for $TARGET_REPO; refusing to seed the version from a failed API call" >&2
    exit 1
  fi
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
