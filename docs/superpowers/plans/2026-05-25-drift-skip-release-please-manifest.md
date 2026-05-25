# Drift-Skip `.release-please-manifest.json` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two skip-lines to `scripts/onboard-drift.sh` so the by-design-mutated `.release-please-manifest.json` no longer triggers `modified` or `stale-lock` false-positives in drift reports.

**Architecture:** Single PR, single file change + bats tests. Two `[[ "$f" == ".release-please-manifest.json" ]] && continue` lines — one in the lock-compare loop, one in the render-compare loop (parallel to the existing `.github/onboard.lock.json` skip from PR #107). Header docstring updated to document both skipped files.

**Tech Stack:** bash 5+, jq, bats-core 1.13.

---

## Pre-flight: Worktree setup

### Task 0.1: Sync main + create worktree

**Files:** none (git only)

- [ ] **Step 1: Sync local main**

```bash
git fetch origin main
git checkout main
git pull --rebase origin main
```

Expected: `Your branch is up to date with 'origin/main'.`

- [ ] **Step 2: Create worktree**

```bash
git worktree add .worktrees/drift-skip-manifest -b fix/drift-skip-release-please-manifest main
```

Expected: `Preparing worktree (new branch 'fix/drift-skip-release-please-manifest')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: new entry `.worktrees/drift-skip-manifest [fix/drift-skip-release-please-manifest]`.

All subsequent tasks (1–3) execute from `.worktrees/drift-skip-manifest`.

---

## Task 1: Skip-lines + header docstring update

**Files:**
- Modify: `scripts/onboard-drift.sh`

### Three edits to one file: two skip-lines + header docstring.

- [ ] **Step 1: Update the header docstring**

Find the header comment block at the top (lines 1-23). The current header ends with the stdout description, just above `set -euo pipefail`. Replace the entire header block with:

```bash
#!/usr/bin/env bash
# onboard-drift.sh — compute drift status for a single adopter checkout.
#
# Compares the SHA-256 hashes in <target>/.github/onboard.lock.json against
# the working-tree contents of the same paths, plus catalog-version freshness.
# When lock-comparison says "clean", additionally re-renders the catalog
# templates at the current catalog state and byte-compares the result — if
# the renderer would now produce different files than what the lock recorded,
# emits status=stale-lock. This catches within-major template evolution that
# pure lock-comparison cannot see.
#
# Skipped from both compare loops (by-design adopter mutation):
#   - .github/onboard.lock.json     lock never self-tracks (defensive)
#   - .release-please-manifest.json release-please rewrites it on every release
#
# Usage:   onboard-drift.sh <target-path> <catalog-path>
# Env:     CATALOG_CURRENT_VERSION   string, e.g. "v3" or "v3.0.1"
#                                    Empty → only modified/no-lock/stale-lock
#                                    can fire, behind is suppressed.
#
# Stdout (key=value, sink-friendly for GITHUB_OUTPUT):
#   status=<clean|behind|modified|behind+modified|no-lock|stale-lock>
#   modified=<comma-separated paths>      empty when clean (without re-render)
#                                         lists stale paths when stale-lock
#   lock_version=<value from lock>        absent when no-lock
#   current_version=<value from env>      absent when env unset
#   render_error=<phase:truncated-stderr> empty when render OK or skipped
set -euo pipefail
```

The only new content is the "Skipped from both compare loops" block (5 lines). Everything else is preserved verbatim.

- [ ] **Step 2: Add the skip-line to the lock-compare loop**

Find the lock-compare loop (around lines 53-62). Currently:
```bash
modified_files=()
while IFS= read -r f; do
  if [[ ! -f "$TARGET/$f" ]]; then
    modified_files+=("$f(missing)")
    continue
  fi
  expected=$(jq -r --arg k "$f" '.files[$k]' "$LOCK")
  actual="sha256:$(sha256_of "$TARGET/$f")"
  [[ "$expected" != "$actual" ]] && modified_files+=("$f")
done < <(jq -r '.files | keys[]' "$LOCK")
```

Insert a skip-line at the TOP of the loop body, before the missing-file check:

```bash
modified_files=()
while IFS= read -r f; do
  # .release-please-manifest.json is by-design mutated by release-please-action
  # on every release (rewrites the version-state object). Skip from compare so
  # active-release adopters don't show as perpetually modified.
  [[ "$f" == ".release-please-manifest.json" ]] && continue
  if [[ ! -f "$TARGET/$f" ]]; then
    modified_files+=("$f(missing)")
    continue
  fi
  expected=$(jq -r --arg k "$f" '.files[$k]' "$LOCK")
  actual="sha256:$(sha256_of "$TARGET/$f")"
  [[ "$expected" != "$actual" ]] && modified_files+=("$f")
done < <(jq -r '.files | keys[]' "$LOCK")
```

- [ ] **Step 3: Add the skip-line to the render-compare loop**

Find the render-compare loop (around lines 99-110). Currently:
```bash
    stale_files=()
    while IFS= read -r f; do
      # Lock should never track itself, but guard defensively.
      [[ "$f" == ".github/onboard.lock.json" ]] && continue
      # If the rendered tree doesn't contain this path (profile-conditional
      # template), skip — we can't compare what doesn't exist on both sides.
      [[ -f "$scratch/rendered/$f" ]] || continue
      if ! cmp -s "$TARGET/$f" "$scratch/rendered/$f"; then
        stale_files+=("$f")
      fi
    done < <(jq -r '.files | keys[]' "$LOCK")
```

Insert the manifest-skip immediately after the existing lock-self-skip:

```bash
    stale_files=()
    while IFS= read -r f; do
      # Lock should never track itself, but guard defensively.
      [[ "$f" == ".github/onboard.lock.json" ]] && continue
      # .release-please-manifest.json mutates by-design (see lock-compare loop).
      # Skip here too so the render-compare doesn't surface stale-lock for the
      # same reason.
      [[ "$f" == ".release-please-manifest.json" ]] && continue
      # If the rendered tree doesn't contain this path (profile-conditional
      # template), skip — we can't compare what doesn't exist on both sides.
      [[ -f "$scratch/rendered/$f" ]] || continue
      if ! cmp -s "$TARGET/$f" "$scratch/rendered/$f"; then
        stale_files+=("$f")
      fi
    done < <(jq -r '.files | keys[]' "$LOCK")
```

- [ ] **Step 4: Smoke test — drift-clean fixture still reports clean**

```bash
CATALOG_CURRENT_VERSION=v3 scripts/onboard-drift.sh tests/fixtures/onboard/drift-clean "$PWD"
```

Expected:
```
lock_version=v3
current_version=v3
status=clean
modified=
render_error=
```

(Unchanged from pre-fix behavior — the fixture's manifest matches the lock so the skip is moot for this case. The smoke test verifies we didn't break the happy path.)

- [ ] **Step 5: Run existing bats — no regression**

```bash
bats tests/shell/onboard-drift.bats
```

Expected: 11 tests PASS (unchanged from current count).

If any existing test fails, the script change introduced a regression — re-read the diff carefully. The added lines are pure skips; they shouldn't change anything for tests that don't involve the manifest.

- [ ] **Step 6: Commit**

```bash
git add scripts/onboard-drift.sh
git commit -m "fix(onboard-drift): skip .release-please-manifest.json from compare loops (#66 follow-up)"
```

---

## Task 2: Bats coverage for the two new skip-paths

**Files:**
- Modify: `tests/shell/onboard-drift.bats` (append 2 tests)

- [ ] **Step 1: Append two new tests at the END of the file**

Open `tests/shell/onboard-drift.bats`. Append these two tests at the end:

```bats
@test "drift: mutated .release-please-manifest.json does NOT count as modified" {
  # Simulate release-please updating the manifest after a release.
  echo '{".":"0.32.0"}' > "$TARGET/.release-please-manifest.json"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # Should still report clean — manifest is skipped from the lock-compare loop.
  [[ "$output" == *"status=clean"* ]]
  # And modified should NOT mention the manifest.
  [[ "$output" != *"release-please-manifest"* ]]
}

@test "drift: divergent manifest in render-compare does NOT count as stale-lock" {
  # Mutate working-tree manifest AND update lock to record the new hash so the
  # lock-compare loop sees match. The render-compare loop then re-renders the
  # original initial-state manifest, which would byte-diverge from the
  # working-tree's "1.2.3" content. With the skip, the manifest is excluded
  # → no divergence detected → stays clean (instead of stale-lock).
  echo '{".":"1.2.3"}' > "$TARGET/.release-please-manifest.json"
  new_hash="sha256:$(sha256_of "$TARGET/.release-please-manifest.json")"
  jq --arg h "$new_hash" '.files[".release-please-manifest.json"] = $h' \
    "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"

  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
  [[ "$output" != *"release-please-manifest"* ]]
}
```

The bats `setup()` (lines 15-32 of the file) already defines `$DRIFT`, `$TARGET`, `$REPO_ROOT`, and sources `hash-lib.sh` so `sha256_of` is available. New tests inherit that.

- [ ] **Step 2: Run filtered**

```bash
bats tests/shell/onboard-drift.bats --filter "release-please-manifest"
```

Expected: 2 tests PASS.

If test #1 ("mutated manifest does NOT count as modified") fails with `status=modified`: Task 1's lock-compare skip is missing or wrong. Re-read the diff for the lock-compare loop.

If test #2 ("divergent manifest does NOT count as stale-lock") fails with `status=stale-lock`: Task 1's render-compare skip is missing or wrong. Re-read the diff for the render-compare loop.

If test #2 reports `render_error` non-empty instead of stale-lock: that means render failed before the compare loop even runs — likely a gomplate/path issue. Should not happen in this local environment if gomplate is on PATH.

- [ ] **Step 3: Run full bats file**

```bash
bats tests/shell/onboard-drift.bats
```

Expected: 13 tests PASS (was 11, +2 new).

- [ ] **Step 4: Run full bats suite to confirm no cross-test pollution**

```bash
bats tests/shell/
```

Expected: count grew by exactly 2 (the same 2 new tests in onboard-drift.bats).

- [ ] **Step 5: Commit**

```bash
git add tests/shell/onboard-drift.bats
git commit -m "test(onboard-drift): bats coverage for manifest-skip in modified + stale-lock paths"
```

---

## Task 3: Push branch + open PR

**Files:** none (git/gh only)

- [ ] **Step 1: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected (2 commits, newest first):
```
xxxxxxx test(onboard-drift): bats coverage for manifest-skip in modified + stale-lock paths
xxxxxxx fix(onboard-drift): skip .release-please-manifest.json from compare loops (#66 follow-up)
```

- [ ] **Step 2: Push**

```bash
git push -u origin fix/drift-skip-release-please-manifest
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head fix/drift-skip-release-please-manifest \
  --title "fix(onboard-drift): skip .release-please-manifest.json from compare" \
  --body "$(cat <<'EOF'
## Summary

Follow-up to #66. The `.release-please-manifest.json` is rendered by `onboard-render.sh` at first-onboard time (initial version-state) and then by-design rewritten by `release-please-action` after every release. Drift-check was treating that mutation as `modified` (skytrack-ui in the latest Issue) — a perpetual false-positive for any active-release adopter.

## Fix

Two skip-lines in `scripts/onboard-drift.sh`, one in each `.files{}`-iterating loop:

- **Lock-compare loop** — prevents the false-positive `modified` status (the visible issue from #66)
- **Render-compare loop** — prevents the equivalent false-positive `stale-lock` (added in PR #107) for the same root cause

Pattern parallels the existing `.github/onboard.lock.json` defensive skip from PR #107. Header docstring updated to document both files that are skipped from compare.

**No lock-schema migration.** The manifest entry stays in existing adopter locks; drift just ignores it. Works against ALL existing adopters immediately, no re-onboarding required.

## Out of scope

- Lock-side removal (would invalidate all existing adopter locks)
- `release-please-config.json` skip — kept tracked. Hand-edits to the config are real drift worth flagging.
- Configurable drift-ignore list — YAGNI for one file.

Spec: `docs/superpowers/specs/2026-05-25-drift-skip-release-please-manifest-design.md`
Plan: `docs/superpowers/plans/2026-05-25-drift-skip-release-please-manifest.md`

## Test plan

- [ ] `bats tests/shell/onboard-drift.bats` green (13 tests; +2 new)
- [ ] `bats tests/shell/` full suite green (no cross-test pollution)
- [ ] `caller-onboard-drift-happy / drift` PR check green (drift-clean fixture unaffected)
- [ ] `validate.yml` PR check green
- [ ] Post-merge: trigger drift-check.yml and verify the next rolling Issue does NOT show `.release-please-manifest.json` in "Modified files" column for active-release adopters
EOF
)"
```

- [ ] **Step 4: Confirm PR check status**

```bash
gh pr view --json statusCheckRollup -q '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Expected after ~3-5 min: all checks SUCCESS.

---

## Post-merge: cleanup

### Task 4: Remove worktree after merge

**Files:** none (git only)

- [ ] **Step 1: Verify merged**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
gh pr list --state merged --search "fix/drift-skip-release-please-manifest" --json number,mergedAt
```

Expected: non-null `mergedAt`.

- [ ] **Step 2: Sync local main**

```bash
git checkout main
git pull --rebase origin main
```

- [ ] **Step 3: Remove worktree + branch**

```bash
git worktree remove .worktrees/drift-skip-manifest
git branch -d fix/drift-skip-release-please-manifest
```

- [ ] **Step 4: Verify**

```bash
git worktree list
```

Expected: no `drift-skip-manifest` entry remains.

- [ ] **Step 5: Trigger drift-check to confirm Issue #66 follow-up**

```bash
gh workflow run drift-check.yml --ref main
sleep 30
gh run list --workflow drift-check.yml --limit 1
```

After the run completes (~5–10 min), check the rolling "Onboarding Drift Report" Issue. Expected: skytrack-ui (and any other active-release adopter) NO LONGER shows `.release-please-manifest.json` in the "Modified files" column.

---

## Self-Review (writer's checklist — performed at plan-write time)

**1. Spec coverage:**
- C-1 lock-compare loop skip → Task 1 Step 2 ✓
- C-2 render-compare loop skip → Task 1 Step 3 ✓
- C-3 bats coverage (2 tests) → Task 2 ✓
- C-4 header docstring update → Task 1 Step 1 ✓
- Push + PR → Task 3 ✓
- Cleanup + verification → Task 4 ✓

**2. Placeholder scan:** No TBDs/TODOs. Each step has concrete code or commands.

**3. Type consistency:**
- The skip-line string `[[ "$f" == ".release-please-manifest.json" ]] && continue` is byte-identical between Task 1 Step 2 (lock-compare) and Task 1 Step 3 (render-compare). ✓
- Bats test names use consistent prefixes (`drift: ...`) matching existing tests. ✓
- Test count progression: existing 11 → +2 = 13. Mentioned consistently in Task 2 Step 3 and Task 3 PR body. ✓
- Commit messages match: Task 1's `fix(onboard-drift): skip ...` and Task 2's `test(onboard-drift): ...` are both `onboard-drift`-scoped, parallel structure. ✓
