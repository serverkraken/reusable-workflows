# Onboard Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `.github/workflows/onboard-sweep.yml` — a weekly Monday 07:00 UTC cron that (a) re-onboards onboarded adopters with `status=behind` OR `status=stale-lock` and (b) fresh-onboards `serverkraken/*` repos not yet in `docs/onboarding-status.md`, skipping repos with the GitHub topic `no-serverkraken-onboard`.

**Architecture:** One workflow with four jobs: enumerate (list org repos → filter opt-out → cross-reference status doc → compute drift for onboarded → bucket into update vs fresh vs skipped), update-batch (calls existing `onboard.yml` for the update targets), fresh-batch (calls `onboard.yml` for fresh targets), summary (posts digest comment on the rolling Onboarding Drift Report Issue). Single helper script `scripts/onboard-sweep-drift-status.sh` clones an adopter and runs `onboard-drift.sh` against it. No production-workflow changes — purely additive operational tooling.

**Tech Stack:** GitHub Actions scheduled workflow, `gh api --paginate`, bash 5+, jq, bats-core 1.13, `actions/create-github-app-token@v3`, existing `actions/onboard-drift` action.

**Spec evolution (since 2026-05-23):** The render-and-compare feature (PR #107, merged 2026-05-24) added a new drift status `stale-lock`. This plan extends the spec's bucket-logic to route `stale-lock` repos into the update batch alongside `behind` — that integration was the explicit purpose of PR #107.

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
git worktree add .worktrees/onboard-sweep -b feat/onboard-sweep main
```

Expected: `Preparing worktree (new branch 'feat/onboard-sweep')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: new entry `.worktrees/onboard-sweep [feat/onboard-sweep]`.

All subsequent tasks (1–8) execute from `.worktrees/onboard-sweep`.

---

## Task 1: Helper script `scripts/onboard-sweep-drift-status.sh`

**Files:**
- Create: `scripts/onboard-sweep-drift-status.sh`

Tiny driver that clones an adopter and runs `onboard-drift.sh` against the clone, emitting just the status value to stdout.

- [ ] **Step 1: Write the script**

Create `scripts/onboard-sweep-drift-status.sh` with this exact content:

```bash
#!/usr/bin/env bash
# onboard-sweep-drift-status.sh <owner/repo> <current_major>
# Clones the adopter to a tmpdir, runs scripts/onboard-drift.sh against the
# clone, emits the status value (e.g. "clean", "behind", "stale-lock") to
# stdout. Used by .github/workflows/onboard-sweep.yml's enumerate job to
# bucket onboarded repos into update vs skipped.
#
# Requires GH_TOKEN env var with read access to the target repo.
# When env var ONBOARD_SWEEP_TARGET_PATH is set, skips the clone and runs
# drift against that path directly — used by bats tests to avoid network.
set -euo pipefail

TARGET="${1:-}"
CURRENT="${2:-}"

if [[ -z "$TARGET" || -z "$CURRENT" ]]; then
  echo "::error::usage: $0 <owner/repo> <current_major>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${ONBOARD_SWEEP_TARGET_PATH:-}" ]]; then
  # Test mode — caller already prepared the target tree.
  target_path="$ONBOARD_SWEEP_TARGET_PATH"
else
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN env var required to clone $TARGET" >&2
    exit 1
  fi
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  if ! git clone --depth=1 --quiet \
       "https://x-access-token:${GH_TOKEN}@github.com/${TARGET}.git" \
       "$tmpdir/target" 2>/dev/null; then
    # Clone failure → emit "error" so the caller can bucket it as skipped.
    echo "error"
    exit 0
  fi
  target_path="$tmpdir/target"
fi

output=$(CATALOG_CURRENT_VERSION="$CURRENT" \
  "$SCRIPT_DIR/onboard-drift.sh" "$target_path" "$CATALOG_ROOT")
echo "$output" | grep '^status=' | cut -d= -f2-
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/onboard-sweep-drift-status.sh
```

- [ ] **Step 3: Local smoke test against drift-clean fixture (test mode)**

```bash
ONBOARD_SWEEP_TARGET_PATH=tests/fixtures/onboard/drift-clean \
  scripts/onboard-sweep-drift-status.sh serverkraken/dummy v3
```

Expected output (single line): `clean`

(The drift-clean fixture should report clean after the Phase 6 regen + PR #107 fix.)

If the output is `stale-lock` or `error`: the drift script doesn't behave as expected against the fixture. Verify the fixture state independently:
```bash
CATALOG_CURRENT_VERSION=v3 scripts/onboard-drift.sh tests/fixtures/onboard/drift-clean "$PWD"
```
Should show `status=clean`.

- [ ] **Step 4: Commit**

```bash
git add scripts/onboard-sweep-drift-status.sh
git commit -m "feat(onboard-sweep): drift-status helper for bucket-logic"
```

---

## Task 2: Bats coverage for helper script

**Files:**
- Create: `tests/shell/onboard-sweep-drift-status.bats`

The helper has two paths: clone-mode (network, untestable in bats) and test-mode (uses `ONBOARD_SWEEP_TARGET_PATH`). Bats covers only the test-mode path.

- [ ] **Step 1: Write the bats file**

Create `tests/shell/onboard-sweep-drift-status.bats`:

```bash
#!/usr/bin/env bats
# Tests for scripts/onboard-sweep-drift-status.sh
#
# The script clones an adopter and runs onboard-drift.sh against the clone.
# Bats uses the ONBOARD_SWEEP_TARGET_PATH env var to skip the clone and point
# the script at a pre-prepared local target — this avoids network access and
# keeps tests deterministic.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/onboard-sweep-drift-status.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
}

@test "drift-status: drift-clean fixture reports clean in test mode" {
  ONBOARD_SWEEP_TARGET_PATH="$FIX/drift-clean" \
    run "$SCRIPT" serverkraken/dummy v3
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "drift-status: hand-edited adopter reports modified" {
  # Copy the drift-clean fixture so we can tamper with it.
  tmp=$(mktemp -d)
  cp -R "$FIX/drift-clean/." "$tmp/"
  echo "# tampered" >> "$tmp/.github/workflows/ci.yml"
  ONBOARD_SWEEP_TARGET_PATH="$tmp" \
    run "$SCRIPT" serverkraken/dummy v3
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "modified" ]
}

@test "drift-status: adopter on old major reports behind" {
  tmp=$(mktemp -d)
  cp -R "$FIX/drift-clean/." "$tmp/"
  jq '.catalog_version = "v1"' "$tmp/.github/onboard.lock.json" \
    > "$tmp/.github/onboard.lock.json.new"
  mv "$tmp/.github/onboard.lock.json.new" "$tmp/.github/onboard.lock.json"
  ONBOARD_SWEEP_TARGET_PATH="$tmp" \
    run "$SCRIPT" serverkraken/dummy v3
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "behind" ]
}

@test "drift-status: missing args exits 1 with usage message" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "drift-status: missing GH_TOKEN in clone mode exits 1" {
  # No ONBOARD_SWEEP_TARGET_PATH set → script tries clone mode.
  # No GH_TOKEN → script errors out before attempting any network call.
  unset GH_TOKEN
  run "$SCRIPT" serverkraken/dummy v3
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN"* ]]
}
```

- [ ] **Step 2: Run the bats file**

```bash
bats tests/shell/onboard-sweep-drift-status.bats
```

Expected: 5 tests, all PASS.

If a test fails:
- Test #1 (clean): the drift-clean fixture isn't reporting clean. Check with `CATALOG_CURRENT_VERSION=v3 scripts/onboard-drift.sh tests/fixtures/onboard/drift-clean "$PWD"` directly.
- Test #2 (modified): the script isn't propagating the modified status. Inspect the `grep '^status=' | cut -d= -f2-` line — it must extract exactly the value after `status=`.
- Test #5 (GH_TOKEN): make sure the test runs with `unset GH_TOKEN` actually working in the bats subshell.

- [ ] **Step 3: Run full bats suite to confirm no cross-test pollution**

```bash
bats tests/shell/
```

Expected: existing tests still pass, +5 for the new file.

- [ ] **Step 4: Commit**

```bash
git add tests/shell/onboard-sweep-drift-status.bats
git commit -m "test(onboard-sweep): bats coverage for drift-status helper"
```

---

## Task 3: onboard-sweep.yml skeleton + enumerate job

**Files:**
- Create: `.github/workflows/onboard-sweep.yml`

This task creates the workflow file with triggers, top-level concurrency/permissions, and the enumerate job. Subsequent tasks add update-batch, fresh-batch, and summary jobs.

- [ ] **Step 1: Write the workflow file (header + enumerate job only)**

Create `.github/workflows/onboard-sweep.yml`:

```yaml
# .github/workflows/onboard-sweep.yml
# Weekly auto-update + auto-onboard sweep.
# - Re-onboards adopters with status=behind OR status=stale-lock against the
#   current catalog major.
# - Fresh-onboards serverkraken/* repos not yet in onboarding-status.md.
# - Skips repos with topic `no-serverkraken-onboard` (opt-out).
#
# Schedule: Monday 07:00 UTC, 1h after drift-check.yml (06:00 UTC) so the
# drift report Issue already exists when sweep posts its summary comment.
#
# Operational tool — not a public reusable workflow.
name: onboard-sweep
on:
  schedule:
    - cron: '0 7 * * 1'
  workflow_dispatch:
    inputs:
      dry_run:
        description: 'When true, enumerate + bucket but skip the batch jobs.'
        required: false
        type: boolean
        default: false

concurrency:
  group: onboard-sweep-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  enumerate:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    outputs:
      update_targets: ${{ steps.bucket.outputs.update_targets }}
      onboard_targets: ${{ steps.bucket.outputs.onboard_targets }}
      skipped: ${{ steps.bucket.outputs.skipped }}
      current_version: ${{ steps.ver.outputs.current_version }}
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0  # need full tag history for git describe

      - id: ver
        name: Derive current catalog major
        run: |
          set -euo pipefail
          tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
          major=$(echo "$tag" | sed -E 's/^v([0-9]+).*$/v\1/')
          echo "current_version=$major" >> "$GITHUB_OUTPUT"
          echo "Resolved current major: $major (from tag $tag)"

      - name: Mint App token for org-wide enumerate + drift
        id: app-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
          private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
          owner: serverkraken

      - id: list
        name: List all org repos
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          set -euo pipefail
          gh api -X GET '/orgs/serverkraken/repos' \
            --paginate -f per_page=100 \
            -q '.[] | select(.archived | not) | select(.name | test("^(reusable-workflows|\\.github)$") | not) | {name: .name, topics: .topics}' \
            > all-repos.json
          count=$(jq -s 'length' all-repos.json)
          echo "Total in-scope repos (before opt-out filter): $count"

      - id: bucket
        name: Bucket repos into update vs fresh-onboard vs skip
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          CURRENT: ${{ steps.ver.outputs.current_version }}
        run: |
          set -euo pipefail

          # Step 1: filter out opt-out topic
          jq -c 'select(.topics | index("no-serverkraken-onboard") | not)' all-repos.json > in-scope.json

          # Step 2: parse onboarding-status.md for existing rows
          onboarded=$(grep -oE '^\| serverkraken/[A-Za-z0-9._-]+ \|' docs/onboarding-status.md 2>/dev/null | \
                      sed -E 's/^\| serverkraken\/([A-Za-z0-9._-]+) \|.*/\1/' | sort -u || true)

          update_csv=""
          onboard_csv=""
          skipped_csv=""

          while IFS= read -r r; do
            name=$(echo "$r" | jq -r '.name')
            full="serverkraken/$name"

            # Duplicate-PR guard: skip if an open bot PR already exists.
            open_pr=$(gh api -X GET "/repos/$full/pulls" \
              -f state=open \
              -q '[.[] | select(.user.login == "serverkraken-release-bot[bot]") | select(.head.ref | test("^chore/(onboard-reusable-workflows|remove-legacy-workflows)$"))] | length' 2>/dev/null || echo "0")
            if [[ "$open_pr" -gt 0 ]]; then
              skipped_csv+="${full}:open-pr,"
              continue
            fi

            if echo "$onboarded" | grep -qx "$name"; then
              # Bucket A: existing onboarded. Compute drift.
              status=$(scripts/onboard-sweep-drift-status.sh "$full" "$CURRENT") || status="error"
              case "$status" in
                behind|stale-lock)
                  update_csv+="${full},"
                  ;;
                clean|modified|behind+modified|no-lock|error|*)
                  skipped_csv+="${full}:${status},"
                  ;;
              esac
            else
              # Bucket B: fresh candidate (not in status doc).
              onboard_csv+="${full},"
            fi
          done < <(jq -c '.' in-scope.json)

          # Strip trailing commas
          update_csv="${update_csv%,}"
          onboard_csv="${onboard_csv%,}"
          skipped_csv="${skipped_csv%,}"

          echo "update_targets=$update_csv" >> "$GITHUB_OUTPUT"
          echo "onboard_targets=$onboard_csv" >> "$GITHUB_OUTPUT"
          echo "skipped=$skipped_csv" >> "$GITHUB_OUTPUT"

          uc=$([[ -n "$update_csv" ]] && echo "$update_csv" | tr ',' '\n' | wc -l | tr -d ' ' || echo 0)
          oc=$([[ -n "$onboard_csv" ]] && echo "$onboard_csv" | tr ',' '\n' | wc -l | tr -d ' ' || echo 0)
          sc=$([[ -n "$skipped_csv" ]] && echo "$skipped_csv" | tr ',' '\n' | wc -l | tr -d ' ' || echo 0)
          echo "Update batch ($uc repos): $update_csv"
          echo "Fresh batch ($oc repos): $onboard_csv"
          echo "Skipped ($sc): $skipped_csv"
```

Note the `chore/(onboard-reusable-workflows|remove-legacy-workflows)` regex for the duplicate-PR guard. This matches `onboard.yml`'s default branch names — verified earlier:
- `add_branch_name` default: `chore/onboard-reusable-workflows`
- `cleanup_branch_name` default: `chore/remove-legacy-workflows`

Also note: the bucket-logic case includes both `behind` AND `stale-lock` for update_targets — this is the integration with PR #107's new status.

- [ ] **Step 2: Lint**

```bash
yamllint -s .github/workflows/onboard-sweep.yml
actionlint .github/workflows/onboard-sweep.yml 2>&1 | head
```

Both silent (or pre-existing client-id stale-data noise — ignore).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/onboard-sweep.yml
git commit -m "feat(onboard-sweep): scheduled workflow + enumerate/bucket job"
```

---

## Task 4: update-batch + fresh-batch jobs

**Files:**
- Modify: `.github/workflows/onboard-sweep.yml`

Add two batch jobs that call `onboard.yml` with the bucketed target lists.

- [ ] **Step 1: Append the two batch jobs**

Open `.github/workflows/onboard-sweep.yml`. After the `enumerate:` job's closing block (after the last `echo "Skipped..."` step), add two new top-level job entries inside `jobs:` (so they're siblings of `enumerate:`):

```yaml
  update-batch:
    needs: enumerate
    if: needs.enumerate.outputs.update_targets != ''
    uses: ./.github/workflows/onboard.yml
    secrets: inherit
    with:
      target_repos: ${{ needs.enumerate.outputs.update_targets }}
      language: auto
      pin_version: ${{ needs.enumerate.outputs.current_version }}
      # Forward dry_run from the top-level dispatch input (default false for cron).
      # workflow_call inputs require fromJSON wrap for boolean conversion
      # (cf. memory: troubleshooting_gha_type_coercion).
      dry_run: ${{ fromJSON(inputs.dry_run || 'false') }}

  fresh-batch:
    needs: enumerate
    if: needs.enumerate.outputs.onboard_targets != ''
    uses: ./.github/workflows/onboard.yml
    secrets: inherit
    with:
      target_repos: ${{ needs.enumerate.outputs.onboard_targets }}
      language: auto
      pin_version: ${{ needs.enumerate.outputs.current_version }}
      dry_run: ${{ fromJSON(inputs.dry_run || 'false') }}
```

- [ ] **Step 2: Lint**

```bash
yamllint -s .github/workflows/onboard-sweep.yml
actionlint .github/workflows/onboard-sweep.yml 2>&1 | head
```

Both silent.

If actionlint complains about `inputs.dry_run` in a job-context expression: cron-triggered runs have `inputs` set to default values (so `inputs.dry_run` is `false`). The `|| 'false'` fallback handles the null case. If actionlint still complains, add an `-ignore` flag in validate.yml — but try clean first.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/onboard-sweep.yml
git commit -m "feat(onboard-sweep): update-batch + fresh-batch jobs call onboard.yml"
```

---

## Task 5: summary job

**Files:**
- Modify: `.github/workflows/onboard-sweep.yml`

Add a summary job that posts a digest comment on the existing rolling Onboarding Drift Report Issue (or creates a standalone Issue if no drift report exists).

- [ ] **Step 1: Append the summary job**

Open `.github/workflows/onboard-sweep.yml`. After `fresh-batch:`, add:

```yaml
  summary:
    needs: [enumerate, update-batch, fresh-batch]
    if: always() && needs.enumerate.result == 'success'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@v6

      - name: Mint App token for catalog repo
        id: cat-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
          private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
          owner: serverkraken
          repositories: reusable-workflows

      - name: Build digest body
        id: body
        env:
          UPDATE_TARGETS: ${{ needs.enumerate.outputs.update_targets }}
          ONBOARD_TARGETS: ${{ needs.enumerate.outputs.onboard_targets }}
          SKIPPED: ${{ needs.enumerate.outputs.skipped }}
          UPDATE_RESULT: ${{ needs.update-batch.result }}
          FRESH_RESULT: ${{ needs.fresh-batch.result }}
        run: |
          set -euo pipefail
          today=$(date -u +%Y-%m-%d)
          {
            echo "## Onboard Sweep — $today"
            echo
            echo "**Update batch:** ${UPDATE_RESULT:-skipped} — \`${UPDATE_TARGETS:-(empty)}\`"
            echo "**Fresh batch:** ${FRESH_RESULT:-skipped} — \`${ONBOARD_TARGETS:-(empty)}\`"
            echo "**Skipped:** \`${SKIPPED:-(none)}\`"
            echo
            echo "_Run: [${{ github.run_id }}](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})_"
          } > digest.md
          {
            echo 'body<<EOF_DIGEST'
            cat digest.md
            echo 'EOF_DIGEST'
          } >> "$GITHUB_OUTPUT"

      - name: Post digest as comment on rolling Onboarding Drift Report Issue
        env:
          GH_TOKEN: ${{ steps.cat-token.outputs.token }}
          BODY: ${{ steps.body.outputs.body }}
        run: |
          set -euo pipefail
          # Find the rolling Issue by exact title (drift-check.yml uses the
          # same title-match pattern when upserting).
          drift_issue=$(gh issue list \
            --repo serverkraken/reusable-workflows \
            --state open \
            --limit 100 \
            --json number,title \
            -q '.[] | select(.title == "Onboarding Drift Report") | .number' \
            | head -1)
          if [[ -n "$drift_issue" ]]; then
            gh issue comment "$drift_issue" --repo serverkraken/reusable-workflows --body "$BODY"
            echo "Posted summary comment on Issue #$drift_issue"
          else
            gh issue create \
              --repo serverkraken/reusable-workflows \
              --title "Onboard sweep — $(date -u +%Y-%m-%d)" \
              --body "$BODY"
            echo "No rolling drift Issue found — created standalone Issue"
          fi
```

Note the title-match pattern (`select(.title == "Onboarding Drift Report")`) — matches what drift-check.yml uses at line 251.

- [ ] **Step 2: Lint**

```bash
yamllint -s .github/workflows/onboard-sweep.yml
actionlint .github/workflows/onboard-sweep.yml 2>&1 | head
```

Both silent.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/onboard-sweep.yml
git commit -m "feat(onboard-sweep): summary job posts digest on rolling drift Issue"
```

---

## Task 6: Opt-out documentation

**Files:**
- Modify: `docs/operations.md`

- [ ] **Step 1: Read current operations.md**

```bash
cat docs/operations.md | head -30
```

Familiarize yourself with the existing section structure (headings, prose style).

- [ ] **Step 2: Append the opt-out section**

Append to the END of `docs/operations.md` (or insert in a sensible location near the "Drift audit" section if one exists — use `rg "## " docs/operations.md` to identify section anchors first):

```markdown

## Onboard sweep (weekly auto-update + auto-onboard)

`.github/workflows/onboard-sweep.yml` runs every Monday at 07:00 UTC (1h after
drift-check) and:

1. **Re-onboards** adopters with `status=behind` or `status=stale-lock` against
   the current catalog major (opens an Onboarding PR on the adopter).
2. **Fresh-onboards** `serverkraken/*` repositories not yet present in
   `docs/onboarding-status.md` (opens an Onboarding PR on the adopter).
3. **Skips** any repo with the GitHub topic `no-serverkraken-onboard`, plus any
   repo where the bot already has an open onboarding PR (`chore/onboard-reusable-workflows`
   or `chore/remove-legacy-workflows` branch).

Adopters with `status=modified` or `status=behind+modified` are NOT touched —
the sweep avoids overwriting hand-edits. Re-onboard those manually after
reviewing the diff in the drift report.

A summary comment is posted on the rolling "Onboarding Drift Report" Issue
after each run; if that Issue doesn't exist, the sweep opens its own
standalone Issue.

### Opting out

Add the GitHub topic **`no-serverkraken-onboard`** to any repository's
Settings → "Topics" field. The next sweep run will skip the repo. Existing
rows in `docs/onboarding-status.md` are left intact for history.

### Dry-run mode

Trigger via `workflow_dispatch` with `dry_run: true` to see what would be
dispatched without opening PRs. Useful before the first scheduled run after
a major catalog change.
```

- [ ] **Step 3: Verify markdown structure**

```bash
rg "^## " docs/operations.md -n
```

Expected: a clean list of section headings with the new "Onboard sweep" section appearing.

- [ ] **Step 4: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): document onboard-sweep + opt-out topic"
```

---

## Task 7: Push branch + open PR

**Files:** none (git/gh only)

- [ ] **Step 1: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected (5 commits, newest first):
```
xxxxxxx docs(operations): document onboard-sweep + opt-out topic
xxxxxxx feat(onboard-sweep): summary job posts digest on rolling drift Issue
xxxxxxx feat(onboard-sweep): update-batch + fresh-batch jobs call onboard.yml
xxxxxxx feat(onboard-sweep): scheduled workflow + enumerate/bucket job
xxxxxxx test(onboard-sweep): bats coverage for drift-status helper
xxxxxxx feat(onboard-sweep): drift-status helper for bucket-logic
```

(That's actually 6 commits — the helper script, the bats, then 3 workflow commits, then docs. Re-count.)

- [ ] **Step 2: Push branch**

```bash
git push -u origin feat/onboard-sweep
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head feat/onboard-sweep \
  --title "feat: weekly onboard-sweep cron (auto-update + auto-onboard)" \
  --body "$(cat <<'EOF'
## Summary

Adds `.github/workflows/onboard-sweep.yml` — a Monday 07:00 UTC cron that:

- **Re-onboards** adopters with `status=behind` OR `status=stale-lock` (the new status from PR #107) against the current catalog major
- **Fresh-onboards** `serverkraken/*` repos not yet in `docs/onboarding-status.md`
- **Skips** repos with topic `no-serverkraken-onboard` (opt-out), repos with an open bot PR (duplicate-PR guard), and repos in non-actionable states (`clean`, `modified`, `behind+modified`, `no-lock`)

Calls existing `onboard.yml` via `uses:` with two bucketed target lists (update-batch + fresh-batch). Summary job posts a digest comment on the rolling Onboarding Drift Report Issue.

Closes the manual gap between drift-check (read-only audit) and onboard.yml (manual dispatch) — automates the fix-loop.

Spec: `docs/superpowers/specs/2026-05-23-onboard-sweep-design.md`
Plan: `docs/superpowers/plans/2026-05-24-onboard-sweep.md`

## Spec evolution

Spec was written before PR #107 landed. Plan extended the bucket-logic to route `stale-lock` → update_targets alongside `behind` — that integration was the explicit purpose of the render-and-compare work.

## Test plan

- [ ] `bats tests/shell/onboard-sweep-drift-status.bats` green (5 tests for the drift-status helper)
- [ ] `validate.yml` PR check green (actionlint + yamllint on the new workflow)
- [ ] **Post-merge, BEFORE first Monday cron run:** dispatch with `dry_run: true` and verify the bucketed target lists are reasonable (no surprise repos in update or fresh batches). First cron is whichever Monday 07:00 UTC follows merge.
- [ ] First scheduled run: verify summary comment lands on the existing rolling drift Issue (or a standalone Issue is created if drift-check hasn't run yet).
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

### Task 8: Remove worktree after merge

**Files:** none (git only)

- [ ] **Step 1: Verify merged**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
gh pr list --state merged --search "feat/onboard-sweep" --json number,mergedAt
```

Expected: non-null `mergedAt`.

- [ ] **Step 2: Sync local main**

```bash
git checkout main
git pull --rebase origin main
```

- [ ] **Step 3: Remove worktree + branch**

```bash
git worktree remove .worktrees/onboard-sweep
git branch -d feat/onboard-sweep
```

- [ ] **Step 4: Pre-flight dry-run dispatch (important)**

Before the first Monday cron, manually trigger a dry-run to verify the bucketed lists:

```bash
gh workflow run onboard-sweep.yml --ref main -f dry_run=true
sleep 30
# Find the latest run and inspect the bucket step's output
gh run list --workflow onboard-sweep.yml --limit 1 --json databaseId -q '.[0].databaseId'
# Then: gh run view <id> --log to inspect what would be dispatched
```

If the bucketed lists look wrong (unexpected adopters in fresh batch, etc.), debug before letting the cron loose. The dry-run mode forwards `dry_run: true` to `onboard.yml`, which then renders+diffs but doesn't push PRs.

---

## Self-Review (writer's checklist — performed at plan-write time)

**1. Spec coverage:**
- C-1 enumerate (list + opt-out filter + status-doc cross-ref + drift compute) → Task 3 ✓
- C-2 drift-status per onboarded repo → Task 1 helper + Task 3 bucket-step ✓
- C-3 bucketing (update vs fresh vs skip) → Task 3 bucket-step ✓
- C-4 duplicate-PR guard → Task 3 bucket-step (open_pr query) ✓
- C-5 update-batch → Task 4 ✓
- C-6 fresh-batch → Task 4 ✓
- C-7 summary job → Task 5 ✓
- C-8 opt-out documentation → Task 6 ✓
- C-9 smoke test (validate.yml + bats) → Task 2 + Task 7 (PR checks) ✓
- Spec evolution (stale-lock in bucket-logic) → noted in plan header, applied in Task 3's case statement ✓

**2. Placeholder scan:** No TBDs/TODOs. Each step has concrete code or commands.

**3. Type consistency:**
- `update_targets` / `onboard_targets` / `skipped` output names consistent across enumerate-job (Task 3), batch jobs (Task 4), and summary job (Task 5)
- `current_version` flows from `enumerate.outputs.current_version` → `pin_version` input on `onboard.yml`
- Branch-name regex `chore/(onboard-reusable-workflows|remove-legacy-workflows)` matches onboard.yml's default branch names (verified via reading onboard.yml inputs)
- `ONBOARD_SWEEP_TARGET_PATH` env-override consistent between Task 1 (helper script) and Task 2 (bats)
- `dry_run: ${{ fromJSON(inputs.dry_run || 'false') }}` consistent in both update-batch and fresh-batch jobs

**4. Commit count check:** Plan produces 6 commits (helper + bats + 3 workflow tasks + docs). The PR-creation step's expected log lists 6 entries. ✓

**5. Spec vs plan diffs:** The only intentional spec deviation is the bucket-logic extension to include `stale-lock` (post-PR #107). Documented in the plan header and the PR body.
