# Onboard Sweep — Minor-Version-Aware Stale-PR Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `onboard-sweep` re-render open bot PRs whose content is older than the current catalog minor, so within-major catalog evolution no longer leaves a backlog of stale PRs.

**Architecture:** Additive lock-file field (`rendered_against: vX.Y.Z`) recorded by `scripts/onboard-render.sh`, threaded as a new optional input through `actions/onboard-render/action.yml` and `.github/workflows/onboard.yml`. Sweep's `enumerate` job replaces its title-only PR-guard with a small helper script (`scripts/onboard-sweep-stale-pr-check.sh`) that fetches the lock from the bot branch via `gh api contents` and compares `rendered_against` to `$(git describe --tags --abbrev=0)`. Fail-open: any unexpected outcome (missing field, 404, API error) re-onboards.

**Tech Stack:** bash, jq, gh CLI (with bats-stub for tests), GitHub Actions reusable workflows (`workflow_call`), bats-core for shell unit tests.

**Worktree:** `.worktrees/sweep-stale-pr-v2` on branch `fix/onboard-sweep-stale-pr-guard-v2` (branched from `main` at `bac3d37`). Spec committed at `68ab51c`.

**Spec:** `docs/superpowers/specs/2026-05-30-onboard-sweep-minor-version-guard-design.md`

---

## File map

**Create:**
- `scripts/onboard-sweep-stale-pr-check.sh` — guard helper, ~40 LOC
- `tests/shell/onboard-sweep-stale-pr-check.bats` — 5 test cases
- `tests/fixtures/onboard-sweep-stale-pr/` — gh-stub fixture directory with 5 subdirs (clean-current, stale-minor, missing-field, lock-404, no-open-pr)

**Modify:**
- `scripts/onboard-render.sh:165-171` — write new `rendered_against` field (defaults to `$PIN`)
- `tests/shell/onboard-render.bats` — append 2 new tests for `rendered_against` semantics
- `actions/onboard-render/action.yml` — add `rendered_against` input + env pass-through
- `.github/workflows/onboard.yml` — add `rendered_against` input + thread to render-step env + render-action call
- `.github/workflows/onboard-sweep.yml` — `ver` step emits `current_minor`; `enumerate` guard call-out; `update-batch` + `fresh-batch` pass `rendered_against`

---

## Task 1: Lock writer — record `rendered_against` from env (TDD)

**Files:**
- Modify: `scripts/onboard-render.sh:163-172`
- Modify: `tests/shell/onboard-render.bats` (append)

- [ ] **Step 1.1: Write failing test for default behavior (no env → fallback to PIN)**

Append at the end of `tests/shell/onboard-render.bats`:

```bash
@test "render: lock rendered_against defaults to pin when env unset" {
  seed_profile "go-repo"
  unset RENDERED_AGAINST
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v3.1.4"
  v=$(jq -r '.rendered_against' "$TARGET/.github/onboard.lock.json")
  [ "$v" = "v3.1.4" ]
}

@test "render: lock rendered_against uses RENDERED_AGAINST env when set" {
  seed_profile "go-repo"
  RENDERED_AGAINST="v4.7.0" "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  v=$(jq -r '.rendered_against' "$TARGET/.github/onboard.lock.json")
  [ "$v" = "v4.7.0" ]
}
```

- [ ] **Step 1.2: Run tests — confirm they fail**

Run: `bats tests/shell/onboard-render.bats --filter "rendered_against"`
Expected: 2 failures — `jq -r '.rendered_against'` returns `null`, not the expected string.

- [ ] **Step 1.3: Implement — add field to lock JSON in `scripts/onboard-render.sh`**

Replace the `jq -n` invocation at `scripts/onboard-render.sh:165-171`:

```bash
jq -n \
  --argjson schema_version 1 \
  --arg catalog_version "$PIN" \
  --arg rendered_against "${RENDERED_AGAINST:-$PIN}" \
  --arg rendered_at "$NOW" \
  --argjson files "$files_json" \
  '{schema_version: $schema_version,
    catalog_version: $catalog_version,
    rendered_against: $rendered_against,
    rendered_at: $rendered_at,
    files: $files}' \
  > "$LOCK"
```

