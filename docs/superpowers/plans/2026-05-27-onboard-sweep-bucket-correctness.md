# Onboard Sweep Bucket Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two bugs in `.github/workflows/onboard-sweep.yml`'s `enumerate` job that prevent the weekly sweep from picking up adopters who need re-onboarding or initial onboarding completion.

**Architecture:** Two surgical changes in the enumerate job: (1) add a gomplate-install step so the drift-status script's render-and-compare check can fire (Bug A); (2) reclassify `no-lock` in the bucket case-statement from skipped to update so adopters whose initial onboard PR was never merged get a fresh re-render via the sweep's existing force-push-and-edit-PR mechanism (Bug C). Plus a documentation update in `docs/operations.md` to explain the new `no-lock`-handling semantics.

**Tech Stack:** GitHub Actions YAML, Bash (inline in the workflow's `enumerate` step), the existing `scripts/install-gomplate.sh` (idempotent), bats for shell-test verification, dry-run dispatch for integration verification.

---

## Context

This plan resolves the two outstanding bugs identified during the 2026-05-26 debugging session (Issue #113 / Run 26468366740):

**Bug A — Sweep enumerate is missing gomplate.**
The enumerate job calls `scripts/onboard-sweep-drift-status.sh`, which calls `scripts/onboard-drift.sh`. The drift script's `stale-lock` detector re-renders templates and byte-compares against the working tree. Render requires `gomplate`. When gomplate is missing, the re-render fails and `onboard-drift.sh` is conservative-on-failure: it returns status `clean` even when the lock has actually drifted. The other consumer of `onboard-drift.sh` — the composite action `actions/onboard-drift/action.yml` used by `.github/workflows/drift-check.yml` — installs gomplate explicitly (Issue #66 / PR #111). The sweep enumerate uses the script directly without going through the composite action, so the install never runs. Effect: adopters with stale-lock drift (skytrack-ui in the 2026-05-26 sweep) are misclassified as `clean` and skipped.

**Bug C — Bucket case-statement maps `no-lock` to skipped.**
The enumerate job's bucketing code (`onboard-sweep.yml:118-128`) has:

```bash
case "$status" in
  behind|stale-lock)
    update_csv+="${full},"
    ;;
  clean|modified|behind+modified|no-lock|error|*)
    skipped_csv+="${full}:${status},"
    ;;
esac
```

A repo is in Bucket A (status-doc-onboarded) when it appears in `docs/onboarding-status.md`. If such a repo has no `.github/onboard.lock.json` on its default branch — typically because the initial onboard PR was never merged — drift returns `no-lock`, which the case maps to `skipped`. The fix in PR #137 (`fix/onboard-sweep-stale-pr-guard`) deliberately let stale-version bot PRs through the open-PR-guard so they could be force-rendered; but the bucket case still classifies them as `no-lock → skipped`. Net effect: PR #137 promised "~21 repos updated" in its body, the actual sweep updated zero of them because the bucketing step rejected the entire class.

Both bugs are in the `enumerate` job. They are independent: A affects `stale-lock` detection accuracy; C affects what happens after `no-lock` is correctly detected. Fixing C without A still leaves stale-lock cases (e.g., skytrack-ui) misclassified. Fixing A without C still leaves the 20+ stuck-onboard repos skipped. They go together.

The previously-built `feat/onboard-repo-defaults` feature (PR #139) does not depend on these fixes and should not be confused with them. This plan does not touch the apply-defaults work.

---

## File Structure

**Modify:**
- `.github/workflows/onboard-sweep.yml` — add gomplate install step in `enumerate` job, change one line in the bucket case-statement, add comment explaining the new `no-lock` semantics.
- `docs/operations.md` — extend §Onboard sweep with a brief note on `no-lock` re-render semantics.

**No new files.** No new tests (the bucket logic is inline bash inside YAML and is verified by a dry-run dispatch rather than unit-tested — see Task 4).

---

## Task 1: Install gomplate in the enumerate job (Bug A)

**Files:**
- Modify: `.github/workflows/onboard-sweep.yml` — insert one new step in the `enumerate` job before the `bucket` step.

- [ ] **Step 1: Open the workflow file and locate the bucket step**

Run: `rg -n "id: bucket" .github/workflows/onboard-sweep.yml`
Expected: one line, around the 80s in the current file. Note the exact line number — the new step goes just before it.

- [ ] **Step 2: Insert the install-gomplate step**

Add this step immediately before the `id: bucket` step:

```yaml
      - name: Install gomplate (needed for stale-lock render-and-compare)
        run: sudo ./scripts/install-gomplate.sh
```

The `scripts/install-gomplate.sh` script is idempotent: if the pinned version is already on PATH it's a no-op. This is the same pattern used inside `actions/onboard-drift/action.yml` (which installs gomplate for drift-check's matrix jobs).

Rationale comment (the YAML line should remain self-explanatory but for future readers, the rendering inside the bucket step's drift-status sub-script needs gomplate; without it the stale-lock detector silently falls back to `clean`).

- [ ] **Step 3: Verify YAML syntax**

Run: `actionlint .github/workflows/onboard-sweep.yml`
Expected: clean exit, no warnings. If actionlint is not installed locally:
```bash
which actionlint || echo "not installed locally — relies on CI"
```

If actionlint produces warnings unrelated to this change, leave them alone — only address regressions introduced by this step.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/onboard-sweep.yml
git commit -m "fix(onboard-sweep): install gomplate before bucket step (bug A)"
```

---

## Task 2: Reclassify `no-lock` as update (Bug C)

**Files:**
- Modify: `.github/workflows/onboard-sweep.yml` — single case-statement change in the inline bash of the bucket step.

- [ ] **Step 1: Locate the bucket case-statement**

Run: `rg -n "behind\|stale-lock\)" .github/workflows/onboard-sweep.yml`
Expected: one line in the `enumerate` job's `bucket` step. Read the surrounding 12 lines for context.

- [ ] **Step 2: Apply the case-statement change**

Find this block in `.github/workflows/onboard-sweep.yml`:

```bash
            case "$status" in
              behind|stale-lock)
                update_csv+="${full},"
                ;;
              clean|modified|behind+modified|no-lock|error|*)
                skipped_csv+="${full}:${status},"
                ;;
            esac
```

Replace with:

```bash
            # Bucket A status mapping. Special note on no-lock: a repo in
            # docs/onboarding-status.md with no lock on its default branch
            # typically means an earlier onboard PR was never merged. The
            # sweep's onboard atom is idempotent — it will re-render and
            # force-push the bot branch, then edit the existing PR (if any)
            # to the current catalog version. So no-lock belongs in the
            # update bucket, not skipped. behind+modified stays skipped:
            # those repos have local manual edits that the sweep must not
            # silently overwrite.
            case "$status" in
              behind|stale-lock|no-lock)
                update_csv+="${full},"
                ;;
              clean|modified|behind+modified|error|*)
                skipped_csv+="${full}:${status},"
                ;;
            esac
