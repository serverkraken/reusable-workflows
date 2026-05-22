# Phase 2b Test Coverage Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two test-coverage gaps from `REVIEW-2026-05-22.md` (HIGH-6, HIGH-7) by adding a `dry_run` input to `semantic-release.yml` + a real-fidelity integration test for it, and adding a failure-path caller for `onboard.yml`.

**Architecture:** Two independent PRs in two worktrees branched from `origin/main`.
- **PR-H** is the substantive one: adds `dry_run: boolean = false` input to `semantic-release.yml`, passes `skip-github-release` + `skip-github-pull-request` through to release-please-action v5, guards the floating-tag-push step with `!inputs.dry_run`, and adds a `test-semantic-release-dry-run` job in `integration.yml`.
- **PR-I** adds two jobs in `integration.yml` only: `test-onboard-failure` (calls `onboard.yml` with a non-existent `target_repos` and `continue-on-error: true`) and `assert-onboard-failure` (verifies `needs.test-onboard-failure.result == 'failure'`).

Both PRs touch `integration.yml`, so PR-I will need to rebase after PR-H merges (same append-conflict pattern as Phase 1 with `onboard-detect.bats`).

**Tech Stack:** GitHub Actions reusable workflows (YAML), `actionlint`/`yamllint`. No new bats, no script changes.

**Spec:** `docs/superpowers/specs/2026-05-22-phase-2b-design.md`

**Repo style:** Conventional Commits, no Claude-attribution footer.

---

## Pre-Flight (do once before starting)

- [ ] **Step 1: Verify working tree state**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git status -sb
```

Expected: `## main...origin/main` possibly `[ahead N]` (local-only Phase-2b spec + plan commits — fine, worktrees will branch from `origin/main`). Untracked `foo`/`GEMINI.md`/`REVIEW-2026-05-22.md` may be present — leave them.

- [ ] **Step 2: Fetch upstream**

```bash
git fetch origin --quiet && git log HEAD..origin/main --oneline
```

Expected: empty output.

- [ ] **Step 3: Verify worktree availability**

```bash
git worktree list
```

Expected: 4 unrelated existing worktrees (`docker-multi-perms`, `exclude-catalog`, `go-atoms-fix`, `go-cgo-toggle`). None touch `semantic-release.yml`, `integration.yml`, or `onboard.yml`. No collision.

---

## PR-H: semantic-release dry_run + integration test

**Concerns:** HIGH-7 (Spec § 4.1 Concern A + § 4.2 Concern B)
**Branch:** `feat/semantic-release-dry-run`
**Worktree:** `.worktrees/semantic-release-dry-run`

### Task H1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees`** to create `.worktrees/semantic-release-dry-run` with branch `feat/semantic-release-dry-run` from `origin/main`.

- [ ] **Step 2: Confirm**

```bash
cd .worktrees/semantic-release-dry-run
pwd && git branch --show-current
```

Expected: branch is `feat/semantic-release-dry-run`.

---

### Task H2: Add `dry_run` input + skip-flags + tag-step guard in `semantic-release.yml`

**Files:**
- Modify: `.github/workflows/semantic-release.yml`

This is a single coherent atom change — all three edits land in one commit.

- [ ] **Step 1: Add `dry_run` input**

Find this block (lines 14-17 currently, the end of the `inputs:` block right before `outputs:`):

```yaml
      release_please_manifest:
        required: false
        type: string
        default: '.release-please-manifest.json'
    outputs:
```

Replace with:

```yaml
      release_please_manifest:
        required: false
        type: string
        default: '.release-please-manifest.json'
      dry_run:
        description: |
          When true, run release-please without creating/updating a release PR,
          creating a GitHub release, or moving floating major/minor tags.
          Used by integration tests; production callers leave at false.
        required: false
        type: boolean
        default: false
    outputs:
```

- [ ] **Step 2: Pass `skip-*` flags to release-please-action**

Find the `release` step (currently lines 69-74):

```yaml
      - uses: googleapis/release-please-action@v5
        id: release
        with:
          token: ${{ steps.app-token.outputs.token }}
          config-file: ${{ inputs.release_please_config }}
          manifest-file: ${{ inputs.release_please_manifest }}
```

Replace with:

```yaml
      - uses: googleapis/release-please-action@v5
        id: release
        with:
          token: ${{ steps.app-token.outputs.token }}
          config-file: ${{ inputs.release_please_config }}
          manifest-file: ${{ inputs.release_please_manifest }}
          skip-github-release: ${{ inputs.dry_run }}
          skip-github-pull-request: ${{ inputs.dry_run }}
```

