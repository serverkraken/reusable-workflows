# Phase 4 Test-Coverage Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the six remaining test-coverage gaps from REVIEW-2026-05-22.md (HIGH-11, MED-13, MED-14, MED-15, G.4-M3 onboard-drift wrapper) without touching any production workflow code. Two file-disjoint PRs.

**Architecture:** PR-J adds onboard test-coverage (cargo + pnpm workspace fixtures with bats, seed-onboarding-status.bats, onboard-drift action-wrapper caller against a pre-baked fixture). PR-K converts three `*-fail` callers from dispatch-only to path-filter-triggered with sibling `assert-X-fail` jobs, and adds a new `cleanup-images-fail` caller. All commits use `test:` prefix — no version bump.

**Tech Stack:** GitHub Actions reusable workflows, composite actions, bats-core 1.13+, bash 5+, jq, gh CLI, gomplate (for fixture generation only).

---

## Pre-flight: Worktree setup

Two PRs that don't share files. Each gets its own worktree branched from `main`.

### Task 0.1: Confirm main is current and create PR-J worktree

**Files:** none (git only)

- [ ] **Step 1: Sync local main with origin**

Run:
```bash
git fetch origin main
git checkout main
git pull --rebase origin main
```

Expected: `Your branch is up to date with 'origin/main'.`

- [ ] **Step 2: Create PR-J worktree**

Run:
```bash
git worktree add .worktrees/phase-4-onboard -b test/phase-4-onboard-coverage main
```

Expected: `Preparing worktree (new branch 'test/phase-4-onboard-coverage')`

- [ ] **Step 3: Verify worktree**

Run: `git worktree list`
Expected: new entry for `.worktrees/phase-4-onboard [test/phase-4-onboard-coverage]`

All subsequent PR-J tasks (1–5) execute from `.worktrees/phase-4-onboard`. Use absolute paths or `cd` once at the start of a task.

---

## PR-J — Onboard test-coverage

### Task 1: Cargo-workspace fixture and detect tests

**Files:**
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/Cargo.toml`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-a/Cargo.toml`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-a/src/main.rs`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-b/Cargo.toml`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-b/src/lib.rs`
- Modify: `.worktrees/phase-4-onboard/tests/shell/onboard-detect.bats` (add 2 tests)

- [ ] **Step 1: Create root workspace Cargo.toml**

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/Cargo.toml`:
```toml
[workspace]
members = ["pkg-a", "pkg-b"]
resolver = "2"
```

- [ ] **Step 2: Create pkg-a (binary crate)**

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-a/Cargo.toml`:
```toml
[package]
name = "pkg-a"
version = "0.1.0"
edition = "2021"
```

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-a/src/main.rs`:
```rust
fn main() {
    println!("hello from pkg-a");
}
```

- [ ] **Step 3: Create pkg-b (library crate)**

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-b/Cargo.toml`:
```toml
[package]
name = "pkg-b"
version = "0.1.0"
edition = "2021"
```

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/cargo-workspace/pkg-b/src/lib.rs`:
```rust
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

- [ ] **Step 4: Add bats tests for cargo-workspace**

Append to `.worktrees/phase-4-onboard/tests/shell/onboard-detect.bats` (before the final test at the end of the file — insert near the other rust/cargo tests, after `@test "detects rust from Cargo.toml"`):

```bats
@test "detects rust cargo-workspace" {
  run "$DETECT" "$FIX/cargo-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=rust"* ]]
  [[ "$output" == *"release_type=rust"* ]]
}

@test "cargo-workspace --profile-json emits both member paths" {
  run "$DETECT" --profile-json "$FIX/cargo-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pkg-a"* ]]
  [[ "$output" == *"pkg-b"* ]]
}
```

Placement detail: find the line `@test "detects rust from Cargo.toml" {` block and add the two new tests immediately after its closing `}`. This keeps rust-related tests grouped.

- [ ] **Step 5: Run the new bats tests**

Run from worktree root:
```bash
cd .worktrees/phase-4-onboard
bats tests/shell/onboard-detect.bats --filter cargo-workspace
```

Expected output (both tests PASS):
```
 ✓ detects rust cargo-workspace
 ✓ cargo-workspace --profile-json emits both member paths

