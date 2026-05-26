# `$GITHUB_STEP_SUMMARY` Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Schreibe in jeden consumer-facing oder org-internen Atom (18 von 22) einen konformen `$GITHUB_STEP_SUMMARY`-Block; codifiziere das Schema in einer Konvention-Doc; ziehe einen CI-Gate in `validate.yml`, der zukünftige Atoms ohne Summary blockt.

**Architecture:** Inline-Summary pro Atom (Approach A aus dem Spec). Geteilte Konvention via Markdown-Doc + Shell-Check-Skript. Kein Composite-Action, kein shared shell-lib — die Lint-Atoms haben heterogenes Catalog-Checkout-Verhalten, was den Indirektions-Layer teuer macht. Drift-Risiko wird durch CI-Gate gefangen, nicht durch Code-Sharing.

**Tech Stack:** GitHub Actions YAML, Bash, Bats (Bash Automated Testing System), actionlint (existing), yamllint (existing).

**Spec:** `docs/superpowers/specs/2026-05-26-step-summary-sweep-design.md` — authoritative reference. Wenn dieser Plan und das Spec voneinander abweichen, gewinnt das Spec.

---

## File Structure

**New files (3):**

| Path | Responsibility |
|---|---|
| `docs/conventions/step-summary.md` | Kanonische Konvention: Schema, Glyphen, Per-Klasse-Body, kopierbare Beispiele |
| `tests/conventions/check-step-summary.sh` | CI-Gate-Skript: iteriert Atoms, prüft H2-Heading + STEP_SUMMARY-Presence |
| `tests/shell/check-step-summary.bats` | Bats-Tests für das Gate-Skript (3 Cases: happy / missing-summary / wrong-heading) |

**Modified files (20):**

| Path | Concern |
|---|---|
| `CONTRIBUTING.md` | Neue Section "Atom-Konventionen" mit Link zur step-summary-Konvention |
| `.github/workflows/validate.yml` | Neuer Step, der `check-step-summary.sh` läuft |
| `.github/workflows/lint-go.yml` | Add summary + header-comment |
| `.github/workflows/lint-python.yml` | Add summary + header-comment |
| `.github/workflows/lint-rust.yml` | Add summary + header-comment |
| `.github/workflows/lint-helm.yml` | Add summary + header-comment |
| `.github/workflows/test-go.yml` | Add summary + header-comment |
| `.github/workflows/test-python.yml` | Add summary + header-comment |
| `.github/workflows/test-rust.yml` | Add summary + header-comment |
| `.github/workflows/trivy-fs.yml` | Normalize existing summary + header-comment |
| `.github/workflows/trivy-image.yml` | Normalize existing summary + header-comment |
| `.github/workflows/docker-build.yml` | Normalize existing summary + header-comment |
| `.github/workflows/docker-build-multi.yml` | Add summary + header-comment |
| `.github/workflows/helm-publish.yml` | Normalize existing summary + header-comment |
| `.github/workflows/semantic-release.yml` | Normalize existing summary + header-comment |
| `.github/workflows/goreleaser.yml` | Normalize existing summary + header-comment |
| `.github/workflows/cleanup-images.yml` | Normalize existing summary + header-comment |
| `.github/workflows/onboard.yml` | Prepend atom-level header + header-comment |
| `.github/workflows/onboard-sweep.yml` | Add summary + header-comment |
| `.github/workflows/drift-check.yml` | Add summary + header-comment |

**Commit map** (10 atomic commits in this order):

1. `docs(conventions): add step-summary convention` → Task 1
2. `test(conventions): add step-summary check script + bats` → Task 2
3. `feat(lint): step-summary writes for lint-{go,python,rust,helm}` → Task 3
4. `feat(test): step-summary writes for test-{go,python,rust}` → Task 4
5. `feat(trivy): normalize trivy-* summaries; step-summary for docker-build-multi` → Task 5
6. `feat(docker): normalize step-summary in docker-build` → Task 6
7. `feat(release): normalize step-summary in helm-publish, semantic-release, goreleaser, cleanup-images` → Task 7
8. `feat(onboard): step-summary writes for onboard-sweep, drift-check; normalize onboard` → Task 8
9. `feat(workflows): add convention file-header comments to in-scope atoms` → Task 9
10. `feat(validate): enforce step-summary convention in CI` → Task 10

**Reihenfolge ist wichtig:** Konvention zuerst (Task 1), CI-Gate-Wiring zuletzt (Task 10). Wenn Task 10 vor den Atom-Sweeps käme, würde jeder Zwischenstand-Commit die CI brechen.

---

## Worktree-Hinweis

Diese Arbeit soll in einem isolierten Worktree laufen: `.worktrees/step-summary` auf Branch `feat/step-summary-sweep`. Erstellung via `superpowers:using-git-worktrees` zur Execution-Zeit, nicht in diesem Plan.

---

## Task 1: Convention-Doc + CONTRIBUTING-Verweis

**Files:**
- Create: `docs/conventions/step-summary.md`
- Modify: `CONTRIBUTING.md` (append new section)

- [ ] **Step 1.1: Create `docs/conventions/step-summary.md`**

Inhalt (komplett):

````markdown
# Step-Summary Convention

Every reusable workflow ("atom") in `.github/workflows/` writes a single, conformant Markdown block to `$GITHUB_STEP_SUMMARY` per run. This file is the authoritative spec for the schema. The CI gate in `tests/conventions/check-step-summary.sh` enforces presence; visual review enforces shape.

## Schema

```markdown
## <atom-name>

**Tool:** <toolname> <version>
**Result:** <glyph> <one-line status>

<atom-specific body — table or key-value list>
```

- **`<atom-name>`** is the workflow filename without `.yml` (e.g., `lint-go`, `docker-build-multi`). The CI gate matches `^## <atom-name>$` (with surrounding whitespace tolerated).
- **`**Tool:**`** lists the primary tool and version. For multi-tool atoms (e.g., `lint-go` runs `go vet` and `golangci-lint`), use `**Tools:**` with comma separation.
- **`**Result:**`** uses exactly one glyph from the set below.
- **Body** content varies by atom class — see "Per-Class Body" below.

### Result Glyphs

| Glyph | Meaning |
|---|---|
| `✓` | Success (all checks pass, build succeeded, etc.) |
| `✗` | Failure (at least one check failed, build broke, etc.) |
| `▲` | Warning / Partial (e.g., Trivy findings present with `fail_on_findings=false`; coverage below threshold with enforcement off) |

No emoji. Only the glyphs above. Rationale: see `MEMORY/feedback_no_emoji_use_glyphs.md`.

## Per-Class Body

| Class | Required body |
|---|---|
| `lint-*` | Working dir; table `\| Check \| Status \|` with one row per tool |
| `test-*` | Working dir; test counts (run/pass/fail); coverage % + threshold; duration |
| `trivy-*` | Target (image ref or path); severity filter; findings count table by severity |
| `docker-build`, `docker-build-multi` | Tags; digest; platforms; sign/attest/SBOM status |
| `helm-publish` | Chart name; version; OCI ref; digest |
| `semantic-release` | Old → new version; bump type; release URL (or "no release" if idle) |
| `goreleaser` | Tag; artifact count; release URL |
| `cleanup-images` | Table `\| Rule \| Kept \| Deleted \|` |
| `onboard`, `onboard-sweep`, `drift-check` | Current body stays as-is; only the `## <atom>` header is prepended |