- [ ] **Step 3: Guard the `Move floating major/minor tags` step**

Find this `if:` condition (currently lines 78-80):

```yaml
        if: |
          steps.release.outputs.release_created == 'true' &&
          !contains(steps.release.outputs.tag_name, '-')
```

Replace with:

```yaml
        if: |
          !inputs.dry_run &&
          steps.release.outputs.release_created == 'true' &&
          !contains(steps.release.outputs.tag_name, '-')
```

- [ ] **Step 4: Lint**

```bash
yamllint -s .github/workflows/semantic-release.yml
actionlint .github/workflows/semantic-release.yml 2>&1 | rg -v 'client-id|client_id' | head -10
```

Expected: yamllint exit 0; actionlint no errors beyond known client-id noise.

- [ ] **Step 5: Diff sanity-check**

```bash
git diff --stat origin/main..HEAD
```

Expected: 1 file changed at this point in the task (no commit yet). Diff shows ~10 line additions in `semantic-release.yml`.

- [ ] **Step 6: Commit the atom change**

```bash
git add .github/workflows/semantic-release.yml
git commit -m "feat(semantic-release): add dry_run input for integration tests"
```

Expected: 1 commit ahead of origin/main.

---

### Task H3: Add `test-semantic-release-dry-run` job in `integration.yml`

**Files:**
- Modify: `.github/workflows/integration.yml`

- [ ] **Step 1: Find the insertion point**

The new job goes between `test-cleanup-images` (ends around line 158) and the `test-onboard-dry-run` section (starts around line 159). Confirm via:

```bash
rg -n 'test-cleanup-images|test-onboard-dry-run' .github/workflows/integration.yml
```

Expected: `test-cleanup-images:` near line 148; `test-onboard-dry-run:` near line 160.

- [ ] **Step 2: Insert the new job**

Find this block (lines 145-160 region, the boundary between cleanup-images and onboard sections):

```yaml
  test-cleanup-images:
    needs:
      - test-trivy-image-happy
      - assert-trivy-image-cve-finds-vulns
    uses: ./.github/workflows/cleanup-images.yml
    with:
      package_name: ${{ github.event.repository.name }}/test-fixture
      keep_stable_versions: 1000
      prerelease_age_days: 365
      runs_on: '["ubuntu-latest"]'

  # ----- onboard dry-run: exercise detect + render against the catalog itself -----
  test-onboard-dry-run:
```

Insert the new job between `test-cleanup-images`'s `runs_on:` line and the `# ----- onboard dry-run` comment. After the edit, that region should read:

```yaml
  test-cleanup-images:
    needs:
      - test-trivy-image-happy
      - assert-trivy-image-cve-finds-vulns
    uses: ./.github/workflows/cleanup-images.yml
    with:
      package_name: ${{ github.event.repository.name }}/test-fixture
      keep_stable_versions: 1000
      prerelease_age_days: 365
      runs_on: '["ubuntu-latest"]'

  # ----- semantic-release dry-run: exercise the atom against the catalog's
  #       own release-please configs WITHOUT mutating remote state.
  #       skip-github-release + skip-github-pull-request flags on the
  #       release-please-action prevent PR/release/tag mutations. The
  #       atom-level !dry_run guard on the "Move floating major/minor tags"
  #       step prevents the git push --force --tags. So this job exercises
  #       app-token mint, checkout, release-please logic, and output wiring
  #       without any production side-effects.
  test-semantic-release-dry-run:
    uses: ./.github/workflows/semantic-release.yml
    secrets: inherit
    with:
      dry_run: true

  # ----- onboard dry-run: exercise detect + render against the catalog itself -----
  test-onboard-dry-run:
```

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/integration.yml
actionlint .github/workflows/integration.yml 2>&1 | rg -v 'client-id|client_id' | head -10
```

Expected: yamllint exit 0; actionlint clean.

- [ ] **Step 4: Diff sanity-check**

```bash
git diff --stat origin/main..HEAD
```

Expected: 2 files in diffstat at this point (1 staged commit on `semantic-release.yml` + 1 unstaged change on `integration.yml`).

- [ ] **Step 5: Commit the test addition**

```bash
git add .github/workflows/integration.yml
git commit -m "test(integration): add semantic-release dry-run coverage"
```

Expected: 2 commits ahead of origin/main.

---

### Task H4: Push + open PR-H

- [ ] **Step 1: Push**

```bash
git push -u origin feat/semantic-release-dry-run
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "feat(semantic-release): add dry_run input + integration coverage" --body "$(cat <<'EOF'
## Summary
- `semantic-release.yml` had no integration test because every real run mutates repo state (release PRs, GitHub releases, force-pushed floating tags). Added a `dry_run: boolean = false` input that passes `skip-github-release` + `skip-github-pull-request` through to `googleapis/release-please-action@v5` and guards the floating-tag-push step with `!inputs.dry_run`. With `dry_run: true` the atom exercises its full code path (App-token mint, checkout, release-please logic, output wiring) without any GitHub-side-effects.
- Added a `test-semantic-release-dry-run` job in `integration.yml` that calls the atom with `dry_run: true` against the catalog's own release-please configs.