- [ ] **Step 1.4: Run new + existing render tests — confirm all pass**

Run: `bats tests/shell/onboard-render.bats`
Expected: all green; existing `schema_version`/`catalog_version`/`files` tests still pass (the new field is additive and ordered logically in the JSON).

- [ ] **Step 1.5: Commit**

```bash
git add scripts/onboard-render.sh tests/shell/onboard-render.bats
git commit -m "feat(onboard-render): add rendered_against field to lock

The new optional field records the full catalog tag (vX.Y.Z) that
templates were rendered against. Falls back to the pin argument
when RENDERED_AGAINST env is unset, preserving existing direct-caller
behavior.

Enables onboard-sweep to detect within-major drift on open bot PRs
(follow-up: scripts/onboard-sweep-stale-pr-check.sh)."
```

---

## Task 2: Composite action — thread `rendered_against` to render step

**Files:**
- Modify: `actions/onboard-render/action.yml`

- [ ] **Step 2.1: Add input + env pass-through**

Replace `actions/onboard-render/action.yml` with the version below. Two changes: new `rendered_against` input (default empty), and `RENDERED_AGAINST` env in the render step.

```yaml
name: 'Onboard: render adopter templates'
description: >-
  Render adopter-template files into the target repo workspace from a
  profile.json (emitted by onboard-detect). Writes the six standard files plus
  .github/onboard.lock.json. Wraps scripts/onboard-render.sh.

inputs:
  catalog_path:
    description: 'Path to the checked-out catalog repo'
    required: true
  target_path:
    description: 'Path to the checked-out target repo'
    required: true
  profile_json:
    description: 'profile_json output from onboard-detect (raw JSON string)'
    required: true
  pin_version:
    description: 'Catalog @version to pin the rendered templates to'
    required: false
    default: 'v1'
  rendered_against:
    description: >-
      Full catalog tag (vX.Y.Z) recorded in the lock as rendered_against.
      Defaults to empty; the script falls back to pin_version. The sweep
      passes its `git describe --tags --abbrev=0` output here.
    required: false
    default: ''

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
        RENDERED_AGAINST: ${{ inputs.rendered_against }}
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

- [ ] **Step 2.2: Lint**

Run: `actionlint actions/onboard-render/action.yml`
Expected: no output (clean).

- [ ] **Step 2.3: Commit**

```bash
git add actions/onboard-render/action.yml
git commit -m "feat(onboard-render-action): forward rendered_against input

Optional input (default empty) threaded as RENDERED_AGAINST env to the
render-script step. Direct callers without the input keep prior behavior
(field defaults to pin_version inside the script)."
```

---

## Task 3: `onboard.yml` — accept and forward `rendered_against`

**Files:**
- Modify: `.github/workflows/onboard.yml:55-65` (input block) and the render step calling the composite action around line 227.

- [ ] **Step 3.1: Add input under both `workflow_call.inputs` and `workflow_dispatch.inputs`**

In `.github/workflows/onboard.yml`, locate the existing `pin_version` input (line 29 under `workflow_dispatch` and line 57 under `workflow_call`). Add `rendered_against` right after each.

Patch under `workflow_dispatch.inputs` (after the `pin_version` block ending at line 32):

```yaml
      rendered_against:
        description: 'Full catalog tag for the lock file. Empty → fall back to pin_version.'
        required: false
        type: string
        default: ''
```

Mirror the same block under `workflow_call.inputs` after its `pin_version` block (line 60).

- [ ] **Step 3.2: Forward the input to the composite-action call**

Locate the `uses: ./.catalog/actions/onboard-render` step around line 227. Add a `rendered_against:` field next to the existing `pin_version:`:

```yaml
      - name: Render adopter templates
        uses: ./.catalog/actions/onboard-render
        with:
          catalog_path: .catalog
          target_path: target
          profile_json: ${{ steps.detect.outputs.profile_json }}
          pin_version: ${{ inputs.pin_version }}
          rendered_against: ${{ inputs.rendered_against }}
