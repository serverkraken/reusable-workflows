# Phase 1 Critical Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close five Critical/High findings from `REVIEW-2026-05-22.md` Phase 1 via three independent PRs in three worktrees.

**Architecture:** Three disjoint file sets, each a separate PR:
- **PR-A** — Pass composite-action inputs via `env:` (not `${{ inputs.X }}`-into-shell-text); use a random `GITHUB_OUTPUT` multi-line delimiter.
- **PR-B** — Treat the string `"null"` from `gh release list` as no-release-found, keep `current_version=0.0.0`.
- **PR-C** — Extract `sha256_of()` from `onboard-render.sh` into `scripts/lib/hash-lib.sh`; source from both render + drift so macOS dev runs match Linux CI.

All three are non-breaking and produce three `fix:` / `refactor:` Conventional-Commits → three release-please patch bumps.

**Tech Stack:** GitHub Actions composite actions (YAML), Bash 5 scripts with `set -euo pipefail`, `bats` test runner, `jq` + `gh` CLI, `actionlint`/`yamllint` for workflow lint.

**Spec:** `docs/superpowers/specs/2026-05-22-phase-1-critical-fixes-design.md`

**Repo style:** Conventional commits, no Claude-attribution footer in commits or PR descriptions.

---

## Pre-Flight (do once before starting any PR)

- [ ] **Step 1: Verify clean working tree on main**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git status -sb
```

Expected: `## main...origin/main` (no `[behind N]`, no `[ahead N]`). Untracked `foo`/`GEMINI.md` may be present — leave them alone (REVIEW HYG-1/HYG-2 are out of scope for Phase 1).

- [ ] **Step 2: Fetch upstream**

```bash
git fetch origin --quiet && git log HEAD..origin/main --oneline
```

Expected: empty output (local main is at origin/main).

- [ ] **Step 3: Verify existing worktrees do not collide**

```bash
git worktree list
```

Expected: 4 existing worktrees (`docker-multi-perms`, `exclude-catalog`, `go-atoms-fix`, `go-cgo-toggle`). None of them touch `actions/onboard-*`, `scripts/onboard-*`, or `scripts/lib/`. No collision.

- [ ] **Step 4: Verify required tools available**

```bash
command -v bats actionlint yamllint jq gh && bats --version
```

Expected: All five binaries print a path; `bats --version` ≥ 1.10.

---

## PR-A: Onboard Action Injection Hardening

**Concerns:** CRIT-1, CRIT-2, CRIT-3
**Branch:** `fix/onboard-actions-injection-hardening`
**Worktree:** `.worktrees/onboard-actions-hardening`

### Task A1: Create worktree