## Test plan
- [x] `yamllint`/`actionlint` clean on both modified workflows
- [x] Schema unchanged for existing inputs/outputs/secrets; new input is `required: false` with `default: false` — production callers (`release.yml`, `catalog-release.yml`) get bit-for-bit prior behavior
- [ ] CI: `test-semantic-release-dry-run` green; all existing integration jobs unaffected
EOF
)" 2>&1 | tail -3
```

- [ ] **Step 3: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## PR-I: onboard.yml failure-caller

**Concerns:** HIGH-6 (Spec § 4.3 Concern C)
**Branch:** `test/onboard-failure-caller`
**Worktree:** `.worktrees/onboard-failure-caller`

> **NOTE on file-overlap with PR-H:** Both PRs append jobs to `integration.yml`. PR-H lands its block between `test-cleanup-images` and `test-onboard-dry-run`. PR-I lands its block between `test-onboard-dry-run` and `test-vars-coercion`. The two regions don't overlap textually, but git's merge engine sees both PRs as "modifying the end of the file" — append-pattern conflict likely on the second merge. Resolution strategy in Wrap-Up Task W1.

### Task I1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees`** to create `.worktrees/onboard-failure-caller` with branch `test/onboard-failure-caller` from `origin/main`.

- [ ] **Step 2: Confirm**

```bash
cd .worktrees/onboard-failure-caller
pwd && git branch --show-current
```

---

### Task I2: Add `test-onboard-failure` + `assert-onboard-failure` jobs in `integration.yml`

**Files:**
- Modify: `.github/workflows/integration.yml`

- [ ] **Step 1: Find the insertion point**

The new jobs go between `test-onboard-dry-run` (ends around line 167) and the `test-vars-coercion` comment block (starts around line 169). Confirm via:

```bash
rg -n 'test-onboard-dry-run|test-vars-coercion' .github/workflows/integration.yml
```

Expected: `test-onboard-dry-run:` near line 160; `# ----- vars coercion:` comment block start near line 169.

- [ ] **Step 2: Insert the two new jobs**

Find this block (lines 159-169 region):

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

  # ----- vars coercion: verify type=number + type=boolean inputs accept
