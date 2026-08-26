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
#   detect_gitops_kubernetes — true when the repo matches the Talos/cluster-template fingerprint
#   _gitops_manifests_paths — enumerate kubernetes/<workload> roots (excludes bootstrap/components/flux-system)
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
SUPPORTED_LINT_TEST_LANGUAGES='go|python|rust|helm|flutter'

# Languages that have a catalog atom set and therefore must NOT trigger the
# no_lint_test_atom warning, even though they are not lint/test-named. gitops
# is served by kube-validate / kube-lint / secret-scan instead of lint-X/test-X.
WARNING_EXEMPT_LANGUAGES="${SUPPORTED_LINT_TEST_LANGUAGES}|gitops"

# Wie mit einem fehlgeschlagenen GitHub-Metadaten-Aufruf umzugehen ist.
#
# Rueckgabe 1 (Vorgabe): der Aufrufer soll abbrechen. Das ist der
# ONBOARDING-Fall - ein Repo zum ersten Mal zu rendern und dabei zu raten,
# heisst `.release-please-manifest.json` mit 0.0.0 zu seeden, obwohl das Repo
# auf 1.10.0 steht (Audit H-5, H-10).
#
# Rueckgabe 0, wenn ONBOARD_METADATA_OPTIONAL gesetzt ist: der Aufrufer soll
# degradieren. Das ist der DRIFT-Fall - ein bereits onboardetes Repo wird nur
# erneut gerendert, um es mit dem Eingecheckten zu vergleichen, und Drift laeuft
# in Jobs, die gar kein Token minten. Ein fehlendes Token macht den Vergleich
# nicht wertlos; ein harter Abbruch haette jeden tokenlosen Drift-Lauf zu
# `status=error` gemacht (genau so gemessen, self-ci onboard-drift-happy).
#
# Der Go-Pfad trennt dasselbe an derselben Stelle: die Toleranz sitzt in
# godetect.tolerantMetadata, das nur `drift` umschliesst, nicht im Detektor.
# Gesetzt wird die Variable ausschliesslich von scripts/onboard-drift.sh.
_metadata_failed() {
  local what="$1"
  if [[ -n "${ONBOARD_METADATA_OPTIONAL:-}" ]]; then
    echo "::warning::${what} (drift: degrading instead of failing)" >&2
    return 0
  fi
  echo "::error::${what}" >&2
  return 1
}

