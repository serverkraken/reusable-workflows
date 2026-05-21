# Per-Adopter Override Variables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire ten tunable atom inputs through `${{ vars.SK_* || '<default>' }}` expressions in the adopter skeleton templates so adopters can override defaults via repo/org GitHub Variables UI without editing rendered ci.yml.

**Architecture:** Pure-template approach. `ci.yml.tmpl` and `prerelease.yml.tmpl` emit expression-fallbacks whose defaults are hardcoded constants that mirror the atom-level `default:` fields. A bats default-sync test prevents the two from drifting silently. Drift-check stays clean because the rendered file content is identical for all adopters with the same profile. Type coercion (string-typed GitHub Variables into `type: number` atom inputs) is verified by a dedicated integration smoke caller.

**Tech Stack:** gomplate templates (existing), bats (existing), GitHub Actions reusable workflows, GitHub repository variables (`vars.*` context).

**Spec:** `docs/superpowers/specs/2026-05-21-per-repo-override-vars-design.md`

**Branch:** `feat/per-repo-override-vars` (worktree at `.worktrees/per-repo-vars/`)

---

## Phase 1: Go section in ci.yml.tmpl

Wire `SK_COVERAGE_THRESHOLD`, `SK_CGO_ENABLED` (override-wins), `SK_GO_VERSION`, `SK_GOLANGCI_LINT_VERSION`. This proves the pattern end-to-end before extending to Python/Rust/Trivy.

### Task 1: Edit ci.yml.tmpl Go section to emit SK_* expressions

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl` lines 32-43

- [ ] **Step 1: Open the template and locate the Go block**

Read `docs/adopter-templates/skeletons/ci.yml.tmpl` lines 32-43. Current content:

```
{{- if eq $c.primary_language "go" }}
  lint-go-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-go.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    {{- if index $c "cgo" }}
      cgo_enabled: true
    {{- end }}
    secrets: inherit
  test-go-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-go.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    {{- if index $c "cgo" }}
      cgo_enabled: true
    {{- end }}
    secrets: inherit
```

- [ ] **Step 2: Replace with the SK_*-wired version**

```
{{- if eq $c.primary_language "go" }}
  lint-go-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-go.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      go_version: {{`${{ vars.SK_GO_VERSION || '' }}`}}
      golangci_lint_version: {{`${{ vars.SK_GOLANGCI_LINT_VERSION || 'v2.12.2' }}`}}
    {{- if index $c "cgo" }}
      cgo_enabled: {{`${{ vars.SK_CGO_ENABLED || 'true' }}`}}
    {{- else }}
      cgo_enabled: {{`${{ vars.SK_CGO_ENABLED || 'false' }}`}}
    {{- end }}
    secrets: inherit
  test-go-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-go.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      go_version: {{`${{ vars.SK_GO_VERSION || '' }}`}}
      coverage_threshold: {{`${{ vars.SK_COVERAGE_THRESHOLD || '80' }}`}}
    {{- if index $c "cgo" }}
      cgo_enabled: {{`${{ vars.SK_CGO_ENABLED || 'true' }}`}}
    {{- else }}
      cgo_enabled: {{`${{ vars.SK_CGO_ENABLED || 'false' }}`}}
    {{- end }}
    secrets: inherit
```

Note: cgo branch is duplicated between lint-go and test-go on purpose — both atoms accept `cgo_enabled` and both need the override-wins semantic.

### Task 2: Regenerate golden fixtures for Go-bearing fixtures

**Files:**
- Modify (regenerated): `tests/fixtures/onboard/{go-repo,go-cgo,go-cgo-transitive,monorepo-go,multi-dockerfile,cli-go-with-goreleaser,library-go,service-with-helm}/expected/.github/workflows/ci.yml`
- Modify (regenerated): matching `expected/.github/onboard.lock.json` files (sha256 changes)
- Modify (regenerated): `tests/shell/golden/ci/{single-go.yml,monorepo-mixed.yml}`

- [ ] **Step 1: Run bats with UPDATE_GOLDEN=1 to regenerate every fixture**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/per-repo-vars
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
```

Expected: every `golden:` test reports `# skip UPDATE_GOLDEN — rewrote <fixture>/expected`. No `not ok` lines.

- [ ] **Step 2: Inspect a regenerated golden to confirm it has the new expressions**

```bash
cat tests/fixtures/onboard/go-cgo-transitive/expected/.github/workflows/ci.yml
```

Expected output must contain (among other lines):