```

- [ ] **Step 3: Verify the surrounding loop still reads correctly**

Check that the `while IFS= read -r r; do ... done` loop's flow is unchanged outside the case-statement. The change is contained.

Run: `rg -n "update_csv|onboard_csv|skipped_csv" .github/workflows/onboard-sweep.yml | head -20`
Expected: see the three CSVs accumulated and emitted as outputs (`update_targets`, `onboard_targets`, `skipped`). No change to that surface.

- [ ] **Step 4: actionlint check**

Run: `actionlint .github/workflows/onboard-sweep.yml`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/onboard-sweep.yml
git commit -m "fix(onboard-sweep): no-lock + status-doc → update bucket (bug C)"
```

---

## Task 3: Documentation update in `docs/operations.md`

**Files:**
- Modify: `docs/operations.md` — add 1–2 paragraphs in the §Onboard sweep section explaining the new `no-lock` semantics.

- [ ] **Step 1: Find the §Onboard sweep section**

Run: `rg -n "^## Onboard sweep" docs/operations.md`
Expected: one heading match. Inspect the section's structure with `rg -A 40 "^## Onboard sweep" docs/operations.md`.

- [ ] **Step 2: Append the new paragraph at the end of the §Onboard sweep section**

Locate the end of the §Onboard sweep section (before the next `^## ` heading) and add this content:

```markdown
### `no-lock` semantics

When sweep enumerate computes a drift status of `no-lock` for a repo that is listed in `docs/onboarding-status.md`, it now buckets that repo as **update**, not skipped. Background: a repo lands in the status-doc once the onboard atom runs against it, but the actual lock file (`.github/onboard.lock.json`) only lands on the default branch when the atom's PR-A is merged. If PR-A is never merged — common across a catalog major bump where the initial PR's version pin became stale — the repo stays in `no-lock` indefinitely. The sweep's atom is idempotent: it re-renders templates at the current catalog version, force-pushes the existing bot branch, and edits the existing PR (if any) to the current pin. Bucketing `no-lock` as update unblocks that flow.

The `behind+modified` status remains skipped: those repos have local modifications on top of an older lock, and the sweep must not silently overwrite hand edits. Owners of `behind+modified` repos must re-onboard manually or accept the modifications first.

### gomplate is installed in enumerate

The `enumerate` job installs gomplate before the bucketing loop. Gomplate is required by the `stale-lock` render-and-compare detection path inside `scripts/onboard-drift.sh`. Without gomplate, that path is conservative-on-failure and silently returns `clean`, causing stale-lock adopters to be falsely classified and skipped. Installation is idempotent and shared by all per-repo drift-status calls in the same enumerate step.
```

- [ ] **Step 3: Verify markdown structure**

Run:
```bash
rg -n "^##|^###" docs/operations.md | head -40
```

Confirm the new `### no-lock semantics` and `### gomplate is installed in enumerate` subsections sit inside §Onboard sweep, not after the next `## ` boundary.

- [ ] **Step 4: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): document no-lock-as-update and enumerate gomplate"
```

---

## Task 4: Pre-merge dry-run dispatch verification (manual)

**Files:** none modified. This is a verification step that produces evidence the PR is safe to merge.

- [ ] **Step 1: Push the branch and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --base main \
  --title "fix(onboard-sweep): bucket correctness (bug A + bug C)" \
  --body "Fixes the two enumerate-bucket bugs identified during the 2026-05-26 sweep debug. See plan docs/superpowers/plans/2026-05-27-onboard-sweep-bucket-correctness.md."
```

- [ ] **Step 2: Wait for PR-CI to be green**

Required: validate.yml + test-shell.yml + actionlint pass.

- [ ] **Step 3: Branch-scoped dry-run of onboard-sweep**

```bash
gh workflow run onboard-sweep.yml --ref <branch-name> -f dry_run=true
```

- [ ] **Step 4: Inspect the dry-run enumerate output**

```bash
gh run list --workflow onboard-sweep.yml --limit 1
gh run view --log <run-id> | rg "Update batch \(|Fresh batch \(|Skipped \("
```

Expected outcome to confirm both bugs are fixed:

- `Update batch (N repos): ...` — where **N is at least ~21** (the previously-stuck adopters from Issue #113). The exact count depends on the current state of `docs/onboarding-status.md` and open bot PRs, but it must be substantially larger than `0` (the pre-fix value).
- Specifically, **`serverkraken/skytrack-ui`** must appear in `Update batch`, not in `Skipped` with `:clean`. Pre-fix it was classified `clean` due to Bug A. Confirming it now appears in update validates the gomplate fix.
- **`serverkraken/alexandria`** (and similar repos with merged-status-doc-but-no-lock) must appear in `Update batch`, not in `Skipped` with `:no-lock`. Confirming this validates Bug C.
- `Skipped (M): ...` — should still contain `serverkraken/actions-runner-image:behind+modified` (by-design skip) and any repo that genuinely has no drift.

- [ ] **Step 5: Spotcheck**

Pick 2 adopters from the `Update batch` list — ideally one previously `no-lock` (e.g., alexandria) and one previously `clean`-misclassified (skytrack-ui).

For each, verify against the current state:
- `gh api /repos/serverkraken/<adopter>/contents/.github/onboard.lock.json --jq '.content' -r 2>/dev/null | base64 -d 2>/dev/null | jq '{schema_version, catalog_version, defaults_applied_at}'` — see the current lock state.
- `gh pr list --repo serverkraken/<adopter> --state open --search "head:chore/onboard-reusable-workflows"` — confirm whether an open bot PR exists. If yes, the sweep's onboard atom will edit-in-place rather than create a new PR.

The dry-run output should be consistent with these observations — no surprises (e.g., an adopter we expected in update appearing in skipped or vice versa).

- [ ] **Step 6: Merge**

If the dry-run output matches expectation:
- Approve the PR.
- Squash-merge to main. release-please will bump to a patch version (this is a fix, no breaking change to the public reusable-workflows surface).

- [ ] **Step 7: Post-merge live-sweep**

```bash
gh workflow run onboard-sweep.yml --ref main
```

Watch the run; expect the same Update batch count as the dry-run, but this time atoms will run against each target. Investigate any failed atom job — common failure modes:
- `error (error/error)` repos from `onboarding-status.md` may continue to fail at onboard-detect time. Those failures are individual atom-job failures; the rest of the matrix continues thanks to `fail-fast: false`.
- Repos with a v3 stale PR will get edited in-place to v4. Check `gh pr view <num> --repo serverkraken/<repo>` for one of them: title should now read `chore: onboard ...@v4`.

- [ ] **Step 8: Post-sweep spotcheck**

A reasonable subset:
- `gh issue view 113 --repo serverkraken/reusable-workflows | tail -30` — look at the next drift-check Issue update (cron is Monday 06:00 UTC; for an immediate signal also dispatch drift-check manually):
  ```bash
  gh workflow run drift-check.yml --ref main
  ```
- For 2 adopters, expect their row in the drift report to change from `? no-lock` to `← behind` or `✓ clean` depending on whether the user (you) merged the resulting PRs.

---

## Self-Review

**1. Spec coverage**

This plan addresses the two bugs identified in the prior debugging session (Issue #113 root cause analysis). There is no separate spec document — the bug analysis IS the spec. The two bug fixes plus their docs update are independently complete:

- Task 1 → Bug A (gomplate install in enumerate)
- Task 2 → Bug C (no-lock as update)
- Task 3 → Documentation surface
- Task 4 → Verification gate before merge

**2. Placeholder scan**

Checked for TBD / TODO / "implement later" / "add appropriate error handling" / "similar to Task N" — none present. Every step has concrete YAML / bash / commands.

**3. Type consistency**

The bucket case-statement is the only behavioral change. The keys (`behind`, `stale-lock`, `no-lock`, `clean`, `modified`, `behind+modified`, `error`) match those emitted by `scripts/onboard-drift.sh:30-77` and are stable across the codebase. No name drift.

**4. Scope discipline**

This plan deliberately does NOT:
- Extract the bucket-logic to a separate script for unit-testability. That's a refactor, separate scope.
- Touch the `actions/onboard-drift/action.yml` composite action. Its gomplate install path is correct and already covers drift-check.
- Modify `scripts/onboard-drift.sh` or `scripts/onboard-sweep-drift-status.sh`. The bug is in the sweep enumerate's invocation environment, not the scripts themselves.
- Address Bug B (skytrack lock landing on main via PR reopen). That bug was investigated in the prior session and determined to be a GitHub feature (force-push reopening merged PRs) rather than a code bug; mitigation is the apply-repo-defaults `delete_branch_on_merge=true` change in PR #139.
- Re-test the apply-repo-defaults feature. PR #139 owns that surface.

Done. Plan ready.