2 tests, 0 failures
```

If a test fails: the existing detect logic in `scripts/lib/onboard-detect-lib.sh:115-138` is the cargo-workspace parser. Re-read the awk block and check that the fixture's `members = ["pkg-a", "pkg-b"]` line matches the parser's expected shape.

- [ ] **Step 6: Run full bats suite to confirm no regression**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all tests pass (count grew by 2 vs. baseline).

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/onboard/cargo-workspace/ tests/shell/onboard-detect.bats
git commit -m "test(onboard): cargo-workspace fixture and detect tests"
```

### Task 2: pnpm-workspace fixture and detect tests

**Files:**
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/package.json`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/pnpm-workspace.yaml`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/apps/web/package.json`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/apps/api/package.json`
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/packages/shared/package.json`
- Modify: `.worktrees/phase-4-onboard/tests/shell/onboard-detect.bats` (add 2 tests)

- [ ] **Step 1: Create root package.json**

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/package.json`:
```json
{
  "name": "onboard-fixture-pnpm-root",
  "version": "0.0.0",
  "private": true
}
```

- [ ] **Step 2: Create pnpm-workspace.yaml**

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/pnpm-workspace.yaml`:
```yaml
packages:
  - "apps/*"
  - "packages/*"
```

- [ ] **Step 3: Create three workspace members**

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/apps/web/package.json`:
```json
{ "name": "web", "version": "0.0.0" }
```

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/apps/api/package.json`:
```json
{ "name": "api", "version": "0.0.0" }
```

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/pnpm-workspace/packages/shared/package.json`:
```json
{ "name": "shared", "version": "0.0.0" }
```

- [ ] **Step 4: Add bats tests for pnpm-workspace**

Append to `.worktrees/phase-4-onboard/tests/shell/onboard-detect.bats` immediately after the `@test "detects node from package.json"` block:

```bats
@test "detects node pnpm-workspace" {
  run "$DETECT" "$FIX/pnpm-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=node"* ]]
}

@test "pnpm-workspace --profile-json includes all glob-expanded members" {
  run "$DETECT" --profile-json "$FIX/pnpm-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps/web"* ]]
  [[ "$output" == *"apps/api"* ]]
  [[ "$output" == *"packages/shared"* ]]
}
```

- [ ] **Step 5: Run the new bats tests**

```bash
bats tests/shell/onboard-detect.bats --filter pnpm-workspace
```

Expected:
```
 ✓ detects node pnpm-workspace
 ✓ pnpm-workspace --profile-json includes all glob-expanded members

2 tests, 0 failures
```

If the second test fails (some member path missing in output): re-read the pnpm parser at `scripts/lib/onboard-detect-lib.sh:162-183`. The `compgen -G` glob expansion needs `bash` not `sh` — bats runs bash, but verify the awk parser handles double-quoted vs unquoted glob patterns identically.

- [ ] **Step 6: Run full bats suite to confirm no regression**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all tests pass (count grew by 4 since Task 1's baseline).

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/onboard/pnpm-workspace/ tests/shell/onboard-detect.bats
git commit -m "test(onboard): pnpm-workspace fixture and detect tests"
```

### Task 3: Bats coverage for seed-onboarding-status.sh

**Files:**
- Create: `.worktrees/phase-4-onboard/tests/shell/seed-onboarding-status.bats`

- [ ] **Step 1: Write the bats file**

Write `.worktrees/phase-4-onboard/tests/shell/seed-onboarding-status.bats`:
```bash
#!/usr/bin/env bats
# Tests for scripts/seed-onboarding-status.sh
#
# The script lists serverkraken/* repos via gh CLI and appends one Markdown
# table row per missing repo to docs/onboarding-status.md. Existing rows
# must be preserved; the regex anchor must avoid substring false-matches
# (e.g. "serverkraken/foo" must not match an existing "serverkraken/foo-extra"
# row).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/seed-onboarding-status.sh"
  WORK="$(mktemp -d)"
  cd "$WORK"
  mkdir -p docs

  # PATH-injected gh mock: emits a fixed list of three repos when invoked
  # with `gh repo list ...`. The script reads only the nameWithOwner field
  # so we ignore --json/--limit/-q flags and just print the canned list.
  BIN="$WORK/bin"
  mkdir -p "$BIN"
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "list" ]]; then
  printf 'serverkraken/alpha\nserverkraken/beta\nserverkraken/foo\n'
  exit 0
