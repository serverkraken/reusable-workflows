# Drift-Check Render-and-Compare Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `scripts/onboard-drift.sh` + `actions/onboard-drift/action.yml` + `.github/workflows/drift-check.yml` to detect a new `stale-lock` drift status (lock matches working tree, but a fresh render at current catalog state would produce different output).

**Architecture:** Single PR. Drift-script re-renders templates against current catalog state via `onboard-detect.sh --profile-json` + `onboard-render.sh`, byte-compares each lock-tracked file against the freshly-rendered tree. New output `render_error` carries the reason when render fails (status stays `clean` in that case — conservative). Action exposes the new output. Drift-check publish-job surfaces `stale-lock` distinctly in the rolling Issue.

**Tech Stack:** bash 5+, jq, gomplate (existing render dependency), bats-core 1.13, GitHub Actions composite actions.

---

## Pre-flight: Worktree setup

### Task 0.1: Sync main + create worktree

**Files:** none (git only)

- [ ] **Step 1: Sync local main**

Run:
```bash
git fetch origin main
git checkout main
git pull --rebase origin main
```

Expected: `Your branch is up to date with 'origin/main'.`

- [ ] **Step 2: Create worktree**

```bash
git worktree add .worktrees/drift-render-compare -b feat/drift-render-and-compare main
```