```

- [ ] **Step 3.3: Lint**

Run: `actionlint .github/workflows/onboard.yml`
Expected: no errors. (Use the `-ignore` flags already in `validate.yml` if needed for create-github-app-token false positives.)

- [ ] **Step 3.4: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): accept rendered_against input

New optional input (workflow_call + workflow_dispatch) forwarded to the
onboard-render composite action. Empty default keeps backward compat with
existing callers (direct manual dispatch, drift-check reruns)."
```

---

## Task 4: Sweep guard helper — bats first, then implementation

**Files:**
- Create: `tests/fixtures/onboard-sweep-stale-pr/clean-current/repos__owner__repo__pulls.json`
- Create: `tests/fixtures/onboard-sweep-stale-pr/clean-current/repos__owner__repo__contents__.github__onboard.lock.json?ref=chore__onboard-reusable-workflows.json`
- (and 4 more fixture subdirs)
- Create: `tests/shell/onboard-sweep-stale-pr-check.bats`
- Create: `scripts/onboard-sweep-stale-pr-check.sh`

### 4a — Fixtures

- [ ] **Step 4.1: Create fixture directories**

```bash
mkdir -p tests/fixtures/onboard-sweep-stale-pr/{clean-current,stale-minor,missing-field,lock-404,no-open-pr}
```

- [ ] **Step 4.2: Fixture for `clean-current`**

The helper's first `gh api` call uses `-q '...length'`. The gh-stub does NOT apply jq filters — it returns the fixture verbatim. So we store the *post-jq output* (a bare number).

`tests/fixtures/onboard-sweep-stale-pr/clean-current/repos__owner__repo__pulls.json`:

```
1
```

Compute the base64 lock content for `rendered_against=v4.7.0`:

```bash
CONTENT=$(jq -nc '{schema_version:1, catalog_version:"v4", rendered_against:"v4.7.0", rendered_at:"2026-05-30T00:00:00Z", files:{}}' | base64)
echo "$CONTENT"
```

Store the base64 string (single line, no `data:` prefix) in
`tests/fixtures/onboard-sweep-stale-pr/clean-current/repos__owner__repo__contents__.github__onboard.lock.json?ref=chore__onboard-reusable-workflows.json`.

The endpoint sanitizer in `gh-stub.sh:45-46` does `key="${endpoint#/}"; key="${key//\//__}"`. The `?` and `=` chars stay verbatim. Verify the exact filename matches what the helper's request would sanitize to.

- [ ] **Step 4.3: Fixture for `stale-minor`**

Same `pulls.json` (`1`). Lock content with `rendered_against=v4.4.0`:

```bash
jq -nc '{schema_version:1, catalog_version:"v4", rendered_against:"v4.4.0", rendered_at:"2026-05-27T00:00:00Z", files:{}}' | base64
```

Store in the `stale-minor/` subdir.

- [ ] **Step 4.4: Fixture for `missing-field`**

Same `pulls.json` (`1`). Lock without the new field:

```bash
jq -nc '{schema_version:1, catalog_version:"v4", rendered_at:"2026-05-27T00:00:00Z", files:{}}' | base64
```

Store in `missing-field/`.

- [ ] **Step 4.5: Fixture for `lock-404`**

`pulls.json`: `1`. Lock fixture filename ends in `.404.json` so gh-stub returns non-zero exit:

`tests/fixtures/onboard-sweep-stale-pr/lock-404/repos__owner__repo__contents__.github__onboard.lock.json?ref=chore__onboard-reusable-workflows.404.json`:

```json
{"message": "Not Found"}
```

- [ ] **Step 4.6: Fixture for `no-open-pr`**

Only the pulls fixture is needed (helper short-circuits before the second call):

`tests/fixtures/onboard-sweep-stale-pr/no-open-pr/repos__owner__repo__pulls.json`:

```
0
```

### 4b — Bats tests (failing)

- [ ] **Step 4.7: Write `tests/shell/onboard-sweep-stale-pr-check.bats`**