fi
echo "::error::unexpected gh call: $*" >&2
exit 1
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

@test "creates onboarding-status.md with header when missing" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ -f docs/onboarding-status.md ]]
  grep -q '# Onboarding Status' docs/onboarding-status.md
  grep -q '| Repository | Onboarded |' docs/onboarding-status.md
}

@test "appends new repos and preserves existing rows" {
  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

_Last updated by the onboarding workflow: 2026-01-01T00:00:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/alpha | ✓ | v3.0.0 | #1 | #2 | onboarded |
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Existing row preserved verbatim
  grep -qE '^\| serverkraken/alpha \| ✓ \| v3\.0\.0 \|' docs/onboarding-status.md
  # New rows appended (mock returns beta + foo as not-yet-present)
  grep -qE '^\| serverkraken/beta \|' docs/onboarding-status.md
  grep -qE '^\| serverkraken/foo \|' docs/onboarding-status.md
}

@test "regex anchor avoids substring false-match (foo vs foo-extra)" {
  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

_Last updated by the onboarding workflow: 2026-01-01T00:00:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/foo-extra | — | — | — | — | not onboarded |
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # foo (without the -extra suffix) must now appear exactly once as a fresh row.
  # If the regex anchor were broken, the existing foo-extra row would match
  # ^| serverkraken/foo and the new foo row would never be appended.
  count=$(grep -cE '^\| serverkraken/foo \|' docs/onboarding-status.md)
  [ "$count" -eq 1 ]
  # foo-extra row is still present
  grep -qE '^\| serverkraken/foo-extra \|' docs/onboarding-status.md
}
```

- [ ] **Step 2: Run the new bats file**

```bash
bats tests/shell/seed-onboarding-status.bats
```

Expected:
```
 ✓ creates onboarding-status.md with header when missing
 ✓ appends new repos and preserves existing rows
 ✓ regex anchor avoids substring false-match (foo vs foo-extra)

3 tests, 0 failures
```

If a test fails: the script uses a relative path `DOC=docs/onboarding-status.md`. The bats `setup()` does `cd "$WORK"` and creates `docs/` to satisfy this. If you see "No such file or directory" the `cd` happened in a subshell — confirm `cd` is at the top level of `setup()`.

- [ ] **Step 3: Run the full bats suite to confirm no cross-test pollution**

```bash
bats tests/shell/
```

Expected: all tests pass; total count grew by 3.

- [ ] **Step 4: Commit**

```bash
git add tests/shell/seed-onboarding-status.bats
git commit -m "test(onboard): bats coverage for seed-onboarding-status.sh"
```

### Task 4: Generate drift-clean fixture (pre-baked render output)

**Files:**
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/drift-clean/` (entire rendered tree, committed)
- Create: `.worktrees/phase-4-onboard/tests/fixtures/onboard/drift-clean/README.md`

This task **generates** the fixture by running detect+render against the existing go-repo fixture, then commits the resulting tree as test data. The fixture is then opaque — its purpose is only to give the drift action a checkout where lock + file hashes match.

- [ ] **Step 1: Verify gomplate is installed locally**

Run:
```bash
command -v gomplate && gomplate --version
```