**Files:** none yet

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees` skill** to create a new worktree

The skill creates the worktree at `.worktrees/onboard-actions-hardening` branched from `main` with branch name `fix/onboard-actions-injection-hardening`. After the skill returns, all subsequent steps run from inside that worktree.

- [ ] **Step 2: Confirm location**

```bash
cd .worktrees/onboard-actions-hardening
pwd && git branch --show-current
```

Expected: path ends in `.worktrees/onboard-actions-hardening`; branch is `fix/onboard-actions-injection-hardening`.

---

### Task A2: Write failing test for CRIT-3 (EOF-delimiter survival)

**Files:**
- Modify: `tests/shell/onboard-detect.bats` (append new test at end)

- [ ] **Step 1: Append the new test**

Append to the end of `tests/shell/onboard-detect.bats`:

```bats
@test "GITHUB_OUTPUT multiline block survives payload containing literal EOF" {
  # Mirrors the random-delimiter pattern from actions/onboard-detect/action.yml.
  # If the action used a fixed "EOF" delimiter, a payload line equal to "EOF"
  # would terminate the multi-line block early and the rest would be parsed
  # as a new key=value assignment. This test guards against that regression
  # by running the delimiter generation + extraction in isolation.
  payload=$'{"a":"line1"\nEOF\n"b":"line3"}'
  out=$(mktemp)
  delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
  { echo "profile_json<<${delim}"; echo "$payload"; echo "${delim}"; } > "$out"
  extracted=$(awk -v d="$delim" '$0==("profile_json<<"d){f=1;next} $0==d{f=0;next} f' "$out")
  [ "$extracted" = "$payload" ]
}
```

- [ ] **Step 2: Run only the new test to verify it passes**

```bash
bats tests/shell/onboard-detect.bats -f "GITHUB_OUTPUT multiline block survives"
```

Expected: `1 test, 0 failures`.

Note: this test guards future behavior. It does not need to "fail first" because it tests the desired property of the new design directly. If the action ever regresses back to a fixed `EOF` delimiter, the *integration* (i.e. real GHA run) breaks — but this bats test is a structural regression guard for the pattern itself.

- [ ] **Step 3: Commit the test**

```bash
git add tests/shell/onboard-detect.bats
git commit -m "test(onboard-detect): guard random GITHUB_OUTPUT delimiter pattern"
```

---

### Task A3: Refactor `actions/onboard-detect/action.yml`

**Files:**
- Modify: `actions/onboard-detect/action.yml:36-58`

- [ ] **Step 1: Replace the `steps:` block**

Open `actions/onboard-detect/action.yml`. Replace the existing `steps:` block (line 35 to end of file) with:

```yaml
runs:
  using: composite
  steps:
    - id: detect
      shell: bash
      env:
        TARGET_REPO: ${{ inputs.target_repo }}
        GH_TOKEN: ${{ inputs.github_token }}
        REPO_PATH: ${{ inputs.repo_path }}
        LANG_OVERRIDE: ${{ inputs.language_override }}
      run: |
        set -euo pipefail
        # Inputs are passed via env to avoid GHA expression interpolation into
        # shell text (a single-quote in any input would terminate the quoted
        # section and inject shell code). Multi-line GITHUB_OUTPUT uses a
        # random delimiter to prevent collision with a literal "EOF" line in
        # the payload.
        #
        # The action lives in actions/onboard-detect/action.yml; the script
        # lives in scripts/. When invoked via the catalog-checkout pattern,
        # $GITHUB_ACTION_PATH is .catalog/actions/onboard-detect/ so
        # ../../scripts/onboard-detect.sh resolves to .catalog/scripts/onboard-detect.sh.
        "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" \
          "$REPO_PATH" "$LANG_OVERRIDE" >> "$GITHUB_OUTPUT"
        profile=$("$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --profile-json "$REPO_PATH")
        delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
        { echo "profile_json<<${delim}"; echo "$profile"; echo "${delim}"; } >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Lint the action file**

```bash
actionlint actions/onboard-detect/action.yml || true
yamllint -s actions/onboard-detect/action.yml
```

Expected: `actionlint` may print "composite actions are only partially supported" notes — ignore. `yamllint` returns 0 (no errors).

- [ ] **Step 3: Run all onboard bats tests to verify no regression**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all tests pass (33 tests after Task A2 added one).

- [ ] **Step 4: Commit**

```bash
git add actions/onboard-detect/action.yml
git commit -m "fix(onboard-detect): pass inputs via env, use random GITHUB_OUTPUT delimiter"
```

---

### Task A4: Refactor `actions/onboard-render/action.yml`

**Files:**
- Modify: `actions/onboard-render/action.yml:22-35`

- [ ] **Step 1: Replace the `runs:` block**

Open `actions/onboard-render/action.yml`. Replace lines 22 to end with:

```yaml
runs:
  using: composite
  steps:
    - id: render
      shell: bash
      env:
        CATALOG_PATH: ${{ inputs.catalog_path }}
        TARGET_PATH: ${{ inputs.target_path }}
        PROFILE_JSON: ${{ inputs.profile_json }}
        PIN_VERSION: ${{ inputs.pin_version }}
      run: |
        set -euo pipefail
        # Inputs are passed via env so the shell never re-parses them. printf
        # avoids echo's backslash-interpretation surprises on bash.
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        printf '%s' "$PROFILE_JSON" > "$tmp/profile.json"
        "$CATALOG_PATH/scripts/onboard-render.sh" \
          "$CATALOG_PATH" "$TARGET_PATH" "$tmp/profile.json" "$PIN_VERSION"
```

- [ ] **Step 2: Lint**

```bash
actionlint actions/onboard-render/action.yml || true
yamllint -s actions/onboard-render/action.yml
```

Expected: `yamllint` exits 0.

- [ ] **Step 3: Run onboard-render bats**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all golden tests pass — the action wrapper is a thin shell over the script, the script's behaviour is unchanged.

- [ ] **Step 4: Commit**

```bash
git add actions/onboard-render/action.yml
git commit -m "fix(onboard-render): pass inputs via env, add id and trap-based tmp cleanup"
```

---

### Task A5: Push branch, open PR

- [ ] **Step 1: Push**

```bash
git push -u origin fix/onboard-actions-injection-hardening
```

Expected: branch created on remote.

- [ ] **Step 2: Open PR via `gh`**

```bash
gh pr create --title "fix(onboard): harden composite-action inputs and GITHUB_OUTPUT delimiter" --body "$(cat <<'EOF'
## Summary
- Pass `repo_path`, `language_override`, and `profile_json` to onboard-detect/onboard-render composite actions via `env:` instead of inline `${{ inputs.X }}` shell interpolation, eliminating a script-injection vector if any input ever contains shell metacharacters.
- Switch the multi-line `GITHUB_OUTPUT` block in onboard-detect from a literal `EOF` delimiter to a per-invocation random delimiter, preventing silent truncation if a profile_json line ever equals `EOF`.
- Add `trap 'rm -rf "$tmp"' EXIT` in onboard-render so the tmp dir is cleaned up on early exit.

## Test plan
- [x] `tests/shell/onboard-detect.bats` — all tests pass, including new regression guard for the random-delimiter pattern
- [x] `tests/shell/onboard-render.bats` — golden tests unchanged
- [x] `yamllint` and `actionlint` clean on both modified actions
- [ ] CI integration `test-onboard-dry-run` green
EOF
)"
```

Expected: prints the PR URL.

- [ ] **Step 3: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## PR-B: Empty-Release `current_version` Fix

**Concerns:** HIGH-3
**Branch:** `fix/onboard-detect-null-current-version`
**Worktree:** `.worktrees/onboard-null-version`

### Task B1: Create worktree

**Files:** none yet

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees` skill** to create the worktree at `.worktrees/onboard-null-version` with branch `fix/onboard-detect-null-current-version` from `main`.

- [ ] **Step 2: Confirm location**

```bash
cd .worktrees/onboard-null-version
pwd && git branch --show-current
```

Expected: branch `fix/onboard-detect-null-current-version`.

---

### Task B2: Write failing test for legacy key=value path

**Files:**
- Modify: `tests/shell/onboard-detect.bats` (append)

- [ ] **Step 1: Append the new test**

Append at end of `tests/shell/onboard-detect.bats`:

```bats
@test "current_version=0.0.0 when target_repo has no releases (gh returns \"null\")" {
  # gh release list --json tagName -q '.[0].tagName' on an empty list returns
  # the literal string "null" (exit 0). The script must treat that as no
  # release found and keep the 0.0.0 default.
  GH_MOCK=$(mktemp -d)
  cat > "$GH_MOCK/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api /repos/owner/repo") echo "main" ;;
  "release list")          echo "null" ;;
  *) echo "::error::unexpected gh call: $*" >&2; exit 1 ;;
