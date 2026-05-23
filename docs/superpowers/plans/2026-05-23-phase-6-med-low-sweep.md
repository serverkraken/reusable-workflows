# Phase 6 MED+LOW Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the remaining MED + LOW review items from REVIEW-2026-05-22.md across two file-disjoint PRs: PR-N (12 production fixes) and PR-O (3 docs/template/fixture items).

**Architecture:** PR-N touches `.github/workflows/*`, `scripts/*`, `actions/install-trivy/`, `actions/post-prerelease-comment/`, plus a new bats fixture for the MED-5 go.work parser. PR-O touches templates + CONTRIBUTING.md + deletes a dead fixture. All commits `fix:`/`docs:`/`chore:`/`feat:`/`test:` — patch bump for PR-N, no bump for PR-O.

**Tech Stack:** GitHub Actions reusable workflows, composite actions, bash 5+, jq, bats-core 1.13, awk.

**Pre-implementation scope corrections** (some spec items turned out already-done):
- LOW-4 (`id: body` on post-prerelease step) — already exists in current code
- LOW-7 (`setup-python-deps` header comment) — already correct per memory `troubleshooting_python_pm_detection`
- LOW-10 (README `setup-python-deps` row) — already present in README:132
- LOW-12 (backlog Lint/Test entry) — already removed

These four are DROPPED from the plan. Spec § N.4 should be updated post-merge to reflect actual scope. PR-N final count: 12. PR-O final count: 3.

---

## Pre-flight: Worktree setup (PR-N)

### Task 0N.1: Sync main and create PR-N worktree

**Files:** none (git only)

- [ ] **Step 1: Sync local main**

```bash
git fetch origin main
git checkout main
git pull --rebase origin main
```

Expected: `Your branch is up to date with 'origin/main'.`

- [ ] **Step 2: Create PR-N worktree**

```bash
git worktree add .worktrees/phase-6-prod -b fix/phase-6-prod-fixes main
```

Expected: `Preparing worktree (new branch 'fix/phase-6-prod-fixes')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: new entry `.worktrees/phase-6-prod [fix/phase-6-prod-fixes]`

All PR-N tasks (1–13) execute from `.worktrees/phase-6-prod`.

---

## PR-N — `fix/phase-6-prod-fixes`

### Task 1: MED-1 — setup-go cache-dependency-path in explicit-version branch

**Files:**
- Modify: `.github/workflows/lint-go.yml` (Setup Go explicit-version step, around line 62-65)
- Modify: `.github/workflows/test-go.yml` (Setup Go explicit-version step, around line 58-61)

- [ ] **Step 1: Find the explicit-version block in lint-go.yml**

```bash
rg "Setup Go \(explicit version\)" .github/workflows/lint-go.yml -n -A 5
```

Expected: a block like:
```yaml
      - name: Setup Go (explicit version)
        if: inputs.go_version != ''
        uses: actions/setup-go@v6
        with:
          go-version: ${{ inputs.go_version }}
```

- [ ] **Step 2: Add `cache-dependency-path` to lint-go.yml**

Edit `.github/workflows/lint-go.yml`. In the explicit-version block, add the line after `go-version:`:

```yaml
      - name: Setup Go (explicit version)
        if: inputs.go_version != ''
        uses: actions/setup-go@v6
        with:
          go-version: ${{ inputs.go_version }}
          cache-dependency-path: ${{ inputs.working_directory }}/go.sum
```

- [ ] **Step 3: Add `cache-dependency-path` to test-go.yml**

Identical edit in `.github/workflows/test-go.yml`. Find the same block (different filename, same shape).

- [ ] **Step 4: Lint**

```bash
yamllint -s .github/workflows/lint-go.yml .github/workflows/test-go.yml
actionlint .github/workflows/lint-go.yml .github/workflows/test-go.yml
```

Expected: both silent.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/lint-go.yml .github/workflows/test-go.yml
git commit -m "fix(lint-go,test-go): cache-dependency-path in explicit-version branch (MED-1)"
```

### Task 2: MED-4 — Helm version sync (publish 3.15.0 → 3.16.3) with Renovate anchor

**Files:**
- Modify: `.github/workflows/helm-publish.yml` (lines around 31-35, helm_version input default)

- [ ] **Step 1: Find the helm_version default**

```bash
rg "helm_version" .github/workflows/helm-publish.yml -n -B1 -A 3
```

Expected:
```yaml
      helm_version:
        description: 'Helm CLI version to install (e.g. "v3.15.0", "latest").'
        required: false
        type: string
        default: 'v3.15.0'
```

- [ ] **Step 2: Bump default to match lint-helm + add Renovate anchor**

Edit `.github/workflows/helm-publish.yml`. Change the default value and add a Renovate comment ABOVE the `helm_version:` input:

```yaml
      # renovate: datasource=github-releases depName=helm/helm
      helm_version:
        description: 'Helm CLI version to install (e.g. "v3.16.3", "latest").'
        required: false
        type: string
        default: 'v3.16.3'
```

Also update the example in the `description:` field from `v3.15.0` to `v3.16.3` to keep docs consistent.

- [ ] **Step 3: Verify lint-helm and publish are now in sync**

```bash
rg "default: 'v3" .github/workflows/lint-helm.yml .github/workflows/helm-publish.yml -n
```

Expected: both lines show `'v3.16.3'`.

- [ ] **Step 4: Lint**

```bash
yamllint -s .github/workflows/helm-publish.yml
actionlint .github/workflows/helm-publish.yml
```

Expected: silent.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/helm-publish.yml
git commit -m "fix(helm-publish): bump helm default to v3.16.3 to match lint-helm (MED-4)"
```

### Task 3: MED-5 — go.work single-entry parser

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (the `detect_components` function's go.work awk block, around line 139-142)
- Create: `tests/fixtures/onboard/go-work-single/Cargo.toml` ... no wait, this is Go. Let me restate the files:
- Create: `tests/fixtures/onboard/go-work-single/go.work`
- Create: `tests/fixtures/onboard/go-work-single/go.mod`
- Create: `tests/fixtures/onboard/go-work-single/svc/go.mod`
- Create: `tests/fixtures/onboard/go-work-single/svc/main.go`

(Bats tests for this fixture are in Task 4.)

- [ ] **Step 1: Find the go.work parser block**

```bash
rg "use \\\\(" scripts/lib/onboard-detect-lib.sh -n -B2 -A 6
```

Expected: a block in `detect_components` like:
```bash
  if [[ -f "$repo/go.work" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(awk '/^use \(/{flag=1;next}/^\)/{flag=0}flag{gsub(/[()"\t ]/,"");print}' "$repo/go.work" | sed 's|^\./||')
  elif ...
```

- [ ] **Step 2: Extend the awk parser to handle single-entry form**

Edit `scripts/lib/onboard-detect-lib.sh`. Replace the awk one-liner with a multi-pattern awk that handles both forms:

```bash
  if [[ -f "$repo/go.work" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(awk '
      /^use \(/{flag=1; next}
      /^\)/{flag=0; next}
      flag {
        gsub(/[()"\t ]/, "");
        if ($0 != "") print
        next
      }
      /^use[[:space:]]+[^(]/ {
        sub(/^use[[:space:]]+/, "");
        gsub(/["\t ]/, "");
        print
      }
    ' "$repo/go.work" | sed 's|^\./||')
  elif ...
```

Logic:
- Multi-entry form (`use ( ./a ./b )`) — first three lines of the awk (`flag` state machine).
- Single-entry form (`use ./path`) — last block: matches lines starting with `use` followed by whitespace followed by something other than `(`, strips the `use ` prefix and any whitespace/quotes.
- The `| sed 's|^\./||'` strips leading `./` from any emitted path.

- [ ] **Step 3: Create the single-entry fixture**

Write `tests/fixtures/onboard/go-work-single/go.work`:
```
go 1.22

use ./svc
```

Write `tests/fixtures/onboard/go-work-single/go.mod`:
```
module example.com/root

go 1.22
```

Write `tests/fixtures/onboard/go-work-single/svc/go.mod`:
```
module example.com/root/svc

go 1.22
```

Write `tests/fixtures/onboard/go-work-single/svc/main.go`:
```go
package main

func main() {}
```

- [ ] **Step 4: Smoke-test the parser locally (no bats yet — Task 4 adds them)**

```bash
./scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/go-work-single | jq -r '.components[].path'
```

Expected: `svc` (or `./svc` if the sed strip didn't fire — the strip should be active, so just `svc`).

If output is empty: the awk single-entry branch didn't match — re-read the regex. The line in go.work is `use ./svc`; the regex `/^use[[:space:]]+[^(]/` matches because `./svc` starts with `.` not `(`.

- [ ] **Step 5: Commit (parser change + fixture)**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/fixtures/onboard/go-work-single/
git commit -m "fix(onboard-detect): handle go.work single-entry use form (MED-5)"
```

### Task 4: MED-5 (cont.) — bats tests for go-work-single fixture

**Files:**
- Modify: `tests/shell/onboard-detect.bats` (append 2 tests)

- [ ] **Step 1: Append bats tests**

Open `tests/shell/onboard-detect.bats`. Append at the END of the file:

```bats
@test "detects go workspace single-entry form" {
  run "$DETECT" "$FIX/go-work-single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
}

@test "go-work-single --profile-json emits the single member path" {
  run "$DETECT" --profile-json "$FIX/go-work-single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"svc\""* ]]
}
```

- [ ] **Step 2: Run the new tests**

```bash
bats tests/shell/onboard-detect.bats --filter "go-work-single|workspace single-entry"
```

Expected: 2 tests PASS.

- [ ] **Step 3: Run the full file**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: previous baseline + 2 = N+2 tests pass. (Baseline after Phase 5: 59 tests; this brings it to 61.)

- [ ] **Step 4: Commit**

```bash
git add tests/shell/onboard-detect.bats
git commit -m "test(onboard-detect): go.work single-entry fixture and bats (MED-5)"
```

### Task 5: MED-6 — install-trivy mktemp trap

**Files:**
- Modify: `actions/install-trivy/action.yml` (around line 33, after `TMP=$(mktemp -d)`)

- [ ] **Step 1: Find the mktemp line**

```bash
rg "mktemp -d" actions/install-trivy/action.yml -n -B1 -A 3
```

Expected:
```bash
        TMP=$(mktemp -d)
        cd "$TMP"
        curl -fsSL \
```

- [ ] **Step 2: Add trap**

Edit `actions/install-trivy/action.yml`. Immediately after `TMP=$(mktemp -d)`, add a trap line:

```bash
        TMP=$(mktemp -d)
        trap 'rm -rf "$TMP"' EXIT
        cd "$TMP"
        curl -fsSL \
```

- [ ] **Step 3: Lint**

```bash
yamllint -s actions/install-trivy/action.yml
actionlint actions/install-trivy/action.yml 2>&1 | head
```

Expected: silent (or pre-existing renovate-trivy noise — unaffected by this change).

- [ ] **Step 4: Commit**

```bash
git add actions/install-trivy/action.yml
git commit -m "fix(install-trivy): trap mktemp tempdir on EXIT (MED-6)"
```

### Task 6: MED-7 — seed-onboarding-status SCRIPT_DIR/REPO_ROOT anchor

**Files:**
- Modify: `scripts/seed-onboarding-status.sh` (top of file, around line 8-10)

- [ ] **Step 1: Read the current head**

```bash
head -15 scripts/seed-onboarding-status.sh
```

Expected:
```bash
#!/usr/bin/env bash
# seed-onboarding-status.sh — populate docs/onboarding-status.md with one row
# per serverkraken/* repo. Existing rows are preserved; only new repos are appended.
#
# Usage: scripts/seed-onboarding-status.sh
# Requires: gh, jq

set -euo pipefail

DOC=docs/onboarding-status.md
```

- [ ] **Step 2: Add SCRIPT_DIR/REPO_ROOT anchor**

Edit `scripts/seed-onboarding-status.sh`. Replace the `DOC=docs/onboarding-status.md` line with:

```bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/docs/onboarding-status.md"
```

- [ ] **Step 3: Verify bats still passes**

The existing bats test (`tests/shell/seed-onboarding-status.bats`) uses `cd "$WORK"` workaround. The script-side anchor fix is additive and the workaround still works:

```bash
bats tests/shell/seed-onboarding-status.bats
```

Expected: 3 tests still PASS.

- [ ] **Step 4: Smoke test from a subdir**

```bash
cd /tmp && bash "$OLDPWD/scripts/seed-onboarding-status.sh" 2>&1 | head -5
cd "$OLDPWD"
```

Expected: the script either updates `$OLDPWD/docs/onboarding-status.md` or prints `gh CLI required` (depending on whether gh is auth'd). It should NOT error on missing `docs/` path — that proves the anchor works.

- [ ] **Step 5: Commit**

```bash
git add scripts/seed-onboarding-status.sh
git commit -m "fix(seed-onboarding-status): anchor DOC to repo root via SCRIPT_DIR (MED-7)"
```

### Task 7: MED-8 — post-prerelease-comment commit_sha input

**Files:**
- Modify: `actions/post-prerelease-comment/action.yml`

NOTE: LOW-4 (step `id:` on the Compose body step) is already done — the step already has `id: body`. Skip that portion of the original spec.

- [ ] **Step 1: Add `commit_sha` input**

Edit `actions/post-prerelease-comment/action.yml`. Find the `inputs:` block. Add a new input AFTER `trivy_status:` (preserves existing ordering):

```yaml
  trivy_status:
    description: 'Optional Trivy result line (e.g. "✅ no HIGH/CRITICAL").'
    required: false
    default: ''
  commit_sha:
    description: 'Optional commit SHA; if unset, derived from image_ref tag (best-effort).'
    required: false
    default: ''
  github_token:
    description: 'Token with pull-requests:write permission.'
    required: false
    default: ${{ github.token }}
```

- [ ] **Step 2: Use commit_sha in the Compose body step**

Find the `Compose body` step. Add `COMMIT_SHA` to the `env:` block AND update the SHORT_SHA derivation logic. The result should look like:

```yaml
    - name: Compose body
      id: body
      shell: bash
      env:
        IMAGE_REF: ${{ inputs.image_ref }}
        TRIVY_STATUS: ${{ inputs.trivy_status }}
        COMMIT_SHA: ${{ inputs.commit_sha }}
      run: |
        if [[ -n "$COMMIT_SHA" ]]; then
          SHORT_SHA="${COMMIT_SHA:0:7}"
        else
          SHORT_SHA=$(echo "$IMAGE_REF" | rev | cut -d- -f1 | rev | cut -c1-7)
        fi
        BODY=$(cat <<EOF
        <!-- prerelease-image-comment -->
        🐳 **Prerelease image ready**
        ...
```

(Preserve the rest of the BODY heredoc and the TRIVY_STATUS handling exactly as-is.)

- [ ] **Step 3: Smoke-test logic with both code paths**

Quick mental verification:
- `COMMIT_SHA=abc1234567xyz` → `SHORT_SHA="${COMMIT_SHA:0:7}"` → `abc1234`
- `COMMIT_SHA=''` (default) → falls back to `rev | cut | rev | cut` → existing behavior preserved byte-identically for existing callers

- [ ] **Step 4: Lint**

```bash
yamllint -s actions/post-prerelease-comment/action.yml
actionlint actions/post-prerelease-comment/action.yml
```

Expected: silent.

- [ ] **Step 5: Commit**

```bash
git add actions/post-prerelease-comment/action.yml
git commit -m "feat(post-prerelease-comment): add commit_sha input (MED-8)"
```

### Task 8: MED-9 — local -A seen in detect_components

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (around line 230)

- [ ] **Step 1: Find the declare -A line**

```bash
rg "declare -A seen" scripts/lib/onboard-detect-lib.sh -n -B2 -A 2
```

Expected:
```bash
  # De-duplicate while preserving order
  declare -A seen=()
  local unique=()
```

- [ ] **Step 2: Change `declare -A` to `local -A`**

Edit `scripts/lib/onboard-detect-lib.sh`. Replace:
```bash
  declare -A seen=()
```
with:
```bash
  local -A seen=()
```

(One-line change.)

- [ ] **Step 3: Run full bats to verify no regression**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: 61 tests pass (matches Task 4 baseline).

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh
git commit -m "fix(onboard-detect): local -A seen in detect_components (MED-9)"
```

### Task 9: LOW-1 — docker-build event_name check

**Files:**
- Modify: `.github/workflows/docker-build.yml` (around line 436)

- [ ] **Step 1: Find the if condition**

```bash
rg "pull_request\.number != ''" .github/workflows/docker-build.yml -n -B2 -A2
```

Expected:
```yaml
  post-comment:
    if: inputs.prerelease && github.event.pull_request.number != ''
    needs: [version, merge]
```

- [ ] **Step 2: Replace with event_name check**

Edit `.github/workflows/docker-build.yml`. Change:
```yaml
    if: inputs.prerelease && github.event.pull_request.number != ''
```
to:
```yaml
    if: inputs.prerelease && github.event_name == 'pull_request'
```

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/docker-build.yml
actionlint .github/workflows/docker-build.yml 2>&1 | head
```

Expected: silent.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/docker-build.yml
git commit -m "fix(docker-build): use event_name instead of PR number string check (LOW-1)"
```

### Task 10: LOW-2 — stale "6 rendered files" comment

**Files:**
- Modify: `.github/workflows/onboard.yml` (around line 245)

- [ ] **Step 1: Find the comment**

```bash
rg "6 rendered files" .github/workflows/onboard.yml -n
```

Expected: one line:
```
  245:          # Reset index, then explicitly add only the 6 rendered files.
```

- [ ] **Step 2: Update comment to 7**

Edit `.github/workflows/onboard.yml`. Change:
```
          # Reset index, then explicitly add only the 6 rendered files.
```
to:
```
          # Reset index, then explicitly add only the 7 rendered files.
```

- [ ] **Step 3: Verify count matches RENDERED array**

```bash
rg "RENDERED=" .github/workflows/onboard.yml -n -A 10 | head -15
```

Expected: an array with 7 entries (ci/release/prerelease/cleanup workflow yml + onboard.lock.json + release-please-config + release-please-manifest). If the count doesn't match 7, the comment is still stale — update to actual count.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "fix(onboard): update stale '6 rendered files' comment to 7 (LOW-2)"
```

### Task 11: LOW-3 — cleanup-images contents: read

**Files:**
- Modify: `.github/workflows/cleanup-images.yml` (around line 27)

- [ ] **Step 1: Find the permissions block**

```bash
rg "permissions:" .github/workflows/cleanup-images.yml -n -A 3
```

Expected:
```yaml
permissions:
  packages: write
```

- [ ] **Step 2: Add contents: read**

Edit `.github/workflows/cleanup-images.yml`. Change:
```yaml
permissions:
  packages: write
```
to:
```yaml
permissions:
  contents: read
  packages: write
```

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/cleanup-images.yml
actionlint .github/workflows/cleanup-images.yml
```

Expected: silent.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/cleanup-images.yml
git commit -m "fix(cleanup-images): declare explicit contents:read permission (LOW-3)"
```

### Task 12: LOW-5 — goreleaser packages: write

**Files:**
- Modify: `.github/workflows/goreleaser.yml` (around line 39)

- [ ] **Step 1: Find permissions block**

```bash
rg "permissions:" .github/workflows/goreleaser.yml -n -A 3
```

Expected:
```yaml
permissions:
  contents: write
```

- [ ] **Step 2: Add packages: write**

Edit `.github/workflows/goreleaser.yml`. Change:
```yaml
permissions:
  contents: write
```
to:
```yaml
permissions:
  contents: write
  # packages: write — required when .goreleaser.yaml has a dockers: block
  packages: write
```

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/goreleaser.yml
actionlint .github/workflows/goreleaser.yml
```

Expected: silent.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/goreleaser.yml
git commit -m "fix(goreleaser): add packages:write for GHCR push (LOW-5)"
```

### Task 13: LOW-8 — onboard finalize-job explicit permissions

**Files:**
- Modify: `.github/workflows/onboard.yml` (finalize job at line 466)

- [ ] **Step 1: Read the finalize job header**

```bash
sed -n '466,475p' .github/workflows/onboard.yml
```

Expected:
```yaml
  finalize:
    needs: onboard
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
```

(No explicit `permissions:` block on the job.)

- [ ] **Step 2: Read what the finalize job actually does**

```bash
sed -n '466,640p' .github/workflows/onboard.yml | grep -E "uses:|step:|name:" | head -20
```

The job mints an App-token, checks out the catalog, downloads artifacts, builds a summary, updates `docs/onboarding-status.md`, commits and pushes to the catalog's main branch.

Required permissions on the **GITHUB_TOKEN** (caller-side, not the App-token):
- The job uses an App-token for the catalog push — GITHUB_TOKEN is NOT used for write operations
- `actions/download-artifact@v8` reads artifacts from the current run — needs `actions: read` (typically inherited)
- No PR creation in the finalize job itself

The minimum-required GITHUB_TOKEN permission is `actions: read` (or none if the artifact-download step doesn't actually need a token).

- [ ] **Step 3: Add explicit permissions block**

Edit `.github/workflows/onboard.yml`. Insert a `permissions:` block between `timeout-minutes:` and `steps:`:

```yaml
  finalize:
    needs: onboard
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      actions: read
    steps:
```

(The job's actual writes happen via the App-token minted inside, not via GITHUB_TOKEN — so the GITHUB_TOKEN permission can be read-only. Explicit > implicit.)

- [ ] **Step 4: Lint**

```bash
yamllint -s .github/workflows/onboard.yml
actionlint .github/workflows/onboard.yml 2>&1 | head
```

Expected: silent (or pre-existing client-id stale-data noise — unaffected).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "fix(onboard): explicit permissions on finalize job (LOW-8)"
```

### Task 14: Push PR-N and open pull request

**Files:** none (git/gh only)

- [ ] **Step 1: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected (13 commits, newest first):
```
xxxxxxx fix(onboard): explicit permissions on finalize job (LOW-8)
xxxxxxx fix(goreleaser): add packages:write for GHCR push (LOW-5)
xxxxxxx fix(cleanup-images): declare explicit contents:read permission (LOW-3)
xxxxxxx fix(onboard): update stale '6 rendered files' comment to 7 (LOW-2)
xxxxxxx fix(docker-build): use event_name instead of PR number string check (LOW-1)
xxxxxxx fix(onboard-detect): local -A seen in detect_components (MED-9)
xxxxxxx feat(post-prerelease-comment): add commit_sha input (MED-8)
xxxxxxx fix(seed-onboarding-status): anchor DOC to repo root via SCRIPT_DIR (MED-7)
xxxxxxx fix(install-trivy): trap mktemp tempdir on EXIT (MED-6)
xxxxxxx test(onboard-detect): go.work single-entry fixture and bats (MED-5)
xxxxxxx fix(onboard-detect): handle go.work single-entry use form (MED-5)
xxxxxxx fix(helm-publish): bump helm default to v3.16.3 to match lint-helm (MED-4)
xxxxxxx fix(lint-go,test-go): cache-dependency-path in explicit-version branch (MED-1)
```

- [ ] **Step 2: Push branch**

```bash
git push -u origin fix/phase-6-prod-fixes
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head fix/phase-6-prod-fixes \
  --title "fix: phase 6 production bug sweep (PR-N)" \
  --body "$(cat <<'EOF'
## Summary

Closes 12 MED/LOW items from REVIEW-2026-05-22.md:

- **MED-1** — `setup-go` `cache-dependency-path` in the explicit-version branch (was only on go-mod branch)
- **MED-4** — Helm version: `helm-publish` default bumped 3.15.0 → 3.16.3 (matches lint-helm); Renovate anchor added for future sync
- **MED-5** — `detect_components` now handles `go.work` single-entry form (`use ./path`); new `go-work-single` fixture + 2 bats tests
- **MED-6** — `install-trivy` traps mktemp tempdir on EXIT
- **MED-7** — `seed-onboarding-status.sh` anchors `DOC` to repo root via SCRIPT_DIR (was relative, broke from subdir)
- **MED-8** — `post-prerelease-comment` accepts optional `commit_sha` input; falls back to existing `rev|cut` derivation when unset
- **MED-9** — `local -A seen` in `detect_components` (was global `declare -A`)
- **LOW-1** — `docker-build` post-comment if uses `event_name == 'pull_request'` instead of `pull_request.number != ''`
- **LOW-2** — onboard.yml comment "6 rendered files" → 7 (post-#84 reality)
- **LOW-3** — cleanup-images explicit `contents: read` permission
- **LOW-5** — goreleaser explicit `packages: write` permission (required when `dockers:` block present)
- **LOW-8** — onboard finalize-job explicit permissions block

**Dropped from original Phase 6 scope** (already-done, confirmed during planning):
- LOW-4 (post-prerelease step `id:`) — `id: body` already present
- LOW-7, LOW-10, LOW-12 — also already done (covered in PR-O scope reduction)

Companion PR (PR-O) covers docs/templates/fixture cleanup.

Spec: `docs/superpowers/specs/2026-05-23-phase-6-design.md`
Plan: `docs/superpowers/plans/2026-05-23-phase-6-med-low-sweep.md`

## Test plan

- [ ] `bats tests/shell/onboard-detect.bats` green (61 tests, +2 for MED-5)
- [ ] `bats tests/shell/` green (no cross-test pollution)
- [ ] `validate.yml` PR check green (actionlint + yamllint on all touched workflows)
- [ ] `integration.yml` jobs green — production behavior preserved (additive `commit_sha` input on post-prerelease-comment defaults to `''`)
EOF
)"
```

- [ ] **Step 4: Confirm checks status (manual)**

```bash
gh pr view --json statusCheckRollup -q '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Expected after ~5–10 min: all checks SUCCESS.

---

## Pre-flight: Worktree setup (PR-O)

### Task 15: Create PR-O worktree

**Files:** none (git only)

- [ ] **Step 1: Return to repo root and ensure main is current**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
```

- [ ] **Step 2: Create PR-O worktree**

```bash
git worktree add .worktrees/phase-6-docs -b chore/phase-6-docs-templates main
```

Expected: `Preparing worktree (new branch 'chore/phase-6-docs-templates')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: new entry `.worktrees/phase-6-docs [chore/phase-6-docs-templates]`

All PR-O tasks (16–19) execute from `.worktrees/phase-6-docs`.

---

## PR-O — `chore/phase-6-docs-templates`

### Task 16: LOW-6 — drop `secrets: inherit` from cleanup.yml.tmpl

**Files:**
- Modify: `docs/adopter-templates/skeletons/cleanup.yml.tmpl` (line 17)

- [ ] **Step 1: Find the `secrets: inherit` line**

```bash
rg "secrets: inherit" docs/adopter-templates/skeletons/cleanup.yml.tmpl -n -B2 -A 2
```

Expected:
```yaml
  ...some context...
    uses: serverkraken/reusable-workflows/.github/workflows/cleanup-images.yml@{{ $pin }}
    secrets: inherit
    with:
      ...
```

(Exact surrounding lines may vary.)

- [ ] **Step 2: Remove the `secrets: inherit` line**

Edit `docs/adopter-templates/skeletons/cleanup.yml.tmpl`. Delete the line `    secrets: inherit`. The atom uses only `${{ github.token }}` — no `secrets:` block declared on the workflow_call interface.

- [ ] **Step 3: Verify the rendered template**

The template uses gomplate. We can verify the structure by re-rendering against a fixture:

```bash
# From the worktree root, render the template against a known fixture
profile=$(scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/go-repo)
echo "$profile" > /tmp/test-profile.json
tmpdir=$(mktemp -d)
scripts/onboard-render.sh "$PWD" "$tmpdir" /tmp/test-profile.json v3
grep -A 5 "uses:.*cleanup-images" "$tmpdir/.github/workflows/cleanup.yml" || echo "no cleanup uses found"
rm -rf "$tmpdir" /tmp/test-profile.json
```

Expected: the rendered `cleanup.yml` should NOT contain `secrets: inherit` under the cleanup-images uses block.

- [ ] **Step 4: Update golden if affected**

If `tests/shell/onboard-render.bats` has golden_check tests that include `cleanup.yml`, the goldens need to be re-generated. Verify:

```bash
bats tests/shell/onboard-render.bats
```

Expected: tests FAIL with byte-drift in cleanup.yml goldens. If so, regenerate:

```bash
# Inspect what changed:
diff -u tests/shell/golden/go-repo/.github/workflows/cleanup.yml \
  <(scripts/onboard-render.sh "$PWD" $(mktemp -d) /tmp/x v3 2>/dev/null && cat $(mktemp -d)/.github/workflows/cleanup.yml)
```

If the drift is exactly "removed `secrets: inherit` line", regenerate the golden:

```bash
# Identify all golden directories that contain a cleanup.yml
fd "cleanup.yml" tests/shell/golden -t f
# For each, regenerate by re-rendering the fixture
# (the bats golden_check tells you which fixture maps to which golden dir)
```

A cleaner approach: skip golden regeneration here and instead defer to manual: if bats fails with cleanup.yml drift, regenerate the goldens, run bats again, verify drift was localized to `secrets: inherit` removals only.

Note: if no golden tests reference cleanup.yml content, this step is moot.

- [ ] **Step 5: Commit**

```bash
git add docs/adopter-templates/skeletons/cleanup.yml.tmpl
# Also add any regenerated goldens if Step 4 required them:
# git add tests/shell/golden/
git commit -m "fix(cleanup.yml.tmpl): drop unnecessary secrets: inherit (LOW-6)"
```

If golden regeneration was needed, this commit may also include `tests/shell/golden/` changes. Acceptable — the rendered output's drift is the direct consequence of the template change.

- [ ] **Step 6: Run full bats to confirm green**

```bash
bats tests/shell/onboard-render.bats
bats tests/shell/onboard-drift.bats
```

Expected: all PASS after golden regeneration (if needed).

### Task 17: LOW-9 — delete dead simple fixture

**Files:**
- Delete: `tests/fixtures/onboard/simple/` (entire directory)

- [ ] **Step 1: Verify the fixture is dead**

```bash
rg "fixtures/onboard/simple" tests/ -l 2>&1
```

Expected: no matches (no test references the fixture).

```bash
ls -la tests/fixtures/onboard/simple/
```

Expected: just `.gitkeep`.

- [ ] **Step 2: Delete the directory**

```bash
rm -rf tests/fixtures/onboard/simple/
```

- [ ] **Step 3: Verify**

```bash
ls -la tests/fixtures/onboard/simple/ 2>&1
```

Expected: `No such file or directory`.

- [ ] **Step 4: Run full bats**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all tests pass (no fixture was referenced, so removing it doesn't break anything).

- [ ] **Step 5: Commit**

```bash
git add -A tests/fixtures/onboard/
git commit -m "chore(fixtures): remove dead simple fixture (LOW-9)"
```

### Task 18: LOW-11 — CONTRIBUTING act caveats

**Files:**
- Modify: `CONTRIBUTING.md` (around line 14-19)

- [ ] **Step 1: Read the current act mention**

```bash
sed -n '12,22p' CONTRIBUTING.md
```

Expected:
```markdown
For the integration tests, use `act`:

```bash
act pull_request -W .github/workflows/integration.yml --container-architecture linux/amd64
```

(No caveats.)

- [ ] **Step 2: Add caveats**

Edit `CONTRIBUTING.md`. After the `act pull_request ...` code block, append a caveats note:

```markdown
For the integration tests, use `act`:

```bash
act pull_request -W .github/workflows/integration.yml --container-architecture linux/amd64
```

> **`act` limitations.** `act` cannot exercise the self-hosted runner labels
> (defaults to ubuntu-latest images), cannot perform cosign keyless signing
> (no OIDC token in `act`'s runner identity), and cannot push to GHCR without
> a manually-mounted token. For end-to-end validation of those paths, rely
> on the catalog's `integration.yml` self-CI.
```

- [ ] **Step 3: Verify markdown rendering**

```bash
# Quick sanity: does the file still parse cleanly?
yamllint -s CONTRIBUTING.md 2>&1 | head
```

(yamllint doesn't lint markdown, but skipping any silent errors.)

- [ ] **Step 4: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs(CONTRIBUTING): add act caveats for self-hosted/cosign (LOW-11)"
```

### Task 19: Push PR-O and open pull request

**Files:** none (git/gh only)

- [ ] **Step 1: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected (3 commits, newest first):
```
xxxxxxx docs(CONTRIBUTING): add act caveats for self-hosted/cosign (LOW-11)
xxxxxxx chore(fixtures): remove dead simple fixture (LOW-9)
xxxxxxx fix(cleanup.yml.tmpl): drop unnecessary secrets: inherit (LOW-6)
```

If Task 16 required golden regeneration, the first commit may also include `tests/shell/golden/` changes.

- [ ] **Step 2: Push branch**

```bash
git push -u origin chore/phase-6-docs-templates
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head chore/phase-6-docs-templates \
  --title "chore: phase 6 docs / templates / fixture cleanup (PR-O)" \
  --body "$(cat <<'EOF'
## Summary

Closes 3 LOW items from REVIEW-2026-05-22.md:

- **LOW-6** — `cleanup.yml.tmpl` drops the unnecessary `secrets: inherit` (the atom uses only `${{ github.token }}`)
- **LOW-9** — delete dead `tests/fixtures/onboard/simple/` (contained only `.gitkeep`, no test references)
- **LOW-11** — `CONTRIBUTING.md` adds caveats about `act` limitations (no self-hosted, no cosign, no GHCR push)

**Dropped from original Phase 6 scope** (already-done, confirmed during planning):
- LOW-7 (`setup-python-deps` header comment) — already correct
- LOW-10 (README `setup-python-deps` row) — already present
- LOW-12 (backlog Lint/Test entry) — already removed

Companion PR (PR-N #xxx) covers 12 production bug fixes (MED-1, 4, 5, 6, 7, 8, 9 + LOW-1, 2, 3, 5, 8).

Spec: `docs/superpowers/specs/2026-05-23-phase-6-design.md`
Plan: `docs/superpowers/plans/2026-05-23-phase-6-med-low-sweep.md`

## Test plan

- [ ] `bats tests/shell/onboard-render.bats` green (golden_check passes after any cleanup.yml golden regeneration)
- [ ] `bats tests/shell/onboard-drift.bats` green
- [ ] `validate.yml` PR check green (no workflow changes, but markdown shouldn't break anything)
EOF
)"
```

Replace `#xxx` with the PR-N number from Task 14.

- [ ] **Step 4: Confirm checks status**

```bash
gh pr view --json statusCheckRollup -q '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Expected after ~3–5 min: all checks SUCCESS.

---

## Post-merge: cleanup

### Task 20: Remove worktrees after both PRs are merged

**Files:** none (git only)

- [ ] **Step 1: Verify both PRs merged**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
gh pr list --state merged --search "fix/phase-6-prod-fixes" --json number,mergedAt
gh pr list --state merged --search "chore/phase-6-docs-templates" --json number,mergedAt
```

Expected: both show a non-null `mergedAt`.

- [ ] **Step 2: Sync local main**

```bash
git checkout main
git pull --rebase origin main
```

- [ ] **Step 3: Remove worktrees + branches**

```bash
git worktree remove .worktrees/phase-6-prod
git worktree remove .worktrees/phase-6-docs
git branch -d fix/phase-6-prod-fixes chore/phase-6-docs-templates
```

- [ ] **Step 4: Confirm cleanup**

```bash
git worktree list
```

Expected: only `main` and unrelated worktrees remain.

---

## Self-Review (writer's checklist — performed at plan-write time)

**1. Spec coverage:**
- MED-1 cache-dep-path → Task 1 ✓
- MED-4 helm sync → Task 2 ✓
- MED-5 go.work single-entry → Tasks 3 + 4 ✓
- MED-6 install-trivy trap → Task 5 ✓
- MED-7 seed-onboarding-status anchor → Task 6 ✓
- MED-8 post-prerelease-comment commit_sha → Task 7 ✓
- MED-9 local -A seen → Task 8 ✓
- LOW-1 event_name check → Task 9 ✓
- LOW-2 "6 rendered files" → 7 → Task 10 ✓
- LOW-3 cleanup-images contents:read → Task 11 ✓
- LOW-5 goreleaser packages:write → Task 12 ✓
- LOW-8 onboard finalize permissions → Task 13 ✓
- LOW-6 cleanup.yml.tmpl secrets:inherit → Task 16 ✓
- LOW-9 dead simple fixture → Task 17 ✓
- LOW-11 CONTRIBUTING act caveats → Task 18 ✓
- LOW-4, LOW-7, LOW-10, LOW-12 dropped (verified already-done) → noted in plan header + both PR bodies
- Push PRs → Tasks 14, 19 ✓
- Worktree cleanup → Task 20 ✓

**2. Placeholder scan:** No TBDs or vague requirements. Each step has concrete commands and exact content.

**3. Type consistency:**
- Variable names, file paths, commit messages consistent across tasks
- LOW-8's `permissions: contents: read + actions: read` chosen based on actual finalize-job behavior (App-token does writes; GITHUB_TOKEN is read-only)
- Task 4's `61 tests` matches Task 3's `+2 tests` from Phase 5 baseline of 59
- Task 16 acknowledges potential golden regeneration explicitly rather than assuming it isn't needed