Expected: a version string. If gomplate is missing, install via `sudo ./scripts/install-gomplate.sh` (catalog's helper).

- [ ] **Step 2: Generate the rendered tree**

From the worktree root:
```bash
cd .worktrees/phase-4-onboard
mkdir -p tests/fixtures/onboard/drift-clean
profile=$(scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/go-repo)
printf '%s\n' "$profile" > /tmp/phase-4-profile.json
scripts/onboard-render.sh "$PWD" tests/fixtures/onboard/drift-clean /tmp/phase-4-profile.json v3
rm /tmp/phase-4-profile.json
```

Expected: files appear under `tests/fixtures/onboard/drift-clean/.github/workflows/`, plus `release-please-config.json`, `.release-please-manifest.json`, and `.github/onboard.lock.json`.

- [ ] **Step 3: Inspect the generated tree**

```bash
fd . tests/fixtures/onboard/drift-clean -t f | sort
```

Expected: at minimum these paths (exact list depends on render template content for a go single-component repo):
- `tests/fixtures/onboard/drift-clean/.github/onboard.lock.json`
- `tests/fixtures/onboard/drift-clean/.github/workflows/ci.yml`
- `tests/fixtures/onboard/drift-clean/.github/workflows/release.yml`
- `tests/fixtures/onboard/drift-clean/.github/workflows/prerelease.yml`
- `tests/fixtures/onboard/drift-clean/.github/workflows/cleanup.yml`
- `tests/fixtures/onboard/drift-clean/.release-please-manifest.json`
- `tests/fixtures/onboard/drift-clean/release-please-config.json`

If the lock file is missing or the file list is much shorter: the render script aborted partway. Re-run with `bash -x scripts/onboard-render.sh ...` to see which step failed.

- [ ] **Step 4: Verify drift reports `clean` locally**

```bash
CATALOG_CURRENT_VERSION=v3 scripts/onboard-drift.sh tests/fixtures/onboard/drift-clean "$PWD"
```

Expected output contains:
```
status=clean
```

If the output says `modified` instead: an extraneous file ended up in the fixture (e.g. a `.DS_Store` on macOS). Run `fd '\.DS_Store' tests/fixtures/onboard/drift-clean -H` and delete any matches before re-running.

- [ ] **Step 5: Write the fixture README**

Write `.worktrees/phase-4-onboard/tests/fixtures/onboard/drift-clean/README.md`:
```markdown
# drift-clean fixture

Pre-rendered v3 onboarding output. Used by `tests/callers/onboard-drift-happy.yml`
to verify the `actions/onboard-drift` composite-action wrapper layer
(env passthrough, GITHUB_OUTPUT capture, GITHUB_ACTION_PATH resolution).

Script-level drift logic is covered by `tests/shell/onboard-drift.bats`; this
fixture exercises only the GHA wrapper.

## Regenerating

When the catalog cuts a new major (v4+), this fixture's lock will point at the
old major and drift will report `behind`, breaking the wrapper test. Refresh:

    rm -rf tests/fixtures/onboard/drift-clean
    mkdir -p tests/fixtures/onboard/drift-clean
    profile=$(scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/go-repo)
    printf '%s\n' "$profile" > /tmp/profile.json
    scripts/onboard-render.sh "$PWD" tests/fixtures/onboard/drift-clean /tmp/profile.json v4
    rm /tmp/profile.json

Then restore this README and update the `current_version:` input in the caller.
```

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/onboard/drift-clean/
git commit -m "test(onboard): drift-clean fixture for action-wrapper test"
```

### Task 5: Onboard-drift composite-action caller workflow

**Files:**
- Create: `.worktrees/phase-4-onboard/tests/callers/onboard-drift-happy.yml`

- [ ] **Step 1: Write the caller workflow**

Write `.worktrees/phase-4-onboard/tests/callers/onboard-drift-happy.yml`:
```yaml
# tests/callers/onboard-drift-happy.yml
# Happy-path caller for the onboard-drift composite action. Exercises the
# GHA wrapper layer (env passthrough, GITHUB_OUTPUT capture, GITHUB_ACTION_PATH
# resolution) against the pre-rendered drift-clean fixture. The script-level
# drift logic is already covered by tests/shell/onboard-drift.bats.
name: caller-onboard-drift-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - 'actions/onboard-drift/**'
      - 'scripts/onboard-drift.sh'
      - 'scripts/lib/hash-lib.sh'
      - 'tests/callers/onboard-drift-happy.yml'
      - 'tests/fixtures/onboard/drift-clean/**'

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - id: drift
        uses: ./actions/onboard-drift
        with:
          target_path: tests/fixtures/onboard/drift-clean
          current_version: v3
      - name: Assert clean status
        env:
          STATUS: ${{ steps.drift.outputs.status }}
        run: |
          if [[ "$STATUS" != "clean" ]]; then
            echo "::error::expected status=clean, got status=$STATUS"
            exit 1
          fi
          echo "onboard-drift wrapper returned status=clean"
```

- [ ] **Step 2: Lint locally**

Run from the worktree:
```bash
yamllint -s tests/callers/onboard-drift-happy.yml
```

Expected: no output (silent = clean). If yamllint reports an issue, fix the indentation/comment spacing to match the project's `.yamllint.yml` rules.

```bash
actionlint tests/callers/onboard-drift-happy.yml 2>&1 | head -20
```

Expected: no output, exit code 0. If actionlint isn't installed locally, skip this step — validate.yml will catch issues in CI.

- [ ] **Step 3: Commit**

```bash
git add tests/callers/onboard-drift-happy.yml
git commit -m "test(onboard): onboard-drift composite-action caller workflow"
```

### Task 6: Push PR-J and open pull request

**Files:** none (git/gh only)

- [ ] **Step 1: Verify PR-J commit log**

```bash
git log --oneline main..HEAD
```

Expected (5 commits, newest first):
```
xxxxxxx test(onboard): onboard-drift composite-action caller workflow
xxxxxxx test(onboard): drift-clean fixture for action-wrapper test
xxxxxxx test(onboard): bats coverage for seed-onboarding-status.sh
xxxxxxx test(onboard): pnpm-workspace fixture and detect tests
xxxxxxx test(onboard): cargo-workspace fixture and detect tests
```

- [ ] **Step 2: Push branch**

```bash
git push -u origin test/phase-4-onboard-coverage
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head test/phase-4-onboard-coverage \
  --title "test(onboard): phase 4 test-coverage expansion (PR-J)" \
  --body "$(cat <<'EOF'
## Summary

Closes onboard-side test-coverage gaps from REVIEW-2026-05-22.md § N Phase 4:

- HIGH-11 — cargo-workspace + pnpm-workspace fixtures with detect bats tests
- MED-15 — bats coverage for `scripts/seed-onboarding-status.sh`
- G.4-M3 — `onboard-drift` composite-action wrapper caller against a pre-baked `drift-clean` fixture

No production-workflow code changes; pure test additions. Companion PR (PR-K) covers atom failure-path coverage (MED-13, MED-14).

Spec: `docs/superpowers/specs/2026-05-22-phase-4-design.md`
Plan: `docs/superpowers/plans/2026-05-22-phase-4-test-coverage-expansion.md`

## Test plan

- [ ] `bats tests/shell/onboard-detect.bats` green (+4 tests)
- [ ] `bats tests/shell/seed-onboarding-status.bats` green (3 tests)
- [ ] `caller-onboard-drift-happy / drift` PR check green
- [ ] `validate.yml` PR check green (actionlint + yamllint + full bats suite)
EOF
)"
```

Note PR-body style: no Claude-attribution footer (memory: `feedback_pr_style`).

- [ ] **Step 4: Confirm PR check status (manual)**

```bash
gh pr view --json statusCheckRollup -q '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Expected (after ~2-5 min): every check is `SUCCESS` or in `IN_PROGRESS`. Watch until all complete, then verify all `SUCCESS`. If any check fails, read the workflow log and fix.