## Style Rules

- Inline code (backticks) for image refs, paths, version strings.
- Tables: pad pipes with spaces (`| key | value |`).
- No emoji. Only the glyphs from the Result-Glyphs table.
- No external links except to GHCR / GitHub-owned URLs (release pages, compare views).
- Append, never overwrite: always use `>>`, never `>`.
- Wrap every summary write in `|| true` so a write failure (e.g., 1 MB cap exceeded) never breaks the job.

## Step Conditions

| Class | Step condition | Why |
|---|---|---|
| `lint-*` | `if: always()` | Issue count must be visible even when a tool exits non-zero |
| `test-*` | `if: always()` | Coverage must be reported even when tests fail |
| `trivy-*` | `if: always()` | Findings must be visible before the gate-fail step aborts |
| `docker-build*` | normal (no `always()`) | Digest only exists after successful push |
| `helm-publish`, `semantic-release`, `goreleaser`, `cleanup-images` | normal | Values only exist after success |
| `onboard*`, `drift-check` | existing conditions stay | Bestehender Step-Flow bleibt |

## Examples

### `lint-go` (success)

```markdown
## lint-go

**Tools:** go vet, golangci-lint v2.12.2
**Working dir:** `./services/api`
**Result:** ✓ passed

| Check | Status |
|---|---|
| go vet | ✓ |
| golangci-lint | ✓ |
```

### `test-python` (failure, coverage under threshold)

```markdown
## test-python

**Tool:** pytest 8.3.2
**Working dir:** `.`
**Result:** ✗ coverage 84% < threshold 90%

| Metric | Value |
|---|---|
| Coverage | 84% |
| Threshold | 90% |
```

### `trivy-image` (findings, fail_on_findings=false)

```markdown
## trivy-image

**Tool:** Trivy 0.58.1
**Image:** `ghcr.io/serverkraken/foo:v1.2.3`
**Severities:** HIGH, CRITICAL
**Result:** ▲ 3 findings (gate disabled)

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| HIGH | 2 |
```

### `docker-build-multi` (happy)

```markdown
## docker-build-multi

**Tool:** Buildx, distributed multi-arch
**Result:** ✓ pushed

| Field | Value |
|---|---|
| Tags | `v1.2.3`, `latest` |
| Digest | `sha256:abc...` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Sign | ✓ cosign keyless |
| Attest | ✓ SLSA provenance |
| SBOM | ✓ SPDX-JSON |
```

## Adding a New Atom

When you add a workflow to `.github/workflows/` that is not in the Self-CI exemption list (`validate.yml`, `integration.yml`, `release.yml`, `catalog-release.yml`), you MUST:

1. Add a summary step matching this schema.
2. Add the file-header line at the top of your atom: `# Summary convention: docs/conventions/step-summary.md`
3. Run `bash tests/conventions/check-step-summary.sh` locally — exit 0 required.

If the gate rejects a legitimate writing pattern, extend the regex in the script and add a Bats case in `tests/shell/check-step-summary.bats`.
````

- [ ] **Step 1.2: Append section to `CONTRIBUTING.md`**

Open `CONTRIBUTING.md`. Append (at the end of the file):

```markdown

## Atom-Konventionen

Reusable workflows ("Atoms") follow shared conventions enforced by `.github/workflows/validate.yml`. When adding or modifying an atom, consult:

- [`docs/conventions/step-summary.md`](docs/conventions/step-summary.md) — required Markdown block written to `$GITHUB_STEP_SUMMARY`.

New conventions land in `docs/conventions/`. Each must be linked from this section and (where automatable) gated in `validate.yml`.
```

- [ ] **Step 1.3: Verify both files render**

Run:

```bash
ls -la docs/conventions/step-summary.md CONTRIBUTING.md
head -5 docs/conventions/step-summary.md
tail -8 CONTRIBUTING.md
```

Expected: file exists, head shows `# Step-Summary Convention`, tail of CONTRIBUTING shows the new section.

- [ ] **Step 1.4: Commit**

```bash
git add docs/conventions/step-summary.md CONTRIBUTING.md
git commit -m "docs(conventions): add step-summary convention"
```

---

## Task 2: Convention-Check-Skript + Bats-Tests (TDD)

**Files:**
- Create: `tests/conventions/check-step-summary.sh`
- Create: `tests/shell/check-step-summary.bats`

- [ ] **Step 2.1: Create test fixture directory**

```bash
mkdir -p tests/shell/fixtures/step-summary
```

- [ ] **Step 2.2: Write failing bats test (happy path)**

Create `tests/shell/check-step-summary.bats`:

```bash
#!/usr/bin/env bats
# Tests for tests/conventions/check-step-summary.sh
# Verifies the CI-gate that enforces docs/conventions/step-summary.md.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-step-summary.sh"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows"
  cd "$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "passes when atom has H2-heading + STEP_SUMMARY write" {
  cat > .github/workflows/lint-go.yml <<'EOF'
name: lint-go
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Summary
        run: |
          {
            echo "## lint-go"
            echo "**Result:** ✓ passed"
          } >> "$GITHUB_STEP_SUMMARY"
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "fails when atom has no STEP_SUMMARY write" {
  cat > .github/workflows/lint-go.yml <<'EOF'
name: lint-go
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo "nothing"
EOF
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "writes no \$GITHUB_STEP_SUMMARY" ]]
}

@test "fails when atom writes summary but no '## <atom>' heading" {
  cat > .github/workflows/lint-go.yml <<'EOF'
name: lint-go
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Summary
        run: |
          {
            echo "## something-else"
            echo "**Result:** ✓ passed"
          } >> "$GITHUB_STEP_SUMMARY"
EOF
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no '## lint-go' heading found" ]]
}

@test "skips Self-CI atoms (validate.yml)" {
  cat > .github/workflows/validate.yml <<'EOF'
name: validate
on: [push]
jobs:
  v:
    runs-on: ubuntu-latest
    steps:
      - run: echo "no summary needed for self-CI"
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2.3: Run bats to verify all four tests fail (script doesn't exist yet)**

Run:

```bash
bats tests/shell/check-step-summary.bats
```

Expected: 4 failures, each citing "No such file or directory" or similar for `tests/conventions/check-step-summary.sh`.

- [ ] **Step 2.4: Create the check script**

Create `tests/conventions/check-step-summary.sh`:

```bash
#!/usr/bin/env bash
# tests/conventions/check-step-summary.sh
#
# CI gate enforcing docs/conventions/step-summary.md.
#
# For every workflow in .github/workflows/ (except the Self-CI allowlist),
# assert:
#   1. The file writes to $GITHUB_STEP_SUMMARY at least once.
#   2. The file contains an H2 heading matching its own basename
#      (e.g., lint-go.yml must contain a line writing "## lint-go").
#
# Bats fixtures invoke this from a temp dir; CI invokes from repo root.
# Both cases work because we glob `.github/workflows/*.yml` relative to CWD.

