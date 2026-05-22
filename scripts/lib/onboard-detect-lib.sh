#!/usr/bin/env bash
# onboard-detect-lib.sh — JSON profile builders.
# Sourced by scripts/onboard-detect.sh and tested via bats.
#
# Public entry point:
#   emit_profile_json <repo-path>
#     → prints the full profile JSON document to stdout.
#
# Internal helpers:
#   detect_components       — enumerate sub-components for monorepos, else single root
#   detect_languages        — per-component language marker inventory
#   inventory_dockerfiles   — per-component Dockerfile inventory + image-name override
#   read_image_override     — read `# onboard:image=<name>` from a Dockerfile
#   derive_image_name       — convention-based image name when no override is set
#   detect_role             — service / cli / helm-app / library classification
#   detect_release_signals  — goreleaser config + secondary chart_yaml paths
#   detect_legacy_ci        — classify legacy .github/workflows/*.yml and suggest replacements
#   emit_unsupported_language_warnings — append no_lint_test_atom warnings for unsupported primary_language values
#   emit_no_release_eligible_warnings  — append no_release_eligible warnings for components whose Dockerfiles are all dev/aux

# shellcheck shell=bash
set -euo pipefail

# Supported primary_language values for lint/test atoms in the catalog.
# Anything outside this set triggers a `no_lint_test_atom` warning in profile.json.
# IMPORTANT: keep this list in sync with docs/adopter-templates/skeletons/ci.yml.tmpl
# (Task 11 rewrites that template to consume these warnings).
SUPPORTED_LINT_TEST_LANGUAGES='go|python|rust|helm'

emit_profile_json() {
  local repo="$1"
  local target_repo="${TARGET_REPO:-}"
  local default_branch="main"
  local current_version="0.0.0"

  if [[ -n "$target_repo" ]]; then
    default_branch=$(gh api "/repos/$target_repo" -q '.default_branch' 2>/dev/null || echo "main")
    local tag
    tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    # jq '.[0].tagName' on an empty release list returns the literal string
    # "null" (exit 0, not an error). Treat "null" as no-release-found.
    [[ -n "$tag" && "$tag" != "null" ]] && current_version="${tag#v}"
  fi

  local components
  components=$(detect_components "$repo")
  local legacy_ci
  legacy_ci=$(detect_legacy_ci "$repo")

  local profile
  profile=$(jq -n \
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
    }')

  profile=$(emit_unsupported_language_warnings "$profile")
  emit_no_release_eligible_warnings "$profile"
}

# Append a `no_lint_test_atom` warning for each unique component primary_language
# that has no lint/test atom in the catalog. Reads the full profile JSON on stdin-as-arg,
# emits the updated profile JSON to stdout.
# Signature: emit_unsupported_language_warnings <profile-json>
emit_unsupported_language_warnings() {
  local profile_json="$1"
  echo "$profile_json" | jq --arg supported "$SUPPORTED_LINT_TEST_LANGUAGES" '
    . as $root
    | (.components
        | map(.primary_language)
        | unique
        | map(select(test("^(" + $supported + ")$") | not))
        | map({
            code: "no_lint_test_atom",
            primary_language: .,
            message: ("no lint/test atom for primary_language=" + . + "; rendered ci.yml will fall back to secscan only")
          })
      ) as $extra
    | $root | .warnings += $extra
  '
}

# Append a `no_release_eligible` warning for each component that has 1+ Dockerfiles
# but none are release_eligible. Such a component would render a release.yml with
# no docker-build job, which is usually a surprise — adopters opt-in via
# `# onboard:release=true` on the Dockerfile(s) they want shipped.
# Reads the full profile JSON, emits the updated profile JSON to stdout.
# Signature: emit_no_release_eligible_warnings <profile-json>
emit_no_release_eligible_warnings() {
  local profile_json="$1"
  echo "$profile_json" | jq '
    . as $root
    | (.components
        | map(select(
            (.dockerfiles | length > 0) and
            ([.dockerfiles[] | select(.release_eligible)] | length == 0)
          ))
        | map({
            code: "no_release_eligible",
            path: .path,
            message: ("component at " + .path + " has " + ((.dockerfiles | length) | tostring) +
                      " Dockerfile(s) but none are release-eligible; rendered release.yml will skip docker-build. Set `# onboard:release=true` on the Dockerfile(s) to ship.")
          })
      ) as $extra
    | $root | .warnings += $extra
  '
}

