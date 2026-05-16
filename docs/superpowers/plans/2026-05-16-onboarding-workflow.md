# Onboarding Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `.github/workflows/onboard.yml` — a workflow_dispatch tool that adopts the catalog into other `serverkraken/*` repos via two staged PRs (add + cleanup), powered by composite actions and bats-tested shell scripts.

**Architecture:** Matrix-per-target workflow (`fail-fast: false`) → composite actions `onboard-detect` + `onboard-render` wrap bats-testable shell scripts → two bot-owned branches per target (force-reset each run for idempotency) → finalize job aggregates results into `docs/onboarding-status.md`. Reuses existing `serverkraken-release-bot` App.

**Tech Stack:** GitHub Actions (workflow_dispatch + workflow_call), bash, bats, `actions/create-github-app-token@v2`, `gh` CLI, `actions/checkout@v6`, `sed` for template substitution. All jobs run on `ubuntu-latest`.

**Spec:** `docs/superpowers/specs/2026-05-16-onboarding-workflow-design.md`

---

## File map

**New files (created during this plan):**

| Path | Purpose |
|---|---|
| `scripts/onboard-detect.sh` | Language + version detection (testable, no GitHub-Actions deps) |
| `scripts/onboard-render.sh` | Template rendering (testable) |
| `scripts/seed-onboarding-status.sh` | One-shot org repo enumerator for status doc |
| `actions/onboard-detect/action.yml` | Composite wrapper for detect script |
| `actions/onboard-render/action.yml` | Composite wrapper for render script |
| `.github/workflows/onboard.yml` | The workflow itself |
| `docs/adopter-templates/release-please-config.json.tmpl` | release-please config template |
| `docs/adopter-templates/release-please-manifest.json.tmpl` | manifest template |
| `docs/onboarding-status.md` | Status table (seeded once, updated by workflow) |
| `tests/shell/onboard-detect.bats` | bats unit tests for detect |
| `tests/shell/onboard-render.bats` | bats unit tests for render |
| `tests/fixtures/onboard/go-repo/go.mod` | Detection fixture: go |
| `tests/fixtures/onboard/python-poetry/pyproject.toml` | Detection fixture: python |
| `tests/fixtures/onboard/rust-cargo/Cargo.toml` | Detection fixture: rust |
| `tests/fixtures/onboard/helm-chart/Chart.yaml` | Detection fixture: helm |
| `tests/fixtures/onboard/node-package/package.json` | Detection fixture: node |
| `tests/fixtures/onboard/simple/.gitkeep` | Detection fixture: simple (empty) |
| `tests/fixtures/onboard/ambiguous/go.mod` | Detection fixture: ambiguous (paired) |
| `tests/fixtures/onboard/ambiguous/pyproject.toml` | Detection fixture: ambiguous (paired) |

**Modified files:**

| Path | Change |
|---|---|
| `.github/workflows/integration.yml` | Add `test-onboard-dry-run` job |
| `docs/contracts.md` | Append "Internal Composite Actions" subsection for the two new actions |
| `docs/operations.md` | Append §5 "Onboarding workflow" |
| `CONTRIBUTING.md` | Document the manual acceptance procedure |
| `CLAUDE-activeContext.md` | Note onboarding completion + next focus |
| `CLAUDE-patterns.md` | Add "Matrix-output aggregation via artifact" pattern |
| `CLAUDE-decisions.md` | Add OB-1..OB-10 from spec §14 |
| `CLAUDE-troubleshooting.md` | (deferred — populate as bugs emerge during acceptance) |

---

## Task 1: Detection fixtures

**Files:**
- Create: `tests/fixtures/onboard/go-repo/go.mod`
- Create: `tests/fixtures/onboard/python-poetry/pyproject.toml`
- Create: `tests/fixtures/onboard/rust-cargo/Cargo.toml`
- Create: `tests/fixtures/onboard/helm-chart/Chart.yaml`
- Create: `tests/fixtures/onboard/node-package/package.json`
- Create: `tests/fixtures/onboard/simple/.gitkeep`
- Create: `tests/fixtures/onboard/ambiguous/go.mod`
- Create: `tests/fixtures/onboard/ambiguous/pyproject.toml`

- [ ] **Step 1: Create the go fixture**

File: `tests/fixtures/onboard/go-repo/go.mod`
```
module example.com/onboard-fixture-go

go 1.22
```

- [ ] **Step 2: Create the python fixture**

File: `tests/fixtures/onboard/python-poetry/pyproject.toml`
```toml
[project]
name = "onboard-fixture-python"
version = "0.0.0"
```

- [ ] **Step 3: Create the rust fixture**

File: `tests/fixtures/onboard/rust-cargo/Cargo.toml`
```toml
[package]
name = "onboard-fixture-rust"
version = "0.0.0"
edition = "2021"
```

- [ ] **Step 4: Create the helm fixture**

File: `tests/fixtures/onboard/helm-chart/Chart.yaml`
```yaml
apiVersion: v2
name: onboard-fixture-helm
version: 0.0.0
```

- [ ] **Step 5: Create the node fixture**

File: `tests/fixtures/onboard/node-package/package.json`
```json
{
  "name": "onboard-fixture-node",
  "version": "0.0.0",
  "private": true
}
```

- [ ] **Step 6: Create the simple + ambiguous fixtures**

File: `tests/fixtures/onboard/simple/.gitkeep` — empty file (touch it).

File: `tests/fixtures/onboard/ambiguous/go.mod`
```
module example.com/ambiguous

go 1.22
```

File: `tests/fixtures/onboard/ambiguous/pyproject.toml`
```toml
[project]
name = "ambiguous"
version = "0.0.0"
```

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/onboard/
git commit -m "test(onboard): add detection fixtures (go/python/rust/helm/node/simple/ambiguous)"
```

---

## Task 2: bats tests for `onboard-detect.sh` (RED)

**Files:**
- Create: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write the bats file**

File: `tests/shell/onboard-detect.bats`

```bats
#!/usr/bin/env bats
# Tests for scripts/onboard-detect.sh
#
# Contract (from spec §5):
#   onboard-detect.sh <repo-path> [language-override]
#   stdout key=value lines: language, release_type, current_version, default_branch
#   - When TARGET_REPO env is unset (local/test mode), current_version=0.0.0
#     and default_branch=main are emitted as defaults.
#   - Exit 1 on ambiguous signals or missing repo path.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DETECT="$REPO_ROOT/scripts/onboard-detect.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
  # Ensure target-repo env isn't bleeding in from CI
  unset TARGET_REPO
  unset GH_TOKEN
}

@test "detects go from go.mod" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
  [[ "$output" == *"release_type=go"* ]]
}

@test "detects python from pyproject.toml" {
  run "$DETECT" "$FIX/python-poetry"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=python"* ]]
  [[ "$output" == *"release_type=python"* ]]
}

@test "detects rust from Cargo.toml" {
  run "$DETECT" "$FIX/rust-cargo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=rust"* ]]
}

@test "detects helm from Chart.yaml" {
  run "$DETECT" "$FIX/helm-chart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=helm"* ]]
}

@test "detects node from package.json" {
  run "$DETECT" "$FIX/node-package"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=node"* ]]
}

@test "falls back to simple when no signals" {
  run "$DETECT" "$FIX/simple"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=simple"* ]]
  [[ "$output" == *"release_type=simple"* ]]
}

@test "errors on ambiguous signals" {
  run "$DETECT" "$FIX/ambiguous"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous language signals"* ]]
  [[ "$output" == *"go"* ]]
  [[ "$output" == *"python"* ]]
}

