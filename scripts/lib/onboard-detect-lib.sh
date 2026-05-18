#!/usr/bin/env bash
# onboard-detect-lib.sh — JSON profile builders.
# Sourced by scripts/onboard-detect.sh and tested via bats.
#
# Public entry point:
#   emit_profile_json <repo-path>
#     → prints the full profile JSON document to stdout.
#
# Internal helpers (some are stubs filled in by later tasks):
#   detect_components       — Task 2.2 skeleton, extended for monorepo in Task 2.3
#   detect_languages        — per-component language inventory
#   inventory_dockerfiles   — Task 2.4 (currently stub → [])
#   detect_role             — Task 2.5 minimal heuristic; refined later
#   detect_release_signals  — Task 2.5 (currently stub)
#   detect_legacy_ci        — Task 2.6 (currently stub → [])

# shellcheck shell=bash
set -euo pipefail

emit_profile_json() {
  local repo="$1"
  local target_repo="${TARGET_REPO:-}"
  local default_branch="main"
  local current_version="0.0.0"

  if [[ -n "$target_repo" ]]; then
    default_branch=$(gh api "/repos/$target_repo" -q '.default_branch' 2>/dev/null || echo "main")
    local tag
    tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    [[ -n "$tag" ]] && current_version="${tag#v}"
  fi

  local components
  components=$(detect_components "$repo")
  local legacy_ci
  legacy_ci=$(detect_legacy_ci "$repo")

  jq -n \
    --argjson schema_version 1 \
    --arg target_repo "$target_repo" \
    --arg default_branch "$default_branch" \
    --arg current_version "$current_version" \
    --argjson monorepo "$(echo "$components" | jq 'length > 1')" \
    --argjson components "$components" \
    --argjson legacy_ci "$legacy_ci" \
    --argjson warnings '[]' \
    '{
      schema_version: $schema_version,
      target_repo: $target_repo,
      default_branch: $default_branch,
      current_version: $current_version,
      monorepo: $monorepo,
      components: $components,
      legacy_ci: $legacy_ci,
      warnings: $warnings
    }'
}

# Minimal first cut — single-component, ignores monorepo markers (added in Task 2.3).
detect_components() {
  local repo="$1"
  local langs dockerfiles role primary signals
  langs=$(detect_languages "$repo" ".")
  dockerfiles=$(inventory_dockerfiles "$repo" ".")
  role=$(detect_role "$repo" "." "$dockerfiles")
  primary=$(echo "$langs" | jq -r '.[0] // "generic"')
  signals=$(detect_release_signals "$repo" ".")

  jq -n \
    --arg path "." \
    --argjson languages "$langs" \
    --arg primary "$primary" \
    --arg role "$role" \
    --argjson dockerfiles "$dockerfiles" \
    --argjson signals "$signals" \
    '[{
      path: $path,
      languages: $languages,
      primary_language: $primary,
      release_please_type: $primary,
      role: $role,
      dockerfiles: $dockerfiles,
      release_signals: $signals
    }]'
}

detect_languages() {
  local repo="$1" path="$2"
  local p="$repo/$path"
  local langs=()
  [[ -f "$p/go.mod" ]]         && langs+=(go)
  [[ -f "$p/pyproject.toml" ]] && langs+=(python)
  [[ -f "$p/Cargo.toml" ]]     && langs+=(rust)
  [[ -f "$p/Chart.yaml" ]]     && langs+=(helm)
  [[ -f "$p/package.json" ]]   && langs+=(node)
  if (( ${#langs[@]} == 0 )); then
    echo '[]'
  else
    printf '%s\n' "${langs[@]}" | jq -R . | jq -s .
  fi
}

# Stub for Task 2.4 — emits an empty array. Real Dockerfile inventory + override parsing
# lands in Task 2.4. Keeping the function name stable lets that task swap in the body.
inventory_dockerfiles() {
  echo '[]'
}

# Stub for Task 2.5 — minimal heuristic, refined in Task 2.5.
detect_role() {
  local repo="$1" path="$2" dockerfiles="$3"
  local p="$repo/$path"
  local has_docker
  has_docker=$(echo "$dockerfiles" | jq 'length > 0')
  if [[ "$has_docker" == "true" ]]; then
    echo "service"; return
  fi
  if [[ -f "$p/Chart.yaml" ]]; then
    echo "helm-app"; return
  fi
  echo "library"
}

# detect_release_signals — emit a JSON object describing optional release signals:
#   {
#     "goreleaser_config": <path/string|null>,  # path to .goreleaser.yaml if present
#     "chart_yaml":        <path/string|null>   # path to charts/*/Chart.yaml if present
#   }
# Task 2.5 fills this in.
detect_release_signals() {
  echo '{"goreleaser_config": null, "chart_yaml": null}'
}

# Stub for Task 2.6 — legacy CI scan lands later.
detect_legacy_ci() {
  echo '[]'
}
