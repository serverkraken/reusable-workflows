# GitOps Onboard Detection + Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the onboard detector to recognise Talos/cluster-template GitOps repos and make the renderer emit a `ci.yml`-only kube-validation workflow for them, so `homelab-study` and `homelab-incus-oracle` become first-class catalog adopters.

**Architecture:** Additive `primary_language="gitops"` reuses the existing component-range + lock machinery: one detection helper sets the marker and attaches a top-level `profile.gitops` object; the renderer becomes variant-aware (gitops → render `ci.yml` only, never release-please); `ci.yml.tmpl` gains one `gitops` arm that wires `kube-validate` + `kube-lint` + `secret-scan` and a gitops-only `secscan` skip set. No existing field changes shape — `schema_version` stays `1`.

**Tech Stack:** Bash (`scripts/lib/onboard-detect-lib.sh`, `scripts/onboard-{detect,render}.sh`), `jq`, gomplate Go-templates (`docs/adopter-templates/skeletons/ci.yml.tmpl`), bats (`tests/shell/*.bats`), golden fixtures (`tests/fixtures/onboard/`, `tests/shell/golden/ci/`).

---

## Preamble — worktree + dependency

This is **PR2** of the GitOps phase. **PR1** (`docs/superpowers/plans/2026-05-30-gitops-support-atoms.md`) ships the `kube-validate.yml` / `kube-lint.yml` / `secret-scan.yml` atoms + the `trivy-fs.yml` `files_ignore` enhancement + the integration callers.

**Branch ordering:** Land PR1 first, then branch this work from `origin/main` so main is internally consistent. Plan 2's own test suite (bats detect + render + golden) does **not** execute the atoms — the rendered `ci.yml` references them via remote refs (`serverkraken/reusable-workflows/.github/workflows/kube-validate.yml@v4`), and `actionlint` does **not** resolve remote `uses:` targets — so the render/golden tests pass even before PR1 merges. The runtime dependency (atoms must exist) only bites at PR4 (auto-onboard). Integration callers that exercise the atoms belong to **PR1**, not this plan.

Before starting, from the catalog repo root:

```bash
git worktree list                       # confirm no existing worktree owns this work
git fetch origin
git worktree add .worktrees/gitops-onboard -b feat/gitops-onboard origin/main
cd .worktrees/gitops-onboard
```

All task paths below are relative to that worktree root.

---

## File Structure

**Modify:**
- `scripts/lib/onboard-detect-lib.sh` — add `detect_gitops_kubernetes` + `_gitops_manifests_paths` helpers; add `WARNING_EXEMPT_LANGUAGES` global; gitops post-process in `emit_profile_json`; `detect_legacy_ci` recognition for the four superseded workflows.
- `scripts/onboard-detect.sh` — legacy `language=gitops` in both the `--emit-both` and pure-legacy paths; `gitops) release_type="simple"` in both case blocks; header doc.
- `scripts/onboard-render.sh` — variant-aware render set + lock array (gitops → `ci.yml` only).
- `docs/adopter-templates/skeletons/ci.yml.tmpl` — gitops arm in the `primary_language` chain + gitops-only `secscan` skip block.
- `actions/onboard-detect/action.yml` — `language_override` doc string adds `gitops`.

**Create:**
- `tests/fixtures/onboard/gitops-cluster/` — happy-path fixture (`kubernetes/{apps,argo,bootstrap,components}`, `.sops.yaml`, `makejinja.toml`, `.kube-linter.yaml`, `.gitleaks.toml`), `expected/` added in Task 7.
- `tests/shell/golden/ci/gitops.yml` — hand-curated rendered `ci.yml` golden for the inline render test.

**Test files (extend existing):**
- `tests/shell/onboard-detect.bats` — helper unit tests, profile-json assertions, legacy_ci recognition, legacy-mode `language=gitops`.
- `tests/shell/onboard-render.bats` — variant render-set + lock tests, inline `render_ci_for_profile` golden, full `golden_check "gitops-cluster"`.

---

## Task 1: Detection helpers — `detect_gitops_kubernetes` + `_gitops_manifests_paths`

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (insert after `_component_is_flutter`, line 37)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
# ---- gitops detection helpers (Task 1) ----

# Source the lib directly to unit-test the helper functions.
load_lib() { source "$REPO_ROOT/scripts/lib/onboard-detect-lib.sh"; }

@test "detect_gitops_kubernetes: true on full cluster-template fingerprint" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps" "$d/bootstrap/templates"
  touch "$d/.sops.yaml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
}

@test "detect_gitops_kubernetes: true via makejinja.toml marker" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps"
  touch "$d/.sops.yaml" "$d/makejinja.toml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
}

@test "detect_gitops_kubernetes: false when .sops.yaml missing" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps" "$d/bootstrap/templates"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ]
}

@test "detect_gitops_kubernetes: false when kubernetes/ missing" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bootstrap/templates"
  touch "$d/.sops.yaml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ]
}

@test "detect_gitops_kubernetes: false when no cluster-template marker" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps"
  touch "$d/.sops.yaml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ]
}