```yaml
  lint-go-root:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-go.yml@v2
    with:
      working_directory: .
      go_version: ${{ vars.SK_GO_VERSION || '' }}
      golangci_lint_version: ${{ vars.SK_GOLANGCI_LINT_VERSION || 'v2.12.2' }}
      cgo_enabled: ${{ vars.SK_CGO_ENABLED || 'true' }}
    secrets: inherit
  test-go-root:
    uses: serverkraken/reusable-workflows/.github/workflows/test-go.yml@v2
    with:
      working_directory: .
      go_version: ${{ vars.SK_GO_VERSION || '' }}
      coverage_threshold: ${{ vars.SK_COVERAGE_THRESHOLD || '80' }}
      cgo_enabled: ${{ vars.SK_CGO_ENABLED || 'true' }}
    secrets: inherit
```

If a non-cgo fixture is inspected (e.g. `go-repo`), the cgo line must read `... || 'false' }}`.

- [ ] **Step 3: Re-run bats without UPDATE_GOLDEN to verify clean state**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all `golden:` tests now report `ok` (no skip suffix).

### Task 3: Add inline render assertions for the Go vars pattern

**Files:**
- Modify: `tests/shell/onboard-render.bats` (append after the existing "ci.yml emits cgo_enabled: true when component has cgo:true" test)

- [ ] **Step 1: Append the new assertion block**

Append to `tests/shell/onboard-render.bats`:

```bash
@test "ci.yml emits SK_* override expressions for Go test atom" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service", "cgo": false,
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "coverage_threshold: \${{ vars.SK_COVERAGE_THRESHOLD || '80' }}" "$rendered"
  grep -qF "go_version: \${{ vars.SK_GO_VERSION || '' }}" "$rendered"
  grep -qF "golangci_lint_version: \${{ vars.SK_GOLANGCI_LINT_VERSION || 'v2.12.2' }}" "$rendered"
  grep -qF "cgo_enabled: \${{ vars.SK_CGO_ENABLED || 'false' }}" "$rendered"
}

@test "ci.yml emits SK_CGO_ENABLED || 'true' branch when profile sets cgo:true" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service", "cgo": true,
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  # Both lint-go and test-go branches must carry the 'true' fallback.
  grep -c "cgo_enabled: \${{ vars.SK_CGO_ENABLED || 'true' }}" "$rendered" | grep -qx 2
}
```

- [ ] **Step 2: Run the two new tests**

```bash
bats tests/shell/onboard-render.bats --filter "SK_\\*|SK_CGO"
```

Expected: both `ok`, zero `not ok`.

- [ ] **Step 3: Run full bats suite to confirm nothing else broke**

```bash
bats tests/shell/
```

Expected: total ok count = previous count + 2, `not ok` count = 0.

### Task 4: Commit Phase 1

- [ ] **Step 1: Stage + commit**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/per-repo-vars
git add docs/adopter-templates/skeletons/ci.yml.tmpl \
        tests/fixtures/onboard \
        tests/shell/golden \
        tests/shell/onboard-render.bats
git commit -m "feat(onboard): wire SK_* vars override for Go atoms in ci.yml.tmpl

Routes coverage_threshold, cgo_enabled, go_version, and
golangci_lint_version through GitHub Variables expressions
(SK_COVERAGE_THRESHOLD, SK_CGO_ENABLED, SK_GO_VERSION,
SK_GOLANGCI_LINT_VERSION). Adopters tune these in Settings UI
without touching rendered ci.yml.

SK_CGO_ENABLED uses override-wins: any explicit value (true OR false)
replaces the profile auto-detect result. Template default in the
||-fallback comes from the profile.

First slice of the per-adopter override design — Python, Rust, and
trivy knobs follow in subsequent commits."
```

---

## Phase 2: Python section in ci.yml.tmpl

Wire `SK_PYTHON_VERSION`, `SK_COVERAGE_THRESHOLD` for the Python atoms.

### Task 5: Edit ci.yml.tmpl Python section

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl` (Python branch, ~lines 44-55)

- [ ] **Step 1: Replace the Python branch with SK_*-wired version**

Locate the `{{- else if eq $c.primary_language "python" }}` block in `ci.yml.tmpl`. Replace its body with:

```
{{- else if eq $c.primary_language "python" }}
  lint-python-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-python.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      python_version: {{`${{ vars.SK_PYTHON_VERSION || '' }}`}}
    secrets: inherit
  test-python-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-python.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      python_version: {{`${{ vars.SK_PYTHON_VERSION || '' }}`}}
      coverage_threshold: {{`${{ vars.SK_COVERAGE_THRESHOLD || '80' }}`}}
    secrets: inherit
```

### Task 6: Regenerate Python-bearing fixtures

- [ ] **Step 1: UPDATE_GOLDEN run**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
```

Expected: same per-fixture skip messages as before. Note: most fixtures are Go; only `tests/shell/golden/ci/single-python.yml` exercises this path.

- [ ] **Step 2: Inspect the python golden**

```bash
cat tests/shell/golden/ci/single-python.yml
```

Must contain:

```yaml
  test-python-root:
    uses: serverkraken/reusable-workflows/.github/workflows/test-python.yml@v3
    with:
      working_directory: .
      python_version: ${{ vars.SK_PYTHON_VERSION || '' }}
      coverage_threshold: ${{ vars.SK_COVERAGE_THRESHOLD || '80' }}
    secrets: inherit