@test "respects explicit language override" {
  run "$DETECT" "$FIX/ambiguous" go
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
}

@test "emits default current_version=0.0.0 when TARGET_REPO unset" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=0.0.0"* ]]
}

@test "emits default default_branch=main when TARGET_REPO unset" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_branch=main"* ]]
}

@test "errors on missing repo path" {
  run "$DETECT" "/nonexistent/path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}
```

- [ ] **Step 2: Run bats to verify RED**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all 11 tests FAIL, each with "command not found" or "file not executable" — `scripts/onboard-detect.sh` doesn't exist yet.

- [ ] **Step 3: Commit**

```bash
git add tests/shell/onboard-detect.bats
git commit -m "test(onboard-detect): add bats spec (RED)"
```

---

## Task 3: Implement `onboard-detect.sh` (GREEN)

**Files:**
- Create: `scripts/onboard-detect.sh`

- [ ] **Step 1: Write the script**

File: `scripts/onboard-detect.sh`

```bash
#!/usr/bin/env bash
# onboard-detect.sh — detect target repo language + version.
#
# Usage: onboard-detect.sh <repo-path> [language-override]
#
# When TARGET_REPO env is set, calls `gh` for default_branch and latest release.
# When unset (local/test mode), emits defaults: current_version=0.0.0, default_branch=main.
#
# Outputs (stdout, key=value, GitHub-Actions friendly):
#   language=<go|python|rust|helm|node|simple>
#   release_type=<same as language>
#   current_version=<X.Y.Z, no leading v>
#   default_branch=<branch>
#
# Exits 1 on:
#   - repo path missing
#   - ambiguous language signals (more than one match, no override)

set -euo pipefail

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
  raw_tag=$(gh release list --repo "$TARGET_REPO" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
  if [[ -n "$raw_tag" ]]; then
    current_version="${raw_tag#v}"
  fi
fi

printf 'language=%s\n' "$language"
printf 'release_type=%s\n' "$release_type"
printf 'current_version=%s\n' "$current_version"
printf 'default_branch=%s\n' "$default_branch"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/onboard-detect.sh
```

- [ ] **Step 3: Run bats to verify GREEN**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: 11 of 11 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/onboard-detect.sh
git commit -m "feat(onboard-detect): implement language and version detection"
```

---

## Task 4: New adopter-template files

**Files:**
- Create: `docs/adopter-templates/release-please-config.json.tmpl`
- Create: `docs/adopter-templates/release-please-manifest.json.tmpl`

- [ ] **Step 1: Write the release-please-config template**

File: `docs/adopter-templates/release-please-config.json.tmpl`

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "packages": {
    ".": {
      "release-type": "{{RELEASE_TYPE}}",
      "include-component-in-tag": false,
      "bump-minor-pre-major": true,
      "draft": false,
      "prerelease": false,
      "changelog-sections": [
        { "type": "feat", "section": "Features" },
        { "type": "fix", "section": "Bug Fixes" },
        { "type": "perf", "section": "Performance" },
        { "type": "refactor", "section": "Refactors" },
        { "type": "docs", "section": "Documentation", "hidden": false },
        { "type": "test", "section": "Tests", "hidden": true },
        { "type": "ci", "section": "CI", "hidden": true },
        { "type": "chore", "section": "Chores", "hidden": true }
      ]
    }
  }
}
```

- [ ] **Step 2: Write the manifest template**

File: `docs/adopter-templates/release-please-manifest.json.tmpl`

```json
{
  ".": "{{VERSION}}"
}
```

- [ ] **Step 3: Commit**

```bash
git add docs/adopter-templates/release-please-config.json.tmpl docs/adopter-templates/release-please-manifest.json.tmpl
git commit -m "feat(adopter-templates): add release-please config + manifest templates"
```

---

## Task 5: bats tests for `onboard-render.sh` (RED)

**Files:**
- Create: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Write the bats file**

File: `tests/shell/onboard-render.bats`

```bats
#!/usr/bin/env bats
# Tests for scripts/onboard-render.sh
#
# Contract (from spec §6):
#   onboard-render.sh <catalog-path> <target-path> <release-type> <current-version> <pin-version>
#   Writes 6 files into <target>:
#     .github/workflows/{ci,release,prerelease,cleanup}.yml
#     release-please-config.json
#     .release-please-manifest.json

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  TARGET="$(mktemp -d)"
}

teardown() {
  rm -rf "$TARGET"
}

@test "renders all six files for go release-type" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" go 2.4.0 v1
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
  [ -f "$TARGET/.github/workflows/release.yml" ]
  [ -f "$TARGET/.github/workflows/prerelease.yml" ]
  [ -f "$TARGET/.github/workflows/cleanup.yml" ]
  [ -f "$TARGET/release-please-config.json" ]
  [ -f "$TARGET/.release-please-manifest.json" ]
}

@test "substitutes release-type into config" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" python 1.0.0 v1
  [ "$status" -eq 0 ]
  grep -q '"release-type": "python"' "$TARGET/release-please-config.json"
  ! grep -q '{{RELEASE_TYPE}}' "$TARGET/release-please-config.json"
}

@test "substitutes version into manifest" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" go 2.4.0 v1
  [ "$status" -eq 0 ]
  grep -q '"\.": "2\.4\.0"' "$TARGET/.release-please-manifest.json"
  ! grep -q '{{VERSION}}' "$TARGET/.release-please-manifest.json"
}

@test "pin_version=v1 is a no-op (templates already pin @v1)" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" simple 0.0.0 v1
  [ "$status" -eq 0 ]
  grep -q '@v1' "$TARGET/.github/workflows/release.yml"
  ! grep -q '@v11' "$TARGET/.github/workflows/release.yml"
}

@test "pin_version=v1.1.0 substitutes @v1 → @v1.1.0" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" simple 0.0.0 v1.1.0
  [ "$status" -eq 0 ]
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/release.yml"
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/ci.yml"
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/prerelease.yml"
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/cleanup.yml"
}

@test "errors when a template file is missing" {
  # Point catalog at a path that has no templates
  EMPTY_CATALOG="$(mktemp -d)"
  mkdir -p "$EMPTY_CATALOG/docs/adopter-templates"
  run "$RENDER" "$EMPTY_CATALOG" "$TARGET" go 1.0.0 v1
  [ "$status" -eq 1 ]
  [[ "$output" == *"template missing"* ]]
  rm -rf "$EMPTY_CATALOG"
}