```bash
#!/usr/bin/env bats
# Tests for scripts/onboard-sweep-stale-pr-check.sh
#
# Decides whether the sweep should skip an adopter because its open bot
# onboard PR is already at the current catalog minor. Network is mocked via
# the shared gh-stub on PATH (tests/shell/lib/gh-stub.sh).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/onboard-sweep-stale-pr-check.sh"
  STUB="$REPO_ROOT/tests/shell/lib/gh-stub.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard-sweep-stale-pr"

  WORK=$(mktemp -d)
  export GH_STUB_CALL_LOG="$WORK/gh-calls.log"
  : > "$GH_STUB_CALL_LOG"

  mkdir -p "$WORK/bin"
  ln -sf "$STUB" "$WORK/bin/gh"

  # Bot identity required so the script's API filter selects.
  # Default to the real bot login. Override per-test if needed.
  export GH_TOKEN="dummy-token-for-tests"
}

teardown() {
  rm -rf "$WORK"
}

run_check() {
  local fixture_dir="$1"; shift
  export GH_STUB_FIXTURE_DIR="$FIX/$fixture_dir"
  PATH="$WORK/bin:$PATH" run "$SCRIPT" "$@"
}

@test "stale-pr-check: lock rendered_against matches current minor → skip" {
  run_check clean-current owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "skip" ]
}

@test "stale-pr-check: lock rendered_against is older minor → stale" {
  run_check stale-minor owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: lock missing rendered_against field → stale" {
  run_check missing-field owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: lock 404 → stale" {
  run_check lock-404 owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: no open bot PR → no-pr" {
  run_check no-open-pr owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "no-pr" ]
}

@test "stale-pr-check: missing args → exits 1 with usage" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}
```

- [ ] **Step 4.8: Run tests — confirm they fail**

Run: `bats tests/shell/onboard-sweep-stale-pr-check.bats`
Expected: all 6 fail with `bats: command not found: $SCRIPT` (script does not exist yet).

### 4c — Implementation

- [ ] **Step 4.9: Create `scripts/onboard-sweep-stale-pr-check.sh`**

```bash
#!/usr/bin/env bash
# onboard-sweep-stale-pr-check.sh — decide whether an open bot onboard PR's
# content is already at the current catalog minor.
#
# Usage:   onboard-sweep-stale-pr-check.sh <owner/repo> <current_minor>
# Env:     GH_TOKEN — read access to the target repo's PRs + contents.
# Stdout:  one of {skip|stale|no-pr}
#
# Decision tree (fail-open):
#   no open bot PR on chore/onboard-reusable-workflows         → "no-pr"
#   open PR + lock.rendered_against == current_minor           → "skip"
#   open PR + lock missing / field absent / API error / mismatch → "stale"
#
# The sweep treats "skip" as `skipped:open-pr` and "no-pr" / "stale" as
# "fall through to drift-status / fresh-onboard".
set -euo pipefail

TARGET="${1:-}"
CURRENT_MINOR="${2:-}"

if [[ -z "$TARGET" || -z "$CURRENT_MINOR" ]]; then
  echo "::error::usage: $0 <owner/repo> <current_minor>" >&2
  exit 1
fi

BRANCH="chore/onboard-reusable-workflows"

# Step 1: does an open bot PR exist on the onboard branch?
exists=$(gh api -X GET "/repos/$TARGET/pulls" -f state=open \
  -q "[.[] | select(.user.login == \"serverkraken-release-bot[bot]\")
            | select(.head.ref == \"$BRANCH\")
      ] | length" 2>/dev/null || echo 0)

if [[ "$exists" -eq 0 ]]; then
  echo "no-pr"
  exit 0
fi

# Step 2: fetch lock from the bot branch and compare rendered_against.
# gh api returns base64 content; decode and read the field.
lock_b64=$(gh api \
  "/repos/$TARGET/contents/.github/onboard.lock.json?ref=$BRANCH" \
  -q '.content' 2>/dev/null || true)

lock_rendered=$(printf '%s' "$lock_b64" | base64 -d 2>/dev/null \
                | jq -r '.rendered_against // empty' 2>/dev/null || true)

if [[ "$lock_rendered" == "$CURRENT_MINOR" ]]; then
  echo "skip"
else
  echo "stale"
fi
```