```

- [ ] **Step 3: Re-run bats to confirm clean**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all green.

### Task 7: Add inline assertion for Python vars

**Files:**
- Modify: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Append new test**

```bash
@test "ci.yml emits SK_* override expressions for Python test atom" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["python"], "primary_language": "python",
      "release_please_type": "python", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "python_version: \${{ vars.SK_PYTHON_VERSION || '' }}" "$rendered"
  grep -qF "coverage_threshold: \${{ vars.SK_COVERAGE_THRESHOLD || '80' }}" "$rendered"
}
```

- [ ] **Step 2: Run it**

```bash
bats tests/shell/onboard-render.bats --filter "SK_\\* override expressions for Python"
```

Expected: ok.

### Task 8: Commit Phase 2

```bash
git add docs/adopter-templates/skeletons/ci.yml.tmpl \
        tests/fixtures/onboard \
        tests/shell/golden \
        tests/shell/onboard-render.bats
git commit -m "feat(onboard): wire SK_PYTHON_VERSION + SK_COVERAGE_THRESHOLD for Python atoms"
```

---

## Phase 3: Rust section in ci.yml.tmpl

Wire `SK_RUST_TOOLCHAIN`, `SK_COVERAGE_THRESHOLD`, `SK_CARGO_LLVM_COV_VERSION`, `SK_CLIPPY_ARGS`.

### Task 9: Edit ci.yml.tmpl Rust section

- [ ] **Step 1: Replace the Rust branch**

Locate `{{- else if eq $c.primary_language "rust" }}` in `ci.yml.tmpl`. Replace body:

```
{{- else if eq $c.primary_language "rust" }}
  lint-rust-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-rust.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      rust_toolchain: {{`${{ vars.SK_RUST_TOOLCHAIN || '' }}`}}
      clippy_args: {{`${{ vars.SK_CLIPPY_ARGS || '' }}`}}
    secrets: inherit
  test-rust-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-rust.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      rust_toolchain: {{`${{ vars.SK_RUST_TOOLCHAIN || '' }}`}}
      coverage_threshold: {{`${{ vars.SK_COVERAGE_THRESHOLD || '80' }}`}}
      cargo_llvm_cov_version: {{`${{ vars.SK_CARGO_LLVM_COV_VERSION || 'v0.6.16' }}`}}
    secrets: inherit
```

### Task 10: Regenerate Rust-bearing fixtures + add bats

- [ ] **Step 1: UPDATE_GOLDEN run**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
```

- [ ] **Step 2: Inspect `tests/shell/golden/ci/single-rust.yml`**

Must contain:

```yaml
      cargo_llvm_cov_version: ${{ vars.SK_CARGO_LLVM_COV_VERSION || 'v0.6.16' }}
```

- [ ] **Step 3: Append rust bats assertion**

```bash
@test "ci.yml emits SK_* override expressions for Rust test atom" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["rust"], "primary_language": "rust",
      "release_please_type": "rust", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "rust_toolchain: \${{ vars.SK_RUST_TOOLCHAIN || '' }}" "$rendered"
  grep -qF "cargo_llvm_cov_version: \${{ vars.SK_CARGO_LLVM_COV_VERSION || 'v0.6.16' }}" "$rendered"
  grep -qF "clippy_args: \${{ vars.SK_CLIPPY_ARGS || '' }}" "$rendered"
}
```

- [ ] **Step 4: Run + commit**

```bash
bats tests/shell/ | tail -3   # confirm all green
git add docs/adopter-templates/skeletons/ci.yml.tmpl \
        tests/fixtures/onboard \
        tests/shell/golden \
        tests/shell/onboard-render.bats
git commit -m "feat(onboard): wire SK_* vars for Rust atoms (toolchain/threshold/llvm-cov/clippy)"
```

---

## Phase 4: ci.yml.tmpl secscan (trivy-fs)

Wire `SK_TRIVY_SEVERITY`, `SK_TRIVY_VERSION` on the always-emitted secscan job.

### Task 11: Edit secscan block in ci.yml.tmpl

- [ ] **Step 1: Locate the existing secscan block (lines 17-24)**

Current:

```
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      actions: read
    secrets: inherit
```

- [ ] **Step 2: Add a `with:` block**

```
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      severity: {{`${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}`}}
      trivy_version: {{`${{ vars.SK_TRIVY_VERSION || '' }}`}}
    secrets: inherit
```

### Task 12: Regenerate + add bats for secscan