@test "errors on missing positional args" {
  run "$RENDER"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run bats to verify RED**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all tests FAIL — `scripts/onboard-render.sh` doesn't exist yet.

- [ ] **Step 3: Commit**

```bash
git add tests/shell/onboard-render.bats
git commit -m "test(onboard-render): add bats spec (RED)"
```

---

## Task 6: Implement `onboard-render.sh` (GREEN)

**Files:**
- Create: `scripts/onboard-render.sh`

- [ ] **Step 1: Write the script**

File: `scripts/onboard-render.sh`

```bash
#!/usr/bin/env bash
# onboard-render.sh — render adopter-template files into a target workspace.
#
# Usage:
#   onboard-render.sh <catalog-path> <target-path> <release-type> <current-version> <pin-version>
#
# Writes six files into <target>:
#   .github/workflows/{ci,release,prerelease,cleanup}.yml
#   release-please-config.json
#   .release-please-manifest.json
#
# Substitutions:
#   YAML templates: literal "@v1" → "@<pin-version>"
#   Config tmpl:    "{{RELEASE_TYPE}}" → <release-type>
#   Manifest tmpl:  "{{VERSION}}"      → <current-version>

set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "::error::usage: $0 <catalog> <target> <release-type> <current-version> <pin-version>" >&2
  exit 2
fi

CATALOG="$1"
TARGET="$2"
RELEASE_TYPE="$3"
CURRENT_VERSION="$4"
PIN_VERSION="$5"

TEMPLATES="$CATALOG/docs/adopter-templates"

mkdir -p "$TARGET/.github/workflows"

# YAML workflow templates — replace @v1 (word-boundary-terminated) with @<pin>
for name in ci release prerelease cleanup; do
  src="$TEMPLATES/${name}.yml"
  dst="$TARGET/.github/workflows/${name}.yml"
  if [[ ! -f "$src" ]]; then
    echo "::error::template missing: $src" >&2
    exit 1
  fi
  sed "s|@v1\\b|@${PIN_VERSION}|g" "$src" > "$dst"
done

# release-please-config.json.tmpl
src="$TEMPLATES/release-please-config.json.tmpl"
dst="$TARGET/release-please-config.json"
if [[ ! -f "$src" ]]; then
  echo "::error::template missing: $src" >&2
  exit 1
fi
sed "s|{{RELEASE_TYPE}}|${RELEASE_TYPE}|g" "$src" > "$dst"

# release-please-manifest.json.tmpl
src="$TEMPLATES/release-please-manifest.json.tmpl"
dst="$TARGET/.release-please-manifest.json"
if [[ ! -f "$src" ]]; then
  echo "::error::template missing: $src" >&2
  exit 1
fi
sed "s|{{VERSION}}|${CURRENT_VERSION}|g" "$src" > "$dst"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/onboard-render.sh
```

- [ ] **Step 3: Run bats to verify GREEN**

```bash
bats tests/shell/onboard-render.bats
```

Expected: 7 of 7 tests PASS.

- [ ] **Step 4: Run BOTH bats files to confirm no regression**

```bash
bats tests/shell/
```

Expected: all detect + render tests PASS, plus existing `compute-prerelease-tag.bats` still passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/onboard-render.sh
git commit -m "feat(onboard-render): implement adopter-template rendering"
```

---

## Task 7: Composite action `actions/onboard-detect`

**Files:**
- Create: `actions/onboard-detect/action.yml`

- [ ] **Step 1: Write the action**

File: `actions/onboard-detect/action.yml`

```yaml
name: 'Onboard: detect language and version'
description: 'Detect a target repo language signal and current GitHub-release version. Wraps scripts/onboard-detect.sh.'
inputs:
  repo_path:
    description: 'Path to the checked-out target repo on the runner'
    required: true
  language_override:
    description: 'auto | go | python | rust | helm | node | simple (auto = file-signal detection)'
    required: false
    default: 'auto'
  target_repo:
    description: 'owner/repo for gh api calls (default_branch + latest release)'
    required: true
  github_token:
    description: 'GitHub token with read access to target_repo'
    required: true
outputs:
  language:
    description: 'Detected language'
    value: ${{ steps.detect.outputs.language }}
  release_type:
    description: 'release-please release-type (1:1 with language for V1)'
    value: ${{ steps.detect.outputs.release_type }}
  current_version:
    description: 'Current version without leading v (0.0.0 if no release found)'
    value: ${{ steps.detect.outputs.current_version }}
  default_branch:
    description: 'Default branch of target_repo'
    value: ${{ steps.detect.outputs.default_branch }}
runs:
  using: composite
  steps:
    - id: detect
      shell: bash
      env:
        TARGET_REPO: ${{ inputs.target_repo }}
        GH_TOKEN: ${{ inputs.github_token }}
      run: |
        # The action lives in actions/onboard-detect/action.yml; the script lives in scripts/.
        # When invoked via the catalog-checkout pattern, $GITHUB_ACTION_PATH is .catalog/actions/onboard-detect/
        # so ../../scripts/onboard-detect.sh resolves to .catalog/scripts/onboard-detect.sh.
        "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" \
          "${{ inputs.repo_path }}" \
          "${{ inputs.language_override }}" \
          >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Run actionlint locally**

```bash
actionlint actions/onboard-detect/action.yml
```

Expected: no output (clean).

If actionlint isn't installed, install it: `brew install actionlint` (macOS) or `go install github.com/rhysd/actionlint/cmd/actionlint@latest`.

- [ ] **Step 3: Run yamllint locally**

```bash
yamllint actions/onboard-detect/action.yml
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add actions/onboard-detect/action.yml
git commit -m "feat(onboard-detect): add composite action wrapping the detect script"
```

---

## Task 8: Composite action `actions/onboard-render`

**Files:**
- Create: `actions/onboard-render/action.yml`

- [ ] **Step 1: Write the action**

File: `actions/onboard-render/action.yml`

```yaml
name: 'Onboard: render adopter templates'
description: 'Render adopter-template files into the target repo workspace. Wraps scripts/onboard-render.sh.'
inputs:
  catalog_path:
    description: 'Path to the checked-out catalog repo'
    required: true
  target_path:
    description: 'Path to the checked-out target repo'
    required: true
  release_type:
    description: 'release-please release-type (go/python/rust/helm/node/simple)'
    required: true
  current_version:
    description: 'Current version (no leading v)'
    required: true
  pin_version:
    description: 'Catalog @version to pin the rendered templates to'
    required: false
    default: 'v1'
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        "${{ inputs.catalog_path }}/scripts/onboard-render.sh" \
          "${{ inputs.catalog_path }}" \
          "${{ inputs.target_path }}" \
          "${{ inputs.release_type }}" \
          "${{ inputs.current_version }}" \
          "${{ inputs.pin_version }}"
```

- [ ] **Step 2: Run actionlint + yamllint**

```bash
actionlint actions/onboard-render/action.yml && yamllint actions/onboard-render/action.yml
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add actions/onboard-render/action.yml
git commit -m "feat(onboard-render): add composite action wrapping the render script"
```

---

## Task 9: `onboard.yml` scaffolding — triggers + parse-inputs job

**Files:**
- Create: `.github/workflows/onboard.yml`

- [ ] **Step 1: Write the scaffold**

File: `.github/workflows/onboard.yml`

```yaml
# .github/workflows/onboard.yml
# Operational tool: dispatches per-target onboarding PRs into serverkraken/* repos.
# Not a public reusable workflow's API surface — input contract may evolve without semver bump.
# See docs/superpowers/specs/2026-05-16-onboarding-workflow-design.md.
name: onboard
on:
  workflow_dispatch:
    inputs:
      target_repos:
        description: 'Comma-separated owner/repo list (e.g. serverkraken/blupod-ui,serverkraken/flow)'
        required: true
        type: string
      language:
        description: 'auto = detect, otherwise force release-type'
        required: false
        type: choice
        default: auto
        options: [auto, go, python, rust, helm, node, simple]
      dry_run:
        description: 'Render + log diff; do NOT push or open PRs'
        required: false
        type: boolean
        default: false
      pin_version:
        description: 'Catalog @version that rendered templates pin to'
        required: false
        type: string
        default: v1
      add_branch_name:
        description: 'Branch for PR A (add new workflows)'
        required: false
        type: string
        default: chore/onboard-reusable-workflows
      cleanup_branch_name:
        description: 'Branch for PR B (remove legacy workflows)'
        required: false
        type: string
        default: chore/remove-legacy-workflows
  workflow_call:
    inputs:
      target_repos:
        required: true
        type: string
      language:
        required: false
        type: string
        default: auto
      dry_run:
        required: false
        type: boolean
        default: true
      pin_version:
        required: false
        type: string
        default: v1
      add_branch_name:
        required: false
        type: string
        default: chore/onboard-reusable-workflows
      cleanup_branch_name:
        required: false
        type: string
        default: chore/remove-legacy-workflows

concurrency:
  # Hardcoded prefix per CLAUDE-patterns "concurrency group" rule.
  group: onboard-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  parse-inputs:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.parse.outputs.matrix }}
    steps:
      - id: parse
        env:
          REPOS: ${{ inputs.target_repos }}
        run: |
          set -euo pipefail
          IFS=',' read -ra raw <<< "$REPOS"
          declare -A seen=()
          out='['
          first=1
          for entry in "${raw[@]}"; do
            entry="${entry//[[:space:]]/}"
            [[ -z "$entry" ]] && continue
            if [[ ! "$entry" =~ ^serverkraken/[A-Za-z0-9._-]+$ ]]; then
              echo "::error::invalid target_repos entry: '$entry' (must match ^serverkraken/[A-Za-z0-9._-]+\$)"
              exit 1
            fi
            if [[ -n "${seen[$entry]:-}" ]]; then
              continue
            fi
            seen[$entry]=1
            owner="${entry%/*}"
            name="${entry#*/}"
            if [[ $first -eq 0 ]]; then out+=','; fi
            out+="{\"target\":\"$entry\",\"owner\":\"$owner\",\"name\":\"$name\"}"
            first=0
          done
          out+=']'
          if [[ "$out" == "[]" ]]; then
            echo "::error::target_repos is empty after parse"
            exit 1
          fi
          echo "matrix=$out" >> "$GITHUB_OUTPUT"
          echo "Parsed matrix: $out"
```

- [ ] **Step 2: Run actionlint + yamllint**

```bash
actionlint .github/workflows/onboard.yml && yamllint .github/workflows/onboard.yml
```

Expected: no output. (At this point the workflow has only `parse-inputs`; actionlint accepts that.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): scaffold workflow with dispatch/call triggers and parse-inputs job"
```

---

## Task 10: `onboard.yml` — onboard matrix job (detect + render + diff log only)

**Files:**
- Modify: `.github/workflows/onboard.yml` — append `onboard` job after `parse-inputs`

- [ ] **Step 1: Append the onboard job**

Append to `.github/workflows/onboard.yml` (under `jobs:`, after `parse-inputs:`):

```yaml
  onboard:
    needs: parse-inputs
    runs-on: ubuntu-latest
    permissions:
      contents: read
    strategy:
      fail-fast: false
      matrix:
        target: ${{ fromJSON(needs.parse-inputs.outputs.matrix) }}
    steps:
      - name: Mint App token scoped to target
        id: target-token
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.RELEASE_PLEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
          owner: ${{ matrix.target.owner }}
          repositories: ${{ matrix.target.name }}

      - name: Checkout target repo
        uses: actions/checkout@v6
        with:
          repository: ${{ matrix.target.target }}
          token: ${{ steps.target-token.outputs.token }}
          path: target
          fetch-depth: 0

      - name: Checkout catalog at this workflow's SHA
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.workflow_sha }}
          path: .catalog

      - name: Detect language and version
        id: detect
        uses: ./.catalog/actions/onboard-detect
        with:
          repo_path: target
          language_override: ${{ inputs.language }}
          target_repo: ${{ matrix.target.target }}
          github_token: ${{ steps.target-token.outputs.token }}

      - name: Render templates into target
        uses: ./.catalog/actions/onboard-render
        with:
          catalog_path: .catalog
          target_path: target
          release_type: ${{ steps.detect.outputs.release_type }}
          current_version: ${{ steps.detect.outputs.current_version }}
          pin_version: ${{ inputs.pin_version }}

      - name: Stage rendered files and log diff
        working-directory: target
        run: |
          set -euo pipefail
          git add -A
          echo "## Rendered diff for ${{ matrix.target.target }}" >> "$GITHUB_STEP_SUMMARY"
          echo '```diff' >> "$GITHUB_STEP_SUMMARY"
          git --no-pager diff --cached --stat >> "$GITHUB_STEP_SUMMARY" || true
          echo '```' >> "$GITHUB_STEP_SUMMARY"
          git --no-pager diff --cached --stat
          git --no-pager diff --cached