```bash
chmod +x scripts/onboard-sweep-stale-pr-check.sh
```

- [ ] **Step 4.10: Run tests — confirm all pass**

Run: `bats tests/shell/onboard-sweep-stale-pr-check.bats`
Expected: 6 PASS.

If any fail on fixture filename mismatch, verify the sanitizer logic in `tests/shell/lib/gh-stub.sh:45-46` produces the same key the helper's endpoint sanitizes to. Use `cat $GH_STUB_CALL_LOG` after a failing test to see the exact endpoints requested.

- [ ] **Step 4.11: Commit**

```bash
git add scripts/onboard-sweep-stale-pr-check.sh \
        tests/shell/onboard-sweep-stale-pr-check.bats \
        tests/fixtures/onboard-sweep-stale-pr/
git commit -m "feat(onboard-sweep): minor-version-aware stale-PR guard

New helper script + bats coverage. Decides skip/stale/no-pr for the sweep's
enumerate job by fetching the lock from the bot branch and comparing
rendered_against to the current catalog minor.

Fail-open semantics: any unexpected outcome (missing field, 404, API
error, mismatch) returns 'stale' so the sweep re-onboards the adopter.
Follows scripts/onboard-sweep-drift-status.sh pattern."
```

---

## Task 5: Wire the helper into `onboard-sweep.yml`

**Files:**
- Modify: `.github/workflows/onboard-sweep.yml`

- [ ] **Step 5.1: Emit `current_minor` from the `ver` step**

Locate `.github/workflows/onboard-sweep.yml:54-61` (the `ver` step). The existing block:

```yaml
      - id: ver
        name: Derive current catalog major
        run: |
          set -euo pipefail
          tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
          major=$(echo "$tag" | sed -E 's/^v([0-9]+).*$/v\1/')
          echo "current_version=$major" >> "$GITHUB_OUTPUT"
          echo "Resolved current major: $major (from tag $tag)"
```

Replace with:

```yaml
      - id: ver
        name: Derive current catalog major + minor
        run: |
          set -euo pipefail
          tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
          major=$(echo "$tag" | sed -E 's/^v([0-9]+).*$/v\1/')
          echo "current_version=$major" >> "$GITHUB_OUTPUT"
          echo "current_minor=$tag" >> "$GITHUB_OUTPUT"
          echo "Resolved current major: $major / minor: $tag"
```

Also add `current_minor` to the `enumerate.outputs` list near line 45:

```yaml
    outputs:
      update_targets: ${{ steps.bucket.outputs.update_targets }}
      onboard_targets: ${{ steps.bucket.outputs.onboard_targets }}
      skipped: ${{ steps.bucket.outputs.skipped }}
      current_version: ${{ steps.ver.outputs.current_version }}
      current_minor: ${{ steps.ver.outputs.current_minor }}
```

- [ ] **Step 5.2: Replace the duplicate-PR guard with the helper call**

Locate `.github/workflows/onboard-sweep.yml:110-123` (the `existing_current` block). Replace those 14 lines with:

```bash
            # Duplicate-PR guard: skip ONLY if the bot's open onboard PR
            # already renders against the current catalog minor. Stale-minor
            # PRs (rendered against an older minor of the same major) and
            # legacy PRs without rendered_against fall through — onboard.yml
            # force-pushes the branch and edits the existing PR.
            case "$(scripts/onboard-sweep-stale-pr-check.sh "$full" "$CURRENT_MINOR")" in
              skip)
                skipped_csv+="${full}:open-pr,"
                continue
                ;;
              stale|no-pr|*)
                ;;  # fall through to drift / fresh-onboard
            esac
```

Also extend the step's env to include `CURRENT_MINOR`:

```yaml
      - id: bucket
        name: Bucket repos into update vs fresh-onboard vs skip
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          CURRENT: ${{ steps.ver.outputs.current_version }}
          CURRENT_MINOR: ${{ steps.ver.outputs.current_minor }}
        run: |
```

- [ ] **Step 5.3: Forward `rendered_against` in the workflow_call steps**

Locate the `update-batch` and `fresh-batch` jobs (around lines 168 and 180 in the current file). Add `rendered_against` next to the existing `pin_version`:

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
      rendered_against: ${{ needs.enumerate.outputs.current_minor }}
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
      rendered_against: ${{ needs.enumerate.outputs.current_minor }}
      dry_run: ${{ fromJSON(inputs.dry_run || 'false') }}
```

- [ ] **Step 5.4: Lint**

```bash
actionlint .github/workflows/onboard-sweep.yml .github/workflows/onboard.yml
yamllint -s .github/workflows/onboard-sweep.yml .github/workflows/onboard.yml
```

Expected: no errors.

- [ ] **Step 5.5: Commit**

```bash
git add .github/workflows/onboard-sweep.yml
git commit -m "feat(onboard-sweep): wire minor-version-aware stale-PR guard

ver step now emits current_minor (full git describe tag) alongside
current_version (major). enumerate's duplicate-PR guard delegates to
scripts/onboard-sweep-stale-pr-check.sh, which fetches the lock from
the bot branch and compares rendered_against to the current minor.

update-batch and fresh-batch forward current_minor into onboard.yml's
rendered_against input so the new lock writes carry the correct tag.

Cutover: first sweep after v4.8.0 release sees the absent field on all
28 existing stale PRs, re-onboards them once, and from the next run
onward the field gates them correctly until the next minor bump."
```

---

## Task 6: Local verification

- [ ] **Step 6.1: Run the full bats suite**

```bash
bats tests/shell/
```

Expected: every existing test still passes, plus the 8 new ones (2 in `onboard-render.bats`, 6 in `onboard-sweep-stale-pr-check.bats`).

- [ ] **Step 6.2: Run actionlint and yamllint over all workflows**

```bash
actionlint
yamllint -s .github/
```

Expected: no new errors. (The `-ignore` flags already in `validate.yml` cover known false positives for create-github-app-token.)

- [ ] **Step 6.3: Sanity-check: re-render a fixture and inspect lock content**

```bash
tmp=$(mktemp -d)
cp -R tests/fixtures/onboard/drift-clean/. "$tmp/"
RENDERED_AGAINST="v4.7.0" \
  scripts/onboard-render.sh . "$tmp" tests/fixtures/onboard-detect/profiles/go-repo.json v4
jq '{catalog_version, rendered_against, schema_version}' "$tmp/.github/onboard.lock.json"
rm -rf "$tmp"
```

Expected output:

```json
{
  "catalog_version": "v4",
  "rendered_against": "v4.7.0",
  "schema_version": 1
}
```

If the `profiles/go-repo.json` path differs in your tree, run `fd 'go-repo.json' tests/fixtures` to locate the actual fixture; the canonical path is `tests/fixtures/onboard-detect/profiles/go-repo.json` per existing render-bats setup.

---

## Task 7: Push, open PR, watch self-CI

- [ ] **Step 7.1: Push the branch**

```bash
git push -u origin fix/onboard-sweep-stale-pr-guard-v2
```

- [ ] **Step 7.2: Open the PR**

Title: `fix(onboard-sweep): minor-version-aware stale-PR guard (v2)`

Body (HEREDOC, no Claude attribution per memory `feedback_pr_style`):

```
## Summary

Follow-up to #137. The duplicate-PR guard now compares the bot branch's
`onboard.lock.json:.rendered_against` to the current catalog minor
(`git describe --tags --abbrev=0`), not just the major in the PR title.

Stale-minor PRs — like the 28 open `@v4.4.0`-rendered PRs from the
2026-05-27 sweep, blocked behind the title-only `@v4`-match — are now
re-onboarded on the next sweep instead of being skipped forever.

## Why