- [ ] **Step 1: UPDATE_GOLDEN run**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
```

- [ ] **Step 2: Inspect any golden's secscan emit**

```bash
sed -n '/^  secscan:/,/^[a-z]/p' tests/shell/golden/ci/single-go.yml
```

Must contain:

```yaml
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@v3
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      severity: ${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}
      trivy_version: ${{ vars.SK_TRIVY_VERSION || '' }}
    secrets: inherit
```

- [ ] **Step 3: Append bats**

```bash
@test "ci.yml secscan wires SK_TRIVY_SEVERITY and SK_TRIVY_VERSION" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [], "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "severity: \${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}" "$rendered"
  grep -qF "trivy_version: \${{ vars.SK_TRIVY_VERSION || '' }}" "$rendered"
}
```

- [ ] **Step 4: Run + commit**

```bash
bats tests/shell/ | tail -3
git add docs/adopter-templates/skeletons/ci.yml.tmpl \
        tests/fixtures/onboard \
        tests/shell/golden \
        tests/shell/onboard-render.bats
git commit -m "feat(onboard): wire SK_TRIVY_SEVERITY + SK_TRIVY_VERSION on ci.yml secscan"
```

---

## Phase 5: prerelease.yml.tmpl scan (trivy-image)

Thread the same Trivy knobs through the prerelease scan job.

### Task 13: Edit prerelease.yml.tmpl

- [ ] **Step 1: Locate the existing scan block (single-image branch, lines 29-39)**

Current:

```
  scan:
    needs: build
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-image.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      packages: read
      actions: read
    secrets: inherit
    with:
      image_ref: {{`${{ needs.build.outputs.image_ref }}`}}
```

- [ ] **Step 2: Add Trivy SK_* lines**

```
  scan:
    needs: build
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-image.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      packages: read
      actions: read
    secrets: inherit
    with:
      image_ref: {{`${{ needs.build.outputs.image_ref }}`}}
      severity: {{`${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}`}}
      trivy_version: {{`${{ vars.SK_TRIVY_VERSION || '' }}`}}
```

### Task 14: Regenerate prerelease fixtures + verify

- [ ] **Step 1: UPDATE_GOLDEN run**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
```

- [ ] **Step 2: Inspect a prerelease golden that has a single-Dockerfile component**

```bash
cat tests/fixtures/onboard/go-repo/expected/.github/workflows/prerelease.yml
```

Scan job block must include the two new SK_* lines.

- [ ] **Step 3: Re-run bats clean**

```bash
bats tests/shell/onboard-render.bats | tail -3
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add docs/adopter-templates/skeletons/prerelease.yml.tmpl \
        tests/fixtures/onboard
git commit -m "feat(onboard): wire SK_TRIVY_SEVERITY + SK_TRIVY_VERSION on prerelease scan"
```

---

## Phase 6: Type-coercion integration smoke caller

Prove that GitHub Actions coerces a string-valued `vars.*` fallback into `type: number` and `type: boolean` atom inputs.

### Task 15: Create the smoke caller

**Files:**
- Create: `tests/callers/test-vars-coercion.yml`

- [ ] **Step 1: Write the file**

```yaml
# tests/callers/test-vars-coercion.yml
# Verifies GitHub Actions' workflow_call type coercion of string-valued
# `vars.*` expressions into `type: number` and `type: boolean` atom inputs.
#
# The vars.NONEXISTENT_*_FOR_COERCION_TEST references intentionally point
# at variables that don't exist — the || fallback always fires, evaluating
# to a literal string ('70', 'false'). If the atom accepts that as the
# correct number / boolean, our SK_* override pattern works in production.
name: caller-test-vars-coercion
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/test-go.yml'
      - 'tests/callers/test-vars-coercion.yml'
      - 'docs/adopter-templates/skeletons/ci.yml.tmpl'

jobs:
  test-go-coercion:
    uses: ./.github/workflows/test-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/minimal-go
      coverage_threshold: ${{ vars.NONEXISTENT_NUMBER_FOR_COERCION_TEST || '70' }}
      cgo_enabled: ${{ vars.NONEXISTENT_BOOL_FOR_COERCION_TEST || 'false' }}
```

The `tests/fixtures/minimal-go` already exists for integration tests and has zero `*_test.go` files — `go test ./...` exits with `coverage: [no statements]`, the threshold check uses 0% < 70 and fails noisily IF coercion broke (because the input would be treated as nil/invalid). With coercion working, the gate runs `0 < 70 ⇒ fail` cleanly with the expected `::error::coverage 0.0% < threshold 70%` line — which is the success signal for our coercion test (a numeric comparison happened).

The realistic positive signal is the `threshold: 70%` echo line — that proves the value was passed numerically.

### Task 16: Wire the caller into integration.yml

**Files:**
- Modify: `.github/workflows/integration.yml`