@test "_gitops_manifests_paths: enumerates workload dirs, excludes control dirs" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps" "$d/kubernetes/argo" \
           "$d/kubernetes/bootstrap" "$d/kubernetes/components" "$d/kubernetes/flux-system"
  load_lib
  run _gitops_manifests_paths "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .)" = '["kubernetes/apps","kubernetes/argo"]' ]
}

@test "_gitops_manifests_paths: empty array when no workload dirs" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/bootstrap"
  load_lib
  run _gitops_manifests_paths "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/shell/onboard-detect.bats -f gitops`
Expected: FAIL — `detect_gitops_kubernetes: command not found` / `_gitops_manifests_paths: command not found`.

- [ ] **Step 3: Implement the helpers**

In `scripts/lib/onboard-detect-lib.sh`, insert after the `_component_is_flutter` function (after line 37, before `emit_profile_json`):

```bash
# GitOps cluster-template detection. Arg: repo root.
# True only when all three legs hold: a kubernetes/ dir (workloads), a
# .sops.yaml (SOPS encryption config), and a cluster-template generator marker
# (makejinja.toml OR bootstrap/templates/). The .sops.yaml + template
# conjunction prevents a false positive on a service repo that merely ships a
# kubernetes/ deploy dir.
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/shell/onboard-detect.bats -f gitops`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): add gitops cluster-template detection helpers"
```

---

## Task 2: GitOps fixture + `emit_profile_json` post-process + warning exemption

**Files:**
- Create: `tests/fixtures/onboard/gitops-cluster/` (multiple files below)
- Modify: `scripts/lib/onboard-detect-lib.sh` (add `WARNING_EXEMPT_LANGUAGES` after line 28; gitops post-process in `emit_profile_json`; switch `emit_unsupported_language_warnings` to the exempt list)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Create the happy-path fixture**

```bash
mkdir -p tests/fixtures/onboard/gitops-cluster/kubernetes/apps/app1 \
         tests/fixtures/onboard/gitops-cluster/kubernetes/argo/argo1 \
         tests/fixtures/onboard/gitops-cluster/kubernetes/bootstrap \
         tests/fixtures/onboard/gitops-cluster/kubernetes/components
```

Create `tests/fixtures/onboard/gitops-cluster/kubernetes/apps/app1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

Create `tests/fixtures/onboard/gitops-cluster/kubernetes/apps/app1/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app1
```

Create `tests/fixtures/onboard/gitops-cluster/kubernetes/argo/argo1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

Create `tests/fixtures/onboard/gitops-cluster/kubernetes/argo/argo1/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argo1
```

Create `tests/fixtures/onboard/gitops-cluster/kubernetes/bootstrap/talos.yaml` (proves `bootstrap` exclusion):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: talos-bootstrap
```

Create `tests/fixtures/onboard/gitops-cluster/kubernetes/components/shared.yaml` (proves `components` exclusion):

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
```

Create `tests/fixtures/onboard/gitops-cluster/.sops.yaml`:

```yaml
creation_rules:
  - path_regex: .*\.sops\.yaml$
    age: age1examplepublickeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Create `tests/fixtures/onboard/gitops-cluster/makejinja.toml`:

```toml
[makejinja]
inputs = ["bootstrap/templates"]
output = "kubernetes"
```

Create `tests/fixtures/onboard/gitops-cluster/.kube-linter.yaml`:

```yaml
checks:
  addAllBuiltIn: false
  include:
    - latest-tag
```

Create `tests/fixtures/onboard/gitops-cluster/.gitleaks.toml`:

```toml
title = "gitops-cluster gitleaks config"
[extend]
useDefault = true
```

- [ ] **Step 2: Write the failing profile-json tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
# ---- gitops profile-json (Task 2) ----

@test "profile-json: gitops-cluster sets primary_language=gitops" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "gitops"'
}

@test "profile-json: gitops-cluster sets role=gitops" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.components[0].role == "gitops"'
}

@test "profile-json: gitops-cluster release_please_type is simple" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.components[0].release_please_type == "simple"'
}

@test "profile-json: gitops-cluster attaches .gitops object" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.gitops.manifests_paths == ["kubernetes/apps","kubernetes/argo"]'
  echo "$output" | jq -e '.gitops.sops == true'
  echo "$output" | jq -e '.gitops.has_kube_linter_config == true'
  echo "$output" | jq -e '.gitops.has_gitleaks_config == true'
}

@test "profile-json: gitops-cluster emits zero warnings" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.warnings | length == 0'
}