```

- [ ] **Step 2: Run actionlint + yamllint**

```bash
actionlint .github/workflows/onboard.yml && yamllint .github/workflows/onboard.yml
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): add matrix job for detect + render + diff logging"
```

---

## Task 11: `onboard.yml` — Branch A push + PR logic

**Files:**
- Modify: `.github/workflows/onboard.yml` — append step "Branch A: ensure add PR"

- [ ] **Step 1: Append the Branch A step to the `onboard` job**

Append after the "Stage rendered files and log diff" step inside the `onboard` job:

```yaml
      - name: Branch A — ensure add-workflows PR
        if: ${{ !inputs.dry_run }}
        id: pr_a
        working-directory: target
        env:
          GH_TOKEN: ${{ steps.target-token.outputs.token }}
          DEFAULT_BRANCH: ${{ steps.detect.outputs.default_branch }}
          ADD_BRANCH: ${{ inputs.add_branch_name }}
          TARGET_REPO: ${{ matrix.target.target }}
          PIN: ${{ inputs.pin_version }}
          LANG: ${{ steps.detect.outputs.language }}
          RTYPE: ${{ steps.detect.outputs.release_type }}
          CUR_VER: ${{ steps.detect.outputs.current_version }}
        run: |
          set -euo pipefail
          # Bot identity: id is public and stable; fetched inline so we never
          # commit a hardcoded numeric id that could drift.
          bot_id=$(gh api '/users/serverkraken-release-bot[bot]' -q '.id')
          git config user.name 'serverkraken-release-bot[bot]'
          git config user.email "${bot_id}+serverkraken-release-bot[bot]@users.noreply.github.com"

          # Target already has rendered files staged (from prior step's "git add -A").
          # Reset index, then explicitly add only the 6 rendered files.
          git reset

          RENDERED=(
            ".github/workflows/ci.yml"
            ".github/workflows/release.yml"
            ".github/workflows/prerelease.yml"
            ".github/workflows/cleanup.yml"
            "release-please-config.json"
            ".release-please-manifest.json"
          )
          # All 6 should exist after render; defensive guard.
          for f in "${RENDERED[@]}"; do
            [[ -f "$f" ]] || { echo "::error::expected rendered file missing: $f"; exit 1; }
          done

          # Create / reset the bot branch from default HEAD; rendered files are working-tree
          # mods so they survive `checkout -B`.
          git fetch origin "$DEFAULT_BRANCH"
          git checkout -B "$ADD_BRANCH" "origin/$DEFAULT_BRANCH"

          git add "${RENDERED[@]}"

          existing_pr_num=$(gh pr list --repo "$TARGET_REPO" --head "$ADD_BRANCH" --state open --json number -q '.[0].number' || echo "")

          if git diff --cached --quiet; then
            echo "No diff for add branch."
            if [[ -n "$existing_pr_num" ]]; then
              gh pr close "$existing_pr_num" --repo "$TARGET_REPO" --comment "No changes needed; closing." || true
            fi
            echo "pr_a_url=" >> "$GITHUB_OUTPUT"
            echo "pr_a_status=no-changes" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          git commit -m "chore: onboard serverkraken/reusable-workflows@${PIN}"
          git push -f origin "$ADD_BRANCH"

          body=$(cat <<EOF
          ## Onboard to serverkraken/reusable-workflows@${PIN}

          Drops in the standard reusable-workflow consumer files:

          - \`.github/workflows/ci.yml\`         — PR-time fs scan
          - \`.github/workflows/release.yml\`    — main → release (orchestrator)
          - \`.github/workflows/prerelease.yml\` — manual dispatch image builds
          - \`.github/workflows/cleanup.yml\`    — weekly GHCR retention
          - \`release-please-config.json\`       — release-please config (release-type: \`${RTYPE}\`)
          - \`.release-please-manifest.json\`    — seeded at current version \`${CUR_VER}\`

          **Detected language:** \`${LANG}\`
          **Detected current version:** \`${CUR_VER}\` (from latest GitHub release)
          **Catalog version pinned:** \`${PIN}\`

          After merging:
          1. Push a \`feat:\` / \`fix:\` commit to \`${DEFAULT_BRANCH}\` — \`release.yml\` should open a release-please PR.
          2. Merge that release-please PR. A release + image build + Trivy scan should run end-to-end.
          3. Once one full release has run green, merge the companion cleanup PR (if open) to retire legacy workflow files.

          _Opened by the \`onboard.yml\` workflow in \`serverkraken/reusable-workflows\`._
          EOF
          )

          if [[ -n "$existing_pr_num" ]]; then
            gh pr edit "$existing_pr_num" --repo "$TARGET_REPO" --body "$body"
            pr_url=$(gh pr view "$existing_pr_num" --repo "$TARGET_REPO" --json url -q .url)
          else
            pr_url=$(gh pr create --repo "$TARGET_REPO" \
                                   --base "$DEFAULT_BRANCH" --head "$ADD_BRANCH" \
                                   --title "chore: onboard serverkraken/reusable-workflows@${PIN}" \
                                   --body "$body")
          fi
          echo "pr_a_url=$pr_url" >> "$GITHUB_OUTPUT"
          echo "pr_a_status=add-open" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Run actionlint + yamllint**

```bash
actionlint .github/workflows/onboard.yml && yamllint .github/workflows/onboard.yml
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): add PR A (add workflows) push + open/edit/close logic"
```

---

## Task 12: `onboard.yml` — Branch B push + PR logic

**Files:**
- Modify: `.github/workflows/onboard.yml` — append step "Branch B: ensure cleanup PR"

- [ ] **Step 1: Append the Branch B step to the `onboard` job**

Append after the Branch A step inside the `onboard` job:

```yaml
      - name: Branch B — ensure remove-legacy PR
        if: ${{ !inputs.dry_run }}
        id: pr_b
        working-directory: target
        env:
          GH_TOKEN: ${{ steps.target-token.outputs.token }}
          DEFAULT_BRANCH: ${{ steps.detect.outputs.default_branch }}
          CLEANUP_BRANCH: ${{ inputs.cleanup_branch_name }}
          TARGET_REPO: ${{ matrix.target.target }}
          PIN: ${{ inputs.pin_version }}
          PR_A_URL: ${{ steps.pr_a.outputs.pr_a_url }}
        run: |
          set -euo pipefail
          # Hard reset to default branch HEAD to discard rendered files from prior step;
          # cleanup PR works against the unmodified default branch.
          git fetch origin "$DEFAULT_BRANCH"
          git checkout "$DEFAULT_BRANCH"
          git reset --hard "origin/$DEFAULT_BRANCH"
          git clean -fd

          LEGACY=(
            ".github/workflows/semantic-release.yml"
            ".github/workflows/docker-build.yml"
            ".github/workflows/trivy.yml"
            ".github/workflows/trivy.yaml"
            ".github/workflows/build.yml"
            ".github/workflows/publish.yml"
          )

          matched=()
          for f in "${LEGACY[@]}"; do
            if [[ -f "$f" ]]; then
              matched+=("$f")
            fi
          done

          existing_pr_num=$(gh pr list --repo "$TARGET_REPO" --head "$CLEANUP_BRANCH" --state open --json number -q '.[0].number' || echo "")

          if (( ${#matched[@]} == 0 )); then
            echo "No legacy files in target."
            if [[ -n "$existing_pr_num" ]]; then
              gh pr close "$existing_pr_num" --repo "$TARGET_REPO" --comment "No legacy files to remove; closing." || true
            fi
            echo "pr_b_url=" >> "$GITHUB_OUTPUT"
            echo "pr_b_status=no-legacy" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          git checkout -B "$CLEANUP_BRANCH" "origin/$DEFAULT_BRANCH"
          git rm "${matched[@]}"
          git commit -m "chore: remove legacy workflows superseded by reusable-workflows@${PIN}"
          git push -f origin "$CLEANUP_BRANCH"

          # Build a markdown bullet list of removed files for the PR body.
          removed_list=""
          for f in "${matched[@]}"; do
            removed_list+="- \`$f\`"$'\n'
          done

          pr_a_ref="(no companion PR opened)"
          if [[ -n "$PR_A_URL" ]]; then
            pr_a_ref="$PR_A_URL"
          fi

          body=$(cat <<EOF
          ## Retire legacy workflows

          Removes the following files, which are now covered by reusable workflows from \`serverkraken/reusable-workflows@${PIN}\`:

          ${removed_list}

          **Soft dependency:** companion PR ${pr_a_ref} ("onboard reusable-workflows") should be merged and have run at least one successful release before merging this PR. Otherwise this repo loses its release flow until the new one is exercised.

          _Opened by the \`onboard.yml\` workflow in \`serverkraken/reusable-workflows\`._
          EOF
          )

          if [[ -n "$existing_pr_num" ]]; then
            gh pr edit "$existing_pr_num" --repo "$TARGET_REPO" --body "$body"
            pr_url=$(gh pr view "$existing_pr_num" --repo "$TARGET_REPO" --json url -q .url)
          else
            pr_url=$(gh pr create --repo "$TARGET_REPO" \
                                   --base "$DEFAULT_BRANCH" --head "$CLEANUP_BRANCH" \
                                   --title "chore: remove legacy workflows superseded by reusable-workflows@${PIN}" \
                                   --body "$body")
          fi
          echo "pr_b_url=$pr_url" >> "$GITHUB_OUTPUT"
          echo "pr_b_status=cleanup-open" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Append the "emit result artifact" step (last step of the `onboard` job)**

Append after the Branch B step:

```yaml
      - name: Emit per-target result artifact
        if: always()
        env:
          TARGET: ${{ matrix.target.target }}
          LANG: ${{ steps.detect.outputs.language || '' }}
          CUR_VER: ${{ steps.detect.outputs.current_version || '' }}
          PR_A_URL: ${{ steps.pr_a.outputs.pr_a_url || '' }}
          PR_A_STATUS: ${{ steps.pr_a.outputs.pr_a_status || 'error' }}
          PR_B_URL: ${{ steps.pr_b.outputs.pr_b_url || '' }}
          PR_B_STATUS: ${{ steps.pr_b.outputs.pr_b_status || 'error' }}
          JOB_STATUS: ${{ job.status }}
        run: |
          set -euo pipefail
          mkdir -p result
          # Sanitize target slash → dash for artifact name
          safe_name="${TARGET//\//-}"
          jq -n \
            --arg target "$TARGET" \
            --arg language "$LANG" \
            --arg version "$CUR_VER" \
            --arg pr_a_url "$PR_A_URL" \
            --arg pr_a_status "$PR_A_STATUS" \
            --arg pr_b_url "$PR_B_URL" \
            --arg pr_b_status "$PR_B_STATUS" \
            --arg job_status "$JOB_STATUS" \
            '{target: $target, language: $language, version: $version, pr_a_url: $pr_a_url, pr_a_status: $pr_a_status, pr_b_url: $pr_b_url, pr_b_status: $pr_b_status, job_status: $job_status}' \
            > "result/$safe_name.json"
          echo "Artifact contents:"
          cat "result/$safe_name.json"

      - name: Upload result artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: onboard-result-${{ matrix.target.owner }}-${{ matrix.target.name }}
          path: result/
          retention-days: 7
```

- [ ] **Step 3: Run actionlint + yamllint**

```bash
actionlint .github/workflows/onboard.yml && yamllint .github/workflows/onboard.yml
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): add PR B (cleanup) logic and per-target result artifact"
```

---

## Task 13: `onboard.yml` — finalize job (aggregate + status doc commit + step summary)

**Files:**
- Modify: `.github/workflows/onboard.yml` — append `finalize` job

- [ ] **Step 1: Append the finalize job**

Append at the end of `.github/workflows/onboard.yml`:

```yaml
  finalize:
    needs: onboard
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Mint App token for catalog repo
        id: catalog-token
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.RELEASE_PLEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
          owner: serverkraken
          repositories: reusable-workflows

      - name: Checkout catalog on main
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: main
          token: ${{ steps.catalog-token.outputs.token }}
          fetch-depth: 0

      - name: Download all result artifacts
        uses: actions/download-artifact@v4
        with:
          path: results
          pattern: onboard-result-*
          merge-multiple: true

      - name: Build step summary table
        id: summary
        run: |
          set -euo pipefail
          {
            echo "## Onboarding run summary"
            echo ""
            echo "| Repository | Language | Version | Add PR | Cleanup PR | Status |"
            echo "|---|---|---|---|---|---|"
            for f in results/*.json; do
              [[ -f "$f" ]] || continue
              target=$(jq -r '.target' "$f")
              lang=$(jq -r '.language' "$f")
              ver=$(jq -r '.version' "$f")
              pa=$(jq -r '.pr_a_url' "$f")
              pas=$(jq -r '.pr_a_status' "$f")
              pb=$(jq -r '.pr_b_url' "$f")
              pbs=$(jq -r '.pr_b_status' "$f")
              js=$(jq -r '.job_status' "$f")

              if [[ "$pas" == "no-changes" && "$pbs" == "no-legacy" ]]; then
                combined="complete"
              elif [[ "$pas" == "no-changes" && "$pbs" == "cleanup-open" ]]; then
                combined="cleanup-open"
              elif [[ "$pas" == "add-open" && "$pbs" == "no-legacy" ]]; then
                combined="add-open, no-legacy"
              elif [[ "$pas" == "add-open" && "$pbs" == "cleanup-open" ]]; then
                combined="add-open, cleanup-open"
              else
                combined="$pas / $pbs"
              fi
              if [[ "$js" != "success" ]]; then
                combined="error ($combined)"
              fi

              pa_md="—"
              pb_md="—"
              [[ -n "$pa" ]] && pa_md="[link]($pa)"
              [[ -n "$pb" ]] && pb_md="[link]($pb)"
              echo "| $target | $lang | $ver | $pa_md | $pb_md | $combined |"
            done
          } >> "$GITHUB_STEP_SUMMARY"

          # Also emit a machine-readable copy for the status-doc step.
          cp -r results results-for-status

      - name: Update docs/onboarding-status.md
        if: ${{ !inputs.dry_run }}
        env:
          GH_TOKEN: ${{ steps.catalog-token.outputs.token }}
        run: |
          set -euo pipefail
          # Bot identity: id is public and stable; fetched inline so we never
          # commit a hardcoded numeric id that could drift.
          bot_id=$(gh api '/users/serverkraken-release-bot[bot]' -q '.id')
          git config user.name 'serverkraken-release-bot[bot]'
          git config user.email "${bot_id}+serverkraken-release-bot[bot]@users.noreply.github.com"

          DOC=docs/onboarding-status.md
          if [[ ! -f "$DOC" ]]; then
            echo "::warning::$DOC missing — initializing"
            cat > "$DOC" <<EOF
          # Onboarding Status

          _Last updated by the onboarding workflow: $(date -u +%Y-%m-%dT%H:%M:%SZ)_

          | Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
          |---|---|---|---|---|---|
          EOF
          fi

          # Re-derive "Last updated" line.
          stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          sed -i "s|^_Last updated by the onboarding workflow:.*|_Last updated by the onboarding workflow: ${stamp}_|" "$DOC"

          # For each result, replace or append a row.
          for f in results-for-status/*.json; do
            [[ -f "$f" ]] || continue
            target=$(jq -r '.target' "$f")
            ver=$(jq -r '.version' "$f")
            pa=$(jq -r '.pr_a_url' "$f")
            pas=$(jq -r '.pr_a_status' "$f")
            pb=$(jq -r '.pr_b_url' "$f")
            pbs=$(jq -r '.pr_b_status' "$f")

            if [[ "$pas" == "no-changes" && "$pbs" == "no-legacy" ]]; then
              status="complete"
            elif [[ "$pas" == "no-changes" && "$pbs" == "cleanup-open" ]]; then
              status="cleanup-open"
            elif [[ "$pas" == "add-open" && "$pbs" == "no-legacy" ]]; then
              status="add-open, no-legacy"
            elif [[ "$pas" == "add-open" && "$pbs" == "cleanup-open" ]]; then
              status="add-open, cleanup-open"
            else
              status="$pas / $pbs"
            fi

            pa_md="—"
            pb_md="—"
            [[ -n "$pa" ]] && pa_md="[PR]($pa)"
            [[ -n "$pb" ]] && pb_md="[PR]($pb)"

            today=$(date -u +%Y-%m-%d)
            new_row="| $target | $today | ${PIN_VERSION:-v1} | $pa_md | $pb_md | $status |"

            # Replace existing row (matched by exact "| <target> |" at line start) or append.
            awk -v tgt="$target" -v row="$new_row" '
              BEGIN { replaced=0 }
              {
                if (index($0, "| " tgt " |") == 1) { print row; replaced=1 }
                else { print $0 }
              }
              END {
                if (!replaced) { print row }
              }
            ' "$DOC" > "$DOC.new" && mv "$DOC.new" "$DOC"
          done

          if git diff --quiet -- "$DOC"; then
            echo "No status doc changes."
            exit 0
          fi

          git add "$DOC"
          git commit -m "chore(onboard): update onboarding-status.md [skip ci]"
          git push origin main
        env:
          PIN_VERSION: ${{ inputs.pin_version }}
          GH_TOKEN: ${{ steps.catalog-token.outputs.token }}
```

> **Note for executor:** the awk pass writes the new content to `$DOC.new` and atomically moves it back into place — this is the table-row replace/append routine. The `[skip ci]` suffix on the commit message prevents `catalog-release.yml` from firing on the bot's own status-doc commits.

- [ ] **Step 2: Run actionlint + yamllint**

```bash
actionlint .github/workflows/onboard.yml && yamllint .github/workflows/onboard.yml
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): add finalize job (aggregation + status doc + step summary)"
```

---

## Task 14: Self-CI dry-run integration test

**Files:**
- Modify: `.github/workflows/integration.yml` — append a `test-onboard-dry-run` job

- [ ] **Step 1: Append the test job**

At the end of `.github/workflows/integration.yml`, after the existing `test-cleanup-images:` job, append:

```yaml

  # ----- onboard dry-run: exercise detect + render against the catalog itself -----
  test-onboard-dry-run:
    uses: ./.github/workflows/onboard.yml
    with:
      target_repos: serverkraken/reusable-workflows
      language: auto
      dry_run: true
      pin_version: v1
    secrets: inherit
```

- [ ] **Step 2: Run actionlint + yamllint**

```bash
actionlint .github/workflows/integration.yml && yamllint .github/workflows/integration.yml
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "test(integration): exercise onboard.yml in dry-run against self"
```

---

## Task 15: Seed script + initial `onboarding-status.md`

**Files:**
- Create: `scripts/seed-onboarding-status.sh`
- Create: `docs/onboarding-status.md` (initial skeleton, no rows)

- [ ] **Step 1: Write the seed script**

File: `scripts/seed-onboarding-status.sh`

```bash
#!/usr/bin/env bash
# seed-onboarding-status.sh — populate docs/onboarding-status.md with one row
# per serverkraken/* repo. Existing rows are preserved; only new repos are appended.
#
# Usage: scripts/seed-onboarding-status.sh
# Requires: gh, jq

set -euo pipefail

DOC=docs/onboarding-status.md

if ! command -v gh >/dev/null; then
  echo "gh CLI required" >&2
  exit 1
fi

stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ ! -f "$DOC" ]]; then
  cat > "$DOC" <<EOF
# Onboarding Status

_Last updated by the onboarding workflow: ${stamp}_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
EOF
fi

repos=$(gh repo list serverkraken --limit 200 --json nameWithOwner -q '.[].nameWithOwner' | sort)

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  esc=$(printf '%s' "$repo" | sed 's|/|\\/|g')
  if grep -qE "^\\| ${esc} \\|" "$DOC"; then
    continue
  fi
  echo "| ${repo} | — | — | — | — | not onboarded |" >> "$DOC"
done <<< "$repos"

echo "Seeded $DOC. Review with git diff before committing."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/seed-onboarding-status.sh
```

- [ ] **Step 3: Write the initial skeleton onboarding-status.md**

File: `docs/onboarding-status.md`

```markdown
# Onboarding Status

_Last updated by the onboarding workflow: 2026-05-16T00:00:00Z_

This document tracks which `serverkraken/*` repositories have been onboarded to the reusable-workflows catalog. The `onboard.yml` workflow updates rows for repos it touches. Run `scripts/seed-onboarding-status.sh` once to populate `not onboarded` rows for all org repos.

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
```

(The table is intentionally empty here. Run the seed script locally — described in `docs/operations.md` §5 — to populate the rows.)

- [ ] **Step 4: Commit**

```bash
git add scripts/seed-onboarding-status.sh docs/onboarding-status.md
git commit -m "feat(onboard): add status doc skeleton and one-shot seed script"
```

---

## Task 16: Documentation updates

**Files:**
- Modify: `docs/contracts.md` — append "Internal Composite Actions" subsection
- Modify: `docs/operations.md` — append §5 "Onboarding workflow"
- Modify: `CONTRIBUTING.md` — document acceptance procedure

- [ ] **Step 1: Update `docs/contracts.md`**

At the very end of `docs/contracts.md`, append:

```markdown

---

## Internal Composite Actions

These are not intended for external consumption — they exist to factor `onboard.yml`. Their inputs/outputs are not part of the catalog's semver-protected surface.

### `actions/onboard-detect`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `repo_path` | string | yes | — | Path to checked-out target repo on the runner |
| input | `language_override` | string | no | `'auto'` | `auto` runs file-signal detection; otherwise forces the value |
| input | `target_repo` | string | yes | — | `owner/repo` of target (for `gh` API lookups) |
| input | `github_token` | string | yes | — | Token with read access to `target_repo` |
| output | `language` | string | — | — | Detected language |
| output | `release_type` | string | — | — | release-please release-type (1:1 with language for V1) |
| output | `current_version` | string | — | — | Current version (no leading `v`); `0.0.0` if no release found |
| output | `default_branch` | string | — | — | Default branch of `target_repo` |

### `actions/onboard-render`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `catalog_path` | string | yes | — | Path to checked-out catalog repo |
| input | `target_path` | string | yes | — | Path to checked-out target repo (rendered files written here) |
| input | `release_type` | string | yes | — | release-please release-type |
| input | `current_version` | string | yes | — | Current version, no leading `v` |
| input | `pin_version` | string | no | `'v1'` | Catalog `@version` to pin rendered templates to |
```

- [ ] **Step 2: Update `docs/operations.md`**

At the very end of `docs/operations.md`, append:

```markdown

---

## 5. Onboarding Workflow

`onboard.yml` (workflow_dispatch + workflow_call) adopts the catalog into other `serverkraken/*` repos. Reuses the existing `serverkraken-release-bot` App — **no new App setup, permissions, or org secrets required**.

### 5.1 Prerequisites

- `docs/onboarding-status.md` must exist. Initial seed (one-time): `scripts/seed-onboarding-status.sh` (requires local `gh` CLI authenticated against `serverkraken`).
- `serverkraken-release-bot` App is already installed org-wide (see §1.2).
- Catalog `main` branch protection must allow the App actor to push directly (already required by `catalog-release.yml`).

### 5.2 Dispatching an onboarding run

UI: **Actions → onboard → Run workflow**.

| Input | Notes |
|---|---|
| `target_repos` | Comma-separated `serverkraken/<name>` list. Validated against `^serverkraken/[A-Za-z0-9._-]+$`. |
| `language` | `auto` runs detection. Set explicitly to break detection ambiguity. |
| `dry_run` | `true` renders + logs diff, no PRs opened. Use for first-time verification. |
| `pin_version` | What `@version` the rendered templates pin to. Default `v1`. |
| `add_branch_name` / `cleanup_branch_name` | Escape hatches. Default branch names are bot-owned and force-pushed each run. |

### 5.3 What it produces

Per target, up to two PRs:

- **PR A** on `chore/onboard-reusable-workflows`: adds `ci.yml`, `release.yml`, `prerelease.yml`, `cleanup.yml`, `release-please-config.json`, `.release-please-manifest.json`. Always opened when the rendered diff is non-empty.
- **PR B** on `chore/remove-legacy-workflows`: deletes a curated list of legacy workflow names (`semantic-release.yml`, `docker-build.yml`, `trivy.yml`, `trivy.yaml`, `build.yml`, `publish.yml`). Only opened when at least one matches in the target.

### 5.4 Idempotency

Branches are bot-owned and force-reset to `default_branch` HEAD on every run. Empty-diff cases close any open PR on that branch. Re-running on a fully-onboarded repo is a no-op.

### 5.5 Manual acceptance flow (first run after a change to the workflow)

1. Pick one low-risk target (recommend a fresh throwaway repo first, then one of the smallest production repos).
2. Dispatch with `dry_run: true` — verify the step summary's diff matches expectations.
3. Re-dispatch with `dry_run: false` — review PR A in the target repo, merge it, push one `feat:` / `fix:` commit, verify the release-please PR opens and a release runs end-to-end.
4. Merge PR B once a release has run green.
5. Move to bulk: dispatch with a comma-separated list of all candidate repos.

### 5.6 Failure handling

`fail-fast: false` ensures one target's failure doesn't abort the rest. Each target's status is in the run's step summary and `docs/onboarding-status.md`. Re-running with the same inputs is safe and skips already-applied changes.
```

- [ ] **Step 3: Update `CONTRIBUTING.md`**

At the very end of `CONTRIBUTING.md`, append:

```markdown

## Onboarding workflow — acceptance procedure

Whenever `onboard.yml`, `actions/onboard-*`, or `scripts/onboard-*` change:

1. Bats unit tests pass: `bats tests/shell/`.
2. Static lint passes: the `validate` workflow on PR.
3. Self dry-run passes: the `test-onboard-dry-run` job inside `integration` runs the workflow against the catalog itself with `dry_run: true`.
4. Manual smoke: from a release of the catalog, dispatch `onboard.yml` against one low-risk repo with `dry_run: true`. Verify the rendered diff in the step summary. Re-run with `dry_run: false` and merge PR A. Push a `feat:` commit. Verify `release.yml` end-to-end runs green. Merge PR B.

Document any new gotcha in `CLAUDE-troubleshooting.md` so the next session benefits.
```

- [ ] **Step 4: Commit**

```bash
git add docs/contracts.md docs/operations.md CONTRIBUTING.md
git commit -m "docs(onboard): document contracts, operations runbook §5, and acceptance procedure"
```

---

## Task 17: Memory bank sync

**Files (LOCAL ONLY — NEVER COMMITTED, per global rule):**
- Modify: `CLAUDE-activeContext.md`
- Modify: `CLAUDE-decisions.md`
- Modify: `CLAUDE-patterns.md`

- [ ] **Step 1: Update `CLAUDE-activeContext.md`**

Replace the "Current state" and "Next session focus" sections with:

```markdown
## Current state (2026-05-16 — onboarding shipped)

**Onboarding workflow shipped.** `.github/workflows/onboard.yml` + two composite actions (`onboard-detect`, `onboard-render`) + two bats-tested scripts + seven detection fixtures + two new adopter templates + status doc skeleton + ops runbook §5. Self-CI exercises a dry-run against the catalog itself.

Per-target run produces up to two PRs (add + cleanup), bot-owned branches, idempotent on re-run. Reuses `serverkraken-release-bot` App without any new operational setup.

Spec: `docs/superpowers/specs/2026-05-16-onboarding-workflow-design.md`
Plan: `docs/superpowers/plans/2026-05-16-onboarding-workflow.md` (17 tasks, all complete)

## Next session focus

1. **Manual acceptance run** — dispatch onboard.yml against ONE low-risk target with `dry_run: true`, review diff; then `dry_run: false`, merge PR A, push commit, verify release pipeline. Merge PR B.
2. **Bulk run** — once acceptance is green, dispatch against the 6-repo hand-rolled-bash cohort.
3. **Language-track atoms** (`lint-go`, `test-go`, `lint-python`, …) — separate spec, future.
```

- [ ] **Step 2: Update `CLAUDE-decisions.md`**

Append at the end:

```markdown

---

## D-10..D-19: Onboarding workflow

Inherited verbatim from the onboarding spec §14 (entries OB-1..OB-10). See `docs/superpowers/specs/2026-05-16-onboarding-workflow-design.md` §14 for full rationale per decision. Highlights:

- **OB-1**: Two-PR split (add + cleanup) for staging-friendly adoption.
- **OB-2**: Composite actions + bats — matches the existing `compute-prerelease-tag` pattern.
- **OB-4**: `fail-fast: false` matrix — bulk-run resilience.
- **OB-5**: Bot-owned branches force-reset each run — what makes idempotency work.
- **OB-7**: `dry_run` first-class — essential for bulk previews.
- **OB-10**: Reuse existing App, no new setup.
```

- [ ] **Step 3: Update `CLAUDE-patterns.md`**

Append at the end:

```markdown

---

## Matrix-output aggregation via per-slot artifact

**Problem.** GitHub Actions matrix jobs can't aggregate outputs the way `needs.<job>.outputs.X` does for non-matrix jobs — each matrix slot is a separate job instance, and `outputs:` from a matrix job is undefined.

**Solution.** Each matrix slot uploads a JSON artifact named `onboard-result-<owner>-<name>`. A downstream `finalize` job (`needs: onboard, if: always()`) downloads all matching artifacts via `actions/download-artifact@v4` with `pattern: onboard-result-*, merge-multiple: true`, then aggregates with `jq`.

```yaml
# Per matrix slot:
- uses: actions/upload-artifact@v4
  with:
    name: onboard-result-${{ matrix.target.owner }}-${{ matrix.target.name }}
    path: result/
    retention-days: 7

# In finalize:
- uses: actions/download-artifact@v4
  with:
    path: results
    pattern: onboard-result-*
    merge-multiple: true
```

Code: `.github/workflows/onboard.yml` (matrix `onboard` job's "Emit per-target result artifact" + finalize's "Download all result artifacts" + "Build step summary table"). Apply when adding future matrix workflows that need to roll-up results into a single summary.

---

## Idempotent bot-owned branch via force-reset

**Problem.** Workflows that maintain a long-lived PR branch face two failure modes: (a) the bot accumulates stale content if it merges into the existing branch; (b) if the adopter pushed to the branch, the bot collides.

**Solution.** Treat the branch as **owned by the bot, recreated each run**. Pattern:

```bash
git fetch origin "$DEFAULT_BRANCH"
git checkout -B "$BOT_BRANCH" "origin/$DEFAULT_BRANCH"   # discards any prior bot-branch history
# apply changes
git add ...
git commit -m "..."
git push -f origin "$BOT_BRANCH"
```

Combined with:
- Empty-diff detection: `git diff --cached --quiet` → close existing PR.
- Idempotent PR ensure: `gh pr list --head $branch --state open` → edit if exists, else create.

Code: `onboard.yml` PR A and PR B steps. Apply when designing any "bot maintains a PR" workflow.
```

- [ ] **Step 4: Do NOT commit memory bank files**

Per the global rule in `~/.claude/CLAUDE.md` ("NEVER commit CLAUDE.md or CLAUDE-*.md files"), leave these as untracked local changes. Run `git status` and verify they're unstaged.

```bash
git status
```

Expected: `CLAUDE-activeContext.md`, `CLAUDE-decisions.md`, `CLAUDE-patterns.md` shown as modified but not staged.

---

## Final verification

- [ ] **Step 1: Run the full bats suite**

```bash
bats tests/shell/
```

Expected: all tests pass (compute-prerelease-tag + onboard-detect + onboard-render).

- [ ] **Step 2: Run actionlint on every workflow + action**

```bash
actionlint .github/workflows/*.yml actions/*/action.yml
```

Expected: clean.

- [ ] **Step 3: Run yamllint**

```bash
yamllint .github/ actions/ tests/
```

Expected: clean.

- [ ] **Step 4: Push the branch and verify the validate + integration workflows pass on PR**

```bash
git push origin <feature-branch>
gh pr create --title "feat: add Level-3 onboarding workflow" --body "Implements docs/superpowers/specs/2026-05-16-onboarding-workflow-design.md per plan docs/superpowers/plans/2026-05-16-onboarding-workflow.md"
gh pr checks --watch
```

Expected: `validate` and `integration` pass. The `test-onboard-dry-run` integration job exercises detect + render against the catalog itself.

- [ ] **Step 5: Manual acceptance (one low-risk target)**

After the PR merges and release-please cuts a new minor version (`v1.2.0`), dispatch `onboard.yml` from the Actions UI with:

- `target_repos`: a single low-risk repo (recommend a throwaway test repo first)
- `dry_run`: true

Verify the step summary diff. If correct, re-dispatch with `dry_run: false` and inspect PR A in the target. Merge it, push a commit, verify the new `release.yml` pipeline runs green. Then merge PR B.