Expected: `Preparing worktree (new branch 'feat/drift-render-and-compare')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: new entry `.worktrees/drift-render-compare [feat/drift-render-and-compare]`.

All subsequent tasks (1–5) execute from `.worktrees/drift-render-compare`.

---

## Task 1: Extend onboard-drift.sh with render-and-compare

**Files:**
- Modify: `scripts/onboard-drift.sh`

The existing script (74 lines) computes lock-comparison status. We add a render-and-compare block AFTER the existing logic, only triggered when `$status == "clean"`.

- [ ] **Step 1: Read the current script tail (lines 60-75)**

```bash
sed -n '58,75p' scripts/onboard-drift.sh
```

Expected: the status-decision block + output emission:
```bash
is_mod=0
[[ ${#modified_files[@]} -gt 0 ]] && is_mod=1

if   (( behind && is_mod )); then status="behind+modified"
elif (( behind ));            then status="behind"
elif (( is_mod ));             then status="modified"
else                                status="clean"
fi

echo "status=$status"
if (( is_mod )); then
  # IFS local to subshell so we don't pollute caller.
  echo "modified=$(IFS=,; echo "${modified_files[*]}")"
else
  echo "modified="
fi
```

- [ ] **Step 2: Update the header docstring to mention the new mode**

Find the header comment block at the top of `scripts/onboard-drift.sh` (lines 2-19). Replace the entire docstring with:

```bash
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

The set -euo pipefail line at the bottom stays unchanged (currently line 20).

- [ ] **Step 3: Insert render-and-compare block BEFORE the existing output emission**

In `scripts/onboard-drift.sh`, after the status-decision block (the if/elif/elif/else that sets `$status` based on `$behind`/`$is_mod`, ending around line 66) and BEFORE the `echo "status=$status"` line (around line 68), insert:

```bash
# Render-and-compare check — only when lock-comparison says "clean".
# Catches within-major template evolution: the lock's stored hashes match the
# working tree, but the catalog renderer has since evolved and would now
# produce different output. Conservative on failure: if the re-render itself
# breaks (detect or render exits non-zero), status stays "clean" and we record
# the reason in render_error so it surfaces in the drift-check Issue.
render_error=""
if [[ "$status" == "clean" ]]; then
  scratch=$(mktemp -d)
  # Use a function-scoped trap so the existing set -e behavior stays intact.
  trap 'rm -rf "$scratch"' EXIT

  # Step 1: re-detect the adopter's profile from its source files.
  if ! "$CATALOG/scripts/onboard-detect.sh" --profile-json "$TARGET" \
       > "$scratch/profile.json" 2>"$scratch/detect.err"; then
    render_error="detect-failed:$(tr '\n' ' ' < "$scratch/detect.err" | cut -c1-80)"
  fi

  # Step 2: re-render templates against current catalog state.
  if [[ -z "$render_error" ]]; then
    if ! "$CATALOG/scripts/onboard-render.sh" "$CATALOG" "$scratch/rendered" \
         "$scratch/profile.json" "$CURRENT" 2>"$scratch/render.err"; then
      render_error="render-failed:$(tr '\n' ' ' < "$scratch/render.err" | cut -c1-80)"
    fi
  fi

  # Step 3: byte-compare each lock-tracked file between target and rendered scratch.
  if [[ -z "$render_error" ]]; then
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

    if (( ${#stale_files[@]} > 0 )); then
      status="stale-lock"
      modified_files=("${stale_files[@]}")
      is_mod=1
    fi
  fi
fi
```

- [ ] **Step 4: Add the render_error output line at the end**

After the existing block:
```bash
if (( is_mod )); then
  echo "modified=$(IFS=,; echo "${modified_files[*]}")"
else
  echo "modified="
fi
```

Add a final line (so the script ends with):
```bash
echo "render_error=$render_error"
```

- [ ] **Step 5: Quick smoke test against drift-clean fixture**

The drift-clean fixture's re-render should match the lock (no template evolution between fixture creation and current state). Run:

```bash
CATALOG_CURRENT_VERSION=v3 scripts/onboard-drift.sh tests/fixtures/onboard/drift-clean "$PWD"
```

Expected output:
```
lock_version=v3
current_version=v3
status=clean
modified=
render_error=
```

(All four output lines present, status `clean`, render_error empty.)

If `status=stale-lock` instead: the drift-clean fixture is out of sync with current renderer output — flag as DONE_WITH_CONCERNS so it can be addressed (likely needs fixture regeneration).

- [ ] **Step 6: Run the existing bats suite — no new tests yet, just no regression**

```bash
bats tests/shell/onboard-drift.bats
```

Expected: 8 existing tests still PASS. The render-and-compare block runs on tests that hit the `clean` branch (tests #1 "drift: clean state reports clean" and #7 "drift: re-render at locked catalog_version is byte-reproducible") — for these, the re-render should match the lock files, so `stale-lock` doesn't fire.

If a test fails:
- Test #1 — re-render produces different output than what the bats setup() rendered. Compare the two outputs to identify the divergence. Most likely cause: the bats setup() and the script use different code paths or different working-directory assumptions.
- Test #7 — already verifies re-reproducibility; if it fails, the existing reproducibility assumption breaks (would be a genuine bug, not a Task 1 issue).

- [ ] **Step 7: Commit**

```bash
git add scripts/onboard-drift.sh
git commit -m "feat(onboard-drift): render-and-compare for stale-lock detection"
```

---

## Task 2: Expose render_error on the composite action

**Files:**
- Modify: `actions/onboard-drift/action.yml`

- [ ] **Step 1: Read the current outputs block**

```bash
sed -n '10,25p' actions/onboard-drift/action.yml
```

Expected:
```yaml
outputs:
  status:
    description: 'clean | modified | behind | behind+modified | no-lock'
    value: ${{ steps.drift.outputs.status }}
  modified:
    description: 'Comma-separated list of paths whose hash differs from lock (or has the (missing) suffix)'
    value: ${{ steps.drift.outputs.modified }}
  lock_version:
    description: 'catalog_version field from .github/onboard.lock.json (empty when no-lock)'
    value: ${{ steps.drift.outputs.lock_version }}
```

- [ ] **Step 2: Replace the outputs block with the extended version**

Edit `actions/onboard-drift/action.yml`. Replace the entire `outputs:` block with:

```yaml
outputs:
  status:
    description: |
      clean | modified | behind | behind+modified | no-lock | stale-lock

      stale-lock: lock hashes match working-tree files, but a fresh render of
      the catalog templates at the current catalog state would produce
      different output. Adopter needs re-onboarding to refresh the rendered
      files (and the lock).
    value: ${{ steps.drift.outputs.status }}
  modified:
    description: |
      Comma-separated list of paths whose hash differs from lock (or has the
      (missing) suffix). When status=stale-lock, lists paths whose rendered
      content differs from the lock-tracked hash.
    value: ${{ steps.drift.outputs.modified }}
  lock_version:
    description: 'catalog_version field from .github/onboard.lock.json (empty when no-lock)'
    value: ${{ steps.drift.outputs.lock_version }}
  render_error:
    description: |
      Reason if the render-and-compare check could not run (empty when render
      succeeded or was skipped because status was already non-clean).
      Format: '<phase>:<truncated-stderr>' where phase is detect-failed or
      render-failed.
    value: ${{ steps.drift.outputs.render_error }}
```

The `inputs:` block and `runs:` block stay UNCHANGED.

- [ ] **Step 3: Lint**

```bash
yamllint -s actions/onboard-drift/action.yml
actionlint actions/onboard-drift/action.yml 2>&1 | head
```

Both silent (or pre-existing composite-action false-positives — ignore the "missing jobs/on" lines, those are noise from actionlint not understanding action.yml format).

- [ ] **Step 4: Commit**

```bash
git add actions/onboard-drift/action.yml
git commit -m "feat(onboard-drift): expose render_error output on composite action"
```

---

## Task 3: Surface stale-lock in drift-check publish-job

**Files:**
- Modify: `.github/workflows/drift-check.yml`

Two edits: extend the per-target result JSON to include `render_error`, and extend the publish-job markdown table to include a "Render error" column + a status icon for `stale-lock`.

- [ ] **Step 1: Find the "Emit per-target result" step**

```bash
rg "Emit per-target result" .github/workflows/drift-check.yml -n -A 25
```

Expected: a step around line 100-130 that builds a JSON object via `jq -n`.

- [ ] **Step 2: Add RENDER_ERROR env var + jq --arg**

In the `Emit per-target result` step:

Find the `env:` block, add `RENDER_ERROR` as a new env var. The current env block looks like:
```yaml
        env:
          TARGET: ${{ matrix.target.target }}
          STATUS: ${{ steps.drift.outputs.status || 'error' }}
          MODIFIED: ${{ steps.drift.outputs.modified || '' }}
          LOCK_VERSION: ${{ steps.drift.outputs.lock_version || '' }}
          CURRENT: ${{ needs.enumerate.outputs.current_version }}
```

Add one new line after `LOCK_VERSION`:
```yaml
          RENDER_ERROR: ${{ steps.drift.outputs.render_error || '' }}
```

Then find the `jq -n` invocation that builds the per-target result. Add `--arg render_error "$RENDER_ERROR"` to the jq args and include `render_error:$render_error` in the output object. The whole jq block becomes:

```bash
          jq -n \
            --arg target "$TARGET" \
            --arg status "$STATUS" \
            --arg modified "$MODIFIED" \
            --arg lock_version "$LOCK_VERSION" \
            --arg render_error "$RENDER_ERROR" \
            --arg current "$CURRENT" \
            '{target:$target, status:$status, modified:$modified, lock_version:$lock_version, render_error:$render_error, current:$current}' \
            > "result/$safe.json"
```

- [ ] **Step 3: Find the "Build markdown body" step in the publish job**

```bash
rg "Build markdown body" .github/workflows/drift-check.yml -n -A 5
```

Expected: around line 180.

- [ ] **Step 4: Extend the markdown table header**

In the `Build markdown body` step, find:
```bash
              echo "| Repo | Status | Catalog (lock → current) | Modified files |"
              echo "|---|---|---|---|"
```

Replace with:
```bash
              echo "| Repo | Status | Catalog (lock → current) | Modified files | Render error |"
              echo "|---|---|---|---|---|"
```

- [ ] **Step 5: Add status-icon logic and render_error column in the row builder**

In the same step, find the `for f in results/*.json; do ... done` loop. The current row line looks like:
```bash
                echo "| $t | $s | $ver | $mods |"
```

Replace the entire row-rendering inside the loop. The new logic:
1. Status gets an icon prefix based on the status value
2. render_error gets rendered as an extra column (empty when no error)

Replace from `for f in results/*.json; do` through `done` with:

```bash
              for f in results/*.json; do
                [[ -f "$f" ]] || continue
                t=$(jq -r '.target' "$f")
                s=$(jq -r '.status' "$f")
                lv=$(jq -r '.lock_version' "$f")
                cv=$(jq -r '.current' "$f")
                mods=$(jq -r '.modified' "$f")
                re=$(jq -r '.render_error' "$f")
                [[ -z "$mods" || "$mods" == "null" ]] && mods="—"
                [[ -z "$re" || "$re" == "null" ]] && re="—"
                if [[ -z "$lv" ]]; then
                  ver="— → $cv"
                elif [[ "$lv" == "$cv" ]]; then
                  ver="$cv"
                else
                  ver="$lv → $cv"
                fi
                case "$s" in
                  clean) icon="✅" ;;
                  modified) icon="✏️" ;;
                  behind) icon="↩️" ;;
                  behind+modified) icon="↩️✏️" ;;
                  no-lock) icon="❓" ;;
                  stale-lock) icon="⚠️" ;;
                  *) icon="🔥" ;;
                esac
                echo "| $t | $icon $s | $ver | $mods | $re |"
              done
```

This adds:
- The `re=$(jq -r '.render_error' "$f")` extraction (was missing previously)
- The `[[ -z "$re" || "$re" == "null" ]] && re="—"` normalization
- The `case "$s" in ... esac` status-icon map
- The extra `| $re |` cell at the end of the row line
- The `$icon $s` prefix on the status cell

- [ ] **Step 6: Lint**

```bash
yamllint -s .github/workflows/drift-check.yml
actionlint .github/workflows/drift-check.yml 2>&1 | head
```

Both silent (or pre-existing client-id stale-data noise — ignore).

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/drift-check.yml
git commit -m "feat(drift-check): surface stale-lock + render_error in rolling Issue"
```

---

## Task 4: Bats coverage for stale-lock and render_error

**Files:**
- Modify: `tests/shell/onboard-drift.bats`

Three new tests appended to the end of the file.

- [ ] **Step 1: Append the three new tests**

Open `tests/shell/onboard-drift.bats`. At the END of the file, append:

```bats
@test "drift: clean state stays clean when re-render matches lock files" {
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
  # render_error field is present and empty
  [[ "$output" == *"render_error="* ]]
  # Negative: render_error= followed by nothing-but-newline (no error reason captured)
  echo "$output" | grep -E "^render_error=$" >/dev/null
}

@test "drift: clean state flips to stale-lock when catalog template evolves" {
  # Simulate template evolution: clone the catalog to a scratch dir, edit a
  # template in the scratch copy so re-render would produce different output,
  # then run drift against the unchanged TARGET with the scratch catalog as
  # the catalog-source argument.
  scratch_catalog=$(mktemp -d)
  cp -R "$REPO_ROOT/." "$scratch_catalog/"
  # Append a benign marker to ci.yml.tmpl so the rendered ci.yml diverges.
  echo "# stale-lock-test marker $(date +%s%N)" \
    >> "$scratch_catalog/docs/adopter-templates/skeletons/ci.yml.tmpl"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$scratch_catalog"
  rm -rf "$scratch_catalog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=stale-lock"* ]]
  # The diverged file should appear in the modified list.
  [[ "$output" == *"ci.yml"* ]]
  # render_error stays empty (render succeeded; just produced different content).
  echo "$output" | grep -E "^render_error=$" >/dev/null
}

@test "drift: render failure keeps status=clean and sets render_error" {
  # Force render-failure by stripping gomplate (and other render-time tools)
  # from PATH. The script still needs core tools (bash, jq, mktemp, etc.) for
  # the lock-comparison phase, so we build a minimal PATH that has those but
  # NOT gomplate.
  fake_path=$(mktemp -d)
  for tool in bash jq mktemp sha256sum cat awk grep cut tr head find sort cmp basename dirname date sed; do
    cmd=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$cmd" "$fake_path/$tool"
  done
  CATALOG_CURRENT_VERSION=v3 PATH="$fake_path" run "$DRIFT" "$TARGET" "$REPO_ROOT"
  rm -rf "$fake_path"
  [ "$status" -eq 0 ]
  # Status stays clean (no false-positive stale-lock when render fails).
  [[ "$output" == *"status=clean"* ]]
  # render_error captures the failure phase.
  [[ "$output" =~ render_error=render-failed: ]]
}
```

- [ ] **Step 2: Run the three new tests filtered**

```bash
bats tests/shell/onboard-drift.bats --filter "stays clean when re-render|stale-lock when catalog|render failure keeps status"
```

Expected: 3 tests PASS.

If test #2 (the stale-lock simulation) fails with `status=clean` instead of `stale-lock`: the template edit didn't actually surface in the rendered output. Verify that `docs/adopter-templates/skeletons/ci.yml.tmpl` exists and that appending a comment line would change the rendered file. If the template is conditional and the go-repo fixture doesn't trigger that branch, pick a different template (e.g. `release.yml.tmpl`).

If test #3 (render failure) fails: the `PATH=$fake_path` might still leak some tool via absolute paths in the script. Inspect the script — if it uses absolute paths to gomplate (unlikely, but verify), the test setup needs adjustment.

- [ ] **Step 3: Run full file**

```bash
bats tests/shell/onboard-drift.bats
```

Expected: 11 tests PASS (8 existing + 3 new).

- [ ] **Step 4: Commit**

```bash
git add tests/shell/onboard-drift.bats
git commit -m "test(onboard-drift): bats coverage for stale-lock and render_error"
```

---

## Task 5: Push branch + open PR

**Files:** none (git/gh only)

- [ ] **Step 1: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected (4 commits, newest first):
```
xxxxxxx test(onboard-drift): bats coverage for stale-lock and render_error
xxxxxxx feat(drift-check): surface stale-lock + render_error in rolling Issue
xxxxxxx feat(onboard-drift): expose render_error output on composite action
xxxxxxx feat(onboard-drift): render-and-compare for stale-lock detection
```

- [ ] **Step 2: Push**

```bash
git push -u origin feat/drift-render-and-compare
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head feat/drift-render-and-compare \
  --title "feat(drift-check): render-and-compare for stale-lock detection" \
  --body "$(cat <<'EOF'
## Summary

Closes the architectural gap in `drift-check.yml` that surfaced when blupod-ui's 0.14.3 release `startup_failure`d: drift-check reported `clean` even though the catalog renderer would now produce a `release.yml` containing `artifact-metadata: write` that the adopter's lock didn't have. Lock-comparison alone can't catch within-major template evolution.

This PR extends `actions/onboard-drift`:

- `scripts/onboard-drift.sh` runs an additional render-and-compare pass when lock-comparison says `clean`. Detects via `onboard-detect.sh --profile-json`, re-renders via `onboard-render.sh` at current catalog state, byte-compares each lock-tracked file. Divergence → status=`stale-lock`.
- Render failures (gomplate missing, weird profile, etc.) keep status=`clean` and emit a new `render_error` output recording the reason. Conservative: no false-positive stale-lock from catalog bugs.
- `actions/onboard-drift/action.yml` exposes the new `render_error` output and updates the status doc.
- `.github/workflows/drift-check.yml` surfaces `stale-lock` ⚠️ distinctly in the rolling Issue + new "Render error" column.

Existing 8 bats tests stay green. 3 new tests cover the new code-paths.

Spec: `docs/superpowers/specs/2026-05-24-drift-check-render-and-compare-design.md`
Plan: `docs/superpowers/plans/2026-05-24-drift-check-render-and-compare.md`

## Status semantics (extended)

| Status | Trigger | Action |
|---|---|---|
| `clean` | Lock match + re-render match | All good |
| `modified` | File hash != lock hash | Hand-edit on adopter |
| `behind` | Lock catalog_version != current major | Major bump — re-onboard |
| `behind+modified` | Both | Major bump + hand-edits |
| `no-lock` | No `.github/onboard.lock.json` | Not onboarded |
| **`stale-lock`** (NEW) | Lock match BUT re-render differs | Template evolved within-major — re-onboard |

`stale-lock` is the signal the upcoming `onboard-sweep.yml` will consume to trigger auto-update.

## Test plan

- [ ] `bats tests/shell/onboard-drift.bats` green (11 tests; +3 new)
- [ ] `bats tests/shell/onboard-render.bats` green (39 tests; drift-clean golden still matches)
- [ ] `caller-onboard-drift-happy / drift` PR check green (drift-clean fixture's re-render matches lock → status=clean)
- [ ] `validate.yml` PR check green
- [ ] Post-merge: `workflow_dispatch` drift-check.yml — verify rolling Issue shows ⚠️ `stale-lock` rows for adopters whose locks predate recent template changes (e.g. PR #60 that added artifact-metadata to docker-build-multi.yml)
EOF
)"
```

- [ ] **Step 4: Confirm PR check status**

```bash
gh pr view --json statusCheckRollup -q '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Expected after ~5–10 min: all checks SUCCESS.

---

## Post-merge: cleanup

### Task 6: Remove worktree after merge

**Files:** none (git only)

- [ ] **Step 1: Verify merged**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
gh pr list --state merged --search "feat/drift-render-and-compare" --json number,mergedAt
```

Expected: non-null `mergedAt`.

- [ ] **Step 2: Sync local main**

```bash
git checkout main
git pull --rebase origin main
```

- [ ] **Step 3: Remove worktree + branch**

```bash
git worktree remove .worktrees/drift-render-compare
git branch -d feat/drift-render-and-compare
```

- [ ] **Step 4: Verify**

```bash
git worktree list
```

Expected: no `drift-render-compare` entry remains.

---

## Self-Review (writer's checklist — performed at plan-write time)

**1. Spec coverage:**
- C-1 drift-script render block → Task 1 ✓
- C-2 stale-lock status flip → Task 1 (status assignment when `${#stale_files[@]} > 0`) ✓
- C-3 render-error tolerance → Task 1 (render_error="" default, captured on detect/render failure) ✓
- C-4 action.yml outputs → Task 2 ✓
- C-5 drift-check publish-job → Task 3 ✓
- C-6 bats coverage → Task 4 ✓
- Push + PR → Task 5 ✓
- Cleanup → Task 6 ✓

**2. Placeholder scan:** No TBDs/TODOs. Each step has concrete code or commands.

**3. Type consistency:**
- `render_error` field name consistent across script (Task 1), action (Task 2), workflow JSON (Task 3 step 2), and bats (Task 4).
- `stale-lock` status name consistent across script (Task 1), action doc (Task 2), publish-job icon-map (Task 3 step 5), and bats (Task 4).
- The lock-self-skip in Task 1's render-compare loop matches the spec § 4.1's defensive `&& continue` line.
- Test #3 in Task 4 uses the `fake_path` approach to simulate render failure — same shape as the spec § 4.4 example.

**4. Test count check:** Bats baseline before this PR is 8 (per the existing file). After this PR: 11 (8+3). Task 4 step 3 says "11 tests PASS" — consistent.