@test "profile-json: non-gitops profile has no .gitops key" {
  run "$DETECT" --profile-json "$FIX/go-repo"
  echo "$output" | jq -e 'has("gitops") | not'
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/shell/onboard-detect.bats -f "gitops-cluster"`
Expected: FAIL — `primary_language` is `generic`, no `.gitops` key, and a `no_lint_test_atom` warning is present.

- [ ] **Step 4: Add the warning-exemption global**

In `scripts/lib/onboard-detect-lib.sh`, immediately after the `SUPPORTED_LINT_TEST_LANGUAGES` definition (after line 28):

```bash
# Languages that have a catalog atom set and therefore must NOT trigger the
# no_lint_test_atom warning, even though they are not lint/test-named. gitops
# is served by kube-validate / kube-lint / secret-scan instead of lint-X/test-X.
WARNING_EXEMPT_LANGUAGES="${SUPPORTED_LINT_TEST_LANGUAGES}|gitops"
```

Then in `emit_unsupported_language_warnings` change the `--arg supported` source (line 94) from `"$SUPPORTED_LINT_TEST_LANGUAGES"` to `"$WARNING_EXEMPT_LANGUAGES"`:

```bash
  echo "$profile_json" | jq --arg supported "$WARNING_EXEMPT_LANGUAGES" '
```

- [ ] **Step 5: Add the gitops post-process to `emit_profile_json`**

In `scripts/lib/onboard-detect-lib.sh`, after `legacy_ci=$(detect_legacy_ci "$repo")` (line 61) and before the `local profile` / `jq -n` block (line 63), insert:

```bash
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
```

Then, after the `jq -n` profile assignment closes (after line 82, the line with `}')`) and before `profile=$(emit_unsupported_language_warnings "$profile")` (line 84), insert:

```bash
  if [[ "$gitops_obj" != "null" ]]; then
    profile=$(echo "$profile" | jq --argjson g "$gitops_obj" '. + {gitops: $g}')
  fi
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/shell/onboard-detect.bats -f "gitops-cluster"`
Expected: PASS (6 tests).

- [ ] **Step 7: Run the full detect suite for no regressions**

Run: `bats tests/shell/onboard-detect.bats`
Expected: PASS (all — the `non-gitops profile has no .gitops key` test and every pre-existing test stay green).

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/onboard/gitops-cluster scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): emit gitops profile + exempt gitops from no_lint_test_atom"
```

---

## Task 3: `detect_legacy_ci` recognition for superseded workflows

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (`detect_legacy_ci`, add elif arms before the `else` fallback at line 640)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
# ---- gitops legacy_ci recognition (Task 3) ----

# Build a tmp repo with a single legacy workflow file containing $2, assert the
# detected replaced_by equals $3 (a JSON array literal).
_legacy_one() {
  local fname="$1" body="$2"
  local d; d="$(mktemp -d)"
  mkdir -p "$d/.github/workflows"
  printf '%s\n' "$body" > "$d/.github/workflows/$fname"
  "$DETECT" --profile-json "$d"
  rm -rf "$d"
}

@test "legacy_ci: kubeconform.yaml → kube-validate.yml" {
  out=$(_legacy_one "kubeconform.yaml" "run: kubeconform -strict")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("kubeconform.yaml")) | .replaced_by] | flatten == ["kube-validate.yml"]'
}

@test "legacy_ci: kube-linter.yaml → kube-lint.yml" {
  out=$(_legacy_one "kube-linter.yaml" "uses: stackrox/kube-linter-action@v1")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("kube-linter.yaml")) | .replaced_by] | flatten == ["kube-lint.yml"]'
}

@test "legacy_ci: gitleaks.yaml → secret-scan.yml" {
  out=$(_legacy_one "gitleaks.yaml" "run: gitleaks detect --source .")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("gitleaks.yaml")) | .replaced_by] | flatten == ["secret-scan.yml"]'
}

@test "legacy_ci: trivy.yaml (CLI fs scan) → trivy-fs.yml" {
  out=$(_legacy_one "trivy.yaml" "run: trivy fs --scanners vuln .")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("trivy.yaml")) | .replaced_by] | flatten == ["trivy-fs.yml"]'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/shell/onboard-detect.bats -f "legacy_ci:"`
Expected: the four new tests FAIL — these files fall through to the `unrecognized` branch (`replaced_by == []`).

- [ ] **Step 3: Implement the recognition arms**

In `scripts/lib/onboard-detect-lib.sh`, in `detect_legacy_ci`, insert these arms after the `semantic-release` elif (after line 639, the `replacements='["release-please.yml"]'` line) and before the `else` fallback (line 640):

```bash
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
```

> Placement note: these arms sit after the `aquasecurity/trivy-action` arm (line 619), so a workflow still using the deprecated action keeps its `["trivy-fs.yml","trivy-image.yml"]` migration message; only a CLI-based `trivy fs` file (homelab-study's pattern, post-migration) reaches the new arm.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/shell/onboard-detect.bats -f "legacy_ci:"`
Expected: PASS (all legacy_ci tests, new + pre-existing).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): recognise kube/gitleaks/trivy-fs legacy workflows for cleanup"
```

---

## Task 4: Legacy `language=gitops` in `onboard-detect.sh`

**Files:**
- Modify: `scripts/onboard-detect.sh` (`--emit-both` path lines 64–76; pure-legacy path lines 137–161; header doc lines 22–26)
- Test: `tests/shell/onboard-detect.bats`

This is the cosmetic legacy key=value path (the renderer uses `profile_json`); it surfaces `language=gitops` in the onboarding status report.

- [ ] **Step 1: Write the failing tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
# ---- gitops legacy key=value path (Task 4) ----

@test "legacy mode: gitops-cluster reports language=gitops" {
  run "$DETECT" "$FIX/gitops-cluster"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=gitops"* ]]
  [[ "$output" == *"release_type=simple"* ]]
}

@test "emit-both: gitops-cluster reports language=gitops + valid profile_json" {
  run "$DETECT" --emit-both "$FIX/gitops-cluster"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=gitops"* ]]
  # the profile_json block carries the gitops object
  echo "$output" | sed -n '/profile_json<</,/^EOF_/p' | sed '1d;$d' | jq -e '.gitops.sops == true'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/shell/onboard-detect.bats -f "gitops"`