---

## Pre-flight: PR-K worktree

Created independently from main — PR-K does not depend on PR-J. Can be created at any time, including before PR-J merges.

### Task 7: Create PR-K worktree

**Files:** none (git only)

- [ ] **Step 1: Ensure main is still current**

From the catalog repo root (not from the PR-J worktree):
```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
```

- [ ] **Step 2: Create PR-K worktree**

```bash
git worktree add .worktrees/phase-4-atom-fail -b test/phase-4-atom-failure-coverage main
```

Expected: `Preparing worktree (new branch 'test/phase-4-atom-failure-coverage')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: a new entry for `.worktrees/phase-4-atom-fail [test/phase-4-atom-failure-coverage]` plus the PR-J worktree.

All subsequent PR-K tasks (8–11) execute from `.worktrees/phase-4-atom-fail`.

---

## PR-K — Atom failure-path coverage

### Task 8: Auto-trigger docker-build-multi-fail with assert job

**Files:**
- Modify: `.worktrees/phase-4-atom-fail/tests/callers/docker-build-multi-fail.yml`

- [ ] **Step 1: Read the current file**

```bash
cd .worktrees/phase-4-atom-fail
cat tests/callers/docker-build-multi-fail.yml
```

Note the existing `name:`, `on: workflow_dispatch`, and the single `test-docker-build-multi-fail` job with its `with:` block — those become the basis for the new file.

- [ ] **Step 2: Rewrite the file**

Overwrite `.worktrees/phase-4-atom-fail/tests/callers/docker-build-multi-fail.yml`:
```yaml
# tests/callers/docker-build-multi-fail.yml
# Failure-path caller for docker-build-multi.yml. Passes an empty JSON
# array as `images`; the reusable workflow's `parse` job must reject it
# (exit 1). The assert-docker-build-multi-fail sibling job verifies the
# atom failed as expected, so this PR check reports green when the atom
# correctly fails. Auto-fires on path-filtered PRs.
name: caller-docker-build-multi-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/docker-build-multi.yml'
      - 'tests/callers/docker-build-multi-fail.yml'
      - 'tests/fixtures/multi-image/**'