- [ ] **Step 1: Locate the end of the existing jobs block in integration.yml**

The last job today is `test-onboard-dry-run`. Append after it.

- [ ] **Step 2: Add a downstream verification job**

```yaml
  # ----- vars coercion: verify type=number + type=boolean inputs accept
  #       string-valued GHA expressions, which is what the SK_* override
  #       pattern emits in adopter ci.yml. continue-on-error: true so a
  #       coercion failure does NOT block the integration run from
  #       reporting other failures.
  test-vars-coercion:
    uses: ./tests/callers/test-vars-coercion.yml
    secrets: inherit
    # The fixture has 0 tests → coverage 0% → coverage gate will fail.
    # That's expected; what we care about is the gate ran a NUMERIC
    # comparison (threshold value coerced to 70 successfully).
    continue-on-error: true

  assert-vars-coercion-ran-numerically:
    needs: test-vars-coercion
    runs-on: ubuntu-latest
    steps:
      - name: Look up the coverage-gate run log
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          RUN_ID: ${{ github.run_id }}
        run: |
          set -euo pipefail
          # Find the test-go-coercion job's coverage-gate step log; assert
          # it contains the literal "threshold: 70%" (proves the var was
          # coerced to 70 by GHA, not to "70" or null or 80).
          gh run view "$RUN_ID" --log \
            | grep -F "threshold: 70%" \
            || { echo "::error::expected 'threshold: 70%' in coverage gate log — type coercion is broken"; exit 1; }
```

- [ ] **Step 3: Actionlint check**

```bash
actionlint \
  -ignore 'input "client-id" is not defined in action "actions/create-github-app-token@v3"' \
  -ignore 'missing input "app-id" which is required by action "actions/create-github-app-token@v3"' \
  .github/workflows/integration.yml tests/callers/test-vars-coercion.yml
```

Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/callers/test-vars-coercion.yml .github/workflows/integration.yml
git commit -m "test(integration): verify GHA coerces string-valued vars.* into type=number+boolean atom inputs"
```

---

## Phase 7: Default-sync bats test

Catch desync between template-emitted defaults and atom-declared defaults at PR time.

### Task 17: Write the bats test

**Files:**
- Create: `tests/shell/template-defaults.bats`

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bats
# template-defaults.bats — catch template-default ↔ atom-default desync.
#
# For each SK_* override pattern in ci.yml.tmpl / prerelease.yml.tmpl,
# extract the template default (the literal between `||` and `}}`) and
# compare against the atom's `default:` field. They must match exactly,
# otherwise an adopter who never sets the var would get a different
# value than what the atom would have defaulted to on its own.

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  CI_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/ci.yml.tmpl"
  PRE_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/prerelease.yml.tmpl"
}

# Args: <template-file> <SK_VAR_NAME>
# Echoes the literal string between `||` and `}}` for the first match.
template_default() {
  local file="$1" var="$2"
  # Match: vars.SK_FOO || '<DEFAULT>' }}
  # Use a portable POSIX-ish regex via grep -oE.
  grep -oE "vars\\.${var} \\|\\| '[^']*' \\}\\}" "$file" \
    | head -1 \
    | sed -E "s/.*\\|\\| '([^']*)' \\}\\}/\\1/"
}

# Args: <atom-yaml> <input-name>
# Echoes the `default:` value (string, with quotes stripped).
atom_default() {
  local file="$1" input="$2"
  # Find the input block, capture next `default:` line within 8 lines.
  awk -v input="$input" '
    $0 ~ "^      " input ":" { in_block = 1; lines = 0; next }
    in_block { lines++; if (lines > 8) { in_block = 0 } }
    in_block && /^        default:/ {
      sub(/^        default: ?/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$file"
}

@test "SK_COVERAGE_THRESHOLD template default matches test-go atom default" {
  t=$(template_default "$CI_TMPL" "SK_COVERAGE_THRESHOLD")
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-go.yml" "coverage_threshold")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_COVERAGE_THRESHOLD also matches test-python atom default" {
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-python.yml" "coverage_threshold")
  t=$(template_default "$CI_TMPL" "SK_COVERAGE_THRESHOLD")
  [ "$t" = "$a" ] || { echo "tmpl=$t python-atom=$a"; false; }
}

@test "SK_COVERAGE_THRESHOLD also matches test-rust atom default" {
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-rust.yml" "coverage_threshold")
  t=$(template_default "$CI_TMPL" "SK_COVERAGE_THRESHOLD")
  [ "$t" = "$a" ] || { echo "tmpl=$t rust-atom=$a"; false; }
}

@test "SK_GOLANGCI_LINT_VERSION matches lint-go atom default" {
  t=$(template_default "$CI_TMPL" "SK_GOLANGCI_LINT_VERSION")
  a=$(atom_default "$REPO_ROOT/.github/workflows/lint-go.yml" "golangci_lint_version")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_CARGO_LLVM_COV_VERSION matches test-rust atom default" {
  t=$(template_default "$CI_TMPL" "SK_CARGO_LLVM_COV_VERSION")
  a=$(atom_default "$REPO_ROOT/.github/workflows/test-rust.yml" "cargo_llvm_cov_version")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_TRIVY_SEVERITY in ci.yml matches trivy-fs atom default" {
  t=$(template_default "$CI_TMPL" "SK_TRIVY_SEVERITY")
  a=$(atom_default "$REPO_ROOT/.github/workflows/trivy-fs.yml" "severity")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_TRIVY_SEVERITY in prerelease.yml matches trivy-image atom default" {
  t=$(template_default "$PRE_TMPL" "SK_TRIVY_SEVERITY")
  a=$(atom_default "$REPO_ROOT/.github/workflows/trivy-image.yml" "severity")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "all empty-default knobs use ''" {
  for var in SK_GO_VERSION SK_PYTHON_VERSION SK_RUST_TOOLCHAIN SK_CLIPPY_ARGS SK_TRIVY_VERSION; do
    t=$(template_default "$CI_TMPL" "$var")
    [ "$t" = "" ] || { echo "$var in CI_TMPL has non-empty template default '$t'"; false; }
  done
  for var in SK_TRIVY_VERSION; do
    t=$(template_default "$PRE_TMPL" "$var")
    [ "$t" = "" ] || { echo "$var in PRE_TMPL has non-empty template default '$t'"; false; }
  done
}
```