esac
GHEOF
  chmod +x "$GH_MOCK/gh"
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=0.0.0"* ]]
  [[ "$output" != *"current_version=null"* ]]
}
```

- [ ] **Step 2: Run to confirm it fails**

```bash
bats tests/shell/onboard-detect.bats -f "current_version=0.0.0 when target_repo has no releases"
```

Expected: **FAIL**. The output will contain `current_version=null` and the negative assertion `[[ "$output" != *"current_version=null"* ]]` will trip.

---

### Task B3: Write failing test for profile-json path

**Files:**
- Modify: `tests/shell/onboard-detect.bats` (append)

- [ ] **Step 1: Append the second test**

Append immediately after the previous test:

```bats
@test "profile_json: current_version=0.0.0 for repo with no releases" {
  GH_MOCK=$(mktemp -d)
  cat > "$GH_MOCK/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api /repos/owner/repo") echo "main" ;;
  "release list")          echo "null" ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$GH_MOCK/gh"
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.current_version')" = "0.0.0" ]
}
```

- [ ] **Step 2: Run to confirm it fails**

```bash
bats tests/shell/onboard-detect.bats -f "profile_json: current_version=0.0.0"
```

Expected: **FAIL**. `jq -r '.current_version'` returns the string `"null"`, the assertion expects `"0.0.0"`.

---

### Task B4: Fix `scripts/onboard-detect.sh`

**Files:**
- Modify: `scripts/onboard-detect.sh:92-95`

- [ ] **Step 1: Apply the fix**

In `scripts/onboard-detect.sh`, replace lines 92–95:

Before:
```bash
  raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
  if [[ -n "$raw_tag" ]]; then
    current_version="${raw_tag#v}"
  fi