jobs:
  test-docker-build-multi-fail:
    uses: ./.github/workflows/docker-build-multi.yml
    secrets: inherit
    continue-on-error: true
    with:
      tag: ''
      prerelease: true
      context: tests/fixtures/multi-image
      images: '[]'
      sign: false
      attest: false
      sbom: false

  assert-docker-build-multi-fail:
    needs: test-docker-build-multi-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-docker-build-multi-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected docker-build-multi to fail for empty images array, got result=$RESULT"
            exit 1
          fi
          echo "docker-build-multi correctly failed for empty images array"
```

- [ ] **Step 3: Lint locally**

```bash
yamllint -s tests/callers/docker-build-multi-fail.yml
```

Expected: silent. Fix any reported issue.

If actionlint is installed locally:
```bash
actionlint tests/callers/docker-build-multi-fail.yml
```

Expected: silent.

- [ ] **Step 4: Commit**

```bash
git add tests/callers/docker-build-multi-fail.yml
git commit -m "test(docker-build-multi): auto-trigger failure caller with assert job"
```

### Task 9: Auto-trigger goreleaser-fail with assert job

**Files:**
- Modify: `.worktrees/phase-4-atom-fail/tests/callers/goreleaser-fail.yml`

- [ ] **Step 1: Rewrite the file**

Overwrite `.worktrees/phase-4-atom-fail/tests/callers/goreleaser-fail.yml`:
```yaml
# tests/callers/goreleaser-fail.yml
# Failure-path caller for goreleaser.yml. Points the atom at a fixture
# with no .goreleaser.yaml, forcing config-load failure. The
# assert-goreleaser-fail sibling job verifies the atom failed as
# expected. Auto-fires on path-filtered PRs.
name: caller-goreleaser-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/goreleaser.yml'
      - 'tests/callers/goreleaser-fail.yml'
      - 'tests/fixtures/cli-go-no-config/**'

jobs:
  test-goreleaser-fail:
    uses: ./.github/workflows/goreleaser.yml
    secrets: inherit
    continue-on-error: true
    with:
      working_directory: tests/fixtures/cli-go-no-config
      snapshot: true

  assert-goreleaser-fail:
    needs: test-goreleaser-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-goreleaser-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected goreleaser to fail for missing config, got result=$RESULT"
            exit 1
          fi
          echo "goreleaser correctly failed for missing .goreleaser.yaml"
