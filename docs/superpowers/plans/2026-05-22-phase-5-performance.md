# Phase 5 Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land five performance items from REVIEW-2026-05-22.md (PERF-1 timeouts on every workflow, PERF-2 jq-in-loop refactor at 4 spots, PERF-3 combined-grep in detect_legacy_ci, PERF-4/MED-11 onboard-detect 1×-call via new `--emit-both` mode, PERF-5 single-awk read_image_override) across two file-disjoint PRs.

**Architecture:** PR-L adds `timeout-minutes:` per § F table to every job in all 21 workflows. PR-M refactors shell perf in `scripts/lib/onboard-detect-lib.sh`, `scripts/onboard-render.sh`, `scripts/onboard-detect.sh`, and the action wrapper at `actions/onboard-detect/action.yml`. All commits `perf:`/`refactor:`/`feat:`/`test:` — at most patch bump.

**Tech Stack:** GitHub Actions reusable workflows, bash 5+, jq, bats-core 1.13, gomplate.

---

## Pre-flight: Worktree setup (PR-L)

### Task 0L.1: Sync main and create PR-L worktree

**Files:** none (git only)

- [ ] **Step 1: Sync local main**

Run from repo root:
```bash
git fetch origin main
git checkout main
git pull --rebase origin main
```

Expected: `Your branch is up to date with 'origin/main'.`

- [ ] **Step 2: Create PR-L worktree**

```bash
git worktree add .worktrees/phase-5-timeouts -b perf/phase-5-workflow-timeouts main
```

Expected: `Preparing worktree (new branch 'perf/phase-5-workflow-timeouts')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: new entry `.worktrees/phase-5-timeouts [perf/phase-5-workflow-timeouts]`

All subsequent PR-L tasks (1) execute from `.worktrees/phase-5-timeouts`.

---

## PR-L — `perf/phase-5-workflow-timeouts`

### Task 1: Add timeout-minutes to every job in all 21 workflows

**Files:** all 21 files in `.github/workflows/`

This is a single mechanical pass. `timeout-minutes:` goes immediately after `runs-on:` for each job. Use the table below.

| File | Job → minutes |
|---|---|
| `lint-go.yml` | `lint` → 15 |
| `lint-python.yml` | `lint` → 15 |
| `lint-rust.yml` | `lint` → 15 |
| `lint-helm.yml` | `lint` → 15 |
| `test-go.yml` | `test` → 30 |
| `test-python.yml` | `test` → 30 |
| `test-rust.yml` | `test` → 30 |
| `docker-build.yml` | every job → 60 |
| `docker-build-multi.yml` | every job → 60 |
| `trivy-fs.yml` | `scan` → 20 |
| `trivy-image.yml` | `scan` → 20 |
| `semantic-release.yml` | `release` → 15 |
| `goreleaser.yml` | `release` → 15 |
| `helm-publish.yml` | `publish` → 10 |
| `cleanup-images.yml` | `cleanup` → 15 |
| `onboard.yml` | every job → 30 |
| `drift-check.yml` | every job → 30 |
| `release.yml` | every job → 60 |
| `validate.yml` | every job → 30 |
| `integration.yml` | every job → 30 |
| `catalog-release.yml` | every job → 30 |

- [ ] **Step 1: Read each workflow file to find all `runs-on:` lines**

For each of the 21 files, find every `runs-on:` line. The job header above it tells you which job you're in (the table tells you the minutes value).

Run (from worktree root):
```bash
rg "^[[:space:]]+runs-on:" .github/workflows/ -n | wc -l
```

This counts how many `timeout-minutes:` insertions you must perform total. (For reference, this should be roughly 30-40 jobs across 21 files — some workflows have multiple jobs.)

- [ ] **Step 2: Insert `timeout-minutes:` after `runs-on:` for each job**

For each `runs-on:` line, insert a new line immediately after with the same indentation:
```
    timeout-minutes: <N>
```

**Example transformation** (lint-go.yml line 50):

Before:
```yaml
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
```

After:
```yaml
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 15
    steps:
```

The indentation of `timeout-minutes:` matches the indentation of `runs-on:` (4 spaces for a job-level key in this repo's style).

**Per-workflow scan order** — do them alphabetically to avoid missing any:
1. `catalog-release.yml` → 30 on every job
2. `cleanup-images.yml` → 15 on `cleanup`
3. `docker-build-multi.yml` → 60 on every job
4. `docker-build.yml` → 60 on every job
5. `drift-check.yml` → 30 on every job
6. `goreleaser.yml` → 15 on `release`
7. `helm-publish.yml` → 10 on `publish`
8. `integration.yml` → 30 on every job (every `runs-on:` you find, regardless of job name)
9. `lint-go.yml` → 15 on `lint`
10. `lint-helm.yml` → 15 on `lint`
11. `lint-python.yml` → 15 on `lint`
12. `lint-rust.yml` → 15 on `lint`
13. `onboard.yml` → 30 on every job
14. `release.yml` → 60 on every job
15. `semantic-release.yml` → 15 on `release`
16. `test-go.yml` → 30 on `test`
17. `test-python.yml` → 30 on `test`
18. `test-rust.yml` → 30 on `test`
19. `trivy-fs.yml` → 20 on `scan`
20. `trivy-image.yml` → 20 on `scan`
21. `validate.yml` → 30 on every job

- [ ] **Step 3: Verify every job has timeout-minutes**

After editing, count: every `runs-on:` line should have a matching `timeout-minutes:` immediately after it. Run:
```bash
runs_on_count=$(rg -c "^[[:space:]]+runs-on:" .github/workflows/ | awk -F: '{sum+=$2} END {print sum}')
timeout_count=$(rg -c "^[[:space:]]+timeout-minutes:" .github/workflows/ | awk -F: '{sum+=$2} END {print sum}')
echo "runs-on: $runs_on_count, timeout-minutes: $timeout_count"
```

Expected: both counts identical.

If they differ, find the missing one:
```bash
# Print every runs-on line with its immediate next line:
rg -A1 "^[[:space:]]+runs-on:" .github/workflows/
```
Any block where the line after `runs-on:` is NOT `timeout-minutes:` is missing the insertion.

- [ ] **Step 4: Lint locally**

```bash
yamllint -s .github/
actionlint .github/workflows/*.yml 2>&1 | head -30
```

Expected: both silent (exit 0). actionlint understands `timeout-minutes:` on jobs natively — no ignores needed.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/
git commit -m "perf(workflows): add timeout-minutes to every job"
```

### Task 2: Push PR-L and open pull request

**Files:** none (git/gh only)

- [ ] **Step 1: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected (1 commit):
```
xxxxxxx perf(workflows): add timeout-minutes to every job
```

- [ ] **Step 2: Push branch**

```bash
git push -u origin perf/phase-5-workflow-timeouts
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head perf/phase-5-workflow-timeouts \
  --title "perf(workflows): add timeout-minutes to every job (PR-L)" \
  --body "$(cat <<'EOF'
## Summary

Closes PERF-1 from REVIEW-2026-05-22.md § F. Every job in all 21 catalog workflows now has an explicit `timeout-minutes:` per the § F table (lint 15min, test 30min, docker-build 60min, trivy 20min, semantic-release/goreleaser 15min, helm-publish 10min, cleanup 15min, onboard/drift/validate/integration/catalog-release 30min, release 60min).

GHA default is 360min (6h); tightening to 10–60min limits the worst-case runner-slot hold for stuck jobs. Companion PR (PR-M) covers shell-script perf items.

Spec: `docs/superpowers/specs/2026-05-22-phase-5-design.md`
Plan: `docs/superpowers/plans/2026-05-22-phase-5-performance.md`

## Test plan

- [ ] `validate.yml` PR check green (actionlint + yamllint)
- [ ] `integration.yml` PR check green (no existing job hits its new limit)
- [ ] Every `runs-on:` in `.github/workflows/` has a matching `timeout-minutes:` immediately after
EOF
)"
```

- [ ] **Step 4: Confirm PR check status**

```bash
gh pr view --json statusCheckRollup -q '.statusCheckRollup[] | "\(.name): \(.conclusion // .status)"'
```

Expected after ~5–10 min: all checks SUCCESS.

---

## Pre-flight: Worktree setup (PR-M)

PR-M is independent of PR-L (file-disjoint). Can be created at any time, including before PR-L merges.

### Task 0M.1: Create PR-M worktree

**Files:** none (git only)

- [ ] **Step 1: Return to repo root and ensure main is current**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
```

- [ ] **Step 2: Create PR-M worktree**

```bash
git worktree add .worktrees/phase-5-scripts -b perf/phase-5-onboard-scripts main
```

Expected: `Preparing worktree (new branch 'perf/phase-5-onboard-scripts')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

All subsequent PR-M tasks (3–10) execute from `.worktrees/phase-5-scripts`.

---

## PR-M — `perf/phase-5-onboard-scripts`

### Task 3: PERF-3 — combine 4 grep calls in detect_legacy_ci into single alternation

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh:494-504`

- [ ] **Step 1: Read the current function**

```bash
sed -n '494,504p' scripts/lib/onboard-detect-lib.sh
```

Expected:
```bash
detect_legacy_ci() {
  local repo="$1" file="$2"
  grep -qE 'serverkraken/reusable-workflows/' "$file" && return 0
  grep -qE 'aquasecurity/trivy-action' "$file" && return 0
  grep -qE 'cargo (build|test|clippy)' "$file" && return 0
  grep -qE 'helm (lint|publish)' "$file" && return 0
  return 1
}
```

(Exact line numbers may shift slightly — find the function by `rg "^detect_legacy_ci" scripts/lib/onboard-detect-lib.sh`. The above is the body to replace.)

**Note:** There is ALSO an outer function named `detect_legacy_ci` (no args — it iterates workflow files and emits a JSON array). That outer function is the one referenced at line 573 with the jq-in-loop. **This task touches the inner two-argument function (the one with the 4 grep calls).** Make sure you're editing the right one.

Verify which is which by line-number lookup:
```bash
rg "^detect_legacy_ci|^detect_legacy_ci\(\)" scripts/lib/onboard-detect-lib.sh -n
```

The inner helper takes `<repo> <file>` (2 args). The outer iterator takes `<repo>` (1 arg) and contains the `arr=$(echo "$arr" | jq ...)` loop.

- [ ] **Step 2: Replace the body with a single combined grep**

Edit `scripts/lib/onboard-detect-lib.sh`. Replace:
```bash
detect_legacy_ci() {
  local repo="$1" file="$2"
  grep -qE 'serverkraken/reusable-workflows/' "$file" && return 0
  grep -qE 'aquasecurity/trivy-action' "$file" && return 0
  grep -qE 'cargo (build|test|clippy)' "$file" && return 0
  grep -qE 'helm (lint|publish)' "$file" && return 0
  return 1
}
```

with:
```bash
detect_legacy_ci() {
  local repo="$1" file="$2"
  grep -qE 'serverkraken/reusable-workflows/|aquasecurity/trivy-action|cargo (build|test|clippy)|helm (lint|publish)' "$file"
}
```

The single grep returns 0 if any alternative matches, 1 otherwise — semantically identical to the original short-circuit chain. `local repo="$1"` is unused but kept to preserve the function signature (other code might pass `repo` defensively; removing it is a separate concern).

Actually `repo` IS unused. Drop it:
```bash
detect_legacy_ci() {
  local file="$2"
  grep -qE 'serverkraken/reusable-workflows/|aquasecurity/trivy-action|cargo (build|test|clippy)|helm (lint|publish)' "$file"
}
```

`local file="$2"` keeps the existing call sites working (callers pass `$repo $file` per the original signature). Removing `$1` from the signature would require updating callers and is out of scope.

- [ ] **Step 3: Run bats to confirm no regression**

```bash
bats tests/shell/onboard-detect.bats --filter "detect_legacy_ci"
```

Expected: all `detect_legacy_ci` tests PASS (the review § G.3 lists 3 existing tests for this function).

- [ ] **Step 4: Run full onboard-detect.bats**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all 57 tests pass (the count from the Phase 4 baseline).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh
git commit -m "perf(onboard-detect): combine 4 legacy_ci grep calls into single alternation"
```

### Task 4: PERF-5 — replace head|grep|sed in read_image_override with single awk

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (`read_image_override` function)

- [ ] **Step 1: Find the function**

```bash
rg "^read_image_override" scripts/lib/onboard-detect-lib.sh -n -A 5
```

Expected: a function around line 340-350 with body containing `head -5 ... | grep -E ... | sed -E ...`.

- [ ] **Step 2: Read the current implementation**

The current body is:
```bash
read_image_override() {
  local f="$1"
  head -5 "$f" | grep -E '^# onboard:image=' | sed -E 's/^# onboard:image=//' | head -n 1
}
```

(The closing `| head -n 1` may or may not be there — preserve whatever logic the current function has for "first match only".)

- [ ] **Step 3: Replace with single awk**

Edit `scripts/lib/onboard-detect-lib.sh`. Replace the function body with:
```bash
read_image_override() {
  local f="$1"
  awk '/^# onboard:image=/{sub(/^# onboard:image=/,""); print; exit} NR>5{exit}' "$f"
}
```

Semantics:
- `/^# onboard:image=/` matches lines that start with the override comment
- `sub(...)` strips the prefix
- `print; exit` emits the value and stops on the first match (equivalent to `| head -n 1`)
- `NR>5{exit}` enforces the 5-line limit (equivalent to `head -5 |`)

- [ ] **Step 4: Run bats tests for read_image_override**

```bash
bats tests/shell/onboard-detect.bats --filter "read_image_override"
```

Expected: all PASS.

- [ ] **Step 5: Run full onboard-detect.bats**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all 57 tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh
git commit -m "perf(onboard-detect): replace head|grep|sed in read_image_override with single awk"
```

### Task 5: PERF-2 — slurp-pattern at 3 detect-lib array builders

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (3 spots: `detect_components`, `inventory_dockerfiles`, outer `detect_legacy_ci` iterator)

Each spot has the same pattern: a `for` loop that grows an `arr` variable by re-piping through `jq`. We replace each with a bash-array `entries[]` builder + one final `jq -cs '.'` slurp.

- [ ] **Step 1: Refactor spot 1 — detect_components (around line 246)**

Find the function: `rg "^detect_components" scripts/lib/onboard-detect-lib.sh -n`.

Locate the `arr='[]'` initialization and the `for p in "${unique[@]}"; do ... arr=$(echo "$arr" | jq ...)` loop within it.

**Before:**
```bash
  local arr='[]'
  for p in "${unique[@]}"; do
    local langs role dockerfiles primary signals cgo
    langs=$(detect_languages "$repo" "$p")
    dockerfiles=$(inventory_dockerfiles "$repo" "$p")
    role=$(detect_role "$repo" "$p" "$dockerfiles")
    primary=$(echo "$langs" | jq -r '.[0] // "generic"')
    signals=$(detect_release_signals "$repo" "$p")
    cgo=$(detect_cgo "$repo" "$p" "$primary")

    arr=$(echo "$arr" | jq \
      --arg path "$p" \
      --argjson languages "$langs" \
      --arg primary "$primary" \
      --arg role "$role" \
      --argjson dockerfiles "$dockerfiles" \
      --argjson signals "$signals" \
      --argjson cgo "$cgo" \
      '. + [{
        path: $path,
        languages: $languages,
        primary_language: $primary,
        release_please_type: $primary,
        role: $role,
        dockerfiles: $dockerfiles,
        release_signals: $signals,
        cgo: $cgo
      }]')
  done
  echo "$arr"
```

**After:**
```bash
  local entries=()
  for p in "${unique[@]}"; do
    local langs role dockerfiles primary signals cgo
    langs=$(detect_languages "$repo" "$p")
    dockerfiles=$(inventory_dockerfiles "$repo" "$p")
    role=$(detect_role "$repo" "$p" "$dockerfiles")
    primary=$(echo "$langs" | jq -r '.[0] // "generic"')
    signals=$(detect_release_signals "$repo" "$p")
    cgo=$(detect_cgo "$repo" "$p" "$primary")

    entries+=("$(jq -nc \
      --arg path "$p" \
      --argjson languages "$langs" \
      --arg primary "$primary" \
      --arg role "$role" \
      --argjson dockerfiles "$dockerfiles" \
      --argjson signals "$signals" \
      --argjson cgo "$cgo" \
      '{
        path: $path,
        languages: $languages,
        primary_language: $primary,
        release_please_type: $primary,
        role: $role,
        dockerfiles: $dockerfiles,
        release_signals: $signals,
        cgo: $cgo
      }')")
  done
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${entries[@]}" | jq -cs '.'
  fi
```

- [ ] **Step 2: Refactor spot 2 — inventory_dockerfiles (around line 374)**

Find: `rg "^inventory_dockerfiles" scripts/lib/onboard-detect-lib.sh -n`. The loop is `for fname in "${files[@]}"; do ... arr=$(echo "$arr" | jq ...)`.

**Before:**
```bash
  local arr='[]'
  local fname
  for fname in "${files[@]}"; do
    local image_name image_name_source release_eligible release_override
    image_name=$(read_image_override "$p/$fname")
    if [[ -n "$image_name" ]]; then
      image_name_source="override"
    else
      image_name_source="derived"
      image_name=$(derive_image_name "$path" "$fname")
    fi
    if [[ "$fname" == "Dockerfile" || "$fname" == "Containerfile" ]]; then
      release_eligible="true"
    else
      release_eligible="false"
    fi
    release_override=$(read_release_override "$p/$fname")
    if [[ -n "$release_override" ]]; then
      release_eligible="$release_override"
    fi
    arr=$(echo "$arr" | jq \
      --arg path "$fname" \
      --arg image_name "$image_name" \
      --arg image_name_source "$image_name_source" \
      --argjson release_eligible "$release_eligible" \
      '. + [{
        path: $path,
        image_name: $image_name,
        image_name_source: $image_name_source,
        release_eligible: $release_eligible
      }]')
  done
  echo "$arr"
```

**After:**
```bash
  local entries=()
  local fname
  for fname in "${files[@]}"; do
    local image_name image_name_source release_eligible release_override
    image_name=$(read_image_override "$p/$fname")
    if [[ -n "$image_name" ]]; then
      image_name_source="override"
    else
      image_name_source="derived"
      image_name=$(derive_image_name "$path" "$fname")
    fi
    if [[ "$fname" == "Dockerfile" || "$fname" == "Containerfile" ]]; then
      release_eligible="true"
    else
      release_eligible="false"
    fi
    release_override=$(read_release_override "$p/$fname")
    if [[ -n "$release_override" ]]; then
      release_eligible="$release_override"
    fi
    entries+=("$(jq -nc \
      --arg path "$fname" \
      --arg image_name "$image_name" \
      --arg image_name_source "$image_name_source" \
      --argjson release_eligible "$release_eligible" \
      '{
        path: $path,
        image_name: $image_name,
        image_name_source: $image_name_source,
        release_eligible: $release_eligible
      }')")
  done
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${entries[@]}" | jq -cs '.'
  fi
```

- [ ] **Step 3: Refactor spot 3 — outer detect_legacy_ci iterator (around line 573)**

Find the iterator function (NOT the inner 2-arg helper from Task 3 — find the one with the `arr=...` and `find ... | while` pattern, around line 540-585):
```bash
rg "^detect_legacy_ci" scripts/lib/onboard-detect-lib.sh -n
```

Identify the no-arg or single-arg function (the OTHER `detect_legacy_ci` overload if both are present — likely the same name re-defined later or a `detect_legacy_workflows`).

Look around lines 540-585. The pattern to find:
```bash
  local arr='[]'
  while IFS= read -r f; do
    ...
    arr=$(echo "$arr" | jq \
      --arg path "$rel" \
      --arg summary "$summary" \
      --argjson replaced_by "$replacements" \
      '. + [{path: $path, summary: $summary, replaced_by: $replaced_by}]')
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort || true)
  echo "$arr"
```

**Before:** (the block above)

**After:**
```bash
  local entries=()
  while IFS= read -r f; do
    ...
    entries+=("$(jq -nc \
      --arg path "$rel" \
      --arg summary "$summary" \
      --argjson replaced_by "$replacements" \
      '{path: $path, summary: $summary, replaced_by: $replaced_by}')")
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort || true)
  if [[ ${#entries[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${entries[@]}" | jq -cs '.'
  fi
```

(Keep the body of the `while IFS= read -r f; do` loop — the `...` representing detection logic that sets `summary`, `replacements`, `rel` — unchanged. Only the array-building line and the trailing `echo "$arr"` change.)

- [ ] **Step 4: Run full bats suite**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all 57 tests pass. If any test fails: the new entries-based code produces different JSON output. The most common cause is forgetting `jq -nc` (need `-n` to create from scratch, `-c` for compact form). Re-read the diff.

- [ ] **Step 5: Run onboard-render golden tests** (these depend on detect output)

```bash
bats tests/shell/onboard-render.bats
```

Expected: all golden_check tests pass — proves detect output is byte-identical.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh
git commit -m "perf(onboard-detect): slurp-pattern for detect_components + inventory_dockerfiles + detect_legacy_ci array builders"
```

### Task 6: PERF-2 — slurp-pattern at render.sh files_json builder

**Files:**
- Modify: `scripts/onboard-render.sh:130-145`

- [ ] **Step 1: Read the current builder**

```bash
sed -n '130,145p' scripts/onboard-render.sh
```

Expected:
```bash
files_json='{}'
for f in "${RENDERED[@]}"; do
  if [[ ! -f "$TARGET/$f" ]]; then
    echo "::error::expected rendered file missing: $f" >&2
    exit 1
  fi
  sha=$(sha256_of "$TARGET/$f")
  files_json=$(echo "$files_json" | jq --arg k "$f" --arg v "sha256:$sha" '. + {($k): $v}')
done
```

- [ ] **Step 2: Replace with bash-array + slurp**

Edit `scripts/onboard-render.sh`. Replace the block above with:
```bash
files_entries=()
for f in "${RENDERED[@]}"; do
  if [[ ! -f "$TARGET/$f" ]]; then
    echo "::error::expected rendered file missing: $f" >&2
    exit 1
  fi
  sha=$(sha256_of "$TARGET/$f")
  files_entries+=("$(jq -nc --arg k "$f" --arg v "sha256:$sha" '{($k): $v}')")
done
if [[ ${#files_entries[@]} -eq 0 ]]; then
  files_json='{}'
else
  files_json=$(printf '%s\n' "${files_entries[@]}" | jq -cs 'add')
fi
```

Note `jq -cs 'add'` (not `jq -cs '.'`): we want to MERGE the per-file `{path: hash}` objects into a single flat object, not produce an array of them.

- [ ] **Step 3: Run render bats tests including golden_check**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all tests pass — golden_check would detect a single byte of drift in any rendered lock file.

- [ ] **Step 4: Run drift bats tests** (these compare a freshly-rendered tree against a stored lock)

```bash
bats tests/shell/onboard-drift.bats
```

Expected: all 8 tests pass — the lock file must be byte-identical to what `drift-clean` (Phase 4 fixture) expects.

- [ ] **Step 5: Commit**

```bash
git add scripts/onboard-render.sh
git commit -m "perf(onboard-render): slurp-pattern for files_json builder"
```

### Task 7: PERF-4 — add --emit-both mode to onboard-detect.sh

**Files:**
- Modify: `scripts/onboard-detect.sh`

This task adds a new dispatch mode that emits both legacy key=value lines AND a `profile_json<<DELIM` multiline block in a single invocation. The next task (Task 8) covers the bats tests; Task 9 wires it into the action.

- [ ] **Step 1: Read the current dispatch logic**

```bash
sed -n '25,45p' scripts/onboard-detect.sh
```

Expected:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dispatch on --profile-json before any positional parsing.
if [[ "${1:-}" == "--profile-json" ]]; then
  # shellcheck source=lib/onboard-detect-lib.sh
  source "$SCRIPT_DIR/lib/onboard-detect-lib.sh"
  shift
  REPO_PATH="${1:-}"
  if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    echo "::error::usage: $0 --profile-json <repo-path>" >&2
    exit 1
  fi
  emit_profile_json "$REPO_PATH"
  exit 0
fi
```

- [ ] **Step 2: Add --emit-both branch before the --profile-json check**

Edit `scripts/onboard-detect.sh`. Insert the new branch BEFORE the existing `--profile-json` dispatch:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dispatch on --emit-both before --profile-json (callers that want both forms
# in a single invocation use this; the action wrapper consumes the output via
# `>> "$GITHUB_OUTPUT"` directly).
if [[ "${1:-}" == "--emit-both" ]]; then
  # shellcheck source=lib/onboard-detect-lib.sh
  source "$SCRIPT_DIR/lib/onboard-detect-lib.sh"
  shift
  REPO_PATH="${1:-}"
  LANG_OVERRIDE="${2:-auto}"
  if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    echo "::error::usage: $0 --emit-both <repo-path> [language-override]" >&2
    exit 1
  fi

  # Language detection (mirrors the legacy fallthrough below).
  if [[ "$LANG_OVERRIDE" != "auto" ]]; then
    language="$LANG_OVERRIDE"
  else
    matches=()
    [[ -f "$REPO_PATH/go.mod" ]]         && matches+=(go)
    [[ -f "$REPO_PATH/pyproject.toml" ]] && matches+=(python)
    [[ -f "$REPO_PATH/Cargo.toml" ]]     && matches+=(rust)
    [[ -f "$REPO_PATH/Chart.yaml" ]]     && matches+=(helm)
    [[ -f "$REPO_PATH/package.json" ]]   && matches+=(node)
    if (( ${#matches[@]} == 0 )); then
      language=simple
    elif (( ${#matches[@]} == 1 )); then
      language="${matches[0]}"
    else
      echo "::error::ambiguous language signals: ${matches[*]}; rerun with explicit language input" >&2
      exit 1
    fi
  fi
  release_type="$language"

  current_version="0.0.0"
  default_branch="main"
  if [[ -n "${TARGET_REPO:-}" ]]; then
    if ! default_branch=$(gh api "/repos/${TARGET_REPO}" -q '.default_branch' 2>/dev/null); then
      echo "::error::repo not accessible: $TARGET_REPO" >&2
      exit 1
    fi
    raw_tag=$(gh release list --repo "$TARGET_REPO" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    if [[ -n "$raw_tag" && "$raw_tag" != "null" ]]; then
      current_version="${raw_tag#v}"
    fi
  fi

  # Emit legacy key=value lines.
  printf 'language=%s\n' "$language"
  printf 'release_type=%s\n' "$release_type"
  printf 'current_version=%s\n' "$current_version"
  printf 'default_branch=%s\n' "$default_branch"

  # Emit profile_json as GITHUB_OUTPUT-compatible multiline block, using cached
  # default_branch and current_version to avoid a second gh api roundtrip.
  delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
  printf 'profile_json<<%s\n' "$delim"
  OVERRIDE_DEFAULT_BRANCH="$default_branch" OVERRIDE_CURRENT_VERSION="$current_version" \
    emit_profile_json "$REPO_PATH"
  printf '%s\n' "$delim"
  exit 0
fi

# Dispatch on --profile-json before any positional parsing.
if [[ "${1:-}" == "--profile-json" ]]; then
```

(The `if [[ "${1:-}" == "--profile-json" ]]` line at the bottom is the existing dispatch — unchanged.)

- [ ] **Step 3: Update emit_profile_json to honor the overrides**

Edit `scripts/lib/onboard-detect-lib.sh`. Find `emit_profile_json` (around line 30). Replace the top of the function:

**Before:**
```bash
emit_profile_json() {
  local repo="$1"
  local target_repo="${TARGET_REPO:-}"
  local default_branch="main"
  local current_version="0.0.0"

  if [[ -n "$target_repo" ]]; then
    default_branch=$(gh api "/repos/$target_repo" -q '.default_branch' 2>/dev/null || echo "main")
    local tag
    tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    [[ -n "$tag" && "$tag" != "null" ]] && current_version="${tag#v}"
  fi
```

**After:**
```bash
emit_profile_json() {
  local repo="$1"
  local target_repo="${TARGET_REPO:-}"
  local default_branch="${OVERRIDE_DEFAULT_BRANCH:-main}"
  local current_version="${OVERRIDE_CURRENT_VERSION:-0.0.0}"

  # When --emit-both invokes us, OVERRIDE_DEFAULT_BRANCH and OVERRIDE_CURRENT_VERSION
  # are already populated from the legacy detection pass — skip the gh calls.
  if [[ -z "${OVERRIDE_DEFAULT_BRANCH:-}" && -n "$target_repo" ]]; then
    default_branch=$(gh api "/repos/$target_repo" -q '.default_branch' 2>/dev/null || echo "main")
    local tag
    tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    [[ -n "$tag" && "$tag" != "null" ]] && current_version="${tag#v}"
  fi
```

The rest of `emit_profile_json` (the components/legacy_ci/jq block) stays unchanged.

- [ ] **Step 4: Verify --profile-json mode still works unchanged**

```bash
bats tests/shell/onboard-detect.bats --filter "profile-json"
```

Expected: all existing profile-json tests pass. The OVERRIDE_* env vars are unset in those test runs, so behavior is byte-identical.

- [ ] **Step 5: Verify legacy mode still works unchanged**

```bash
bats tests/shell/onboard-detect.bats --filter "detects (go|python|rust|helm|node)"
```

Expected: all legacy-mode tests pass.

- [ ] **Step 6: Manual smoke test of --emit-both**

```bash
./scripts/onboard-detect.sh --emit-both tests/fixtures/onboard/go-repo 2>&1
```

Expected output:
```
language=go
release_type=go
current_version=0.0.0
default_branch=main
profile_json<<EOF_<random>
{"schema_version":1,"target_repo":"",..."warnings":[]}
EOF_<random>
```

If the EOF delimiters don't match, or the JSON is malformed, fix before continuing.

- [ ] **Step 7: Commit**

```bash
git add scripts/onboard-detect.sh scripts/lib/onboard-detect-lib.sh
git commit -m "feat(onboard-detect): add --emit-both mode for action 1×-call"
```

### Task 8: Bats coverage for --emit-both

**Files:**
- Modify: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Append two new tests**

Add the following two tests to the end of `tests/shell/onboard-detect.bats`:

```bats
@test "--emit-both emits legacy key=value lines AND profile_json block" {
  run "$DETECT" --emit-both "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
  [[ "$output" == *"release_type=go"* ]]
  [[ "$output" == *"current_version=0.0.0"* ]]
  [[ "$output" == *"default_branch=main"* ]]
  [[ "$output" == *"profile_json<<EOF_"* ]]
}

@test "--emit-both profile_json block contains valid JSON" {
  run "$DETECT" --emit-both "$FIX/go-repo"
  [ "$status" -eq 0 ]
  # Extract the profile_json block content between the delimiter markers.
  # The first line of the block is "profile_json<<EOF_<hash>"; the closing
  # marker is "EOF_<hash>" on its own line. We use awk to find both.
  block=$(echo "$output" | awk '
    /^profile_json<<EOF_/ {
      delim = $0
      sub(/^profile_json<</, "", delim)
      flag = 1
      next
    }
    flag && $0 == delim { flag = 0; next }
    flag { print }
  ')
  # Validate that the extracted block is valid JSON with the expected schema.
  echo "$block" | jq -e '.schema_version == 1 and (.components | type == "array")'
}
```

- [ ] **Step 2: Run the two new tests**

```bash
bats tests/shell/onboard-detect.bats --filter "emit-both"
```

Expected: 2 tests PASS.

- [ ] **Step 3: Run the full bats file**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: 59 tests pass (was 57; +2 for `--emit-both`).

- [ ] **Step 4: Commit**

```bash
git add tests/shell/onboard-detect.bats
git commit -m "test(onboard-detect): cover --emit-both mode"
```

### Task 9: Wire action.yml to use --emit-both (single invocation)

**Files:**
- Modify: `actions/onboard-detect/action.yml`

- [ ] **Step 1: Read the current run block**

```bash
sed -n '38,60p' actions/onboard-detect/action.yml
```

Expected (approximately):
```yaml
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

- [ ] **Step 2: Replace the run block with a single invocation**

Edit `actions/onboard-detect/action.yml`. Replace the `run: |` block above with:

```yaml
      run: |
        set -euo pipefail
        # Inputs are passed via env to avoid GHA expression interpolation into
        # shell text (a single-quote in any input would terminate the quoted
        # section and inject shell code). The --emit-both mode produces both
        # the legacy key=value outputs AND a profile_json<<DELIM multiline block
        # in a single script invocation, halving gh api roundtrips and avoiding
        # the second shell-startup cost.
        #
        # The action lives in actions/onboard-detect/action.yml; the script
        # lives in scripts/. When invoked via the catalog-checkout pattern,
        # $GITHUB_ACTION_PATH is .catalog/actions/onboard-detect/ so
        # ../../scripts/onboard-detect.sh resolves to .catalog/scripts/onboard-detect.sh.
        "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --emit-both \
          "$REPO_PATH" "$LANG_OVERRIDE" >> "$GITHUB_OUTPUT"
```

The action's `outputs:` block (with `language`, `release_type`, `current_version`, `default_branch`, `profile_json`) is unchanged — they all map to `steps.detect.outputs.X` and the script emits all 5 lines.

- [ ] **Step 3: Lint the action**

```bash
actionlint actions/onboard-detect/action.yml
```

Expected: silent (composite action's run blocks aren't deeply validated by actionlint, but no obvious issues).

```bash
yamllint -s actions/onboard-detect/action.yml
```

Expected: silent.

- [ ] **Step 4: Commit**

```bash
git add actions/onboard-detect/action.yml
git commit -m "perf(onboard-detect): action calls script once via --emit-both"
```

### Task 10: Push PR-M and open pull request

**Files:** none (git/gh only)

- [ ] **Step 1: Verify commit log**

```bash
git log --oneline main..HEAD
```

Expected (6 commits, newest first):
```
xxxxxxx perf(onboard-detect): action calls script once via --emit-both
xxxxxxx test(onboard-detect): cover --emit-both mode
xxxxxxx feat(onboard-detect): add --emit-both mode for action 1×-call
xxxxxxx perf(onboard-render): slurp-pattern for files_json builder
xxxxxxx perf(onboard-detect): slurp-pattern for detect_components + inventory_dockerfiles + detect_legacy_ci array builders
xxxxxxx perf(onboard-detect): replace head|grep|sed in read_image_override with single awk
xxxxxxx perf(onboard-detect): combine 4 legacy_ci grep calls into single alternation
```

(7 commits actually — Task 3 + Task 4 + Task 5 + Task 6 + Task 7 + Task 8 + Task 9. The plan's spec § 7 said "6 commits"; this count of 7 matches because Task 9 (`perf(onboard-detect): action calls script once via --emit-both`) is an additional commit beyond the 6 listed in the spec. Update the spec's PR-M commits list if Soenne notes the discrepancy in review.)

- [ ] **Step 2: Push branch**

```bash
git push -u origin perf/phase-5-onboard-scripts
```

- [ ] **Step 3: Open PR**

```bash
gh pr create --base main --head perf/phase-5-onboard-scripts \
  --title "perf(onboard): phase 5 shell-script optimizations (PR-M)" \
  --body "$(cat <<'EOF'
## Summary

Closes 4 perf items from REVIEW-2026-05-22.md § F + § C:

- **PERF-2** — slurp-pattern refactor at 4 jq-in-loop spots (`detect_components`, `inventory_dockerfiles`, outer `detect_legacy_ci` iterator, `onboard-render.sh` files_json builder)
- **PERF-3** — `detect_legacy_ci` 4 grep calls → 1 alternation regex
- **PERF-4 / MED-11** — `onboard-detect.sh` gets a new `--emit-both` mode; `actions/onboard-detect/action.yml` calls the script **once** instead of twice (saves 1 bash startup, 1 lib reload, and 1 `gh api`/`gh release list` roundtrip per onboard run)
- **PERF-5** — `read_image_override` `head|grep|sed` → single `awk`

Pure perf refactor; **all five action outputs are byte-identical** (`language`, `release_type`, `current_version`, `default_branch`, `profile_json`). No consumer migration. Companion PR (PR-L) handles `timeout-minutes:` on all 21 workflows.

Spec: `docs/superpowers/specs/2026-05-22-phase-5-design.md`
Plan: `docs/superpowers/plans/2026-05-22-phase-5-performance.md`

## Test plan

- [ ] `bats tests/shell/onboard-detect.bats` green (59 tests; +2 for `--emit-both`)
- [ ] `bats tests/shell/onboard-render.bats` green (golden_check proves lock files byte-identical)
- [ ] `bats tests/shell/onboard-drift.bats` green (8 tests; reproducibility guard)
- [ ] `validate.yml` PR check green (actionlint + yamllint on action.yml)
- [ ] `integration.yml` `test-onboard-dry-run` job green (end-to-end validation of action 1×-call path)
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

### Task 11: Remove worktrees after both PRs are merged

**Files:** none (git only)

- [ ] **Step 1: Verify both PRs merged**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git fetch origin main
gh pr list --state merged --search "perf/phase-5-workflow-timeouts" --json number,mergedAt
gh pr list --state merged --search "perf/phase-5-onboard-scripts" --json number,mergedAt
```

Expected: both show a non-null `mergedAt`.

- [ ] **Step 2: Sync local main**

```bash
git checkout main
git pull --rebase origin main
```

- [ ] **Step 3: Remove worktrees + branches**

```bash
git worktree remove .worktrees/phase-5-timeouts
git worktree remove .worktrees/phase-5-scripts
git branch -d perf/phase-5-workflow-timeouts perf/phase-5-onboard-scripts
```

- [ ] **Step 4: Confirm cleanup**

```bash
git worktree list
```

Expected: only `main` and any unrelated worktrees remain.

---

## Self-Review (writer's checklist — performed at plan-write time)

**1. Spec coverage:**
- C-1 timeout-minutes 21 workflows → Task 1 ✓
- C-2 jq-in-loop 4 spots → Task 5 (3 detect-lib spots) + Task 6 (render.sh) ✓
- C-3 combined grep → Task 3 ✓
- C-4 `--emit-both` script + action change → Task 7 (script) + Task 8 (bats) + Task 9 (action) ✓
- C-5 single awk → Task 4 ✓
- Worktree setups → Tasks 0L.1, 0M.1 ✓
- PR pushes → Tasks 2, 10 ✓
- Cleanup → Task 11 ✓

**2. Placeholder scan:** No TBDs/TODOs. Every step has concrete code or commands.

**3. Type consistency:**
- `entries[]` array variable name consistent across the 3 detect-lib refactors in Task 5.
- `files_entries[]` for render.sh in Task 6 (different name because it merges into an object, not a list — naming the helper differently flags the difference for readers).
- `OVERRIDE_DEFAULT_BRANCH` / `OVERRIDE_CURRENT_VERSION` consistent across Tasks 7 (set in script) and 7 step 3 (consumed in `emit_profile_json`).
- Output keys `language`, `release_type`, `current_version`, `default_branch`, `profile_json` consistent across Tasks 7, 8, 9.

**4. PR-M commit count note:** Task 9 adds a 7th commit (`perf(onboard-detect): action calls script once via --emit-both`) beyond the 6 in spec § 7. The spec was written before the plan split the action change into its own commit for cleaner review. Documented in Task 10 step 1.