set -euo pipefail

SELF_CI_ALLOWLIST=(
  "validate.yml"
  "integration.yml"
  "release.yml"
  "catalog-release.yml"
)

CONVENTION_DOC="docs/conventions/step-summary.md"
FAILED=0
CHECKED=0

shopt -s nullglob
for file in .github/workflows/*.yml; do
  basename=$(basename "$file")
  atom_name="${basename%.yml}"

  # Skip Self-CI atoms.
  skip=0
  for entry in "${SELF_CI_ALLOWLIST[@]}"; do
    if [[ "$basename" == "$entry" ]]; then
      skip=1
      break
    fi
  done
  if [[ $skip -eq 1 ]]; then
    continue
  fi

  CHECKED=$((CHECKED + 1))

  # Check 1: GITHUB_STEP_SUMMARY write present.
  if ! grep -q 'GITHUB_STEP_SUMMARY' "$file"; then
    echo "FAIL: $basename writes no \$GITHUB_STEP_SUMMARY."
    echo "      Required by $CONVENTION_DOC."
    FAILED=1
    continue
  fi

  # Check 2: H2 heading matches atom name.
  # Two accepted patterns:
  #   (a) echo "## <atom>"      (single-line echo, most common)
  #   (b) a bare line of "## <atom>"  (heredocs or block-quoted)
  pattern_echo="echo[[:space:]]+[\"']## ${atom_name}[\"' ]"
  pattern_bare="^[[:space:]]*## ${atom_name}([[:space:]]|$)"
  if ! grep -qE "$pattern_echo" "$file" && ! grep -qE "$pattern_bare" "$file"; then
    echo "FAIL: $basename writes summary but no '## ${atom_name}' heading found."
    echo "      Heading must match atom filename per $CONVENTION_DOC."
    FAILED=1
  fi
done

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "Convention violations found. See $CONVENTION_DOC."
  exit 1
fi

echo "OK: $CHECKED atoms checked, all conformant."
```

Make it executable:

```bash
chmod +x tests/conventions/check-step-summary.sh
```

- [ ] **Step 2.5: Run bats again to verify all four tests pass**

Run:

```bash
bats tests/shell/check-step-summary.bats
```

Expected: 4 passes. If any fail, fix the script or test until all pass.

- [ ] **Step 2.6: Run script against the real repo from repo root**

Run:

```bash
bash tests/conventions/check-step-summary.sh || echo "expected failures at this point"
```

Expected: many `FAIL` lines (one per atom not yet conformant) followed by `Convention violations found.` Exit code 1. This is correct — the sweep tasks below will progressively eliminate these failures. The CI-gate wiring (Task 10) is the LAST commit.

- [ ] **Step 2.7: Commit**

```bash
git add tests/conventions/check-step-summary.sh tests/shell/check-step-summary.bats
git commit -m "test(conventions): add step-summary check script + bats"
```

---

## Task 3: Step-Summary in lint-{go,python,rust,helm}

**Files:**
- Modify: `.github/workflows/lint-go.yml`
- Modify: `.github/workflows/lint-python.yml`
- Modify: `.github/workflows/lint-rust.yml`
- Modify: `.github/workflows/lint-helm.yml`

**Approach for all four:** Add `id:` to each tool step, then append a single Summary step at the end of the job with `if: always()` that renders the conformant Markdown using `steps.<id>.outcome`.

Glyph mapping helper (use literally in every summary step):

```bash
glyph() {
  case "$1" in
    success) echo "✓" ;;
    failure) echo "✗" ;;
    skipped) echo "−" ;;
    *)       echo "?" ;;
  esac
}
```

- [ ] **Step 3.1: Modify `.github/workflows/lint-go.yml`**

Open the file. Two existing tool steps need `id:` added:

- `- name: go vet` → add `id: vet`
- `- name: golangci-lint` → add `id: lint`

Then append a new step at the very end of `jobs.lint.steps`:

```yaml
      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          GOLANGCI_VERSION: ${{ inputs.golangci_lint_version }}
          VET_OUTCOME: ${{ steps.vet.outcome }}
          LINT_OUTCOME: ${{ steps.lint.outcome }}
        run: |
          glyph() {
            case "$1" in
              success) echo "✓" ;;
              failure) echo "✗" ;;
              skipped) echo "−" ;;
              *)       echo "?" ;;
            esac
          }
          if [[ "$VET_OUTCOME" == "success" && "$LINT_OUTCOME" == "success" ]]; then
            result="✓ passed"
          else
            result="✗ failed"
          fi
          {
            echo "## lint-go"
            echo ""
            echo "**Tools:** go vet, golangci-lint ${GOLANGCI_VERSION}"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Check | Status |"
            echo "|---|---|"
            echo "| go vet | $(glyph "$VET_OUTCOME") |"
            echo "| golangci-lint | $(glyph "$LINT_OUTCOME") |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 3.2: Modify `.github/workflows/lint-python.yml`**

Three tool steps need `id:`:

- `- name: ruff check` → add `id: ruff_check`
- `- name: ruff format --check` → add `id: ruff_format`
- `- name: mypy` → add `id: mypy`

Append:

```yaml
      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          RUFF_CHECK_OUTCOME: ${{ steps.ruff_check.outcome }}
          RUFF_FORMAT_OUTCOME: ${{ steps.ruff_format.outcome }}
          MYPY_OUTCOME: ${{ steps.mypy.outcome }}
        run: |
          glyph() {
            case "$1" in
              success) echo "✓" ;;
              failure) echo "✗" ;;
              skipped) echo "−" ;;
              *)       echo "?" ;;
            esac
          }
          if [[ "$RUFF_CHECK_OUTCOME" == "success" && "$RUFF_FORMAT_OUTCOME" == "success" && "$MYPY_OUTCOME" == "success" ]]; then
            result="✓ passed"
          else
            result="✗ failed"
          fi
          {
            echo "## lint-python"
            echo ""
            echo "**Tools:** ruff (check + format), mypy"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Check | Status |"
            echo "|---|---|"
            echo "| ruff check | $(glyph "$RUFF_CHECK_OUTCOME") |"
            echo "| ruff format --check | $(glyph "$RUFF_FORMAT_OUTCOME") |"
            echo "| mypy | $(glyph "$MYPY_OUTCOME") |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 3.3: Modify `.github/workflows/lint-rust.yml`**

Open the file. Identify existing tool steps (likely `cargo fmt --check` and `cargo clippy`). Add `id: fmt` and `id: clippy` (or matching names). Append:

```yaml
      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          FMT_OUTCOME: ${{ steps.fmt.outcome }}
          CLIPPY_OUTCOME: ${{ steps.clippy.outcome }}
        run: |
          glyph() {
            case "$1" in
              success) echo "✓" ;;
              failure) echo "✗" ;;
              skipped) echo "−" ;;
              *)       echo "?" ;;
            esac
          }
          if [[ "$FMT_OUTCOME" == "success" && "$CLIPPY_OUTCOME" == "success" ]]; then
            result="✓ passed"
          else
            result="✗ failed"
          fi
          {
            echo "## lint-rust"
            echo ""
            echo "**Tools:** cargo fmt, cargo clippy"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Check | Status |"
            echo "|---|---|"
            echo "| cargo fmt --check | $(glyph "$FMT_OUTCOME") |"
            echo "| cargo clippy | $(glyph "$CLIPPY_OUTCOME") |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

If lint-rust uses different step names than `fmt`/`clippy`, adjust the `id:` and the env-var names to match.

- [ ] **Step 3.4: Modify `.github/workflows/lint-helm.yml`**

Open the file. Likely tools: `helm lint` and `ct lint` (chart-testing). Add `id:` to each. Append:

```yaml
      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          HELM_LINT_OUTCOME: ${{ steps.helm_lint.outcome }}
          CT_LINT_OUTCOME: ${{ steps.ct_lint.outcome }}
        run: |
          glyph() {
            case "$1" in
              success) echo "✓" ;;
              failure) echo "✗" ;;
              skipped) echo "−" ;;
              *)       echo "?" ;;
            esac
          }
          if [[ "$HELM_LINT_OUTCOME" == "success" && "$CT_LINT_OUTCOME" == "success" ]]; then
            result="✓ passed"
          else
            result="✗ failed"
          fi
          {
            echo "## lint-helm"
            echo ""
            echo "**Tools:** helm lint, chart-testing"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Check | Status |"
            echo "|---|---|"
            echo "| helm lint | $(glyph "$HELM_LINT_OUTCOME") |"
            echo "| ct lint | $(glyph "$CT_LINT_OUTCOME") |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Adjust step IDs if the actual file uses different names.

- [ ] **Step 3.5: Verify the gate script accepts the 4 modified files**

Run:

```bash
bash tests/conventions/check-step-summary.sh 2>&1 | grep -E '^(FAIL: lint-|OK)' || true
```

Expected: **no** `FAIL: lint-go.yml`, `FAIL: lint-python.yml`, `FAIL: lint-rust.yml`, `FAIL: lint-helm.yml` lines. (Other atoms still fail — that's expected, they're not yet touched.)

- [ ] **Step 3.6: actionlint sanity**

Run:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -ignore 'property "vet" is not defined' -ignore 'property "lint" is not defined' .github/workflows/lint-go.yml .github/workflows/lint-python.yml .github/workflows/lint-rust.yml .github/workflows/lint-helm.yml
```

Expected: no output (clean). actionlint may not recognise step outputs as defined — `-ignore` flags above suppress false-positives for the new IDs. If real errors appear, fix the YAML and re-run.

- [ ] **Step 3.7: Commit**

```bash
git add .github/workflows/lint-go.yml .github/workflows/lint-python.yml .github/workflows/lint-rust.yml .github/workflows/lint-helm.yml
git commit -m "feat(lint): step-summary writes for lint-{go,python,rust,helm}"
```

---

## Task 4: Step-Summary in test-{go,python,rust}

**Files:**
- Modify: `.github/workflows/test-go.yml`
- Modify: `.github/workflows/test-python.yml`
- Modify: `.github/workflows/test-rust.yml`

**Approach:** Capture coverage percentage in step outputs, render in summary with `if: always()`.

- [ ] **Step 4.1: Modify `.github/workflows/test-go.yml`**

Two changes to the existing `Coverage gate` step:

1. Add `id: coverage` to the step.
2. After the `pct=$(...)` line, emit the pct as a step output. Replace the existing `Coverage gate` step body with:

```yaml
      - name: Coverage gate
        id: coverage
        working-directory: ${{ inputs.working_directory }}
        env:
          THRESHOLD: ${{ inputs.coverage_threshold }}
        run: |
          set -euo pipefail
          pct=$(go tool cover -func=cover.out | awk '/^total:/ {sub("%","",$3); print $3}')
          echo "coverage_pct=${pct}" >> "$GITHUB_OUTPUT"
          echo "threshold=${THRESHOLD}" >> "$GITHUB_OUTPUT"
          echo "coverage: ${pct}% (threshold: ${THRESHOLD}%)"
          awk -v pct="$pct" -v thr="$THRESHOLD" 'BEGIN { exit (pct + 0 < thr + 0) ? 1 : 0 }' || {
            echo "::error::coverage ${pct}% < threshold ${THRESHOLD}%"
            exit 1
          }
```

Then add `id: test` to the `go test with coverage` step.

Append the Summary step:

```yaml
      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          TEST_OUTCOME: ${{ steps.test.outcome }}
          COVERAGE_OUTCOME: ${{ steps.coverage.outcome }}
          PCT: ${{ steps.coverage.outputs.coverage_pct }}
          THRESHOLD: ${{ steps.coverage.outputs.threshold }}
        run: |
          if [[ "$TEST_OUTCOME" != "success" ]]; then
            result="✗ tests failed"
          elif [[ "$COVERAGE_OUTCOME" != "success" ]]; then
            result="✗ coverage ${PCT}% < threshold ${THRESHOLD}%"
          else
            result="✓ coverage ${PCT}% ≥ threshold ${THRESHOLD}%"
          fi
          {
            echo "## test-go"
            echo ""
            echo "**Tool:** go test"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Metric | Value |"
            echo "|---|---|"
            echo "| Coverage | ${PCT:-N/A}% |"
            echo "| Threshold | ${THRESHOLD}% |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 4.2: Modify `.github/workflows/test-python.yml`**

Change the `pytest --cov-fail-under` step to also emit term-coverage and capture it.

Replace the existing `pytest --cov-fail-under` step with:

```yaml
      - name: pytest --cov-fail-under
        id: pytest
        working-directory: ${{ inputs.working_directory }}
        env:
          THRESHOLD: ${{ inputs.coverage_threshold }}
        run: |
          set -o pipefail
          ${{ steps.setup.outputs.run_prefix }} pytest --ignore=.catalog --cov --cov-report=term --cov-fail-under="$THRESHOLD" | tee pytest.out
          pct=$(awk '/^TOTAL/ {gsub("%","",$NF); print $NF}' pytest.out)
          echo "coverage_pct=${pct:-N/A}" >> "$GITHUB_OUTPUT"
          echo "threshold=${THRESHOLD}" >> "$GITHUB_OUTPUT"
```

Append the Summary step:

```yaml
      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          PYTEST_OUTCOME: ${{ steps.pytest.outcome }}
          PCT: ${{ steps.pytest.outputs.coverage_pct }}
          THRESHOLD: ${{ steps.pytest.outputs.threshold }}
        run: |
          if [[ "$PYTEST_OUTCOME" == "success" ]]; then
            result="✓ coverage ${PCT}% ≥ threshold ${THRESHOLD}%"
          elif [[ -n "$PCT" && "$PCT" != "N/A" ]]; then
            result="✗ coverage ${PCT}% < threshold ${THRESHOLD}% (or tests failed)"
          else
            result="✗ tests failed"
          fi
          {
            echo "## test-python"
            echo ""
            echo "**Tool:** pytest"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Metric | Value |"
            echo "|---|---|"
            echo "| Coverage | ${PCT:-N/A}% |"
            echo "| Threshold | ${THRESHOLD}% |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 4.3: Modify `.github/workflows/test-rust.yml`**

Open file. The existing coverage tool is likely `cargo-llvm-cov`. Add `id: test` and `id: coverage` (matching real step names). Capture pct from `cargo llvm-cov`'s `--summary-only` JSON or text output and emit as step output. Then append a Summary step analogous to test-go's:

```yaml
      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          TEST_OUTCOME: ${{ steps.test.outcome }}
          COVERAGE_OUTCOME: ${{ steps.coverage.outcome }}
          PCT: ${{ steps.coverage.outputs.coverage_pct }}
          THRESHOLD: ${{ steps.coverage.outputs.threshold }}
        run: |
          if [[ "$TEST_OUTCOME" != "success" ]]; then
            result="✗ tests failed"
          elif [[ "$COVERAGE_OUTCOME" != "success" ]]; then
            result="✗ coverage ${PCT}% < threshold ${THRESHOLD}%"
          else
            result="✓ coverage ${PCT}% ≥ threshold ${THRESHOLD}%"
          fi
          {
            echo "## test-rust"
            echo ""
            echo "**Tool:** cargo test, cargo-llvm-cov"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Metric | Value |"
            echo "|---|---|"
            echo "| Coverage | ${PCT:-N/A}% |"
            echo "| Threshold | ${THRESHOLD}% |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Adjust the coverage-extraction logic to match the actual `cargo-llvm-cov` invocation in the file.

- [ ] **Step 4.4: Run gate against modified atoms**

```bash
bash tests/conventions/check-step-summary.sh 2>&1 | grep -E '^FAIL: test-' || echo "no test-* failures — good"
```

Expected: no `FAIL: test-*` lines.

- [ ] **Step 4.5: actionlint sanity**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest .github/workflows/test-go.yml .github/workflows/test-python.yml .github/workflows/test-rust.yml
```

Expected: no output. If new step IDs trigger property-not-defined warnings, add `-ignore` flags matching the new IDs.

- [ ] **Step 4.6: Commit**

```bash
git add .github/workflows/test-go.yml .github/workflows/test-python.yml .github/workflows/test-rust.yml
git commit -m "feat(test): step-summary writes for test-{go,python,rust}"
```

---

## Task 5: Normalize trivy-* + add docker-build-multi

**Files:**
- Modify: `.github/workflows/trivy-fs.yml`
- Modify: `.github/workflows/trivy-image.yml`
- Modify: `.github/workflows/docker-build-multi.yml`

- [ ] **Step 5.1: Normalize `.github/workflows/trivy-image.yml`**

Open file. Locate the existing summary block. Today it likely renders:

```bash
{
  echo "## Trivy image scan"
  echo "**Image:** $IMAGE"
  echo "**Severities:** ..."
  echo "**Findings:** **$COUNT**"
} >> "$GITHUB_STEP_SUMMARY"
```

Replace the entire block with the conformant version. You need the per-severity count — extract it from the Trivy JSON. The step that runs Trivy likely already produces `trivy.json`. Locate it. Modify the existing `count` step (or wherever the summary is built) to read:

```yaml
      - name: Summary
        if: always()
        env:
          IMAGE: ${{ inputs.image_ref }}
          SEVERITY: ${{ inputs.severity }}
          FAIL_ON_FINDINGS: ${{ inputs.fail_on_findings }}
          COUNT: ${{ steps.count.outputs.findings_count }}
          REPORT: trivy.json
        run: |
          trivy_version=$(trivy --version 2>/dev/null | awk '/^Version:/ {print $2}' || echo unknown)
          # Per-severity counts (jq required; install in catalog runners).
          if [[ -f "$REPORT" ]]; then
            crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$REPORT")
            high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$REPORT")
            med=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' "$REPORT")
            low=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length' "$REPORT")
          else
            crit=0; high=0; med=0; low=0
          fi
          if [[ "$COUNT" == "0" ]]; then
            result="✓ no findings"
          elif [[ "$FAIL_ON_FINDINGS" == "true" ]]; then
            result="✗ ${COUNT} findings"
          else
            result="▲ ${COUNT} findings (gate disabled)"
          fi
          {
            echo "## trivy-image"
            echo ""
            echo "**Tool:** Trivy ${trivy_version}"
            echo "**Image:** \`${IMAGE}\`"
            echo "**Severities:** \`${SEVERITY}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Severity | Count |"
            echo "|---|---|"
            echo "| CRITICAL | ${crit} |"
            echo "| HIGH | ${high} |"
            echo "| MEDIUM | ${med} |"
            echo "| LOW | ${low} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Delete the prior summary echo lines. Keep the existing `count` step (it's used by `Fail on findings`).

- [ ] **Step 5.2: Normalize `.github/workflows/trivy-fs.yml`**

Same pattern as 5.1. Replace heading from `## Trivy fs scan` (or whatever) to `## trivy-fs`. The target is a path, not an image ref:

```yaml
      - name: Summary
        if: always()
        env:
          SCAN_PATH: ${{ inputs.scan_path }}
          SEVERITY: ${{ inputs.severity }}
          FAIL_ON_FINDINGS: ${{ inputs.fail_on_findings }}
          COUNT: ${{ steps.count.outputs.findings_count }}
          REPORT: trivy-fs.json
        run: |
          trivy_version=$(trivy --version 2>/dev/null | awk '/^Version:/ {print $2}' || echo unknown)
          if [[ -f "$REPORT" ]]; then
            crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$REPORT")
            high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$REPORT")
            med=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' "$REPORT")
            low=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length' "$REPORT")
          else
            crit=0; high=0; med=0; low=0
          fi
          if [[ "$COUNT" == "0" ]]; then
            result="✓ no findings"
          elif [[ "$FAIL_ON_FINDINGS" == "true" ]]; then
            result="✗ ${COUNT} findings"
          else
            result="▲ ${COUNT} findings (gate disabled)"
          fi
          {
            echo "## trivy-fs"
            echo ""
            echo "**Tool:** Trivy ${trivy_version}"
            echo "**Path:** \`${SCAN_PATH}\`"
            echo "**Severities:** \`${SEVERITY}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Severity | Count |"
            echo "|---|---|"
            echo "| CRITICAL | ${crit} |"
            echo "| HIGH | ${high} |"
            echo "| MEDIUM | ${med} |"
            echo "| LOW | ${low} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

If the actual report filename or path-input names differ, adjust env-vars accordingly.

- [ ] **Step 5.3: Add summary to `.github/workflows/docker-build-multi.yml`**

Open file. This atom has multiple jobs: per-arch build matrix, then a merge job that pushes the manifest list. Each matrix-build job produces a per-arch digest; merge produces the final manifest digest + tag list.

Add a Summary step to the merge job (the last job that runs after all builds). Place it as the final step:

```yaml
      - name: Summary
        env:
          IMAGE_NAME: ${{ needs.version.outputs.image_name }}
          TAGS: ${{ needs.version.outputs.tags }}
          DIGEST: ${{ steps.merge.outputs.digest }}
          PLATFORMS: ${{ inputs.platforms }}
          SIGN: ${{ inputs.sign }}
          ATTEST: ${{ inputs.attest }}
          SBOM: ${{ inputs.sbom }}
        run: |
          glyph_bool() { [[ "$1" == "true" ]] && echo "✓" || echo "−"; }
          {
            echo "## docker-build-multi"
            echo ""
            echo "**Tool:** Buildx (distributed multi-arch)"
            echo "**Result:** ✓ pushed"
            echo ""
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Image | \`ghcr.io/${IMAGE_NAME}\` |"
            echo "| Tags | \`${TAGS}\` |"
            echo "| Digest | \`${DIGEST}\` |"
            echo "| Platforms | \`${PLATFORMS}\` |"
            echo "| Sign | $(glyph_bool "$SIGN") cosign keyless |"
            echo "| Attest | $(glyph_bool "$ATTEST") SLSA provenance |"
            echo "| SBOM | $(glyph_bool "$SBOM") SPDX-JSON |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Adjust env-var sources (`needs.version.outputs.*`, `steps.merge.outputs.*`) to match the actual job/step IDs in the file. If `version` or `merge` are named differently, update.

No `if: always()` — only meaningful after successful push.

- [ ] **Step 5.4: Gate check**

```bash
bash tests/conventions/check-step-summary.sh 2>&1 | grep -E '^FAIL: (trivy-|docker-build-multi)' || echo "no trivy-*/docker-build-multi failures"
```

Expected: no failures for these three.

- [ ] **Step 5.5: Commit**

```bash
git add .github/workflows/trivy-fs.yml .github/workflows/trivy-image.yml .github/workflows/docker-build-multi.yml
git commit -m "feat(trivy): normalize trivy-* summaries; step-summary for docker-build-multi"
```

---

## Task 6: Normalize docker-build

**Files:**
- Modify: `.github/workflows/docker-build.yml`

- [ ] **Step 6.1: Modify summary block**

Open file. Locate existing summary block (~near `post-comment` job, after merge). Replace the existing summary heading and body with the conformant version:

```yaml
      - name: Summary
        env:
          IMAGE_NAME: ${{ needs.version.outputs.image_name }}
          TAG: ${{ needs.version.outputs.tag }}
          DIGEST: ${{ steps.merge_step.outputs.digest }}
          PLATFORMS: ${{ inputs.platforms }}
          SIGN: ${{ inputs.sign }}
          ATTEST: ${{ inputs.attest }}
          SBOM: ${{ inputs.sbom }}
        run: |
          glyph_bool() { [[ "$1" == "true" ]] && echo "✓" || echo "−"; }
          {
            echo "## docker-build"
            echo ""
            echo "**Tool:** Buildx (distributed multi-arch)"
            echo "**Result:** ✓ pushed"
            echo ""
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Image | \`ghcr.io/${IMAGE_NAME}\` |"
            echo "| Tag | \`${TAG}\` |"
            echo "| Digest | \`${DIGEST}\` |"
            echo "| Platforms | \`${PLATFORMS}\` |"
            echo "| Sign | $(glyph_bool "$SIGN") cosign keyless |"
            echo "| Attest | $(glyph_bool "$ATTEST") SLSA provenance |"
            echo "| SBOM | $(glyph_bool "$SBOM") SPDX-JSON |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Adjust env-vars to match actual job/step IDs (the existing summary block already references them — copy from there).

- [ ] **Step 6.2: Gate check**

```bash
bash tests/conventions/check-step-summary.sh 2>&1 | grep '^FAIL: docker-build.yml' || echo "docker-build OK"
```

Expected: no `FAIL: docker-build.yml`.

- [ ] **Step 6.3: Commit**

```bash
git add .github/workflows/docker-build.yml
git commit -m "feat(docker): normalize step-summary in docker-build"
```

---

## Task 7: Normalize helm-publish, semantic-release, goreleaser, cleanup-images

**Files:**
- Modify: `.github/workflows/helm-publish.yml`
- Modify: `.github/workflows/semantic-release.yml`
- Modify: `.github/workflows/goreleaser.yml`
- Modify: `.github/workflows/cleanup-images.yml`

- [ ] **Step 7.1: Modify `.github/workflows/helm-publish.yml`**

Open file. Replace summary block:

```yaml
      - name: Summary
        env:
          CHART_FILE: ${{ steps.package.outputs.chart_file }}
          CHART_NAME: ${{ steps.package.outputs.chart_name }}
          CHART_VERSION: ${{ steps.package.outputs.chart_version }}
          REGISTRY: ${{ inputs.registry }}
          DIGEST: ${{ steps.push.outputs.digest }}
        run: |
          {
            echo "## helm-publish"
            echo ""
            echo "**Tool:** helm (OCI push)"
            echo "**Result:** ✓ pushed"
            echo ""
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Chart | \`${CHART_NAME}\` |"
            echo "| Version | \`${CHART_VERSION}\` |"
            echo "| OCI Ref | \`oci://${REGISTRY}/${CHART_NAME}:${CHART_VERSION}\` |"
            echo "| Digest | \`${DIGEST:-N/A}\` |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Adjust step-output names to match the actual `package`/`push` step IDs in the file.

- [ ] **Step 7.2: Modify `.github/workflows/semantic-release.yml`**

Open file. The existing summary likely shows old/new version. Replace with:

```yaml
      - name: Summary
        env:
          OLD_VERSION: ${{ steps.release.outputs.previous_version }}
          NEW_VERSION: ${{ steps.release.outputs.new_version }}
          RELEASED: ${{ steps.release.outputs.released }}
          RELEASE_URL: ${{ steps.release.outputs.release_url }}
        run: |
          if [[ "$RELEASED" == "true" ]]; then
            result="✓ ${OLD_VERSION:-none} → ${NEW_VERSION}"
            line_url="[${RELEASE_URL}](${RELEASE_URL})"
          else
            result="− no release (nothing to bump)"
            line_url="—"
          fi
          {
            echo "## semantic-release"
            echo ""
            echo "**Tool:** release-please"
            echo "**Result:** ${result}"
            echo ""
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Old version | \`${OLD_VERSION:-none}\` |"
            echo "| New version | \`${NEW_VERSION:-none}\` |"
            echo "| Release URL | ${line_url} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Note: `−` glyph for "no release" since it's neither success-with-change nor failure. (Result-glyphs section in the convention defines only ✓/✗/▲; for "idle" outcomes the convention permits `−` as a neutral.) If the executing engineer wants to keep strict ✓/✗/▲, use `✓ no release (idle)` instead.

Adjust step-output references to match the actual release-please step ID and its outputs.

- [ ] **Step 7.3: Modify `.github/workflows/goreleaser.yml`**

Replace summary block:

```yaml
      - name: Summary
        env:
          TAG: ${{ github.ref_name }}
          GR_VERSION: ${{ inputs.goreleaser_version }}
          WD: ${{ inputs.working_directory }}
        run: |
          {
            echo "## goreleaser"
            echo ""
            echo "**Tool:** goreleaser ${GR_VERSION}"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ✓ released"
            echo ""
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Tag | \`${TAG}\` |"
            echo "| Release URL | https://github.com/${{ github.repository }}/releases/tag/${TAG} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 7.4: Modify `.github/workflows/cleanup-images.yml`**

Replace summary block:

```yaml
      - name: Summary
        env:
          PACKAGE: ${{ inputs.package_name }}
          KEEP_STABLE: ${{ inputs.keep_stable_versions }}
          PRE_AGE: ${{ inputs.prerelease_age_days }}
          STABLE_KEPT: ${{ steps.stable.outputs.kept_count }}
          STABLE_DELETED: ${{ steps.stable.outputs.deleted_count }}
          PRE_KEPT: ${{ steps.stale.outputs.kept_count }}
          PRE_DELETED: ${{ steps.stale.outputs.deleted_count }}
        run: |
          {
            echo "## cleanup-images"
            echo ""
            echo "**Tool:** GitHub Packages API"
            echo "**Result:** ✓ cleaned"
            echo ""
            echo "**Package:** \`${PACKAGE}\`"
            echo ""
            echo "| Rule | Kept | Deleted |"
            echo "|---|---|---|"
            echo "| Stable (keep last ${KEEP_STABLE}) | ${STABLE_KEPT:-?} | ${STABLE_DELETED:-?} |"
            echo "| Prerelease (older than ${PRE_AGE} days) | ${PRE_KEPT:-?} | ${PRE_DELETED:-?} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

If the existing `stable` / `stale` steps don't expose `kept_count` / `deleted_count` outputs, add them in those steps (small change to their `run:` to `echo "kept_count=..." >> "$GITHUB_OUTPUT"`). Adjust to actual step IDs in the file.

- [ ] **Step 7.5: Gate check**

```bash
bash tests/conventions/check-step-summary.sh 2>&1 | grep -E '^FAIL: (helm-publish|semantic-release|goreleaser|cleanup-images)' || echo "Task 7 atoms OK"
```

Expected: none of the 4 atoms appear in failures.

- [ ] **Step 7.6: Commit**

```bash
git add .github/workflows/helm-publish.yml .github/workflows/semantic-release.yml .github/workflows/goreleaser.yml .github/workflows/cleanup-images.yml
git commit -m "feat(release): normalize step-summary in helm-publish, semantic-release, goreleaser, cleanup-images"
```

---

## Task 8: onboard-sweep + drift-check (new); normalize onboard

**Files:**
- Modify: `.github/workflows/onboard-sweep.yml`
- Modify: `.github/workflows/drift-check.yml`
- Modify: `.github/workflows/onboard.yml`

- [ ] **Step 8.1: Add summary to `.github/workflows/onboard-sweep.yml`**

This atom iterates over adopters and triggers per-target onboarding. Add a summary at the end of the main job:

```yaml
      - name: Summary
        if: always()
        env:
          TARGETS_PROCESSED: ${{ steps.sweep.outputs.targets_processed }}
          TARGETS_FAILED: ${{ steps.sweep.outputs.targets_failed }}
        run: |
          if [[ "${TARGETS_FAILED:-0}" == "0" ]]; then
            result="✓ ${TARGETS_PROCESSED:-0} targets swept"
          else
            result="▲ ${TARGETS_PROCESSED:-0} swept, ${TARGETS_FAILED} failed"
          fi
          {
            echo "## onboard-sweep"
            echo ""
            echo "**Tool:** onboard-sweep cron"
            echo "**Result:** ${result}"
            echo ""
            echo "| Metric | Value |"
            echo "|---|---|"
            echo "| Targets processed | ${TARGETS_PROCESSED:-0} |"
            echo "| Targets failed | ${TARGETS_FAILED:-0} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Adjust step-output references to match the actual sweep step ID. If `targets_processed`/`targets_failed` outputs don't exist yet, add them by counting in the sweep loop.

- [ ] **Step 8.2: Add summary to `.github/workflows/drift-check.yml`**

This atom compares adopter-repo render output against the catalog. Add at end of main job:

```yaml
      - name: Summary
        if: always()
        env:
          TARGETS_CHECKED: ${{ steps.drift.outputs.targets_checked }}
          DRIFTED: ${{ steps.drift.outputs.drifted_count }}
          ISSUES_OPENED: ${{ steps.drift.outputs.issues_opened }}
        run: |
          if [[ "${DRIFTED:-0}" == "0" ]]; then
            result="✓ ${TARGETS_CHECKED:-0} targets in sync"
          else
            result="▲ ${DRIFTED} of ${TARGETS_CHECKED} drifted"
          fi
          {
            echo "## drift-check"
            echo ""
            echo "**Tool:** drift-check render-and-compare"
            echo "**Result:** ${result}"
            echo ""
            echo "| Metric | Value |"
            echo "|---|---|"
            echo "| Targets checked | ${TARGETS_CHECKED:-0} |"
            echo "| Drifted | ${DRIFTED:-0} |"
            echo "| Issues opened/updated | ${ISSUES_OPENED:-0} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Adjust step IDs and output names to match the actual file. Add outputs to the drift step if not yet present.

- [ ] **Step 8.3: Normalize `.github/workflows/onboard.yml`**

This atom has 6 existing summary writes (per-target diff headings, per-target component tables, etc.) at H2 level (`## Rendered diff for <target>`).

Change: demote the existing H2 headings to H3 (`### Rendered diff for <target>`, `### Detected components`, etc.) and prepend ONE atom-level `## onboard` heading early in the job.

The earliest existing summary write is around the diff-display step. Before that step, add:

```yaml
      - name: Begin summary
        if: always()
        env:
          DRY_RUN: ${{ inputs.dry_run }}
        run: |
          if [[ "$DRY_RUN" == "true" ]]; then
            mode="dry-run (no PR push)"
          else
            mode="apply"
          fi
          {
            echo "## onboard"
            echo ""
            echo "**Tool:** onboard render+PR"
            echo "**Mode:** ${mode}"
            echo ""
          } >> "$GITHUB_STEP_SUMMARY" || true
```

Then in every existing summary write in this file, change `## Heading` to `### Heading` (sed-like edit, but manual — there are only 6 occurrences). After the changes, run `grep -n '## ' .github/workflows/onboard.yml | grep -v 'Summary convention'` to inventory; ensure only ONE `## onboard` heading remains at H2 level inside the file body.

- [ ] **Step 8.4: Gate check**

```bash
bash tests/conventions/check-step-summary.sh 2>&1 | grep -E '^FAIL: (onboard|drift-check)' || echo "Task 8 atoms OK"
```

Expected: no Task-8-atom failures.

- [ ] **Step 8.5: Commit**

```bash
git add .github/workflows/onboard-sweep.yml .github/workflows/drift-check.yml .github/workflows/onboard.yml
git commit -m "feat(onboard): step-summary writes for onboard-sweep, drift-check; normalize onboard"
```

---

## Task 9: File-header convention comments

**Files:**
- Modify: all 18 in-scope atoms

- [ ] **Step 9.1: Add header comment to each in-scope atom**

For each of these 18 files, insert this line directly after the existing first comment block (typically `# .github/workflows/<atom>.yml` and one-line description):

```
# Summary convention: docs/conventions/step-summary.md
```

Files to touch (in alphabetical order):

```
.github/workflows/cleanup-images.yml
.github/workflows/docker-build.yml
.github/workflows/docker-build-multi.yml
.github/workflows/drift-check.yml
.github/workflows/goreleaser.yml
.github/workflows/helm-publish.yml
.github/workflows/lint-go.yml
.github/workflows/lint-helm.yml
.github/workflows/lint-python.yml
.github/workflows/lint-rust.yml
.github/workflows/onboard.yml
.github/workflows/onboard-sweep.yml
.github/workflows/semantic-release.yml
.github/workflows/test-go.yml
.github/workflows/test-python.yml
.github/workflows/test-rust.yml
.github/workflows/trivy-fs.yml
.github/workflows/trivy-image.yml
```

(`docker-build-multi.yml`, `lint-helm.yml`, and similar may already have varied header comments — insert the new line as part of the header comment block, before the `name:` declaration.)

- [ ] **Step 9.2: Verify all 18 files contain the header line**

Run:

```bash
for f in cleanup-images docker-build docker-build-multi drift-check goreleaser helm-publish lint-go lint-helm lint-python lint-rust onboard onboard-sweep semantic-release test-go test-python test-rust trivy-fs trivy-image; do
  if ! grep -q '^# Summary convention: docs/conventions/step-summary.md$' ".github/workflows/${f}.yml"; then
    echo "MISSING: ${f}.yml"
  fi
done
echo "(no MISSING lines above = success)"
```

Expected: no `MISSING:` lines.

- [ ] **Step 9.3: Commit**

```bash
git add .github/workflows/
git commit -m "feat(workflows): add convention file-header comments to in-scope atoms"
```

---

## Task 10: Wire CI-Gate into validate.yml

**Files:**
- Modify: `.github/workflows/validate.yml`

- [ ] **Step 10.1: Confirm all in-scope atoms pass the gate locally**

```bash
bash tests/conventions/check-step-summary.sh
```

Expected: `OK: 18 atoms checked, all conformant.`

If any `FAIL:` lines appear, return to the corresponding earlier Task and fix before wiring CI.

- [ ] **Step 10.2: Add gate step to `.github/workflows/validate.yml`**

Open file. Identify the job that runs actionlint/yamllint (likely a single `validate` job). After the yamllint step, append:

```yaml
      - name: Check step-summary convention
        run: bash tests/conventions/check-step-summary.sh
```

- [ ] **Step 10.3: Run actionlint on validate.yml**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest .github/workflows/validate.yml
```

Expected: no output.

- [ ] **Step 10.4: Re-run bats tests for the check script**

```bash
bats tests/shell/check-step-summary.bats
```

Expected: all 4 tests pass.

- [ ] **Step 10.5: Commit**

```bash
git add .github/workflows/validate.yml
git commit -m "feat(validate): enforce step-summary convention in CI"
```

- [ ] **Step 10.6: Push branch and open PR**

```bash
git push -u origin feat/step-summary-sweep
gh pr create --title "feat: step-summary convention + sweep across all atoms" --body "$(cat <<'EOF'
## Summary

Codifies the `$GITHUB_STEP_SUMMARY` schema in `docs/conventions/step-summary.md`, brings all 18 consumer/org-internal atoms into conformance, and wires a CI gate in `validate.yml` to enforce it on future PRs.

Phase 8, Tier 1 (per `reference_phase8_candidate_roadmap.md`). Spec at `docs/superpowers/specs/2026-05-26-step-summary-sweep-design.md`. Plan at `docs/superpowers/plans/2026-05-26-step-summary-sweep.md`.

## Test plan

- [ ] CI green (actionlint, yamllint, integration callers, new step-summary gate)
- [ ] Visual: open one run of each atom-class in the integration job, confirm Run-Page Summary renders with H2 `## <atom>`, `**Tool:**`, `**Result:** <glyph>`
- [ ] Negative gate: temporarily strip the Summary step from `lint-go.yml`, push, confirm CI rejects with pointer to convention doc, revert
EOF
)"
```

Expected: PR URL printed.

---

## Self-Review (after writing the plan)

**Spec coverage check:**

- C-1 (Konvention-Doc) → Task 1.1 ✓
- C-2 (CONTRIBUTING-Verweis) → Task 1.2 ✓
- C-3 (File-Header-Kommentar) → Task 9 ✓
- C-4 (Normalize bestehende Summaries) → Tasks 5.1, 5.2, 6, 7.1-7.4, 8.3 ✓
- C-5 (Add fehlende Summaries) → Tasks 3, 4, 5.3, 8.1, 8.2 ✓
- C-6 (onboard.yml H3-Demote + atom-level H2) → Task 8.3 ✓
- C-7 (CI-Gate Skript + Bats + validate.yml-Wiring) → Tasks 2 + 10 ✓
- C-8 (Self-CI-Allowlist) → Task 2.4 (hardcoded in script) ✓

All Concerns mapped.

**Placeholder scan:**

- No "TBD", "TODO", "implement later" present.
- One soft spot: lint-rust and lint-helm step IDs (`fmt`/`clippy`, `helm_lint`/`ct_lint`) are guesses — the engineer must verify against the actual files and adjust. This is called out explicitly in the relevant steps.
- test-rust coverage-extraction logic is described as "adjust to match the actual `cargo-llvm-cov` invocation" — also a justified gap, since the actual invocation is file-local.

**Type/name consistency:**

- `coverage_pct` step output used consistently across test-go (4.1) and test-python (4.2) and test-rust (4.3).
- `glyph()` helper function defined identically across lint-* and (with bool-variant `glyph_bool`) docker-build*.
- Atom-name strings in `## <atom>` echoes match filenames (verified manually).
- Env-var naming consistent: `*_OUTCOME` for step outcomes, `PCT`/`THRESHOLD` for coverage values.

Plan is complete and internally consistent.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-26-step-summary-sweep.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — Ich dispatche einen frischen Subagent pro Task, review zwischen Tasks, schnelle Iteration. Per-Task Worktree-isolation kann der Subagent selbst aufsetzen wenn nicht vorher geschehen.

**2. Inline Execution** — Tasks in dieser Session abarbeiten via `superpowers:executing-plans`, batch-Execution mit Checkpoints.

Welche Variante?