### Task 18: Run the bats and commit

- [ ] **Step 1: Run the new test file**

```bash
bats tests/shell/template-defaults.bats
```

Expected: 8 tests ok, 0 not ok.

- [ ] **Step 2: Run full bats suite to confirm nothing else broke**

```bash
bats tests/shell/ | tail -3
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add tests/shell/template-defaults.bats
git commit -m "test(onboard): default-sync bats test guards template-vs-atom default drift"
```

---

## Phase 8: Documentation

### Task 19: New section in docs/operations.md

**Files:**
- Modify: `docs/operations.md`

- [ ] **Step 1: Append new section after the existing "Adopter atoms" table**

Find the existing `## Adopter atoms` section (around line 220). After its closing paragraph, add the new top-level section:

```markdown
## Per-Adopter Overrides via Repository Variables

The rendered `ci.yml` (and `prerelease.yml`) in every onboarded adopter pulls a small set of tunable inputs from **GitHub repository variables**. Adopters set them at `Settings → Secrets and variables → Actions → Variables tab → New repository variable`. The override is picked up at the next CI run — no code change, no PR, no re-onboarding.

> **Variables, not Secrets.** GitHub's Settings UI has two adjacent tabs. The override mechanism reads from the *Variables* tab. A value created in *Secrets* will not resolve via `vars.*` and the template default will silently apply.

| Variable | Atom Input | Atoms Affected | Default | Type |
|---|---|---|---|---|
| `SK_COVERAGE_THRESHOLD` | `coverage_threshold` | test-go, test-python, test-rust | `80` | number |
| `SK_CGO_ENABLED` | `cgo_enabled` | lint-go, test-go | profile auto-detect | boolean |
| `SK_GO_VERSION` | `go_version` | lint-go, test-go | (read from `go.mod`) | string |
| `SK_PYTHON_VERSION` | `python_version` | lint-python, test-python | (read from `pyproject.toml`) | string |
| `SK_RUST_TOOLCHAIN` | `rust_toolchain` | lint-rust, test-rust | (rustup default) | string |
| `SK_GOLANGCI_LINT_VERSION` | `golangci_lint_version` | lint-go | `v2.12.2` | string |
| `SK_CLIPPY_ARGS` | `clippy_args` | lint-rust | (atom-internal) | string |
| `SK_CARGO_LLVM_COV_VERSION` | `cargo_llvm_cov_version` | test-rust | `v0.6.16` | string |
| `SK_TRIVY_SEVERITY` | `severity` | trivy-fs (ci.yml secscan), trivy-image (prerelease scan) | `HIGH,CRITICAL` | string |
| `SK_TRIVY_VERSION` | `trivy_version` | trivy-fs, trivy-image | (install-trivy default) | string |

**Org-level layering** (catalog maintainers): set a variable at the organization level (`https://github.com/organizations/serverkraken/settings/variables/actions`) to provide an org-wide default. Repo-level values override org-level. A change to the org var propagates to every non-overriding adopter on the next CI run, no re-rendering required.

**`SK_CGO_ENABLED` override-wins semantic:** the onboard render uses an auto-detected boolean from the adopter's Go source / `go.mod` as the template default. Setting `SK_CGO_ENABLED = true` forces cgo on (auto-detect missed a transitive dep); setting `= false` forces it off (false-positive). Either value wins over the profile-derived default.