The 2026-05-30 sweep run reported `update=0 onboard=0 skipped=33`
because every open onboard PR's title matched `@v4` while their content
was three minors behind (v4.4.0 vs catalog v4.7.0). Merging any of them
today would propagate known-superseded workflows.

Catalog evidence:
https://github.com/serverkraken/reusable-workflows/actions/runs/26677746197

## Changes

- New optional lock field `rendered_against: vX.Y.Z` written by
  `scripts/onboard-render.sh`. Falls back to `pin_version` when the
  RENDERED_AGAINST env is unset → backwards-compatible for direct callers.
- Optional `rendered_against` input on the `onboard-render` composite
  action and on `.github/workflows/onboard.yml`.
- `onboard-sweep.yml`:
  - `ver` step emits `current_minor` (full describe tag).
  - `enumerate`'s duplicate-PR guard delegates to the new helper
    `scripts/onboard-sweep-stale-pr-check.sh`.
  - `update-batch` and `fresh-batch` forward `current_minor` into
    onboard.yml's `rendered_against` input.
- bats coverage:
  - 2 new tests in `tests/shell/onboard-render.bats` (default + env override)
  - 6 new tests in `tests/shell/onboard-sweep-stale-pr-check.bats`
    (skip / stale / missing-field / 404 / no-pr / usage)

## Cutover

After this merges and release-please cuts `v4.8.0`:

1. Next nightly `onboard-sweep` cron tick (or a manual dispatch).
2. Helper finds 28 open PRs, all missing `rendered_against` → returns
   `stale` for each → fall through to drift-status.
3. Onboard re-renders all 28 adopters, force-pushes their bot branches,
   `gh pr edit` updates titles + bodies to reference `@v4.8.0`-equivalent
   content.
4. From the next sweep on, the new field gates them correctly.

No manual PR-closing required.

## Test plan

- [ ] CI green (validate, test-shell, self-ci atom callers)
- [ ] After merge: manual `workflow_dispatch` of `onboard-sweep.yml` and
      confirm `update_targets` contains the 28 stale-PR adopters
- [ ] Spot-check one resulting refreshed PR (e.g. alexandria) to verify
      its bot branch's `.github/onboard.lock.json` carries
      `rendered_against: v4.8.0`
```

Command:

```bash
gh pr create --title "fix(onboard-sweep): minor-version-aware stale-PR guard (v2)" --body "$(cat <<'EOF'
[paste the body above]
EOF
)"
```

- [ ] **Step 7.3: Wait for self-CI; address any failure**

Run: `gh pr checks --watch`

Expected: all green.

If `actionlint` flags `client-id` on create-github-app-token, that is a known stale-data warning (memory: `project_actionlint_clientid`) — the existing `-ignore` flags in `.github/workflows/validate.yml` should cover it; verify they apply to the modified `onboard-sweep.yml` block too.

- [ ] **Step 7.4: Request review, merge when approved**

After merge, release-please will queue a `v4.8.0` release PR (feat-commit train). Merge that, then trigger `onboard-sweep` manually for the cutover.

---

## Self-review

Spec coverage:

- §Lock schema (additive) — Task 1 ✓
- §`onboard.yml` input — Task 3 ✓ (plus Task 2 composite action plumbing not explicit in spec but required by call-chain — added)
- §Sweep guard rewrite — Tasks 4 + 5 ✓
- §PR B orphan case — implicit (no separate handling per spec) ✓
- §Sweep workflow_call to `onboard.yml` — Task 5 ✓
- §Failure/edge cases — Task 4 covers all 5 rows via bats ✓
- §Testing — Task 4 (bats) + Task 6 (local actionlint + sanity) ✓
- §Release & cutover — Task 7 PR body ✓
- §Risks — addressed by fail-open design (Task 4 helper) ✓

Placeholder scan: none.

Type consistency: `current_minor` field name used identically across `ver` step output, `enumerate` env, and both workflow_call `rendered_against` mappings. `RENDERED_AGAINST` env name used identically across composite action and render script. Helper script stdout vocabulary (`skip` / `stale` / `no-pr`) used identically in bats and `enumerate` case.