```

- [ ] **Step 2: Confirm the fixture path exists**

```bash
ls tests/fixtures/cli-go-no-config/ 2>&1
```

Expected: directory exists (it's referenced by the existing dispatch-only caller, so it must already exist on main). If it doesn't exist, the existing dispatch-only caller is already broken and that's a pre-existing bug — flag it and continue.

- [ ] **Step 3: Lint locally**

```bash
yamllint -s tests/callers/goreleaser-fail.yml
```

Expected: silent.

- [ ] **Step 4: Commit**

```bash
git add tests/callers/goreleaser-fail.yml
git commit -m "test(goreleaser): auto-trigger failure caller with assert job"
```

### Task 10: Auto-trigger helm-publish-fail with assert job

**Files:**
- Modify: `.worktrees/phase-4-atom-fail/tests/callers/helm-publish-fail.yml`

- [ ] **Step 1: Rewrite the file**

Overwrite `.worktrees/phase-4-atom-fail/tests/callers/helm-publish-fail.yml`:
```yaml
# tests/callers/helm-publish-fail.yml
# Failure-path caller for helm-publish.yml. Points the atom at a chart
# fixture whose Chart.yaml lacks the required `version` field, forcing
# `helm lint` to exit non-zero. The assert-helm-publish-fail sibling
# job verifies the atom failed as expected. Auto-fires on path-filtered
# PRs.
name: caller-helm-publish-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/helm-publish.yml'
      - 'tests/callers/helm-publish-fail.yml'
      - 'tests/fixtures/helm-broken/**'

jobs:
  test-helm-publish-fail:
    uses: ./.github/workflows/helm-publish.yml
    secrets: inherit
    continue-on-error: true
    with:
      chart_path: tests/fixtures/helm-broken
      oci_registry: ghcr.io/serverkraken/test
      dry_run: true

  assert-helm-publish-fail:
    needs: test-helm-publish-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-helm-publish-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected helm-publish to fail for broken Chart.yaml, got result=$RESULT"
            exit 1
          fi
          echo "helm-publish correctly failed for broken Chart.yaml"
```

- [ ] **Step 2: Confirm the fixture exists**

```bash
ls tests/fixtures/helm-broken/ 2>&1
```

Expected: directory exists (referenced by the existing dispatch-only caller).

- [ ] **Step 3: Lint locally**

```bash
yamllint -s tests/callers/helm-publish-fail.yml
```

Expected: silent.

- [ ] **Step 4: Commit**

```bash
git add tests/callers/helm-publish-fail.yml
git commit -m "test(helm-publish): auto-trigger failure caller with assert job"
```

### Task 11: Add cleanup-images failure-path caller

**Files:**
- Create: `.worktrees/phase-4-atom-fail/tests/callers/cleanup-images-fail.yml`

- [ ] **Step 1: Write the new caller**

Write `.worktrees/phase-4-atom-fail/tests/callers/cleanup-images-fail.yml`:
```yaml
# tests/callers/cleanup-images-fail.yml
# Failure-path caller for cleanup-images.yml. Passes runs_on as an empty
# JSON array; fromJSON yields [], and GHA rejects an empty runner-labels
# array at runner allocation. The assert-cleanup-images-fail sibling job
# verifies the atom failed as expected. Auto-fires on path-filtered PRs.
name: caller-cleanup-images-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/cleanup-images.yml'
      - 'tests/callers/cleanup-images-fail.yml'

jobs:
  test-cleanup-images-fail:
    uses: ./.github/workflows/cleanup-images.yml
    secrets: inherit
    continue-on-error: true
    with:
      runs_on: '[]'

  assert-cleanup-images-fail:
    needs: test-cleanup-images-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-cleanup-images-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected cleanup-images to fail for empty runs_on, got result=$RESULT"
            exit 1
          fi
          echo "cleanup-images correctly failed for empty runs_on"
```

- [ ] **Step 2: Lint locally**

```bash
yamllint -s tests/callers/cleanup-images-fail.yml
```

Expected: silent.

- [ ] **Step 3: Commit**

```bash
git add tests/callers/cleanup-images-fail.yml
git commit -m "test(cleanup-images): add failure-path caller"
```

### Task 12: Push PR-K and open pull request

**Files:** none (git/gh only)

- [ ] **Step 1: Verify PR-K commit log**

```bash
git log --oneline main..HEAD
```

Expected (4 commits):
```
xxxxxxx test(cleanup-images): add failure-path caller
xxxxxxx test(helm-publish): auto-trigger failure caller with assert job
xxxxxxx test(goreleaser): auto-trigger failure caller with assert job
xxxxxxx test(docker-build-multi): auto-trigger failure caller with assert job
```

- [ ] **Step 2: Push branch**

```bash
git push -u origin test/phase-4-atom-failure-coverage
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head test/phase-4-atom-failure-coverage \
  --title "test(callers): phase 4 atom failure-path coverage (PR-K)" \
  --body "$(cat <<'EOF'