**What's not in this list and why:**

- `fail_on_findings`, `ignore_unfixed` — change CI semantics, belong in code review.
- `runs_on` — catalog-side global, not adopter-tunable.
- `working_directory`, `image_name`, `dockerfile`, `tag`, `prerelease` — per-component or build-derived.
- `paths_ignore` — multi-line strings, awkward in Variables UI.
```

- [ ] **Step 2: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): document SK_* per-adopter override variables"
```

### Task 20: Pointer in ci.yml.tmpl header

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl` (top comment block, lines 1-11)

- [ ] **Step 1: Append to the existing header comment**

Current header (~lines 1-11):

```
{{- /*
  ci.yml — PR-time CI workflow.

  Always emits a `secscan` job (trivy-fs). For each profile component,
  emits per-language lint + test jobs keyed off `primary_language`.
  Job-id pattern: <kind>-<lang>-<suffix>.
  Suffix rule:  path == "."  → "root"
                otherwise    → path with `/` → `-`
  The conditional avoids the naive `replaceAll "." "root"` which would
  mangle paths containing dots (e.g. `services/v2.api`).
*/ -}}
```

Replace with:

```
{{- /*
  ci.yml — PR-time CI workflow.

  Always emits a `secscan` job (trivy-fs). For each profile component,
  emits per-language lint + test jobs keyed off `primary_language`.
  Job-id pattern: <kind>-<lang>-<suffix>.
  Suffix rule:  path == "."  → "root"
                otherwise    → path with `/` → `-`
  The conditional avoids the naive `replaceAll "." "root"` which would
  mangle paths containing dots (e.g. `services/v2.api`).

  Tunable inputs accept org/repo `vars.SK_*` overrides — see
  docs/operations.md §Per-Adopter Overrides for the full list and how
  to set them. The `||` fallbacks below mirror each atom's `default:`.
*/ -}}
```

- [ ] **Step 2: Run bats to confirm template still renders identically (comments don't affect output)**

```bash
bats tests/shell/onboard-render.bats | tail -3
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add docs/adopter-templates/skeletons/ci.yml.tmpl
git commit -m "docs(onboard): pointer in ci.yml.tmpl header to vars-override docs"
```

---

## Phase 9: PR, release, and adopter migration

### Task 21: Open the PR

- [ ] **Step 1: Push the branch**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/per-repo-vars
git push -u origin feat/per-repo-override-vars
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --base main --head feat/per-repo-override-vars \
  --title "feat(onboard): per-adopter override variables (SK_*)" \
  --body "$(cat <<'EOF'
## Summary

Routes ten tunable atom inputs (coverage_threshold, cgo_enabled, go/python/rust toolchain versions, golangci-lint version, cargo-llvm-cov version, clippy args, Trivy severity + version) through `${{ vars.SK_* || '<default>' }}` expressions in `ci.yml.tmpl` and `prerelease.yml.tmpl`. Adopters override via Settings UI, no code change.

## Spec

`docs/superpowers/specs/2026-05-21-per-repo-override-vars-design.md` — approved through brainstorming.

## Why

`skytrack` failing at `coverage 66% < threshold 80%` was the immediate prompt. Without this, adopters with non-default needs either hand-edit rendered ci.yml (which drift-check flags forever) or wait for an org-wide catalog default bump. With this, they tune in Settings UI.

## Plan

`docs/superpowers/plans/2026-05-21-per-repo-override-vars.md`

## Test plan

- [x] `bats tests/shell/` — all green incl. new inline render assertions + default-sync test.
- [x] `actionlint` clean.
- [ ] CI green incl. the new `test-vars-coercion` integration smoke caller.
- [ ] After merge: catalog auto-bumps to v3.9.0; `v3` floating tag moves.
- [ ] One-time re-render of blupod-ui, flow, skytrack — see plan Phase 9.
- [ ] skytrack sets `SK_COVERAGE_THRESHOLD = "60"` to unblock its PR #13.
EOF
)"
```

### Task 22: Wait for CI + merge

- [ ] **Step 1: Poll PR checks**

```bash
gh pr checks <PR-NUMBER> --repo serverkraken/reusable-workflows --watch
```

Expected: all green incl. `test-vars-coercion / *` and `assert-vars-coercion-ran-numerically`.

If `assert-vars-coercion-ran-numerically` fails: the type-coercion assumption from the spec is broken. STOP and revisit — see spec § Open Questions §1 for the fallback plan (change atom inputs to `type: string` + internal parsing, major version bump). Do not proceed with merge.

- [ ] **Step 2: Merge**

```bash
gh pr merge <PR-NUMBER> --repo serverkraken/reusable-workflows --squash
```