Expected: the two new tests FAIL — legacy detection currently emits `language=simple` (no buildable marker, no gitops branch).

- [ ] **Step 3: Implement — pure-legacy path**

In `scripts/onboard-detect.sh`, source the lib in the legacy path. After the repo-path existence check (after line 135, the closing `fi` of the `! -d` guard) and before the `if [[ "$LANG_OVERRIDE" != "auto" ]]` block (line 137):

```bash
# shellcheck source=lib/onboard-detect-lib.sh
source "$SCRIPT_DIR/lib/onboard-detect-lib.sh"
```

Then change the matches-empty branch (lines 148–149) from:

```bash
  if (( ${#matches[@]} == 0 )); then
    language=simple
```

to:

```bash
  if (( ${#matches[@]} == 0 )); then
    if detect_gitops_kubernetes "$REPO_PATH"; then language=gitops; else language=simple; fi
```

And update the case statement (lines 158–161) to add a gitops arm:

```bash
case "$language" in
  flutter) release_type="dart" ;;
  gitops)  release_type="simple" ;;
  *)       release_type="$language" ;;
esac
```

- [ ] **Step 4: Implement — `--emit-both` path**

The lib is already sourced in `--emit-both` (line 42). Change its matches-empty branch (lines 64–65) from:

```bash
    if (( ${#matches[@]} == 0 )); then
      language=simple
```

to:

```bash
    if (( ${#matches[@]} == 0 )); then
      if detect_gitops_kubernetes "$REPO_PATH"; then language=gitops; else language=simple; fi
```

And its case statement (lines 73–76):

```bash
  case "$language" in
    flutter) release_type="dart" ;;
    gitops)  release_type="simple" ;;
    *)       release_type="$language" ;;
  esac
```

- [ ] **Step 5: Update the header doc**

In `scripts/onboard-detect.sh`, update the legacy-mode language enum (line 23):

```bash
#   language=<go|python|rust|helm|flutter|node|gitops|simple>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/shell/onboard-detect.bats`
Expected: PASS (all — including the two new gitops legacy tests and every pre-existing test).

- [ ] **Step 7: Commit**

```bash
git add scripts/onboard-detect.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): surface language=gitops in legacy detect output"
```

---

## Task 5: Variant-aware render set + lock file in `onboard-render.sh`

**Files:**
- Modify: `scripts/onboard-render.sh` (add `IS_GITOPS` after line 45; gate the non-ci renders lines 96–106; variant `RENDERED` array lines 139–146)
- Test: `tests/shell/onboard-render.bats`

This must land **before** Task 6 (template arm), because the inline gitops render/golden tests need `ci.yml`-only rendering first.

- [ ] **Step 1: Write the failing tests**

Append to `tests/shell/onboard-render.bats`:

```bash
# ---- gitops variant render set (Task 5) ----

@test "render: gitops profile produces ci.yml only (no release-please set)" {
  seed_profile "gitops-cluster"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
  [ ! -f "$TARGET/.github/workflows/release.yml" ]
  [ ! -f "$TARGET/.github/workflows/prerelease.yml" ]
  [ ! -f "$TARGET/.github/workflows/cleanup.yml" ]
  [ ! -f "$TARGET/release-please-config.json" ]
  [ ! -f "$TARGET/.release-please-manifest.json" ]
  [ -f "$TARGET/.github/onboard.lock.json" ]
}

@test "render: gitops lock file lists ci.yml only" {
  seed_profile "gitops-cluster"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  files=$(jq -r '.files | keys[]' "$TARGET/.github/onboard.lock.json")
  [ "$files" = ".github/workflows/ci.yml" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/shell/onboard-render.bats -f gitops`
Expected: FAIL — the renderer currently emits the full six-file set and locks all six.

- [ ] **Step 3: Add the `IS_GITOPS` flag**

In `scripts/onboard-render.sh`, after `MONOREPO=$(jq -r '.monorepo' "$PROFILE")` (line 45):

```bash
# GitOps profiles render ci.yml ONLY — never release-please / prerelease /
# cleanup. The gitops repos use bespoke calendar-versioned release flows the
# catalog must not overwrite (see spec §Scope). `.gitops` is present iff the
# detector matched the cluster-template fingerprint.
IS_GITOPS=$(jq -r 'if (.gitops // null) != null then "true" else "false" end' "$PROFILE")
```

- [ ] **Step 4: Gate the non-ci renders**

In `scripts/onboard-render.sh`, the `ci.yml` render (line 95) stays unconditional. Wrap the four remaining renders + the release-please config/manifest (lines 96–106) in a not-gitops guard:

```bash
render "$SKELETONS/ci.yml.tmpl"         "$TARGET/.github/workflows/ci.yml"
if [[ "$IS_GITOPS" != "true" ]]; then
  render "$SKELETONS/release.yml.tmpl"    "$TARGET/.github/workflows/release.yml"
  render "$SKELETONS/prerelease.yml.tmpl" "$TARGET/.github/workflows/prerelease.yml"
  render "$SKELETONS/cleanup.yml.tmpl"    "$TARGET/.github/workflows/cleanup.yml"

  # release-please config: single vs monorepo.
  if [[ "$MONOREPO" == "true" ]]; then
    render "$CONFIGS/release-please-config.monorepo.json.tmpl" "$TARGET/release-please-config.json"
  else
    render "$CONFIGS/release-please-config.json.tmpl"          "$TARGET/release-please-config.json"
  fi
  render "$CONFIGS/release-please-manifest.json.tmpl" "$TARGET/.release-please-manifest.json"
fi
```

> The `$REPO` substitution loop (lines 128–135) targets `release.yml`/`prerelease.yml` and is already guarded by `[[ -f "$f" ]]`, so it is a harmless no-op for gitops — leave it unchanged.

- [ ] **Step 5: Make the lock `RENDERED` array variant-aware**

In `scripts/onboard-render.sh`, replace the fixed `RENDERED=( ... )` array (lines 139–146) with:

```bash
if [[ "$IS_GITOPS" == "true" ]]; then
  RENDERED=(
    ".github/workflows/ci.yml"
  )
else
  RENDERED=(
    ".github/workflows/ci.yml"
    ".github/workflows/release.yml"
    ".github/workflows/prerelease.yml"
    ".github/workflows/cleanup.yml"
    "release-please-config.json"
    ".release-please-manifest.json"
  )
fi
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/shell/onboard-render.bats -f gitops`
Expected: PASS (2 tests).

- [ ] **Step 7: Run the full render suite for no regressions**

Run: `bats tests/shell/onboard-render.bats`
Expected: PASS (all — non-gitops profiles still render six files + lock).

- [ ] **Step 8: Commit**

```bash
git add scripts/onboard-render.sh tests/shell/onboard-render.bats
git commit -m "feat(onboard): render ci.yml only for gitops profiles"
```

---

## Task 6: `ci.yml.tmpl` gitops arm + secscan skip block + inline golden

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl` (secscan `with:` block lines 28–31; language chain before line 112)
- Create: `tests/shell/golden/ci/gitops.yml`
- Test: `tests/shell/onboard-render.bats` (inline `render_ci_for_profile`)

- [ ] **Step 1: Write the golden file**

Create `tests/shell/golden/ci/gitops.yml` (the hand-curated expected render; the `diff -u` test in Step 4 is the arbiter — if whitespace differs, adjust the template trimming in Step 3, not this golden):

```yaml
name: ci
on:
  pull_request:

jobs:
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@v4
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      severity: ${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}
      trivy_version: ${{ vars.SK_TRIVY_VERSION || '' }}
      paths_ignore: |-
        bootstrap/templates
      files_ignore: |-
        secrets.yaml
        config.yaml
        github-deploy.key
        age.key
        secrets.sample.yaml
    secrets: inherit

  kube-validate:
    uses: serverkraken/reusable-workflows/.github/workflows/kube-validate.yml@v4
    permissions:
      contents: read
    with:
      manifests_paths: |-
        kubernetes/apps
        kubernetes/argo
      sops: true
    secrets: inherit
  kube-lint:
    uses: serverkraken/reusable-workflows/.github/workflows/kube-lint.yml@v4
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      config_path: .kube-linter.yaml
    secrets: inherit
  secret-scan:
    uses: serverkraken/reusable-workflows/.github/workflows/secret-scan.yml@v4
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      config_path: .gitleaks.toml
    secrets: inherit