# Loest Workspace-Muster gegen das Repo auf und gibt nur Verzeichnisse
# INNERHALB des Repos zurueck, jeweils repo-relativ, eines pro Zeile.
# Signature: _expand_workspace_patterns <repo> <pattern>...
#
# Zwei Funde in einer Funktion:
#
#   H-8/B-8: Cargo-Member wurden woertlich uebernommen. `members = ["crates/*"]`
#   ergab eine Komponente mit dem Pfad `crates/*` - ein Verzeichnis, das es
#   nicht gibt. Die echten Crates bekamen dadurch KEINE Jobs: kein Lint, kein
#   Test, kein Scan. `crates/*` ist das uebliche Cargo-Layout. Der pnpm-Zweig
#   direkt daneben expandierte laengst.
#
#   H-7/B-11: ein Member-Pfad kann aus dem Checkout herausfuehren
#   (`../nachbar`). Die gerenderten Workflows trugen dann ein
#   `working_directory`, das beim Adopter woanders hinzeigt.
#
# Der Go-Detektor macht dasselbe (expandWorkspacePatterns).
_expand_workspace_patterns() {
  local repo="$1"; shift
  local repo_real
  repo_real=$(cd "$repo" 2>/dev/null && pwd -P) || return 0
  local pat d real rel
  for pat in "$@"; do
    [[ -z "$pat" ]] && continue
    while IFS= read -r d; do
      [[ -d "$d" ]] || continue
      real=$(cd "$d" 2>/dev/null && pwd -P) || continue
      case "$real/" in
        "$repo_real"/*) ;;
        *) continue ;;                 # zeigt aus dem Checkout heraus
      esac
      rel="${real#"$repo_real"/}"
      [[ -n "$rel" && "$rel" != "$real" ]] && printf '%s\n' "$rel"
    done < <(compgen -G "$repo/$pat" 2>/dev/null || true)
  done
}

# Flutter detection helper. Arg: absolute component directory.
# True when pubspec.yaml exists AND declares the Flutter SDK dependency
# (`sdk: flutter`) — every Flutter app/package has it; a pure-Dart package
# does not.
#
# `[[:blank:]]+` — one or more spaces/tabs, deliberately not `*` and not
# `[[:space:]]`:
#   * zero would match `sdk:flutter`, which YAML does not read as a mapping at
#     all (a colon needs trailing whitespace), so such a file declares no
#     Flutter dependency. The old `*` claimed it did.
#   * `[[:space:]]` would drift from the Go side, which matches within a line;
#     `[[:blank:]]` is exactly space+tab, so both sides agree by construction.
# Two spaces or a tab ARE valid YAML and do mean Flutter — the Go detector used
# to miss those and rendered such repos as `simple`, i.e. without any Flutter
# lint/test/build job at all.
_component_is_flutter() {
  local dir="$1"
  [[ -f "$dir/pubspec.yaml" ]] && grep -qE 'sdk:[[:blank:]]+flutter' "$dir/pubspec.yaml"
}

# GitOps cluster-template detection. Arg: repo root.
# True only when all three legs hold: a kubernetes/ dir (workloads), a
# .sops.yaml (SOPS encryption config), and a cluster-template generator marker
# (makejinja.toml OR bootstrap/templates/). The .sops.yaml + template
# conjunction prevents a false positive on a service repo that merely ships a
# kubernetes/ deploy dir.
# root_language_signals — die Sprachmarker im Wurzelverzeichnis, als Zeilen.
#
# Frueher stand diese Liste nur inline im Legacy-Block von onboard-detect.sh.
# Der JSON-Modus brauchte dieselbe Liste fuer seine Mehrdeutigkeitspruefung -
# und eine zweite, woertliche Kopie waere genau der Zwilling gewesen, an dem
# `# onboard:image=` und `# onboard:release=` schon auseinandergelaufen sind.
# Also einmal definiert, beide Pfade rufen sie.
#
# Signature: root_language_signals <repo-path>
root_language_signals() {
  local repo="$1"
  [[ -f "$repo/go.mod" ]]         && echo go
  [[ -f "$repo/pyproject.toml" ]] && echo python
  [[ -f "$repo/Cargo.toml" ]]     && echo rust
  [[ -f "$repo/Chart.yaml" ]]     && echo helm
  _component_is_flutter "$repo"   && echo flutter
  [[ -f "$repo/package.json" ]]   && echo node
  return 0
}

# refuse_ambiguous_root_language — bricht ab, wenn mehr als ein Sprachmarker im
# Wurzelverzeichnis liegt und keine Deklaration das aufloest.
#
# Signature: refuse_ambiguous_root_language <repo-path>
refuse_ambiguous_root_language() {
  local repo="$1" matches
  mapfile -t matches < <(root_language_signals "$repo")
  if (( ${#matches[@]} > 1 )); then
    echo "::error::ambiguous language signals: ${matches[*]}; rerun with explicit language input" >&2
    exit 1
  fi
}

detect_gitops_kubernetes() {
  local repo="$1"
  [[ -d "$repo/kubernetes" ]] || return 1
  [[ -f "$repo/.sops.yaml" ]] || return 1
  [[ -f "$repo/makejinja.toml" || -d "$repo/bootstrap/templates" ]] || return 1
  return 0
}

# Enumerate kubernetes/<dir> workload roots for a gitops repo, excluding the
# non-workload control dirs: bootstrap (Talos bootstrap), components (shared
# kustomize components), flux-system (Flux controllers). Emits a compact JSON
# array (e.g. ["kubernetes/apps","kubernetes/argo"]) or [] when none.
_gitops_manifests_paths() {
  local repo="$1"
  local dirs=()
  local d base
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    base=$(basename "$d")
    case "$base" in
      bootstrap|components|flux-system) continue ;;
    esac
    dirs+=("kubernetes/$base")
  done < <(find "$repo/kubernetes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  if (( ${#dirs[@]} == 0 )); then
    echo '[]'
  else
    printf '%s\n' "${dirs[@]}" | jq -R . | jq -cs .
  fi
}

emit_profile_json() {
  local repo="$1"
  local target_repo="${TARGET_REPO:-}"
  local default_branch="${OVERRIDE_DEFAULT_BRANCH:-main}"
  local current_version="${OVERRIDE_CURRENT_VERSION:-0.0.0}"

  # OVERRIDE_DEFAULT_BRANCH and OVERRIDE_CURRENT_VERSION are set by the
  # --emit-both dispatch path so we can skip a second gh-api roundtrip; when
  # called via --profile-json (legacy callers), they are unset and we do the
  # lookups ourselves.
  if [[ -z "${OVERRIDE_DEFAULT_BRANCH:-}" && -n "$target_repo" ]]; then
    # Ein fehlgeschlagener API-Aufruf darf nicht wie eine Antwort aussehen
    # (Audit H-5, H-10). Frueher stand hier `|| echo "main"` und `|| echo ""`:
    # ein Rate-Limit, ein 500er oder ein abgelaufener Token ergaben damit
    # "Default-Branch heisst main" und "es gibt keine Releases" - beides
    # plausibel, beides frei erfunden.
    #
    # `onboard-detect.sh` bricht an der gleichen Stelle laengst mit exit 1 ab;
    # diese Engine tat es nicht. Zwei Codepfade desselben Repos waren sich also
    # uneinig, was ein API-Fehler bedeutet.
    if ! default_branch=$(gh api "/repos/$target_repo" -q '.default_branch' 2>/dev/null); then
      _metadata_failed "repo not accessible: $target_repo" || return 1
      default_branch="main"
    fi
    local tag
    # rc trennt die Faelle sauber, gemessen:
    #   Repo mit Releases     rc=0, Tag
    #   Repo OHNE Releases    rc=0, leer      <- gueltig, current_version bleibt 0.0.0
    #   Repo existiert nicht  rc=1, leer
    #   Token ungueltig       rc=1, leer
    if ! tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null); then
      _metadata_failed "could not list releases for $target_repo; refusing to seed the version from a failed API call" || return 1
      tag=""
    fi
    # jq '.[0].tagName' on an empty release list returns the literal string
    # "null" (exit 0, not an error). Treat "null" as no-release-found.
    [[ -n "$tag" && "$tag" != "null" ]] && current_version="${tag#v}"
  fi

  # Repo topics — a general signal consumed by the renderer (e.g. the
  # `sk-prerelease-on-push` opt-in). gh prints the HTTP error body to STDOUT on
  # failure, so the fallback MUST be outside the substitution (see
  # troubleshooting: gh-api-leaks-error-body-to-stdout); -q '.names' emits the
  # array as compact JSON.
  local topics='[]'
  if [[ -n "$target_repo" ]]; then
    # Topics steuern Opt-ins, allen voran `sk-prerelease-on-push`. Ein
    # verschluckter Fehler hiess "das Repo hat keine Topics" und damit
    # "prerelease-on-push.yml wird nicht gerendert" - ein Adopter haette das
    # Opt-in still verloren (Audit H-10). Ein Repo OHNE Topics antwortet mit
    # rc=0 und einer leeren Liste; das bleibt gueltig.
    if ! topics=$(gh api "/repos/$target_repo/topics" -q '.names' 2>/dev/null); then
      _metadata_failed "could not read topics for $target_repo; refusing to render as if it had none" || return 1
      topics='[]'
    fi
    [[ -z "$topics" || "$topics" == "null" ]] && topics='[]'
  fi

  local components
  components=$(detect_components "$repo")

  # Zwei Dockerfiles duerfen nicht denselben Image-Namen tragen (Audit H-4).
  #
  # Der abgeleitete Name nimmt nur das LETZTE Pfadsegment: `apps/api` und
  # `services/api` ergeben beide `$REPO-api`. Beide Komponenten wuerden dann in
  # dasselbe GHCR-Image pushen; derselbe Versionstag zeigt danach auf den Build,
  # der zufaellig zuletzt lief, und cleanup-images sieht ein Paket statt zweier.
  #
  # Abgewiesen statt automatisch entschaerft - dieselbe Entscheidung wie bei den
  # kollidierenden Job-IDs (J-0b): ein angehaengter Hash muesste fuer alle
  # bestehenden Adopter stabil bleiben und waere in der Registry nicht mehr
  # zuzuordnen.
  #
  # Der Go-Detektor prueft dasselbe (checkImageNameCollisions); die Engines
  # duerfen sich hier nicht unterscheiden.
  local image_collision
  image_collision=$(echo "$components" | jq -r '
    [ .[] as $c | $c.dockerfiles[]? | select(.image_name != "" and .image_name != null)
      | {name: .image_name, where: ($c.path + "/" + .path)} ]
    | group_by(.name) | map(select(length > 1)) | .[0] // empty
    | "\(.[0].name)|\(.[0].where)|\(.[1].where)"
  ')
  if [[ -n "$image_collision" ]]; then
    IFS='|' read -r _ic_name _ic_a _ic_b <<< "$image_collision"
    echo "::error::duplicate image name \"${_ic_name}\": ${_ic_a} and ${_ic_b} both map to it — rename one of the directories; the last path segment becomes both the image name and the release-please package name, and must be unique" >&2
    return 1
  fi

  # Zwei Komponenten duerfen nicht denselben release-please-Paketnamen
  # bekommen. Gefunden ueber das Suchmuster "nicht-injektive Abbildung": die
  # Image-Namen-Pruefung darueber fing den Fall nur, wenn beide Komponenten ein
  # Dockerfile tragen. Ohne Dockerfiles gab es nichts zu vergleichen, und die
  # gerenderte release-please-config.json gab beiden `package-name: api`.
  # release-please erzeugt daraus fuer beide Tags `api-vX.Y.Z`.
  #
  # Das Manifest verbietet dasselbe laengst; fuer auto-erkannte Repos fehlte
  # die Regel. Die Wurzelkomponente ist ausgenommen, genau wie dort.
  #
  # Der Go-Detektor prueft dasselbe (checkPackageNameCollisions).
  local pkg_collision
  pkg_collision=$(echo "$components" | jq -r '
    [ .[] | select(.path != ".") | {name: (.path | split("/") | last), where: .path} ]
    | group_by(.name) | map(select(length > 1)) | .[0] // empty
    | "\(.[0].name)|\(.[0].where)|\(.[1].where)"
  ')
  if [[ -n "$pkg_collision" ]]; then
    IFS='|' read -r _pc_name _pc_a _pc_b <<< "$pkg_collision"
    echo "::error::duplicate release-please package name \"${_pc_name}\": ${_pc_a} and ${_pc_b} both map to it — rename one of the directories; the last path segment becomes the package name and must be unique" >&2
    return 1
  fi

  local legacy_ci
  legacy_ci=$(detect_legacy_ci "$repo")

  # GitOps post-process: when the repo matches the cluster-template fingerprint
  # AND no component has a buildable (lint/test) language, reclassify the root
  # component as primary_language=gitops and attach a top-level .gitops object.
  # This reuses the component-range + lock machinery (one ci.yml.tmpl arm)
  # rather than a separate profile_kind axis. Non-gitops profiles are untouched.
  local gitops_obj="null"
  if detect_gitops_kubernetes "$repo"; then
    local has_buildable
    has_buildable=$(echo "$components" | jq --arg s "$SUPPORTED_LINT_TEST_LANGUAGES" \
      'any(.[]; .primary_language | test("^(" + $s + ")$"))')
    if [[ "$has_buildable" == "false" ]]; then
      components=$(echo "$components" | jq \
        '.[0].primary_language = "gitops"
         | .[0].release_please_type = "simple"
         | .[0].role = "gitops"')
      local manifests_paths kube_linter_cfg gitleaks_cfg sops_present
      manifests_paths=$(_gitops_manifests_paths "$repo")
      kube_linter_cfg=false; [[ -f "$repo/.kube-linter.yaml" ]] && kube_linter_cfg=true
      gitleaks_cfg=false;     [[ -f "$repo/.gitleaks.toml" ]]   && gitleaks_cfg=true
      sops_present=false;     [[ -f "$repo/.sops.yaml" ]]       && sops_present=true
      gitops_obj=$(jq -nc \
        --argjson manifests_paths "$manifests_paths" \
        --argjson has_kube_linter_config "$kube_linter_cfg" \
        --argjson has_gitleaks_config "$gitleaks_cfg" \
        --argjson sops "$sops_present" \
        '{manifests_paths: $manifests_paths,
          has_kube_linter_config: $has_kube_linter_config,
          has_gitleaks_config: $has_gitleaks_config,
          sops: $sops}')
    fi
  fi

  local profile
  profile=$(jq -n \
    --argjson schema_version 1 \
    --arg target_repo "$target_repo" \
    --arg default_branch "$default_branch" \
    --arg current_version "$current_version" \
    --argjson monorepo "$(echo "$components" | jq 'length > 1')" \
    --argjson components "$components" \
    --argjson legacy_ci "$legacy_ci" \
    --argjson topics "$topics" \
    --argjson warnings '[]' \
    '{
      schema_version: $schema_version,
      target_repo: $target_repo,
      default_branch: $default_branch,
      current_version: $current_version,
      monorepo: $monorepo,
      components: $components,
      legacy_ci: $legacy_ci,
      topics: $topics,
      warnings: $warnings
    }')

  if [[ "$gitops_obj" != "null" ]]; then
    profile=$(echo "$profile" | jq --argjson g "$gitops_obj" '. + {gitops: $g}')
  fi

  profile=$(emit_unsupported_language_warnings "$profile")
  profile=$(emit_unassigned_subdir_dockerfile_warnings "$profile" "$repo")
  profile=$(apply_release_type_override "$profile" "${ONBOARD_RELEASE_TYPE_OVERRIDE:-}")
  emit_no_release_eligible_warnings "$profile"
}

# Append a `no_lint_test_atom` warning for each unique component primary_language
# that has no lint/test atom in the catalog. Reads the full profile JSON on stdin-as-arg,
# emits the updated profile JSON to stdout.
# Signature: emit_unsupported_language_warnings <profile-json>
emit_unsupported_language_warnings() {
  local profile_json="$1"
  echo "$profile_json" | jq --arg supported "$WARNING_EXEMPT_LANGUAGES" '
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

# emit_unassigned_subdir_dockerfile_warnings — meldet Dockerfiles in
# Unterverzeichnissen, die zu keiner Komponente gehoeren und deshalb NICHT
# gebaut werden.
#
# Der Go-Detektor meldet das seit je (`subdir_dockerfiles_unassigned`), diese
# Engine nicht. Gemessen an tests/fixtures/onboard/go-root-subdir-dockerfile:
# Go warnt vor images/api/Dockerfile und images/worker/Dockerfile, Bash gab
# `warnings: []` aus. Der Adopter erfuhr je nach onboardender Engine, dass zwei
# seiner Images stillschweigend nicht gebaut werden - oder eben nicht.
#
# Nur der Einkomponenten-Fall, genau wie dort: sobald das Repo in Komponenten
# zerfaellt, ist "gehoert zu keiner" nicht mehr sinnvoll bestimmbar.
#
# Signature: emit_unassigned_subdir_dockerfile_warnings <profile-json> <repo-path>
emit_unassigned_subdir_dockerfile_warnings() {
  local profile_json="$1" repo="$2"
  # Schraegstriche am Ende abschneiden. Ohne das schlaegt der Praefix-Schnitt
  # unten fehl und JEDES Dockerfile gilt als "in einem Unterverzeichnis" - auch
  # das im Wurzelverzeichnis. Gos filepath.Rel stoert ein Schraegstrich nicht,
  # diese Fassung schon, und der Aufrufer darf beides uebergeben.
  while [[ "$repo" == */ && "$repo" != "/" ]]; do repo="${repo%/}"; done

  local shape
  shape=$(echo "$profile_json" | jq -r '"\(.components|length):\(.components[0].path // "")"')
  [[ "$shape" == "1:." ]] || { echo "$profile_json"; return 0; }

  # Versteckte Verzeichnisse werden uebersprungen - `.github/` ist eines, und
  # ein Dockerfile darin ist keine verwaiste Komponente. Der Go-Detektor macht
  # dasselbe (skipHidden).
  local orphans=() f rel
  while IFS= read -r f; do
    rel="${f#"$repo"/}"
    [[ "$rel" == */* ]] && orphans+=("$rel")
  done < <(find "$repo" -type d -name '.*' -prune -o -type f \
             \( -name 'Dockerfile' -o -name 'Containerfile' \
                -o -name 'Dockerfile.*' -o -name 'Containerfile.*' \) \
             -print 2>/dev/null | sort)

  (( ${#orphans[@]} == 0 )) && { echo "$profile_json"; return 0; }

  local joined_comma joined_space
  joined_comma=$(IFS=,; echo "${orphans[*]}")
  joined_space=$(IFS=,; echo "${orphans[*]}"); joined_space="${joined_space//,/, }"

  echo "$profile_json" | jq \
    --arg path "$joined_comma" \
    --arg list "$joined_space" \
    --arg n "${#orphans[@]}" '
    .warnings += [{
      code: "subdir_dockerfiles_unassigned",
      path: $path,
      message: ($n + " Dockerfile(s) in sub-directories are not attached to any component and will not be built: " + $list + ". Declare them in .github/onboard.yml (components[].dockerfiles or their own component).")
    }]'
}

# apply_release_type_override — traegt einen erzwungenen Release-Typ in die
# WURZELKOMPONENTE des Profils ein.
#
# `--language-override` setzte bisher nur die Legacy-Zeilen; das Profil, aus dem
# gerendert wird, blieb unberuehrt (Audit H-6, Bash-Zwilling zu B-4). Gemessen
# an einem go-Repo mit Override `python`: release-please-config.json trug weiter
# `"release-type": "go"`.
#
# Nur der Release-Typ, nicht primary_language: der Eingang verspricht "force
# release-type". Wuerde er auch die Sprachwahl erzwingen, rendere ein
# erzwungenes `python` auf einem reinen Go-Repo Python-Jobs gegen ein Repo ohne
# pyproject.toml. Nur die Wurzel, weil ein repo-weiter Einzelwert sinnvoll nur
# sie meinen kann - trifft er keine, sagt eine Warnung das, statt stumm
# wirkungslos zu bleiben.
#
# Signature: apply_release_type_override <profile-json> <release-type>
apply_release_type_override() {
  local profile_json="$1" rt="$2"
  [[ -z "$rt" ]] && { echo "$profile_json"; return 0; }
  echo "$profile_json" | jq --arg rt "$rt" '
    if any(.components[]; .path == ".") then
      .components |= map(if .path == "." then .release_please_type = $rt else . end)
    else
      .warnings += [{
        code: "language_override_not_applied",
        path: ".",
        message: ("language override release type \"" + $rt + "\" was not applied: this repo has no root component, and a repo-wide release type cannot be assigned to sub-components; declare release types per component in .github/onboard.yml instead")
      }]
    end'
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
    done < <(awk '
      /^use \(/{flag=1; next}
      /^\)/{flag=0; next}
      flag {
        gsub(/[()"\t ]/, "");
        if ($0 != "") print
        next
      }
      /^use[[:space:]]+[^(]/ {
        sub(/^use[[:space:]]+/, "");
        gsub(/["\t ]/, "");
        print
      }
    ' "$repo/go.work" | sed 's|^\./||')
    # Auch hier eingrenzen (Audit B-11): ein `use ../nachbar` zeigte aus dem
    # Checkout heraus. Die bereits gesammelten Pfade werden durch den Helfer
    # geschickt, der sie aufloest und alles ausserhalb verwirft.
    if (( ${#paths[@]} > 0 )); then
      local _gw=("${paths[@]}"); paths=()
      while IFS= read -r p; do
        [[ -n "$p" ]] && paths+=("$p")
      done < <(_expand_workspace_patterns "$repo" "${_gw[@]}")
    fi
  elif [[ -f "$repo/Cargo.toml" ]] && grep -q '^\[workspace\]' "$repo/Cargo.toml" 2>/dev/null; then
    # Cargo workspace: members = [ "crates/a", "crates/*" ]  (single-line or multi-line)
    # Muster werden expandiert und auf das Repo eingegrenzt, siehe
    # _expand_workspace_patterns.
    local _cargo_members=()
    while IFS= read -r p; do
      [[ -n "$p" ]] && _cargo_members+=("$p")
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
    if (( ${#_cargo_members[@]} > 0 )); then
      while IFS= read -r p; do
        [[ -n "$p" ]] && paths+=("$p")
      done < <(_expand_workspace_patterns "$repo" "${_cargo_members[@]}")
    fi
  elif [[ -f "$repo/pnpm-workspace.yaml" ]]; then
    # packages: ["apps/*", "packages/foo"]  — expand globs against the repo
    local _pnpm_patterns=()
    while IFS= read -r pat; do
      [[ -n "$pat" ]] && _pnpm_patterns+=("$pat")
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
    if (( ${#_pnpm_patterns[@]} > 0 )); then
      while IFS= read -r p; do
        [[ -n "$p" ]] && paths+=("$p")
      done < <(_expand_workspace_patterns "$repo" "${_pnpm_patterns[@]}")
    fi
  fi

  # 2) Fallback monorepo via multiple sub-markers — only when the root has no primary
  # marker of its own. If the root is already a component (has go.mod / pyproject.toml /
  # Cargo.toml / Chart.yaml / Dockerfile / Containerfile / package.json), any nested
  # marker (e.g. charts/svc/Chart.yaml) is a release signal of the root component,
  # not a sibling.
  local root_has_marker=false
  if [[ -f "$repo/go.mod" || -f "$repo/pyproject.toml" || -f "$repo/Cargo.toml" \
        || -f "$repo/Chart.yaml" || -f "$repo/Dockerfile" || -f "$repo/Containerfile" \
        || -f "$repo/package.json" || -f "$repo/pubspec.yaml" ]]; then
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
  # — only when the root has no marker of its own (same guard as step 2; a root
  # go.mod/Dockerfile/etc. must not be displaced by Dockerfiles living in sub-directories).
  if [[ ${#paths[@]} -eq 0 && "$root_has_marker" == "false" ]]; then
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
  local -A seen=()
  local unique=()
  local p
  for p in "${paths[@]}"; do
    if [[ -z "${seen[$p]:-}" ]]; then
      seen[$p]=1
      unique+=("$p")
    fi
  done

  local entries=()
  for p in "${unique[@]}"; do
    local langs role dockerfiles primary release_type signals cgo
    langs=$(detect_languages "$repo" "$p")
    dockerfiles=$(inventory_dockerfiles "$repo" "$p")
    role=$(detect_role "$repo" "$p" "$dockerfiles")
    primary=$(echo "$langs" | jq -r '.[0] // "generic"')
    # Map primary_language → release-please-action's release-type enum.
    # "generic" is our internal no-language-detected marker, not a valid
    # release-please type — map it to "simple" (release-please's catch-all
    # for repos without a package-manager-specific version file). Other
    # language strings pass through; if release-please doesn't recognize
    # one, the consumer can override release-please-config.json after onboard.
    case "$primary" in
      generic) release_type="simple" ;;
      flutter) release_type="dart" ;;
      *)       release_type="$primary" ;;
    esac
    signals=$(detect_release_signals "$repo" "$p")
    cgo=$(detect_cgo "$repo" "$p" "$primary")

    entries+=("$(jq -nc \
      --arg path "$p" \
      --argjson languages "$langs" \
      --arg primary "$primary" \
      --arg release_type "$release_type" \
      --arg role "$role" \
      --argjson dockerfiles "$dockerfiles" \
      --argjson signals "$signals" \
      --argjson cgo "$cgo" \
      '{
        path: $path,
        languages: $languages,
        primary_language: $primary,
        release_please_type: $release_type,
        role: $role,
        dockerfiles: $dockerfiles,
        release_signals: $signals,
        cgo: $cgo
      }')")
  done
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${entries[@]}" | jq -cs '.'
  fi
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
  _component_is_flutter "$p"   && langs+=(flutter)
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

  local entries=()
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
    entries+=("$(jq -nc \
      --arg path "$fname" \
      --arg image_name "$image_name" \
      --arg image_name_source "$image_name_source" \
      --argjson release_eligible "$release_eligible" \
      '{
        path: $path,
        image_name: $image_name,
        image_name_source: $image_name_source,
        release_eligible: $release_eligible
      }')")
  done
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${entries[@]}" | jq -cs '.'
  fi
}

# Read `# onboard:image=<name>` override from the first 5 lines of a Dockerfile.
# Emits the name on stdout, or empty string if absent.
# Signature: read_image_override <file-path>
read_image_override() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return; }
  # Dieselbe Regel wie fuer `image:` im Manifest und wie im Go-Detektor
  # (manifest.ImagePattern): OCI-Namen sind kleingeschrieben. Hier stand die
  # grossbuchstaben-tolerante Fassung, und `# onboard:image=Acme/UPPER` lief
  # unbeanstandet durch, waehrend das Manifest denselben Wert laengst abweist.
  #
  # Verankert an BEIDEN Enden: ohne `$` bestand jeder Wert, der mit einem
  # gueltigen Zeichen beginnt - dieselbe Falle wie I-17.
  # `sub(/[ \t\r]+$/,"")` zuerst: ein CR aus einem auf Windows geschriebenen
  # Dockerfile oder ein vom Editor gelassenes Leerzeichen darf nicht ueber das
  # Ergebnis entscheiden. Die Go-Fassung tut dasselbe in firstLines().
  awk '{sub(/[ \t\r]+$/,"")}
       /^# onboard:image=[a-z0-9._\/-]+$/{sub(/^# onboard:image=/,""); print; exit}
       NR>5{exit}' "$file"
}

# Read `# onboard:release=true` or `# onboard:release=false` override from
# the first 5 lines of a Dockerfile. Emits "true", "false", or empty.
# Signature: read_release_override <file-path>
read_release_override() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return; }
  # War `grep -m1 -oE '^# onboard:release=(true|false)'` - nur am ZEILENANFANG
  # verankert, und `-o` schneidet den Treffer heraus. `# onboard:release=false-
  # aber-doch-ja` ergab damit "false", waehrend die Go-Fassung (exakter
  # Zeilenvergleich) die Zeile verwarf und beim Default blieb. Bei einem
  # `Dockerfile`, dessen Default release-faehig ist, entschieden die beiden
  # Engines damit gegensaetzlich ueber die Auslieferung.
  #
  # Jetzt beidseitig verankert, mit demselben Zeilenende-Schnitt wie oben.
  head -n 5 "$file" 2>/dev/null \
    | awk '{sub(/[ \t\r]+$/,"")}
           /^# onboard:release=(true|false)$/{sub(/^# onboard:release=/,""); print; exit}' \
    || true
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

  # OCI-Namen sind kleingeschrieben (Audit H-17). `services/MyService` ergab
  # bisher `$REPO-MyService`, und das landete unveraendert im gerenderten
  # image_name UND im GHCR-package_name. Die Templates lowercasen dieselbe
  # Quelle laengst fuer das Job-ID-Suffix; die Herleitung tat es nicht.
  # Der Go-Detektor macht dasselbe (deriveImageName).
  seg="${seg,,}"
  suffix="${suffix,,}"

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

  if _component_is_flutter "$p" && [[ -d "$p/android" ]]; then
    echo "mobile-app"; return
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

  # Flutter Android release signal: a Flutter component (pubspec declares the
  # flutter SDK) that also has an android/ dir is an Android app and gets a
  # release-flutter-android job. A Flutter *package* (no android/) is linted
  # and tested but not released here.
  local flutter_android=false
  if _component_is_flutter "$p" && [[ -d "$p/android" ]]; then
    flutter_android=true
  fi

  jq -nc \
    --argjson goreleaser_config "$gorel" \
    --argjson chart_yaml "$chart" \
    --argjson flutter_android "$flutter_android" \
    '{goreleaser_config: $goreleaser_config, chart_yaml: $chart_yaml, flutter_android: $flutter_android}'
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
  local OWNED=(ci.yml release.yml prerelease.yml prerelease-on-push.yml cleanup.yml)

  local entries=()
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

    # Pattern order matters: stronger/more-specific signals first. A workflow
    # that does docker push + cargo test is a docker-build replacement (the
    # cargo step is incidental). Conversely, cargo-llvm-cov is a near-certain
    # test-rust signal regardless of what else the file does.
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
    elif grep -q 'cargo-llvm-cov' "$f" 2>/dev/null; then
      summary="cargo-llvm-cov test pipeline; replaced by test-rust.yml"
      replacements='["test-rust.yml"]'
    elif grep -qE 'pytest|coverage run' "$f" 2>/dev/null; then
      summary="python test pipeline (pytest/coverage); replaced by test-python.yml"
      replacements='["test-python.yml"]'
    elif grep -qE 'go test.*(-cover|-coverprofile|-race)' "$f" 2>/dev/null; then
      summary="go test pipeline; replaced by test-go.yml"
      replacements='["test-go.yml"]'
    elif grep -q 'semantic-release' "$f" 2>/dev/null; then
      summary="hand-rolled semantic-release; replaced by release-please.yml"
      replacements='["release-please.yml"]'
    elif grep -q 'kubeconform' "$f" 2>/dev/null; then
      summary="kubeconform manifest validation; replaced by kube-validate.yml"
      replacements='["kube-validate.yml"]'
    elif grep -qE 'kube-linter|stackrox/kube-linter' "$f" 2>/dev/null; then
      summary="kube-linter; replaced by kube-lint.yml"
      replacements='["kube-lint.yml"]'
    elif grep -q 'gitleaks' "$f" 2>/dev/null; then
      summary="gitleaks secret scan; replaced by secret-scan.yml"
      replacements='["secret-scan.yml"]'
    elif grep -qE 'trivy (fs|filesystem|rootfs)' "$f" 2>/dev/null; then
      summary="trivy filesystem scan (CLI); replaced by trivy-fs.yml"
      replacements='["trivy-fs.yml"]'
    else
      summary="unrecognized legacy workflow; manual review needed"
    fi

    local rel="${f#"$repo"/}"
    entries+=("$(jq -nc \
      --arg path "$rel" \
      --arg summary "$summary" \
      --argjson replaced_by "$replacements" \
      '{path: $path, summary: $summary, replaced_by: $replaced_by}')")
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort || true)

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${entries[@]}" | jq -cs '.'
  fi
}