# detect_components — enumerate monorepo components or fall back to single-component.
#
# Detection order:
#   1) Explicit monorepo markers: go.work / Cargo.toml [workspace] / pnpm-workspace.yaml
#   2) Fallback monorepo: 2+ sub-markers (go.mod / pyproject.toml / Cargo.toml / Chart.yaml)
#   3) Sub-Dockerfile fallback: 2+ Dockerfiles in subdirs without language markers
#   4) Single-component fallback (path=".")
detect_components() {
  local repo="$1"

  # 1) Explicit monorepo markers
  local paths=()
  if [[ -f "$repo/go.work" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(awk '/^use \(/{flag=1;next}/^\)/{flag=0}flag{gsub(/[()"\t ]/,"");print}' "$repo/go.work" | sed 's|^\./||')
  elif [[ -f "$repo/Cargo.toml" ]] && grep -q '^\[workspace\]' "$repo/Cargo.toml" 2>/dev/null; then
    # Cargo workspace: members = [ "crates/a", "crates/b" ]  (single-line or multi-line)
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(awk '
      /^\[workspace\]/{flag=1; next}
      /^\[/ && !/^\[workspace\]/{flag=0}
      flag && /members[[:space:]]*=/{
        capture=1
      }
      capture {
        line = line $0
        if (index($0, "]") > 0) {
          gsub(/.*\[|\].*/, "", line)
          n = split(line, arr, ",")
          for (i=1; i<=n; i++) {
            gsub(/[[:space:]"]/, "", arr[i])
            if (arr[i] != "") print arr[i]
          }
          capture=0; line=""
        }
      }
    ' "$repo/Cargo.toml")
  elif [[ -f "$repo/pnpm-workspace.yaml" ]]; then
    # packages: ["apps/*", "packages/foo"]  — expand globs against the repo
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        local rel="${d#"$repo"/}"
        paths+=("$rel")
      done < <(compgen -G "$repo/$pat" 2>/dev/null || true)
    done < <(awk '
      /^packages:/{flag=1; next}
      flag && /^[[:space:]]*-/{
        line=$0
        gsub(/.*-[[:space:]]*/, "", line)
        gsub(/^[\042\047]/, "", line)
        gsub(/[\042\047][[:space:]]*$/, "", line)
        print line
      }
      flag && /^[^[:space:]-]/{flag=0}
    ' "$repo/pnpm-workspace.yaml")
  fi

  # 2) Fallback monorepo via multiple sub-markers — only when the root has no primary
  # marker of its own. If the root is already a component (has go.mod / pyproject.toml /
  # Cargo.toml / Chart.yaml / Dockerfile / Containerfile / package.json), any nested
  # marker (e.g. charts/svc/Chart.yaml) is a release signal of the root component,
  # not a sibling.
  local root_has_marker=false
  if [[ -f "$repo/go.mod" || -f "$repo/pyproject.toml" || -f "$repo/Cargo.toml" \
        || -f "$repo/Chart.yaml" || -f "$repo/Dockerfile" || -f "$repo/Containerfile" \
        || -f "$repo/package.json" ]]; then
    root_has_marker=true
  fi
  if [[ ${#paths[@]} -eq 0 && "$root_has_marker" == "false" ]]; then
    while IFS= read -r m; do
      local d
      d=$(dirname "$m")
      d="${d#"$repo"/}"
      [[ "$d" == "." ]] && continue
      paths+=("$d")
    done < <(find "$repo" -mindepth 2 -maxdepth 3 \( -name 'go.mod' -o -name 'pyproject.toml' -o -name 'Cargo.toml' -o -name 'Chart.yaml' \) 2>/dev/null | sort -u)
  fi

  # 3) Sub-Dockerfile/Containerfile fallback (no language markers but multiple sub-Dockerfiles/Containerfiles)
  if [[ ${#paths[@]} -eq 0 ]]; then
    local sub_dockerfile_dirs=()
    while IFS= read -r f; do
      local d
      d=$(dirname "$f")
      d="${d#"$repo"/}"
      [[ "$d" == "." ]] && continue
      sub_dockerfile_dirs+=("$d")
    done < <(find "$repo" -mindepth 2 -maxdepth 3 \( -name 'Dockerfile' -o -name 'Containerfile' \) 2>/dev/null | sort -u)
    if [[ ${#sub_dockerfile_dirs[@]} -ge 2 ]]; then
      paths=("${sub_dockerfile_dirs[@]}")
    fi
  fi

  # 4) Single-component fallback
  if [[ ${#paths[@]} -eq 0 ]]; then
    paths=(".")
  fi

  # De-duplicate while preserving order
  declare -A seen=()
  local unique=()
  local p
  for p in "${paths[@]}"; do
    if [[ -z "${seen[$p]:-}" ]]; then
      seen[$p]=1
      unique+=("$p")
    fi
  done

  local arr='[]'
  for p in "${unique[@]}"; do
    local langs role dockerfiles primary signals cgo
    langs=$(detect_languages "$repo" "$p")
    dockerfiles=$(inventory_dockerfiles "$repo" "$p")
    role=$(detect_role "$repo" "$p" "$dockerfiles")
    primary=$(echo "$langs" | jq -r '.[0] // "generic"')
    signals=$(detect_release_signals "$repo" "$p")
    cgo=$(detect_cgo "$repo" "$p" "$primary")

    arr=$(echo "$arr" | jq \
      --arg path "$p" \
      --argjson languages "$langs" \
      --arg primary "$primary" \
      --arg role "$role" \
      --argjson dockerfiles "$dockerfiles" \
      --argjson signals "$signals" \
      --argjson cgo "$cgo" \
      '. + [{
        path: $path,
        languages: $languages,
        primary_language: $primary,
        release_please_type: $primary,
        role: $role,
        dockerfiles: $dockerfiles,
        release_signals: $signals,
        cgo: $cgo
      }]')
  done
  echo "$arr"
}

# Well-known Go packages whose own source imports cgo. An adopter pulling any
# of these (direct OR transitive — these all need CGO_ENABLED=1 at build time)
# must run lint/test with cgo on, even if its OWN source has no `import "C"`.
# Add to this list when a new cgo-via-dep adopter onboards.
CGO_PACKAGES=(
  'github.com/mattn/go-sqlite3'   # SQLite (most common)
  'github.com/mattn/go-oci8'      # Oracle (legacy)
  'github.com/godror/godror'      # Oracle (current)
  'github.com/microsoft/go-mssqldb'
  'crawshaw.io/sqlite'            # alt SQLite
  'github.com/containerd/btrfs'
)

# Signature: detect_cgo <repo> <path> <primary_language>
# Emits "true" if ANY of: (a) a *.go file under the component imports cgo
# (`import "C"`), or (b) the component's go.mod references a known transitive
# cgo dep (CGO_PACKAGES). Non-go components always return "false".
detect_cgo() {
  local repo="$1" path="$2" primary="$3"
  [[ "$primary" == "go" ]] || { echo false; return; }
  local p="$repo/$path"

  # (a) Direct: match `import "C"` as a standalone import or inside a
  # parenthesized import block. -q exits on first hit.
  if grep -rqE '^[[:space:]]*"C"[[:space:]]*$|^[[:space:]]*import[[:space:]]+"C"' \
       --include='*.go' "$p" 2>/dev/null; then
    echo true; return
  fi

  # (b) Transitive: scan go.mod for any well-known cgo-via-dep package. A
  # plain substring grep is correct here — go.mod lists deps as full module
  # paths on their own line, so e.g. `github.com/mattn/go-sqlite3 v1.14.x`
  # matches without partial-prefix collisions.
  if [[ -f "$p/go.mod" ]]; then
    for pkg in "${CGO_PACKAGES[@]}"; do
      if grep -qF -- "$pkg" "$p/go.mod" 2>/dev/null; then
        echo true; return
      fi
    done
  fi

  echo false
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

# Inventory all Dockerfiles in a component path. Emits a JSON array of objects:
#   [{path, image_name, image_name_source}, ...]
# image_name_source ∈ {override, derived}.
# `path` is the Dockerfile filename relative to the component path (e.g., "Dockerfile" or "Dockerfile.worker").
# Signature: inventory_dockerfiles <repo> <path>
inventory_dockerfiles() {
  local repo="$1" path="$2"
  local p="$repo/$path"
  [[ -d "$p" ]] || { echo '[]'; return; }

  # Collect Dockerfile + Containerfile names at component root only.
  local files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$(basename "$f")")
  done < <(find "$p" -maxdepth 1 -type f \( \
             -name 'Dockerfile' -o -name 'Dockerfile.*' \
             -o -name 'Containerfile' -o -name 'Containerfile.*' \
           \) 2>/dev/null | sort || true)

  if (( ${#files[@]} == 0 )); then
    echo '[]'; return
  fi

  local arr='[]'
  local fname
  for fname in "${files[@]}"; do
    local override image_name image_name_source release_override release_eligible
    override=$(read_image_override "$p/$fname")
    if [[ -n "$override" ]]; then
      image_name="$override"
      image_name_source="override"
    else
      image_name=$(derive_image_name "$fname" "$path")
      image_name_source="derived"
    fi
    # release-eligibility: bare `Dockerfile`/`Containerfile` default true,
    # any `*.<suffix>` default false. Header override wins.
    if [[ "$fname" == "Dockerfile" || "$fname" == "Containerfile" ]]; then
      release_eligible="true"
    else
      release_eligible="false"
    fi
    release_override=$(read_release_override "$p/$fname")
    if [[ -n "$release_override" ]]; then
      release_eligible="$release_override"
    fi
    arr=$(echo "$arr" | jq \
      --arg path "$fname" \
      --arg image_name "$image_name" \
      --arg image_name_source "$image_name_source" \
      --argjson release_eligible "$release_eligible" \
      '. + [{
        path: $path,
        image_name: $image_name,
        image_name_source: $image_name_source,
        release_eligible: $release_eligible
      }]')
  done
  echo "$arr"
}

# Read `# onboard:image=<name>` override from the first 5 lines of a Dockerfile.
# Emits the name on stdout, or empty string if absent.
# Signature: read_image_override <file-path>
read_image_override() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return; }
  awk '/^# onboard:image=[A-Za-z0-9._\/-]+/{sub(/^# onboard:image=/,""); print; exit} NR>5{exit}' "$file"
}

# Read `# onboard:release=true` or `# onboard:release=false` override from
# the first 5 lines of a Dockerfile. Emits "true", "false", or empty.
# Signature: read_release_override <file-path>
read_release_override() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return; }
  head -n 5 "$file" 2>/dev/null \
    | grep -m1 -oE '^# onboard:release=(true|false)' \
    | sed 's/^# onboard:release=//' || true
}

# Derive image name from Dockerfile filename and component path.
#   path="."             Dockerfile          → $REPO
#   path="."             Dockerfile.worker   → $REPO-worker
#   path="services/foo"  Dockerfile          → $REPO-foo
#   path="services/foo"  Dockerfile.worker   → $REPO-foo-worker
# The literal $REPO placeholder is substituted by the renderer (Phase 3).
# Signature: derive_image_name <filename> <component-path>
derive_image_name() {
  local filename="$1" cpath="$2"
  local suffix=""
  if [[ "$filename" == "Dockerfile" || "$filename" == "Containerfile" ]]; then
    suffix=""
  elif [[ "$filename" =~ ^(Dockerfile|Containerfile)\.(.+)$ ]]; then
    suffix="${BASH_REMATCH[2]}"
  fi

  local seg=""
  if [[ "$cpath" != "." ]]; then
    seg="${cpath##*/}"
  fi

  if [[ -n "$seg" && -n "$suffix" ]]; then
    echo "\$REPO-${seg}-${suffix}"
  elif [[ -n "$seg" ]]; then
    echo "\$REPO-${seg}"
  elif [[ -n "$suffix" ]]; then
    echo "\$REPO-${suffix}"
  else
    echo "\$REPO"
  fi
}

# Determine the component's role from filesystem signals.
# Priority: Dockerfile > CLI signal > Chart.yaml > default library.
# Signature: detect_role <repo> <path> <dockerfiles-json>
detect_role() {
  local repo="$1" path="$2" dockerfiles="$3"
  local p="$repo/$path"

  local has_docker
  has_docker=$(echo "$dockerfiles" | jq 'length > 0')
  if [[ "$has_docker" == "true" ]]; then
    echo "service"; return
  fi

  # CLI heuristics — check before helm-app so a CLI with Chart.yaml isn't misclassified.
  if [[ -d "$p/cmd" ]]; then
    # cmd/<name>/main.go pattern (Go)
    if [[ -n "$(find "$p/cmd" -mindepth 2 -maxdepth 2 -name 'main.go' -print -quit 2>/dev/null)" ]]; then
      echo "cli"; return
    fi
  fi
  if [[ -f "$p/Cargo.toml" ]] && grep -q '^\[\[bin\]\]' "$p/Cargo.toml" 2>/dev/null; then
    echo "cli"; return
  fi
  if [[ -f "$p/pyproject.toml" ]] && grep -qE '^\[project\.scripts\]|^\[tool\.poetry\.scripts\]' "$p/pyproject.toml" 2>/dev/null; then
    echo "cli"; return
  fi

  if [[ -f "$p/Chart.yaml" ]]; then
    echo "helm-app"; return
  fi

  echo "library"
}

# detect_release_signals — emit a JSON object describing optional release signals:
#   {
#     "goreleaser_config": <path/string|null>,  # path to .goreleaser.{yaml,yml} at component root
#     "chart_yaml":        <path/string|null>   # path to a SUB-chart inside the component
#   }
# A component-root Chart.yaml is reported via role=helm-app, not via this signal.
# A sub-chart at e.g. charts/<name>/Chart.yaml means the component publishes a chart
# alongside its primary artifact (service binary or image).
# Signature: detect_release_signals <repo> <path>
detect_release_signals() {
  local repo="$1" path="$2"
  local p="$repo/$path"

  local gorel="null"
  local f
  for f in .goreleaser.yaml .goreleaser.yml goreleaser.yaml goreleaser.yml; do
    if [[ -f "$p/$f" ]]; then
      local rel
      if [[ "$path" == "." ]]; then
        rel="$f"
      else
        rel="$path/$f"
      fi
      gorel=$(jq -nc --arg s "$rel" '$s')
      break
    fi
  done

  # chart_yaml is a SECONDARY chart inside the component (not the component-root Chart.yaml,
  # which makes the component itself a helm-app). Depth 3 = charts/<name>/Chart.yaml,
  # depth 4 = helm/charts/<name>/Chart.yaml.
  local chart="null"
  local found_chart
  found_chart=$(cd "$p" && find . -mindepth 2 -maxdepth 4 -name 'Chart.yaml' 2>/dev/null | head -n 1 || true)
  if [[ -n "$found_chart" ]]; then
    # found_chart is "./charts/svc/Chart.yaml"; strip leading "./"
    found_chart="${found_chart#./}"
    local rel
    if [[ "$path" == "." ]]; then
      rel="$found_chart"
    else
      rel="$path/$found_chart"
    fi
    chart=$(jq -nc --arg s "$rel" '$s')
  fi

  jq -nc \
    --argjson goreleaser_config "$gorel" \
    --argjson chart_yaml "$chart" \
    '{goreleaser_config: $goreleaser_config, chart_yaml: $chart_yaml}'
}

# Scan .github/workflows/*.{yml,yaml} (non-recursive) for legacy CI patterns,
# emitting one entry per file (excluding OWNED filenames the renderer produces).
# Signature: detect_legacy_ci <repo>
detect_legacy_ci() {
  local repo="${1:-}"
  local dir="$repo/.github/workflows"
  if [[ ! -d "$dir" ]]; then
    echo '[]'; return
  fi

  # Filenames OWNED by the catalog renderer — skip classification.
  local OWNED=(ci.yml release.yml prerelease.yml cleanup.yml)

  local arr='[]'
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local base
    base=$(basename "$f")
    local owned=0
    local o
    for o in "${OWNED[@]}"; do
      [[ "$base" == "$o" ]] && owned=1 && break
    done
    [[ $owned -eq 1 ]] && continue

    local summary="" replacements='[]'
    if grep -q 'aquasecurity/trivy-action' "$f" 2>/dev/null; then
      summary="trivy-action (deprecated); replace with trivy-fs.yml or trivy-image.yml"
      replacements='["trivy-fs.yml","trivy-image.yml"]'
    elif grep -q 'docker/build-push-action' "$f" 2>/dev/null; then
      summary="docker/build-push-action; replaced by docker-build.yml"
      replacements='["docker-build.yml"]'
    elif grep -qE 'docker (build|buildx).*--push|docker push ' "$f" 2>/dev/null; then
      summary="ad-hoc docker buildx + push; replaced by docker-build.yml"
      replacements='["docker-build.yml"]'
    elif grep -q 'semantic-release' "$f" 2>/dev/null; then
      summary="hand-rolled semantic-release; replaced by release-please.yml"
      replacements='["release-please.yml"]'
    else
      summary="unrecognized legacy workflow; manual review needed"
    fi

    local rel="${f#"$repo"/}"
    arr=$(echo "$arr" | jq \
      --arg path "$rel" \
      --arg summary "$summary" \
      --argjson replaced_by "$replacements" \
      '. + [{path: $path, summary: $summary, replaced_by: $replaced_by}]')
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort || true)

  echo "$arr"
}