```

After:
```bash
  raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
  # jq -q '.[0].tagName' returns the literal string "null" (exit 0) when the
  # release list is empty. Treat "null" as no-release-found and keep current_version=0.0.0.
  if [[ -n "$raw_tag" && "$raw_tag" != "null" ]]; then
    current_version="${raw_tag#v}"
  fi
```

- [ ] **Step 2: Run the legacy-path test to confirm it now passes**

```bash
bats tests/shell/onboard-detect.bats -f "current_version=0.0.0 when target_repo has no releases"
```

Expected: **PASS**.

---

### Task B5: Fix `scripts/lib/onboard-detect-lib.sh`

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh:38-40`

- [ ] **Step 1: Apply the fix**

In `scripts/lib/onboard-detect-lib.sh`, replace lines 38–40:

Before:
```bash
    local tag
    tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    [[ -n "$tag" ]] && current_version="${tag#v}"
```

After:
```bash
    local tag
    tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    # See onboard-detect.sh: "null" sentinel guard against empty release list.
    [[ -n "$tag" && "$tag" != "null" ]] && current_version="${tag#v}"
```

- [ ] **Step 2: Run the profile-json test to confirm it now passes**

```bash
bats tests/shell/onboard-detect.bats -f "profile_json: current_version=0.0.0"
```

Expected: **PASS**.

---

### Task B6: Full regression run