- [ ] **Step 3: Wait for release-please PR + merge it**

```bash
# Wait for release PR
until gh pr list --repo serverkraken/reusable-workflows --base main \
  --head release-please--branches--main --state open --json number 2>/dev/null \
  | jq -e 'length > 0' > /dev/null; do sleep 30; done
# Get its number, wait for checks, merge
release_pr=$(gh pr list --repo serverkraken/reusable-workflows --base main \
  --head release-please--branches--main --state open --json number --jq '.[0].number')
gh pr checks "$release_pr" --repo serverkraken/reusable-workflows --watch
gh pr merge "$release_pr" --repo serverkraken/reusable-workflows --squash
```

- [ ] **Step 4: Wait for v3 floating tag move**

```bash
# v3 must point to v3.9.0's commit
until [[ "$(git ls-remote --tags origin v3 | awk '{print $1}')" \
       == "$(git ls-remote --tags origin v3.9.0 | awk '{print $1}')" ]]; do
  sleep 20
done
echo "v3 → v3.9.0 confirmed"
```

### Task 23: Re-render the three live adopters

- [ ] **Step 1: Trigger onboard for all three at once**

```bash
gh workflow run onboard.yml --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/blupod-ui,serverkraken/flow,serverkraken/skytrack \
  -f pin_version=v3 \
  -f dry_run=false
```

- [ ] **Step 2: Wait for the run, confirm all three target jobs succeeded**

```bash
run_id=$(gh run list --repo serverkraken/reusable-workflows \
  --workflow onboard.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run_id" --repo serverkraken/reusable-workflows
gh run view "$run_id" --repo serverkraken/reusable-workflows \
  --json jobs --jq '.jobs[] | select(.name | startswith("onboard")) | "\(.name): \(.conclusion)"'
```

Expected: all three `success`.

### Task 24: Set skytrack's coverage override

- [ ] **Step 1: Set the variable**

```bash
gh variable set SK_COVERAGE_THRESHOLD --repo serverkraken/skytrack --body "60"
```

- [ ] **Step 2: Verify**

```bash
gh variable list --repo serverkraken/skytrack
```

Expected: `SK_COVERAGE_THRESHOLD = 60` listed.

- [ ] **Step 3: Re-trigger skytrack PR #13 CI (empty commit)**

```bash
cd /tmp && rm -rf skytrack-clone 2>/dev/null
gh repo clone serverkraken/skytrack skytrack-clone -- --branch chore/onboard-reusable-workflows --depth 1
cd skytrack-clone
git commit --allow-empty -m "ci: re-trigger after SK_COVERAGE_THRESHOLD override"
git push origin chore/onboard-reusable-workflows
cd - && rm -rf /tmp/skytrack-clone
```

- [ ] **Step 4: Watch skytrack PR #13**

```bash
gh pr checks 13 --repo serverkraken/skytrack --watch
```

Expected: `test-go-root / test` passes (66% ≥ 60% new threshold). `secscan / scan` may still fail if the App permission accept for `administration:write` is still pending (unrelated to this PR).

### Task 25: Trigger drift-check baseline

- [ ] **Step 1: Run drift-check workflow**

```bash
gh workflow run drift-check.yml --repo serverkraken/reusable-workflows
```

- [ ] **Step 2: Wait for it, then read the rolling issue**

```bash
run_id=$(gh run list --repo serverkraken/reusable-workflows \
  --workflow drift-check.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run_id" --repo serverkraken/reusable-workflows
gh issue view 66 --repo serverkraken/reusable-workflows --json body --jq .body
```

Expected: blupod-ui, flow, skytrack all report `clean` against `v3`. (skytrack's `SK_COVERAGE_THRESHOLD=60` does NOT cause drift — drift compares file SHAs, not runtime variable values.)

---

## Self-Review Notes

- **Spec coverage:** Every knob in the spec's Knob Registry table maps to a phase + task. The override-wins CGO semantic gets its own bats assertion (Task 3 Step 1, second test). Drift-check interaction tested via existing `tests/shell/onboard-drift.bats` (reproducibility test catches any non-determinism). Migration steps (re-render + skytrack var set) covered in Phase 9.
- **Placeholder scan:** No TBD / TODO / "similar to" / "etc." — all template snippets and commands written out.
- **Type consistency:** Variable names match between spec and plan (`SK_*` everywhere). Atom-input names match. Template literal default values verified against the atom YAML files in the exploration step. The default-sync bats (Task 17) re-verifies at PR time.
- **Test-first discipline:** Phase 1 leads with template change then inline assertion + golden regen, which is the established pattern in this codebase (`UPDATE_GOLDEN=1` flow). Phases 2-5 follow the same pattern. Phase 6 (smoke caller) is pure new test. Phase 7 (default-sync) is pure new test.