```

- [ ] **Step 2: Write the failing render tests**

Append to `tests/shell/onboard-render.bats` (in the `render_ci_for_profile` golden section, after the flutter cases ~line 412):

```bash
@test "ci.yml renders kube-validation jobs for a gitops component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/cluster",
    "default_branch": "main", "current_version": "0.0.0", "monorepo": false,
    "components": [{"path": ".", "languages": [], "primary_language": "gitops",
      "release_please_type": "simple", "role": "gitops",
      "dockerfiles": [], "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": [],
    "gitops": {"manifests_paths": ["kubernetes/apps","kubernetes/argo"],
      "has_kube_linter_config": true, "has_gitleaks_config": true, "sops": true}
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/gitops.yml" "$rendered"
}

@test "ci.yml gitops omits config_path when adopter has no own config" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/cluster",
    "default_branch": "main", "current_version": "0.0.0", "monorepo": false,
    "components": [{"path": ".", "languages": [], "primary_language": "gitops",
      "release_please_type": "simple", "role": "gitops",
      "dockerfiles": [], "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": [],
    "gitops": {"manifests_paths": ["kubernetes/apps"],
      "has_kube_linter_config": false, "has_gitleaks_config": false, "sops": false}
  }')
  grep -qF "kube-validate.yml@v4" "$rendered"
  grep -qF "kube-lint.yml@v4" "$rendered"
  grep -qF "secret-scan.yml@v4" "$rendered"
  ! grep -q "config_path" "$rendered"
  grep -qF "sops: false" "$rendered"
}
```

- [ ] **Step 3: Implement the template changes**

In `docs/adopter-templates/skeletons/ci.yml.tmpl`, **(a)** add the gitops secscan skip block. Between the `trivy_version:` line (line 30) and `secrets: inherit` (line 31):

```gotemplate
      trivy_version: {{`${{ vars.SK_TRIVY_VERSION || '' }}`}}
{{- if index .profile "gitops" }}
      paths_ignore: |-
        bootstrap/templates
      files_ignore: |-
        secrets.yaml
        config.yaml
        github-deploy.key
        age.key
        secrets.sample.yaml
{{- end }}
    secrets: inherit
```

> `index .profile "gitops"` returns nil (falsy) when the key is absent, so non-gitops renders are byte-identical to today — existing goldens are unaffected. Using `.profile.gitops.X` directly would error on non-gitops profiles; `index` is the defensive form for the top-level presence check.

**(b)** Add the gitops arm to the language chain. After the flutter arm's last line (`    secrets: inherit`, line 111) and before the chain-closing `{{- end }}` (line 112):

```gotemplate
{{- else if eq $c.primary_language "gitops" }}
  kube-validate:
    uses: serverkraken/reusable-workflows/.github/workflows/kube-validate.yml@{{ $pin }}
    permissions:
      contents: read
    with:
      manifests_paths: |-
        {{- range $.profile.gitops.manifests_paths }}
        {{ . }}
        {{- end }}
      sops: {{ $.profile.gitops.sops }}
    secrets: inherit
  kube-lint:
    uses: serverkraken/reusable-workflows/.github/workflows/kube-lint.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      actions: read
    {{- if $.profile.gitops.has_kube_linter_config }}
    with:
      config_path: .kube-linter.yaml
    {{- end }}
    secrets: inherit
  secret-scan:
    uses: serverkraken/reusable-workflows/.github/workflows/secret-scan.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      actions: read
    {{- if $.profile.gitops.has_gitleaks_config }}
    with:
      config_path: .gitleaks.toml
    {{- end }}
    secrets: inherit
```

> Inside `range .profile.components`, `.` is rebound to `$c`, so top-level fields use the `$` root: `$.profile.gitops.X`. Job-level `permissions:` mirror the existing `secscan` job's pattern (the catalog declares caller permissions per-job, not workflow-level): `kube-lint`/`secret-scan` upload SARIF so need `security-events: write`; `kube-validate` only reads.

- [ ] **Step 4: Run the render tests**

Run: `bats tests/shell/onboard-render.bats -f gitops`
Expected: PASS. If the golden `diff -u` shows a whitespace mismatch, reconcile by adjusting the template `{{- ... }}` trimming (Step 3) until the rendered output matches the intended golden — the golden encodes the spec-mandated structure (union permissions, both roots, skip set).

- [ ] **Step 5: Verify non-gitops goldens are unchanged**

Run: `bats tests/shell/onboard-render.bats`
Expected: PASS (all — the single-go/python/rust/helm/flutter inline goldens and every `golden_check` stay green, proving the `index .profile "gitops"` guard left non-gitops renders byte-identical).

- [ ] **Step 6: Commit**

```bash
git add docs/adopter-templates/skeletons/ci.yml.tmpl tests/shell/golden/ci/gitops.yml tests/shell/onboard-render.bats
git commit -m "feat(onboard): render kube-validate/kube-lint/secret-scan ci for gitops"
```

---

## Task 7: Full golden fixture `gitops-cluster/expected/` + `golden_check`

**Files:**
- Create: `tests/fixtures/onboard/gitops-cluster/expected/` (generated via `UPDATE_GOLDEN=1`)
- Test: `tests/shell/onboard-render.bats` (`golden_check`)

This is the end-to-end golden: detect the fixture → render the full (gitops) set → snapshot. It proves the detect + render integration produces exactly `ci.yml` + lock, content-stable.

- [ ] **Step 1: Register the golden test**

In `tests/shell/onboard-render.bats`, add to the `golden_check` block (after `@test "golden: flutter-app" ...`, line 184):

```bash
@test "golden: gitops-cluster"         { golden_check "gitops-cluster"; }
```

- [ ] **Step 2: Generate the expected snapshot**

Run: `UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats -f "golden: gitops-cluster"`
Expected: the test reports `skip` with `UPDATE_GOLDEN — rewrote gitops-cluster/expected`. This writes `tests/fixtures/onboard/gitops-cluster/expected/` containing `.github/workflows/ci.yml` + `.github/onboard.lock.json` (with `rendered_at` stripped) and **nothing else**.

- [ ] **Step 3: Inspect the generated snapshot**

Run: `find tests/fixtures/onboard/gitops-cluster/expected -type f | sort`
Expected exactly:
```
tests/fixtures/onboard/gitops-cluster/expected/.github/onboard.lock.json
tests/fixtures/onboard/gitops-cluster/expected/.github/workflows/ci.yml
```
Open `expected/.github/workflows/ci.yml` and confirm it has `secscan` (with `paths_ignore`/`files_ignore`), `kube-validate` (both roots + `sops: true`), `kube-lint` (with `config_path`), `secret-scan` (with `config_path`) — and **no** `release.yml`/`prerelease.yml`/`cleanup.yml`/`release-please-*`. Confirm `expected/.github/onboard.lock.json` `files` has the single `.github/workflows/ci.yml` key.

- [ ] **Step 4: Run the golden test to verify it passes**

Run: `bats tests/shell/onboard-render.bats -f "golden: gitops-cluster"`
Expected: PASS (the snapshot now matches a fresh render).

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/onboard/gitops-cluster/expected tests/shell/onboard-render.bats
git commit -m "test(onboard): golden snapshot for gitops-cluster render"
```

---

## Task 8: Doc strings — `action.yml` + script headers

**Files:**
- Modify: `actions/onboard-detect/action.yml` (line 8)
- Modify: `scripts/lib/onboard-detect-lib.sh` (helper list, lines 9–19)
- Modify: `scripts/onboard-render.sh` (header, lines 6–13)

Pure documentation — no test; `actionlint` in Task 9 validates `action.yml` syntax.

- [ ] **Step 1: Update `action.yml` `language_override`**

In `actions/onboard-detect/action.yml`, change the `language_override` description (line 8) to add `gitops`:

```yaml
    description: 'auto | go | python | rust | helm | flutter | node | gitops | simple (auto = file-signal detection)'
```

- [ ] **Step 2: Update the lib helper list**

In `scripts/lib/onboard-detect-lib.sh`, add to the "Internal helpers" comment block (after the `detect_components` line, ~line 10):

```bash
#   detect_gitops_kubernetes — true when the repo matches the Talos/cluster-template fingerprint
#   _gitops_manifests_paths — enumerate kubernetes/<workload> roots (excludes bootstrap/components/flux-system)
```

- [ ] **Step 3: Update the render header**

In `scripts/onboard-render.sh`, append a note to the header comment (after line 13, the "lock file is the contract" line):

```bash
#
# Variant: a gitops profile (.gitops present) renders `ci.yml` ONLY — no
# release-please / prerelease / cleanup — and the lock lists just ci.yml.
```

- [ ] **Step 4: Commit**

```bash
git add actions/onboard-detect/action.yml scripts/lib/onboard-detect-lib.sh scripts/onboard-render.sh
git commit -m "docs(onboard): document gitops detection + render variant"
```

---

## Task 9: Static-validation sweep + PR

**Files:** none (validation + PR only)

- [ ] **Step 1: Full bats suite**

Run: `bats tests/shell/onboard-detect.bats tests/shell/onboard-render.bats`
Expected: PASS (all). No skips except any pre-existing `UPDATE_GOLDEN` guard behaviour (none in normal runs).

- [ ] **Step 2: ShellCheck the modified scripts**

Run: `shellcheck scripts/lib/onboard-detect-lib.sh scripts/onboard-detect.sh scripts/onboard-render.sh`
Expected: clean (no new warnings). If `shellcheck` flags the sourced-lib path in `onboard-detect.sh`, confirm the `# shellcheck source=lib/onboard-detect-lib.sh` directive is present.

- [ ] **Step 3: Render a real adopter sample and lint it**

Render the fixture to a scratch dir and run the catalog's static validators on the output (proves the rendered gitops `ci.yml` passes `actionlint` + `yamllint`):

```bash
TMP=$(mktemp -d)
scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/gitops-cluster > "$TMP/profile.json"
scripts/onboard-render.sh "$PWD" "$TMP" "$TMP/profile.json" v4
actionlint "$TMP/.github/workflows/ci.yml"
yamllint -s "$TMP/.github/workflows/ci.yml"
rm -rf "$TMP"
```
Expected: `actionlint` and `yamllint` both exit 0. (`actionlint` does not resolve the remote `@v4` reusable-workflow refs, so it validates only the caller YAML — which must be clean.)

- [ ] **Step 4: Run the repo self-CI validators**

Run: `actionlint && yamllint -s .github/`
Expected: clean — confirms no catalog workflow regressed.

- [ ] **Step 5: Push the branch**

```bash
git push -u origin feat/gitops-onboard
```

- [ ] **Step 6: Two-stage review before opening the PR**

Per the established phase workflow, run both reviewers on the branch diff (`git diff origin/main...HEAD`):
1. **spec-reviewer** — verify against `docs/superpowers/specs/2026-05-30-gitops-support-design.md` §6/§7/§8 + acceptance criteria. **Flag the documented deviations** (see Accepted Limitations below) so the reviewer judges them, not re-discovers them.
2. **code-quality-reviewer** — bash/jq correctness, errexit safety, template trimming, test coverage.

Address any blocking findings (new commits), then re-run Step 1–4.

- [ ] **Step 7: Open the PR (PR2)**

```bash
gh pr create --title "feat(onboard): detect gitops_kubernetes and render kube-validation ci" --body "$(cat <<'EOF'
## Summary
- Detect Talos/cluster-template GitOps repos (`kubernetes/` + `.sops.yaml` + makejinja/bootstrap) as `primary_language=gitops`; attach a `profile.gitops` object (manifests_paths, sops, has_kube_linter_config, has_gitleaks_config).
- Render `ci.yml` ONLY for gitops profiles (secscan + kube-validate + kube-lint + secret-scan); never release-please. Lock lists `ci.yml` only.
- Recognise `kubeconform`/`kube-linter`/`gitleaks`/CLI-`trivy fs` legacy workflows for cleanup-PR removal.

## Test plan
- [ ] `bats tests/shell/onboard-detect.bats tests/shell/onboard-render.bats` green
- [ ] `shellcheck` clean on the three modified scripts
- [ ] rendered gitops `ci.yml` passes `actionlint` + `yamllint`
- [ ] non-gitops detect/render goldens unchanged
EOF
)"
```

> Depends on PR1 (atoms) for runtime; mergeable independently for the detection/render layer (render tests do not execute the atoms). Match existing PR style — no attribution footer.

---

## Operational follow-up (NOT part of this plan's worktree)

### PR3 — Release the catalog → v4.8.0

After PR1 + PR2 merge to `main`, the standard release-please flow opens the release PR. All changes are additive → **minor bump v4.8.0**. Merging it tags `v4.8.0` and force-moves the `v4` float, so adopters resolving `@v4` pick up the new atoms + gitops rendering. No manual step beyond merging the release PR.

### PR4 — Auto-onboard `homelab-study` + `homelab-incus-oracle`

Post-v4.8.0, the `onboard-sweep` cron (or a manual dispatch) opens Add-PRs:
- **`homelab-study`** — gitops `ci.yml`; cleanup removes the four superseded workflows (`kubeconform.yaml`, `kube-linter.yaml`, `gitleaks.yaml`, `trivy.yaml`) flagged by `detect_legacy_ci`. Keep `release.yaml` (bespoke calendar versioning), `e2e.yaml`, label workflows.
- **`homelab-incus-oracle`** — net-new gitops `ci.yml`; `kube-lint` falls back to the catalog baseline config, `secret-scan` to gitleaks' built-in ruleset.

**Secret gate (HARD):** `kube-validate` with `sops: true` requires the adopter secret `SOPS_AGE_KEY`. Per the standing rule, get explicit confirmation from Soenne before wiring any secret name into a rendered adopter workflow and before merging either onboard PR. Both repos already have `SOPS_AGE_KEY` for `e2e`, but confirm presence + naming first.

---

## Accepted Limitations / deviations to flag for spec-review

1. **`manifests_paths` denylist** — the detector excludes `{bootstrap, components, flux-system}`, not only `bootstrap` as spec open-question 5 literally states. Reason: `homelab-incus-oracle` carries `kubernetes/components`; naive enumeration would feed a non-workload dir to kubeconform and break the `["kubernetes/apps","kubernetes/argo"]` acceptance criterion. This refines, not contradicts, the spec.
2. **Caller permissions are job-level, not workflow-level** — spec §8 prose says "Caller `permissions:` at the top of `ci.yml`". The implementation mirrors the existing `secscan` job's **job-level** `permissions:` pattern instead (the catalog's established convention), which is functionally equivalent for the chained-reusable ceiling and keeps the rendered file consistent with every other rendered `ci.yml`.
3. **ksops / sops toolchain** — already corrected in the spec edit (decryption is via the `ksops` kustomize exec-plugin reading `SOPS_AGE_KEY_FILE`, not standalone `age`). Atom-side; lives in PR1.
4. **`secret-scan` `no_git`/`scan_path`** — any deviation in the atom's input surface is PR1's concern; this plan only references `config_path`.

---

## Self-Review (completed by author)

- **Spec coverage:** §6 detection → Tasks 1–3; §7 legacy path → Task 4; §8 rendering → Tasks 5–6; golden/acceptance → Tasks 6–7; docs → Task 8; validation/PR → Task 9; post-release §PR-plan items 3–4 → Operational section. Acceptance criteria (primary_language/role/manifests_paths/sops/zero-warnings; ci.yml-only render; lock; non-regression) are each asserted by a named test.
- **Placeholder scan:** no TBD/"add error handling"/"similar to Task N" — every code step shows complete content.
- **Type consistency:** `profile.gitops` field names (`manifests_paths`, `has_kube_linter_config`, `has_gitleaks_config`, `sops`) are identical across the lib post-process (Task 2), the template (Task 6), the golden (Task 6), and every assertion (Tasks 2, 6). `primary_language="gitops"`, `role="gitops"`, `release_please_type="simple"` consistent across Tasks 2, 4, 6. Atom filenames (`kube-validate.yml`, `kube-lint.yml`, `secret-scan.yml`) match the spec and PR1.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-30-gitops-support-onboard.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session via executing-plans, batch execution with checkpoints.

Which approach?