```

Insert the two new jobs between the closing `secrets: inherit` of `test-onboard-dry-run` and the `# ----- vars coercion:` comment. After the edit, that region should read:

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

  # ----- onboard failure path: target_repos points at a non-existent repo,
  #       script must fail fast at the gh api lookup. Tests the operator-typo
  #       case that's the most common failure mode in production dispatch.
  #       continue-on-error: true lets the caller-job report failure without
  #       failing the whole integration workflow; assert-onboard-failure
  #       (if: always()) downstream verifies the failure was the expected one.
  test-onboard-failure:
    uses: ./.github/workflows/onboard.yml
    with:
      target_repos: serverkraken/phase-2b-nonexistent-fixture
      language: auto
      dry_run: true
      pin_version: v3
    secrets: inherit
    continue-on-error: true

  assert-onboard-failure:
    needs: test-onboard-failure
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify onboard failed for non-existent repo
        env:
          RESULT: ${{ needs.test-onboard-failure.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::Expected onboard to fail for non-existent target_repos, got result=$RESULT"
            exit 1
          fi
          echo "onboard correctly failed for non-existent repo"

  # ----- vars coercion: verify type=number + type=boolean inputs accept
```

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/integration.yml
actionlint .github/workflows/integration.yml 2>&1 | rg -v 'client-id|client_id' | head -10
```

Expected: yamllint exit 0; actionlint clean.

- [ ] **Step 4: Diff sanity-check**

```bash
git diff --stat origin/main..HEAD
```

Expected: 1 file changed (`integration.yml`), +~30 lines.

---

### Task I3: Commit + push + open PR-I

- [ ] **Step 1: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "test(integration): add onboard failure-path coverage"
```

- [ ] **Step 2: Push**

```bash
git push -u origin test/onboard-failure-caller
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --title "test(integration): add onboard failure-path coverage" --body "$(cat <<'EOF'
## Summary
- `onboard.yml` (620 lines, 4 nested jobs) had only a happy-path caller (`test-onboard-dry-run`) in `integration.yml`. Added a failure-path caller (`test-onboard-failure`) that points `target_repos` at a non-existent repo (`serverkraken/phase-2b-nonexistent-fixture`) — the most common operator-typo failure mode in production. `scripts/onboard-detect.sh` fails the `gh api /repos/...` lookup and exits 1, which propagates up through the onboard workflow.
- `continue-on-error: true` on the caller lets the job report `failure` without failing the whole integration workflow. A downstream `assert-onboard-failure` job with `if: always()` verifies `needs.test-onboard-failure.result == 'failure'` and itself succeeds, providing the structural proof that the failure path is exercised.

## Test plan
- [x] `yamllint`/`actionlint` clean on the modified workflow
- [x] No other files touched; the new jobs are purely additive
- [ ] CI: `test-onboard-failure` reports `failure`; `assert-onboard-failure` reports `success`; the integration workflow as a whole stays green
EOF
)" 2>&1 | tail -3
```

- [ ] **Step 4: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## Wrap-Up

### Task W1: Sanity-check both PRs + handle file-overlap conflict if needed

- [ ] **Step 1: List the two new PRs**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
gh pr list --author "@me" --state open --limit 5
```

Expected: at minimum two new PRs:
- `feat(semantic-release): add dry_run input + integration coverage` (PR-H)
- `test(integration): add onboard failure-path coverage` (PR-I)

- [ ] **Step 2: Confirm CI on each**

```bash
for pr in $(gh pr list --author "@me" --state open --limit 5 --json number,title -q '.[] | select(.title | contains("semantic-release") or contains("onboard failure")) | .number'); do
  echo "=== PR #$pr ==="
  gh pr checks "$pr" 2>&1 | awk -F'\t' '{print $1, $2}' | head -8
done
```

Expected: both PRs' `validate.yml` jobs pass; both PRs' new `integration.yml` jobs run (the `test-semantic-release-dry-run` on PR-H, the `test-onboard-failure` + `assert-onboard-failure` on PR-I).

- [ ] **Step 3 (if PR-H lands first AND PR-I has merge conflict): rebase PR-I**

PR-H lands a block in `integration.yml`. PR-I's branch was created from origin/main BEFORE PR-H landed. Git's merge engine likely flags both PR insertions as conflicting "modifications near the end of the file" even though their text positions don't textually overlap.

If `gh pr merge <PR-I-number> --squash --delete-branch` fails with "merge conflict":

```bash
cd .worktrees/onboard-failure-caller
git fetch origin --quiet
git rebase origin/main
```

Resolve the conflict by keeping BOTH new blocks in `integration.yml`:
- PR-H's `test-semantic-release-dry-run` block (between `test-cleanup-images` and `test-onboard-dry-run`)
- PR-I's `test-onboard-failure` + `assert-onboard-failure` blocks (between `test-onboard-dry-run` and `# ----- vars coercion:`)

After resolving:

```bash
git add .github/workflows/integration.yml
git rebase --continue
yamllint -s .github/workflows/integration.yml   # confirm valid YAML
git push --force-with-lease origin test/onboard-failure-caller
```

Then retry the merge.

---

## Acceptance Criteria (mirrors spec § 8)

- [ ] PR-H merged: `semantic-release.yml` has `dry_run` input; `test-semantic-release-dry-run` job in `integration.yml` runs green.
- [ ] PR-I merged: `test-onboard-failure` + `assert-onboard-failure` jobs in `integration.yml`; `test-onboard-failure` reports `failure`, `assert-onboard-failure` reports `success` (catches the expected failure).
- [ ] `actionlint`/`yamllint` clean on all changed files (modulo known client-id noise).
- [ ] Existing production workflows unchanged: `catalog-release.yml` and `release.yml` (callers of `semantic-release.yml`) get `dry_run: false` by default — byte-identical prior behavior.
- [ ] release-please PR (post-merge): patch bump for PR-I (`test:`), minor bump for PR-H (`feat:`), or combined minor if merged together.