## Summary

Closes atom-side failure-path coverage gaps from REVIEW-2026-05-22.md § N Phase 4:

- MED-13 — convert `docker-build-multi-fail`, `goreleaser-fail`, `helm-publish-fail` from `workflow_dispatch`-only to path-filter-triggered with sibling `assert-X-fail` jobs (Phase 2b assertion pattern)
- MED-14 — new `cleanup-images-fail` caller (empty `runs_on` triggers GHA runner-allocation failure)

No production-workflow code changes; pure test additions. Companion PR (PR-J) covers onboard-side coverage (HIGH-11, MED-15, drift wrapper).

Spec: `docs/superpowers/specs/2026-05-22-phase-4-design.md`
Plan: `docs/superpowers/plans/2026-05-22-phase-4-test-coverage-expansion.md`

## Test plan

- [ ] `caller-docker-build-multi-fail / assert-docker-build-multi-fail` PR check green
- [ ] `caller-goreleaser-fail / assert-goreleaser-fail` PR check green
- [ ] `caller-helm-publish-fail / assert-helm-publish-fail` PR check green
- [ ] `caller-cleanup-images-fail / assert-cleanup-images-fail` PR check green
- [ ] `validate.yml` PR check green (actionlint + yamllint)
EOF
)"
```

- [ ] **Step 4: Confirm PR check status**

```bash
gh pr view --json statusCheckRollup -q '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Expected after PR completes: all checks `SUCCESS`. The four `assert-*-fail` jobs should each be `SUCCESS` even though their `needs:` jobs report `FAILURE` — that's the point of the pattern.

If an `assert-X-fail` job is `SUCCESS` but its `needs:` job is also `SUCCESS` (not `FAILURE`): the atom did NOT fail as expected. The atom-level behavior changed. Investigate the atom log and decide whether (a) the atom should fail and needs fixing, or (b) the failure trigger needs to be stronger.

---

## Post-merge: cleanup

### Task 13: Remove worktrees after both PRs are merged

**Files:** none (git only)

- [ ] **Step 1: Verify both PRs are merged**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
gh pr list --state merged --search "test/phase-4-onboard-coverage" --json number,mergedAt
gh pr list --state merged --search "test/phase-4-atom-failure-coverage" --json number,mergedAt
```

Expected: both PRs show a non-null `mergedAt` timestamp.

- [ ] **Step 2: Sync local main**

```bash
git checkout main
git pull --rebase origin main
```

- [ ] **Step 3: Remove worktrees**

```bash
git worktree remove .worktrees/phase-4-onboard
git worktree remove .worktrees/phase-4-atom-fail
git branch -d test/phase-4-onboard-coverage test/phase-4-atom-failure-coverage
```

- [ ] **Step 4: Confirm cleanup**

```bash
git worktree list
```

Expected: only `main` and any unrelated worktrees remain; both phase-4 entries are gone.

---

## Self-Review (writer's checklist — performed at plan-write time)

**1. Spec coverage:**
- C-1 cargo-workspace → Task 1 ✓
- C-2 pnpm-workspace → Task 2 ✓
- C-3 seed-onboarding-status bats → Task 3 ✓
- C-4 onboard-drift wrapper (fixture + caller) → Tasks 4 and 5 ✓
- C-5 *-fail callers auto-run (3 files) → Tasks 8, 9, 10 ✓
- C-6 cleanup-images-fail → Task 11 ✓
- PR-J open → Task 6 ✓
- PR-K open → Task 12 ✓
- Worktree cleanup → Task 13 ✓

**2. Placeholder scan:** No "TBD", "TODO", "fill in" — every step has concrete code or commands.

**3. Type consistency:** Filenames, job names, output names (`status`, `result`), and step IDs (`drift`) are consistent across the spec and across tasks 4–5. Commit-message verbs are uniform (`test(<scope>): …`).