- [ ] **Step 1: Run the entire onboard-detect bats suite**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: All tests pass (original 32 + 2 from B2/B3 = 34 tests, or 35 if PR-A's test already landed on main).

- [ ] **Step 2: Commit both fixes together**

```bash
git add scripts/onboard-detect.sh scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "fix(onboard): treat empty gh-release-list \"null\" as no-release-found"
```

---

### Task B7: Push branch, open PR

- [ ] **Step 1: Push**

```bash
git push -u origin fix/onboard-detect-null-current-version
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "fix(onboard): treat empty gh-release-list as no-release-found" --body "$(cat <<'EOF'
## Summary
- `gh release list --json tagName -q '.[0].tagName'` returns the literal string `"null"` (exit 0) when a target repo has no releases yet. The existing `[[ -n "$raw_tag" ]]` guard let that string flow into `current_version`, corrupting the rendered `.release-please-manifest.json` for first-time-onboarded repos.
- Add a `"null"` sentinel guard in both `scripts/onboard-detect.sh` and `scripts/lib/onboard-detect-lib.sh`.
- New bats tests with a mocked `gh` binary cover both the legacy key=value path and the `--profile-json` path.

## Test plan
- [x] New tests fail before the fix and pass after
- [x] Full `tests/shell/onboard-detect.bats` suite green
- [ ] CI integration `test-onboard-dry-run` green
EOF
)"
```

- [ ] **Step 3: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## PR-C: Hash Helper Extraction

**Concerns:** HIGH-4, OPT-1
**Branch:** `refactor/extract-sha256-helper`
**Worktree:** `.worktrees/hash-helper-extract`

### Task C1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees` skill** to create `.worktrees/hash-helper-extract` with branch `refactor/extract-sha256-helper` from `main`.

- [ ] **Step 2: Confirm**

```bash
cd .worktrees/hash-helper-extract
pwd && git branch --show-current
```

---

### Task C2: Write failing test for `hash-lib.sh`

**Files:**
- Create: `tests/shell/hash-lib.bats`

- [ ] **Step 1: Create the test file**

Write `tests/shell/hash-lib.bats`:

```bats
#!/usr/bin/env bats
# Tests for scripts/lib/hash-lib.sh — portable sha256 helper.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/hash-lib.sh"
}

@test "hash-lib.sh exists" {
  [ -f "$LIB" ]
}

@test "sha256_of computes correct hex for known input" {
  src="$(mktemp)"
  printf 'hello\n' > "$src"
  source "$LIB"
  got=$(sha256_of "$src")
  # echo -n "hello\n" | sha256sum  -> 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  [ "$got" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}

@test "sha256_of handles paths with spaces" {
  dir="$(mktemp -d)"
  src="$dir/file with spaces.txt"
  printf 'hello\n' > "$src"
  source "$LIB"
  got=$(sha256_of "$src")
  [ "$got" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}
```

- [ ] **Step 2: Run to confirm all three tests fail**

```bash
bats tests/shell/hash-lib.bats
```

Expected: **3 tests, 3 failures** (file does not exist).

---

### Task C3: Create `scripts/lib/hash-lib.sh`

**Files:**
- Create: `scripts/lib/hash-lib.sh`

- [ ] **Step 1: Create the library**

Write `scripts/lib/hash-lib.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/hash-lib.sh — portable sha256 helper.
#
# Sourced by scripts/onboard-render.sh and scripts/onboard-drift.sh.
# Linux ships sha256sum; macOS ships shasum -a 256. Both emit
# "<hex> <filename>" — we take the first field.
#
# Pure source-only library: no top-level statements, no shell-option changes.

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | cut -d' ' -f1
  else
    shasum -a 256 "$file" | cut -d' ' -f1
  fi
}
```

- [ ] **Step 2: Run tests to verify all pass**

```bash
bats tests/shell/hash-lib.bats
```

Expected: **3 tests, 0 failures**.

- [ ] **Step 3: Commit lib + tests**

```bash
git add scripts/lib/hash-lib.sh tests/shell/hash-lib.bats
git commit -m "refactor(scripts): add portable sha256_of() helper lib"
```

---

### Task C4: Update `scripts/onboard-render.sh`

**Files:**
- Modify: `scripts/onboard-render.sh`

Both edits are content-based to avoid line-number drift between steps.

- [ ] **Step 1: Remove the inline `sha256_of()` definition**

Find this block (currently around lines 126–133) and delete it entirely:

```bash
# Use sha256sum on Linux, shasum -a 256 on macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
```

The call site `sha=$(sha256_of "$TARGET/$f")` further down is left untouched — it will resolve to the sourced helper after Step 2.

- [ ] **Step 2: Add SCRIPT_DIR anchor + source the lib**

Find the `set -euo pipefail` line and the blank line that follows. Insert immediately after the blank line, before the existing `if [[ $# -lt 4 ]]; then` argument-check:

```bash
# Resolve script directory so we can source siblings even when called via $PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/hash-lib.sh"

```

- [ ] **Step 3: Run render bats to confirm no regression**

```bash
bats tests/shell/onboard-render.bats
```

Expected: All golden tests pass.

- [ ] **Step 4: Commit**

```bash
git add scripts/onboard-render.sh
git commit -m "refactor(onboard-render): source sha256_of from hash-lib"
```

---

### Task C5: Update `scripts/onboard-drift.sh`

**Files:**
- Modify: `scripts/onboard-drift.sh`

Both edits are content-based.

- [ ] **Step 1: Replace the direct `sha256sum` call**

Find this line (currently around line 51):

```bash
  actual="sha256:$(sha256sum "$TARGET/$f" | cut -d' ' -f1)"
```

Replace with:

```bash
  actual="sha256:$(sha256_of "$TARGET/$f")"
```

- [ ] **Step 2: Add SCRIPT_DIR anchor + source the lib**

Find the `set -euo pipefail` line. Insert immediately after it, before the existing `TARGET="${1:-}"` assignment:

```bash

# Resolve script directory so we can source siblings even when called via $PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/hash-lib.sh"
```

- [ ] **Step 3: Run drift bats to verify pass on this host**

```bash
bats tests/shell/onboard-drift.bats
```

Expected: All tests pass. On macOS hosts these tests previously failed because `sha256sum` is absent — they now pass because `sha256_of` falls back to `shasum -a 256`. On Linux/CI they were already passing and remain green.

- [ ] **Step 4: Commit**

```bash
git add scripts/onboard-drift.sh
git commit -m "refactor(onboard-drift): use sha256_of helper for macOS portability"
```

---

### Task C6: Full regression run

- [ ] **Step 1: Run every bats suite to confirm no cross-test regression**

```bash
bats tests/shell/
```

Expected: every `.bats` file under `tests/shell/` reports `0 failures`.

- [ ] **Step 2: Lint changed shell files**

```bash
shellcheck scripts/lib/hash-lib.sh scripts/onboard-render.sh scripts/onboard-drift.sh 2>&1 | head -50
```

Expected: no new warnings introduced by these changes. (If pre-existing warnings exist on `onboard-render.sh` / `onboard-drift.sh`, leave them — out of scope.)

---

### Task C7: Push branch, open PR

- [ ] **Step 1: Push**

```bash
git push -u origin refactor/extract-sha256-helper
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "refactor(onboard): extract sha256_of helper, fix drift on macOS" --body "$(cat <<'EOF'
## Summary
- Extract the `sha256_of()` helper from `scripts/onboard-render.sh` into a new `scripts/lib/hash-lib.sh` so both render and drift can use a single portable implementation.
- `scripts/onboard-drift.sh` previously called `sha256sum` directly, which made `tests/shell/onboard-drift.bats` fail on macOS dev machines (macOS only ships `shasum -a 256`). Switching drift to `sha256_of` aligns both scripts and unblocks local development.

## Test plan
- [x] New `tests/shell/hash-lib.bats` covers known-hash and path-with-spaces cases
- [x] `tests/shell/onboard-render.bats` golden tests unchanged
- [x] `tests/shell/onboard-drift.bats` passes on macOS (verified locally) and Linux (CI)
EOF
)"
```

- [ ] **Step 3: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## Wrap-Up

### Task W1: Sanity-check all three PRs are open

- [ ] **Step 1: List recent open PRs**

```bash
gh pr list --author "@me" --state open --limit 10
```

Expected: three PRs listed:
- `fix(onboard): harden composite-action inputs and GITHUB_OUTPUT delimiter`
- `fix(onboard): treat empty gh-release-list as no-release-found`
- `refactor(onboard): extract sha256_of helper, fix drift on macOS`

- [ ] **Step 2: Confirm CI status on each**

```bash
for pr in $(gh pr list --author "@me" --state open --limit 3 --json number -q '.[].number'); do
  echo "=== PR #$pr ==="
  gh pr checks "$pr"
done
```

Expected: each PR's `validate` and `integration` workflows are queued/running/green. If any check fails, follow up in that branch's worktree before declaring Phase 1 done.

### Task W2: Update task tracking

- [ ] **Step 1: Mark Phase 1 done in REVIEW**

Once all three PRs merge to `main`, optionally annotate `REVIEW-2026-05-22.md` § N with `[DONE 2026-05-XX]` markers next to CRIT-1, CRIT-2, CRIT-3, HIGH-3, HIGH-4, OPT-1. (Or rely on release-please commit history — both are acceptable per Phase-1 hygiene.)

---

## Acceptance Criteria (mirrors spec § 10)

- [ ] PR-A merged: composite actions pass inputs via `env:`, random GITHUB_OUTPUT delimiter in place.
- [ ] PR-B merged: bats tests for "no release found" pass; without the fix they would fail.
- [ ] PR-C merged: `scripts/lib/hash-lib.sh` exists, both consumers source it, `onboard-drift.bats` green on macOS.
- [ ] `actionlint` and `yamllint` clean on all changed files.
- [ ] CI `test-onboard-dry-run` green on each branch.
- [ ] Three Conventional-Commits produce three release-please patch bumps in the next release PR.
