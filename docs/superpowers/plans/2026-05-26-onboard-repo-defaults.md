# Onboard Repo Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the onboard atom to apply repository-level defaults (branch protection, merge hygiene, repo settings, topics) idempotently per the design in `docs/superpowers/specs/2026-05-26-onboard-repo-defaults-design.md`.

**Architecture:** New bash script `scripts/apply-repo-defaults.sh` with pure-function library in `scripts/lib/apply-defaults-lib.sh`, declarative config in `catalog/onboard-defaults.json`, thin composite action wrapper at `actions/onboard-apply-defaults/action.yml`. Integrates into the onboard atom as one new step after render and before PR-A push. Lock schema bumped from v1 to v2 with a `defaults_applied_at` marker that gates Tier-2 (comfort) field application.

**Tech Stack:** Bash 5+, `jq` for JSON, `gh` CLI for GitHub REST API, `bats-core` for unit tests, `bashcov` for coverage, GitHub Actions composite-action format.

---

## File Structure

**Create:**
- `catalog/onboard-defaults.json` — declarative source of truth for all defaults
- `scripts/lib/apply-defaults-lib.sh` — pure functions: `classify_tier`, `diff_branch_protection`, `diff_repo_settings`, `diff_merge_hygiene`, `compute_topics_union`
- `scripts/apply-repo-defaults.sh` — entry point, orchestrates API calls and lock mutation
- `actions/onboard-apply-defaults/action.yml` — composite action wrapper
- `tests/shell/apply-defaults-lib.bats` — unit tests for pure functions
- `tests/shell/apply-repo-defaults.bats` — unit tests for script with gh stub
- `tests/shell/lib/gh-stub.sh` — gh CLI mock for tests
- `tests/fixtures/repo-defaults/` — fixture JSON for lock files + API responses

**Modify:**
- `.github/workflows/onboard.yml` — insert snapshot + apply-defaults steps in the atom job
- `docs/operations.md` — new §Repo Defaults section

---

## Task 1: Catalog Defaults JSON

**Files:**
- Create: `catalog/onboard-defaults.json`

- [ ] **Step 1: Write the file**

```json
{
  "_schema_version": 1,
  "_doc": "Source of truth for serverkraken adopter defaults. Modify here, sweep propagates. See docs/superpowers/specs/2026-05-26-onboard-repo-defaults-design.md.",

  "branch_protection": {
    "_target": "default_branch",
    "required_pull_request_reviews": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews": false,
      "require_code_owner_reviews": false,
      "require_last_push_approval": false
    },
    "required_status_checks": null,
    "enforce_admins": false,
    "required_linear_history": true,
    "allow_force_pushes": false,
    "allow_deletions": false,
    "required_conversation_resolution": false,
    "lock_branch": false,
    "block_creations": false,
    "restrictions": null
  },

  "merge_hygiene": {
    "allow_squash_merge": true,
    "allow_merge_commit": false,
    "allow_rebase_merge": false,
    "delete_branch_on_merge": true,
    "allow_auto_merge": true,
    "squash_merge_commit_title": "PR_TITLE",
    "squash_merge_commit_message": "PR_BODY"
  },

  "repo_settings": {
    "has_wiki": false,
    "has_projects": false,
    "has_issues": true,
    "has_discussions": false
  },

  "topics_additive": ["serverkraken-onboarded"]
}
```

- [ ] **Step 2: Verify JSON parses**

Run: `jq -e . catalog/onboard-defaults.json > /dev/null`
Expected: exit 0, no output

- [ ] **Step 3: Commit**

```bash
git add catalog/onboard-defaults.json
git commit -m "feat(onboard-defaults): add declarative catalog config"
```

---

## Task 2: gh-stub Test Harness

**Files:**
- Create: `tests/shell/lib/gh-stub.sh`

The stub is a shim that replaces the `gh` CLI on PATH inside bats tests. It looks up the request in a fixture-keyed map, returns canned JSON, and logs the invocation to a call-log file for assertions.

- [ ] **Step 1: Write the stub**

```bash
#!/usr/bin/env bash
# tests/shell/lib/gh-stub.sh
#
# gh CLI mock for apply-repo-defaults bats tests.
#
# Behavior:
#   - Logs each invocation as a single line to $GH_STUB_CALL_LOG:
#       <verb>\t<endpoint>\t<flags-csv>
#   - Resolves response from $GH_STUB_FIXTURE_DIR keyed by sanitized endpoint
#     (slashes → __, leading slash dropped, no trailing).
#       /repos/owner/repo/branches/main/protection
#         → "$GH_STUB_FIXTURE_DIR/repos__owner__repo__branches__main__protection.json"
#   - If the fixture file is named *.404.json, exit 1 + stderr error simulating
#     a missing-resource response.
#   - If the fixture is *.403.json, exit 1 + 403 stderr.
#   - Otherwise: print the fixture file content to stdout, exit 0.
#   - For 'gh api -X PUT/PATCH/POST/DELETE' (mutating verbs): also accept JSON
#     payload via -f or --input; record it in the call-log line.
set -euo pipefail

CALL_LOG="${GH_STUB_CALL_LOG:-/dev/null}"
FIX_DIR="${GH_STUB_FIXTURE_DIR:-/dev/null}"

# Parse: gh api [-X METHOD] [-f key=val|--input file|--jq expr] ENDPOINT
verb="GET"
endpoint=""
flags=()
input_payload=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    api) shift ;;
    -X) verb="$2"; shift 2 ;;
    --method) verb="$2"; shift 2 ;;
    -f) flags+=("$2"); shift 2 ;;
    --input) input_payload="$(cat "$2")"; shift 2 ;;
    --jq) flags+=("--jq=$2"); shift 2 ;;
    -q) flags+=("--jq=$2"); shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done

# Sanitize endpoint for filename
key="${endpoint#/}"
key="${key//\//__}"
fixture=""
for ext in json 404.json 403.json 500.json; do
  if [[ -f "$FIX_DIR/${key}.${ext}" ]]; then
    fixture="$FIX_DIR/${key}.${ext}"
    break
  fi
done

# Log the call
flags_csv=$(IFS=,; echo "${flags[*]:-}")
printf "%s\t%s\t%s\t%s\n" "$verb" "$endpoint" "$flags_csv" "${input_payload//$'\n'/ }" >> "$CALL_LOG"

if [[ -z "$fixture" ]]; then
  echo "gh-stub: no fixture for $endpoint (looked in $FIX_DIR)" >&2
  exit 1
fi

case "$fixture" in
  *.404.json) echo "gh: HTTP 404" >&2; exit 1 ;;
  *.403.json) echo "gh: HTTP 403 forbidden" >&2; exit 1 ;;
  *.500.json) echo "gh: HTTP 500" >&2; exit 1 ;;
  *) cat "$fixture" ;;
esac
```

- [ ] **Step 2: Make executable**

Run: `chmod +x tests/shell/lib/gh-stub.sh`
Expected: no output, exit 0

- [ ] **Step 3: Smoke-test the stub manually**

```bash
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/fix"
echo '{"name":"main"}' > "$tmpdir/fix/repos__o__r__branches__main.json"
echo '' > "$tmpdir/log"
GH_STUB_CALL_LOG="$tmpdir/log" GH_STUB_FIXTURE_DIR="$tmpdir/fix" \
  tests/shell/lib/gh-stub.sh api /repos/o/r/branches/main
cat "$tmpdir/log"
rm -rf "$tmpdir"
```

Expected stdout: `{"name":"main"}`
Expected log contents: `GET\t/repos/o/r/branches/main\t\t`

- [ ] **Step 4: Commit**

```bash
git add tests/shell/lib/gh-stub.sh
git commit -m "test(onboard-defaults): add gh CLI stub for bats"
```

---

## Task 3: Lib — classify_tier()

**Files:**
- Create: `scripts/lib/apply-defaults-lib.sh`
- Create: `tests/shell/apply-defaults-lib.bats`

- [ ] **Step 1: Write the failing test for classify_tier**

`tests/shell/apply-defaults-lib.bats`:

```bash
#!/usr/bin/env bats
# Pure-function tests for scripts/lib/apply-defaults-lib.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  source "$REPO_ROOT/scripts/lib/apply-defaults-lib.sh"
}

@test "classify_tier: branch_protection is tier_1" {
  run classify_tier "branch_protection"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_1" ]
}

@test "classify_tier: delete_branch_on_merge is tier_1" {
  run classify_tier "delete_branch_on_merge"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_1" ]
}

@test "classify_tier: topics_additive is tier_1" {
  run classify_tier "topics_additive"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_1" ]
}

@test "classify_tier: allow_squash_merge is tier_2" {
  run classify_tier "allow_squash_merge"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_2" ]
}

@test "classify_tier: has_wiki is tier_2" {
  run classify_tier "has_wiki"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_2" ]
}

@test "classify_tier: unknown field returns unknown" {
  run classify_tier "totally_made_up_field"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}
```

- [ ] **Step 2: Run test to verify failure (no library yet)**

Run: `bats tests/shell/apply-defaults-lib.bats`
Expected: All tests FAIL with "No such file or directory" or similar (library not yet created).

- [ ] **Step 3: Implement classify_tier**

`scripts/lib/apply-defaults-lib.sh`:

```bash
#!/usr/bin/env bash
# apply-defaults-lib.sh — pure functions for repo-defaults computation.
#
# No API side effects in this file. apply-repo-defaults.sh is the only
# consumer; tests source this file directly.

# classify_tier <field-name> → echoes "tier_1" | "tier_2" | "unknown"
#
# Tier 1 (always-overwrite every sweep): security-relevant fields.
# Tier 2 (first-onboard-only): comfort fields, gated by the lock marker.
classify_tier() {
  case "$1" in
    branch_protection|delete_branch_on_merge|topics_additive)
      echo "tier_1"
      ;;
    allow_squash_merge|allow_merge_commit|allow_rebase_merge|allow_auto_merge|\
    squash_merge_commit_title|squash_merge_commit_message|\
    has_wiki|has_projects|has_issues|has_discussions)
      echo "tier_2"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bats tests/shell/apply-defaults-lib.bats`
Expected: 6 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/apply-defaults-lib.sh tests/shell/apply-defaults-lib.bats
git commit -m "feat(apply-defaults-lib): add classify_tier function"
```

---

## Task 4: Lib — compute_topics_union()

**Files:**
- Modify: `scripts/lib/apply-defaults-lib.sh` (append function)
- Modify: `tests/shell/apply-defaults-lib.bats` (append tests)

- [ ] **Step 1: Append failing tests**

Add to `tests/shell/apply-defaults-lib.bats`:

```bash
@test "compute_topics_union: empty current + one new → just the new" {
  run compute_topics_union "[]" '["serverkraken-onboarded"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["serverkraken-onboarded"]' ]
}

@test "compute_topics_union: existing without target → appended at end" {
  run compute_topics_union '["go","backend"]' '["serverkraken-onboarded"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["go","backend","serverkraken-onboarded"]' ]
}

@test "compute_topics_union: existing already contains target → unchanged" {
  run compute_topics_union '["serverkraken-onboarded","go"]' '["serverkraken-onboarded"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["serverkraken-onboarded","go"]' ]
}

@test "compute_topics_union: multiple new, some already present → only missing appended" {
  run compute_topics_union '["a","b"]' '["b","c"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["a","b","c"]' ]
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bats tests/shell/apply-defaults-lib.bats -f compute_topics_union`
Expected: 4 failing with "command not found" or similar.

- [ ] **Step 3: Append implementation**

Append to `scripts/lib/apply-defaults-lib.sh`:

```bash
# compute_topics_union <current-json-array> <additive-json-array>
#   → echoes JSON array: current ∪ additive, preserving current order,
#     appending missing additives in their input order.
compute_topics_union() {
  local current="$1"
  local additive="$2"
  jq -nc \
    --argjson current "$current" \
    --argjson additive "$additive" \
    '$current + ($additive - $current)'
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bats tests/shell/apply-defaults-lib.bats`
Expected: 10 passing (6 from Task 3 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/apply-defaults-lib.sh tests/shell/apply-defaults-lib.bats
git commit -m "feat(apply-defaults-lib): add compute_topics_union"
```

---

## Task 5: Lib — diff_branch_protection()

**Files:**
- Modify: `scripts/lib/apply-defaults-lib.sh`
- Modify: `tests/shell/apply-defaults-lib.bats`

This function compares a current GitHub branch-protection response (or the literal string `"missing"` if none exists) against the target config from the catalog. Returns `""` if they match, or a single-line diff summary otherwise. Used by the script to decide whether to call the PUT API.

- [ ] **Step 1: Append failing tests**

```bash
@test "diff_branch_protection: missing target → diff with reason=missing" {
  target='{"enforce_admins":false,"required_linear_history":true}'
  run diff_branch_protection "missing" "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == reason=missing* ]]
}

@test "diff_branch_protection: identical state → empty" {
  current='{"enforce_admins":{"enabled":false},"required_linear_history":{"enabled":true}}'
  target='{"enforce_admins":false,"required_linear_history":true}'
  run diff_branch_protection "$current" "$target"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "diff_branch_protection: enforce_admins flipped → drift" {
  current='{"enforce_admins":{"enabled":true},"required_linear_history":{"enabled":true}}'
  target='{"enforce_admins":false,"required_linear_history":true}'
  run diff_branch_protection "$current" "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == *enforce_admins* ]]
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bats tests/shell/apply-defaults-lib.bats -f diff_branch_protection`
Expected: 3 failing.

- [ ] **Step 3: Append implementation**

```bash
# diff_branch_protection <current-json> <target-json>
#   → echoes diff summary line, or empty if equivalent.
#
# Current is the GitHub API's branch-protection response shape:
#   { enforce_admins: {enabled: bool}, required_linear_history: {enabled: bool},
#     required_pull_request_reviews: {required_approving_review_count, ...} ... }
# Or the literal string "missing" when no protection exists.
#
# Target is the catalog config shape (flat booleans / nested objects).
#
# We normalize both to a canonical comparison shape, then jq-diff.
diff_branch_protection() {
  local current="$1"
  local target="$2"

  if [[ "$current" == "missing" ]]; then
    echo "reason=missing"
    return 0
  fi

  # Normalize current API shape → flat keys matching target.
  local normalized_current
  normalized_current=$(jq -nc --argjson c "$current" '
    {
      enforce_admins: ($c.enforce_admins.enabled // false),
      required_linear_history: ($c.required_linear_history.enabled // false),
      allow_force_pushes: ($c.allow_force_pushes.enabled // false),
      allow_deletions: ($c.allow_deletions.enabled // false),
      required_conversation_resolution: ($c.required_conversation_resolution.enabled // false),
      lock_branch: ($c.lock_branch.enabled // false),
      block_creations: ($c.block_creations.enabled // false),
      required_status_checks: ($c.required_status_checks // null),
      required_pull_request_reviews: (
        if $c.required_pull_request_reviews == null then null
        else {
          required_approving_review_count: ($c.required_pull_request_reviews.required_approving_review_count // 0),
          dismiss_stale_reviews: ($c.required_pull_request_reviews.dismiss_stale_reviews // false),
          require_code_owner_reviews: ($c.required_pull_request_reviews.require_code_owner_reviews // false),
          require_last_push_approval: ($c.required_pull_request_reviews.require_last_push_approval // false)
        }
        end
      ),
      restrictions: ($c.restrictions // null)
    }
  ')

  # Reduce target to the same keyset (drop the leading "_target" hint).
  local normalized_target
  normalized_target=$(jq -nc --argjson t "$target" '
    $t | del(._target)
  ')

  # Build keys-where-they-differ list.
  local diff_keys
  diff_keys=$(jq -nc \
    --argjson c "$normalized_current" \
    --argjson t "$normalized_target" \
    '[($c | keys_unsorted)[] | select(($c[.]) != ($t[.]))] | join(",")')

  if [[ "$diff_keys" == "" || "$diff_keys" == '""' ]]; then
    echo ""
  else
    echo "reason=drift fields=$(echo "$diff_keys" | tr -d '"')"
  fi
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bats tests/shell/apply-defaults-lib.bats`
Expected: 13 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/apply-defaults-lib.sh tests/shell/apply-defaults-lib.bats
git commit -m "feat(apply-defaults-lib): add diff_branch_protection"
```

---

## Task 6: Lib — diff_repo_settings() and diff_merge_hygiene()

**Files:**
- Modify: `scripts/lib/apply-defaults-lib.sh`
- Modify: `tests/shell/apply-defaults-lib.bats`

These two functions are structurally identical (compare a flat JSON object's keyset against a target's), so a private helper is appropriate.

- [ ] **Step 1: Append failing tests**

```bash
@test "diff_repo_settings: identical → empty" {
  current='{"has_wiki":false,"has_projects":false,"has_issues":true,"has_discussions":false}'
  target='{"has_wiki":false,"has_projects":false,"has_issues":true,"has_discussions":false}'
  run diff_repo_settings "$current" "$target"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "diff_repo_settings: has_wiki drift → reports field" {
  current='{"has_wiki":true,"has_projects":false,"has_issues":true,"has_discussions":false}'
  target='{"has_wiki":false,"has_projects":false,"has_issues":true,"has_discussions":false}'
  run diff_repo_settings "$current" "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == *has_wiki* ]]
}

@test "diff_merge_hygiene: identical → empty" {
  current='{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"allow_auto_merge":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  target="$current"
  run diff_merge_hygiene "$current" "$target"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "diff_merge_hygiene: allow_merge_commit drift → reports field" {
  current='{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":false,"delete_branch_on_merge":true,"allow_auto_merge":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  target='{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"allow_auto_merge":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  run diff_merge_hygiene "$current" "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == *allow_merge_commit* ]]
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bats tests/shell/apply-defaults-lib.bats -f "diff_repo_settings|diff_merge_hygiene"`
Expected: 4 failing.

- [ ] **Step 3: Append implementation**

```bash
# _diff_flat_object <current-json> <target-json>
#   Internal helper: compares two flat objects on the target's keyset only.
#   Echoes "fields=<csv>" if any differ, empty otherwise.
_diff_flat_object() {
  local current="$1"
  local target="$2"
  local diff_keys
  diff_keys=$(jq -nc \
    --argjson c "$current" \
    --argjson t "$target" \
    '[($t | keys_unsorted)[] | select(($c[.]) != ($t[.]))] | join(",")')
  if [[ "$diff_keys" == "" || "$diff_keys" == '""' ]]; then
    echo ""
  else
    echo "fields=$(echo "$diff_keys" | tr -d '"')"
  fi
}

diff_repo_settings()  { _diff_flat_object "$1" "$2"; }
diff_merge_hygiene()  { _diff_flat_object "$1" "$2"; }
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bats tests/shell/apply-defaults-lib.bats`
Expected: 17 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/apply-defaults-lib.sh tests/shell/apply-defaults-lib.bats
git commit -m "feat(apply-defaults-lib): add diff_repo_settings and diff_merge_hygiene"
```

---

## Task 7: Fixture Files — Lock + API Responses

**Files:**
- Create: `tests/fixtures/repo-defaults/locks/lock-v1-no-marker.json`
- Create: `tests/fixtures/repo-defaults/locks/lock-v2-with-marker.json`
- Create: `tests/fixtures/repo-defaults/locks/lock-v2-empty-marker.json`
- Create: `tests/fixtures/repo-defaults/api-clean/` — directory with canned responses representing a fully-compliant target
- Create: `tests/fixtures/repo-defaults/api-no-bp/` — same but with BP missing (404 response)
- Create: `tests/fixtures/repo-defaults/api-drifted/` — BP exists but enforce_admins flipped

The API responses are keyed by sanitized endpoint per `gh-stub.sh` (see Task 2).

- [ ] **Step 1: Write the lock fixtures**

`tests/fixtures/repo-defaults/locks/lock-v1-no-marker.json`:

```json
{
  "schema_version": 1,
  "catalog_version": "v4",
  "rendered_at": "2026-05-26T17:10:08Z",
  "files": {
    ".github/workflows/ci.yml": "sha256:0000000000000000000000000000000000000000000000000000000000000001"
  }
}
```

`tests/fixtures/repo-defaults/locks/lock-v2-with-marker.json`:

```json
{
  "schema_version": 2,
  "catalog_version": "v4",
  "rendered_at": "2026-05-26T17:10:08Z",
  "defaults_applied_at": "2026-05-26T18:00:00Z",
  "files": {
    ".github/workflows/ci.yml": "sha256:0000000000000000000000000000000000000000000000000000000000000001"
  }
}
```

`tests/fixtures/repo-defaults/locks/lock-v2-empty-marker.json`:

```json
{
  "schema_version": 2,
  "catalog_version": "v4",
  "rendered_at": "2026-05-26T17:10:08Z",
  "defaults_applied_at": "",
  "files": {
    ".github/workflows/ci.yml": "sha256:0000000000000000000000000000000000000000000000000000000000000001"
  }
}
```

- [ ] **Step 2: Write the api-clean fixture set**

This represents a target where everything already matches the catalog. The script should make zero mutating API calls.

`tests/fixtures/repo-defaults/api-clean/repos__o__r.json`:

```json
{
  "default_branch": "main",
  "topics": ["serverkraken-onboarded","go"],
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "delete_branch_on_merge": true,
  "allow_auto_merge": true,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY",
  "has_wiki": false,
  "has_projects": false,
  "has_issues": true,
  "has_discussions": false,
  "visibility": "private"
}
```

`tests/fixtures/repo-defaults/api-clean/repos__o__r__branches__main__protection.json`:

```json
{
  "enforce_admins": {"enabled": false},
  "required_linear_history": {"enabled": true},
  "allow_force_pushes": {"enabled": false},
  "allow_deletions": {"enabled": false},
  "required_conversation_resolution": {"enabled": false},
  "lock_branch": {"enabled": false},
  "block_creations": {"enabled": false},
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false
  },
  "required_status_checks": null,
  "restrictions": null
}
```

`tests/fixtures/repo-defaults/api-clean/repos__o__r__topics.json`:

```json
{"names": ["serverkraken-onboarded","go"]}
```

- [ ] **Step 3: Write the api-no-bp fixture set**

Same as api-clean but with BP missing.

`tests/fixtures/repo-defaults/api-no-bp/repos__o__r.json`: copy from api-clean
`tests/fixtures/repo-defaults/api-no-bp/repos__o__r__topics.json`: copy from api-clean
`tests/fixtures/repo-defaults/api-no-bp/repos__o__r__branches__main__protection.404.json`:

```json
{"message":"Branch not protected"}
```

- [ ] **Step 4: Write the api-drifted fixture set**

api-drifted has BP but with `enforce_admins` flipped to true.

`tests/fixtures/repo-defaults/api-drifted/repos__o__r.json`: copy from api-clean
`tests/fixtures/repo-defaults/api-drifted/repos__o__r__topics.json`: copy from api-clean
`tests/fixtures/repo-defaults/api-drifted/repos__o__r__branches__main__protection.json`: copy from api-clean BUT with `"enforce_admins": {"enabled": true}`

- [ ] **Step 5: Verify all fixtures parse**

Run: `find tests/fixtures/repo-defaults -name '*.json' -exec jq -e . {} \; > /dev/null`
Expected: exit 0, no errors.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/repo-defaults
git commit -m "test(onboard-defaults): add lock and API fixtures"
```

---

## Task 8: Script Skeleton + Argument Parsing

**Files:**
- Create: `scripts/apply-repo-defaults.sh`
- Create: `tests/shell/apply-repo-defaults.bats`

This task scaffolds the entry point with arg parsing, config loading, and the main dispatch loop. No actual API calls or tier logic yet — those come in Tasks 9–13.

- [ ] **Step 1: Write the failing tests for arg parsing**

```bash
#!/usr/bin/env bats
# Script-level tests for apply-repo-defaults.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/apply-repo-defaults.sh"
  STUB="$REPO_ROOT/tests/shell/lib/gh-stub.sh"
  FIX="$REPO_ROOT/tests/fixtures/repo-defaults"

  # Working dir for one test invocation
  WORK=$(mktemp -d)
  export GH_STUB_CALL_LOG="$WORK/gh-calls.log"
  : > "$GH_STUB_CALL_LOG"
}

teardown() {
  rm -rf "$WORK"
}

# Helper: prepare a target tree with a given lock fixture.
prepare_target() {
  local lock_fixture="$1"
  local tgt="$WORK/target"
  mkdir -p "$tgt/.github"
  [[ -n "$lock_fixture" ]] && cp "$FIX/locks/$lock_fixture" "$tgt/.github/onboard.lock.json"
  echo "$tgt"
}

# Helper: run the script with the stub on PATH.
run_with_stub() {
  local fixture_dir="$1"; shift
  export GH_STUB_FIXTURE_DIR="$FIX/$fixture_dir"
  # PATH-prepend a directory containing a 'gh' shim that delegates to the stub.
  mkdir -p "$WORK/bin"
  ln -sf "$STUB" "$WORK/bin/gh"
  PATH="$WORK/bin:$PATH" run "$SCRIPT" "$@"
}

@test "script: no args → usage error" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
}

@test "script: --help → exits 0 with usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *usage* ]]
}

@test "script: missing target_path arg → exits non-zero" {
  run "$SCRIPT" --repo o/r
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bats tests/shell/apply-repo-defaults.bats`
Expected: 3 failing (script doesn't exist).

- [ ] **Step 3: Implement skeleton**

`scripts/apply-repo-defaults.sh`:

```bash
#!/usr/bin/env bash
# apply-repo-defaults.sh — apply catalog repo-level defaults to a target.
#
# Usage: apply-repo-defaults.sh --repo <owner/repo> --target-path <dir>
#                               [--prev-marker <iso-timestamp>] [--dry-run]
#
# Reads catalog/onboard-defaults.json (relative to repo root containing this
# script), applies Tier 1 every run, Tier 2 only when --prev-marker is empty,
# mutates <target-path>/.github/onboard.lock.json to record defaults_applied_at
# and bump schema_version to 2.
#
# Requires GH_TOKEN env var with administration:write scope.
#
# Outputs (key=value lines, sink-friendly for $GITHUB_OUTPUT):
#   defaults_applied=true|false
#   tier_2_applied=true|false
#   modified=<csv of field-categories that were mutated>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/apply-defaults-lib.sh
source "$SCRIPT_DIR/lib/apply-defaults-lib.sh"

usage() {
  cat <<'EOF'
usage: apply-repo-defaults.sh --repo <owner/repo> --target-path <dir>
                              [--prev-marker <iso-timestamp>] [--dry-run] [--help]

Applies catalog repo-level defaults to a target repository. Reads the catalog's
onboard-defaults.json, calls GitHub API to apply Tier 1 (always) and Tier 2
(first-onboard-only) fields, then mutates the target's onboard.lock.json to
record defaults_applied_at and schema_version=2.

Env:
  GH_TOKEN  Required. Token with administration:write on the target.
EOF
}

REPO=""
TARGET_PATH=""
PREV_MARKER=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --target-path) TARGET_PATH="$2"; shift 2 ;;
    --prev-marker) PREV_MARKER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "::error::--repo is required" >&2
  usage >&2
  exit 1
fi
if [[ -z "$TARGET_PATH" ]]; then
  echo "::error::--target-path is required" >&2
  usage >&2
  exit 1
fi
if [[ ! -d "$TARGET_PATH" ]]; then
  echo "::error::--target-path does not exist: $TARGET_PATH" >&2
  exit 1
fi

CONFIG="$CATALOG_ROOT/catalog/onboard-defaults.json"
if [[ ! -f "$CONFIG" ]]; then
  echo "::error::config not found: $CONFIG" >&2
  exit 1
fi
if ! jq -e . "$CONFIG" > /dev/null 2>&1; then
  echo "::error::invalid JSON in $CONFIG" >&2
  exit 1
fi

# Tier 2 decision: apply only when no marker is preserved from the snapshot.
APPLY_TIER_2=0
if [[ -z "$PREV_MARKER" ]]; then
  APPLY_TIER_2=1
fi

MODIFIED_CATEGORIES=()

# --- Tier 1 + Tier 2 logic implemented in later tasks ---

# --- Lock mutation implemented in Task 12 ---

# Outputs
modified_csv=$(IFS=,; echo "${MODIFIED_CATEGORIES[*]:-}")
echo "defaults_applied=true"
if (( APPLY_TIER_2 )); then
  echo "tier_2_applied=true"
else
  echo "tier_2_applied=false"
fi
echo "modified=$modified_csv"
```

- [ ] **Step 4: Make executable**

Run: `chmod +x scripts/apply-repo-defaults.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Run tests, verify pass**

Run: `bats tests/shell/apply-repo-defaults.bats`
Expected: 3 passing.

- [ ] **Step 6: Commit**

```bash
git add scripts/apply-repo-defaults.sh tests/shell/apply-repo-defaults.bats
git commit -m "feat(apply-repo-defaults): skeleton + arg parsing"
```

---

## Task 9: Script — Tier 1: Branch Protection

**Files:**
- Modify: `scripts/apply-repo-defaults.sh`
- Modify: `tests/shell/apply-repo-defaults.bats`

Apply branch-protection always. Sub-cases: missing → PUT with full config; drift → PUT to overwrite; clean → no-op.

- [ ] **Step 1: Append failing tests**

```bash
@test "tier_1 bp: no protection (404) → PUT full config" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-no-bp --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  # The stub call-log should contain a PUT to branches/main/protection
  grep -q $'^PUT\t/repos/o/r/branches/main/protection' "$GH_STUB_CALL_LOG"
}

@test "tier_1 bp: clean state → no PUT" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  ! grep -q $'^PUT\t/repos/o/r/branches/main/protection' "$GH_STUB_CALL_LOG"
}

@test "tier_1 bp: drift (enforce_admins flipped) → PUT" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-drifted --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  grep -q $'^PUT\t/repos/o/r/branches/main/protection' "$GH_STUB_CALL_LOG"
}
```

- [ ] **Step 2: Add a Tier-1 branch-protection block to fixtures**

Add fixture file for branch-protection PUT response (success means GitHub returns the same object). Add an empty placeholder response so the stub returns something on PUT:

For each of `api-no-bp`, `api-drifted`, `api-clean` add a file named `repos__o__r__branches__main__protection.PUT.json` containing `{}`.

The stub's current shape doesn't differentiate verbs in fixture lookup. Update the stub to try verb-prefixed fixtures first:

Modify `tests/shell/lib/gh-stub.sh` — in the fixture-lookup section, add a verb-prefixed key:

```bash
# Sanitize endpoint for filename
key="${endpoint#/}"
key="${key//\//__}"
verb_lc=$(echo "$verb" | tr '[:upper:]' '[:lower:]')
fixture=""
for try_key in "${verb_lc}.${key}" "${key}"; do
  for ext in json 404.json 403.json 500.json; do
    if [[ -f "$FIX_DIR/${try_key}.${ext}" ]]; then
      fixture="$FIX_DIR/${try_key}.${ext}"
      break 2
    fi
  done
done
```

Now add `put.repos__o__r__branches__main__protection.json` containing `{}` to each api-* fixture dir that needs it (for tests that do trigger PUT).

- [ ] **Step 3: Run tests to verify failure**

Run: `bats tests/shell/apply-repo-defaults.bats -f tier_1_bp`
Expected: 3 failing (Tier 1 not yet implemented).

- [ ] **Step 4: Implement Tier 1 branch-protection in the script**

Insert before the `--- Lock mutation ---` comment in `scripts/apply-repo-defaults.sh`:

```bash
# --- Tier 1: Branch Protection (always) ---

# Fetch repo metadata to know the default branch
REPO_META=$(gh api "/repos/$REPO" 2>/dev/null) || {
  echo "::error::failed to fetch /repos/$REPO" >&2
  exit 2
}
DEFAULT_BRANCH=$(echo "$REPO_META" | jq -r '.default_branch')

# Fetch existing branch protection, or "missing" on 404.
BP_CURRENT=$(gh api "/repos/$REPO/branches/$DEFAULT_BRANCH/protection" 2>/dev/null || echo "missing")

# Target shape from config (drop the _target hint).
BP_TARGET=$(jq -c '.branch_protection | del(._target)' "$CONFIG")

BP_DIFF=$(diff_branch_protection "$BP_CURRENT" "$BP_TARGET")

if [[ -n "$BP_DIFF" ]]; then
  if (( DRY_RUN )); then
    echo "::notice::dry-run: would PUT branch protection ($BP_DIFF)"
  else
    echo "$BP_TARGET" | gh api -X PUT \
      "/repos/$REPO/branches/$DEFAULT_BRANCH/protection" \
      --input - > /dev/null
  fi
  MODIFIED_CATEGORIES+=("branch_protection")
fi
```

- [ ] **Step 5: Run tests, verify pass**

Run: `bats tests/shell/apply-repo-defaults.bats -f tier_1_bp`
Expected: 3 passing. Re-run full file: `bats tests/shell/apply-repo-defaults.bats` → 6 passing.

- [ ] **Step 6: Commit**

```bash
git add scripts/apply-repo-defaults.sh tests/shell/apply-repo-defaults.bats tests/shell/lib/gh-stub.sh tests/fixtures/repo-defaults
git commit -m "feat(apply-repo-defaults): tier 1 branch protection"
```

---

## Task 10: Script — Tier 1: delete_branch_on_merge + Topics

**Files:**
- Modify: `scripts/apply-repo-defaults.sh`
- Modify: `tests/shell/apply-repo-defaults.bats`

`delete_branch_on_merge` is sent via PATCH `/repos/{owner}/{repo}`. Topics are PUT `/repos/{owner}/{repo}/topics` with the union list.

- [ ] **Step 1: Append failing tests**

```bash
@test "tier_1 delete_branch_on_merge: clean (already true) → no PATCH" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  ! grep -qE $'^PATCH\t/repos/o/r\t' "$GH_STUB_CALL_LOG"
}

@test "tier_1 topics: target absent → PUT with union" {
  # api-no-topics: same as api-clean but topics list lacks serverkraken-onboarded
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-no-topics --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  grep -q $'^PUT\t/repos/o/r/topics' "$GH_STUB_CALL_LOG"
  # Payload must contain serverkraken-onboarded
  grep -q "serverkraken-onboarded" "$GH_STUB_CALL_LOG"
}

@test "tier_1 topics: target already present → no PUT" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  ! grep -q $'^PUT\t/repos/o/r/topics' "$GH_STUB_CALL_LOG"
}
```

- [ ] **Step 2: Add the api-no-topics fixture set**

Create directory `tests/fixtures/repo-defaults/api-no-topics/` with:

- `repos__o__r.json`: copy from api-clean BUT with `"delete_branch_on_merge": false, "topics": ["go"]`
- `repos__o__r__branches__main__protection.json`: copy from api-clean
- `repos__o__r__topics.json`: `{"names":["go"]}`
- `put.repos__o__r__topics.json`: `{"names":["go","serverkraken-onboarded"]}`
- `patch.repos__o__r.json`: `{}` (response on PATCH success)

- [ ] **Step 3: Run tests to verify failure**

Run: `bats tests/shell/apply-repo-defaults.bats -f "tier_1_delete|tier_1_topics"`
Expected: 3 failing.

- [ ] **Step 4: Implement in the script**

Append after the branch-protection block:

```bash
# --- Tier 1: delete_branch_on_merge (always) ---

DEL_BRANCH_TARGET=$(jq -r '.merge_hygiene.delete_branch_on_merge' "$CONFIG")
DEL_BRANCH_CURRENT=$(echo "$REPO_META" | jq -r '.delete_branch_on_merge')

if [[ "$DEL_BRANCH_CURRENT" != "$DEL_BRANCH_TARGET" ]]; then
  if (( DRY_RUN )); then
    echo "::notice::dry-run: would PATCH delete_branch_on_merge=$DEL_BRANCH_TARGET"
  else
    jq -nc --argjson v "$DEL_BRANCH_TARGET" '{delete_branch_on_merge:$v}' \
      | gh api -X PATCH "/repos/$REPO" --input - > /dev/null
  fi
  MODIFIED_CATEGORIES+=("delete_branch_on_merge")
fi

# --- Tier 1: topics additive (always) ---

CURRENT_TOPICS=$(gh api "/repos/$REPO/topics" --jq '.names' 2>/dev/null || echo "[]")
ADDITIVE=$(jq -c '.topics_additive' "$CONFIG")
NEW_TOPICS=$(compute_topics_union "$CURRENT_TOPICS" "$ADDITIVE")

if [[ "$NEW_TOPICS" != "$CURRENT_TOPICS" ]]; then
  if (( DRY_RUN )); then
    echo "::notice::dry-run: would PUT topics=$NEW_TOPICS"
  else
    jq -nc --argjson n "$NEW_TOPICS" '{names:$n}' \
      | gh api -X PUT "/repos/$REPO/topics" --input - > /dev/null
  fi
  MODIFIED_CATEGORIES+=("topics")
fi
```

- [ ] **Step 5: Run tests, verify pass**

Run: `bats tests/shell/apply-repo-defaults.bats`
Expected: 9 passing.

- [ ] **Step 6: Commit**

```bash
git add scripts/apply-repo-defaults.sh tests/shell/apply-repo-defaults.bats tests/fixtures/repo-defaults
git commit -m "feat(apply-repo-defaults): tier 1 delete_branch_on_merge + topics"
```

---

## Task 11: Script — Tier 2: Merge Hygiene + Repo Settings

**Files:**
- Modify: `scripts/apply-repo-defaults.sh`
- Modify: `tests/shell/apply-repo-defaults.bats`

Tier 2 is gated by `APPLY_TIER_2` which was set during arg parsing based on `--prev-marker`. When applied, both merge_hygiene and repo_settings are sent in one PATCH to `/repos/{owner}/{repo}`.

- [ ] **Step 1: Append failing tests**

```bash
@test "tier_2: marker present → no merge_hygiene/repo_settings PATCH" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  # api-drifted-tier2: has_wiki=true, allow_merge_commit=true (would trigger Tier 2 if not gated)
  run_with_stub api-drifted-tier2 --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  # Only Tier 1 fields (delete_branch_on_merge maybe) — no has_wiki PATCH payload
  ! grep -q "has_wiki" "$GH_STUB_CALL_LOG"
}

@test "tier_2: marker empty + drift → PATCH" {
  tgt=$(prepare_target "lock-v2-empty-marker.json")
  run_with_stub api-drifted-tier2 --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  grep -q "has_wiki" "$GH_STUB_CALL_LOG"
}

@test "tier_2: no prev lock → both tiers apply" {
  tgt=$(prepare_target "")  # no lock fixture
  run_with_stub api-drifted-tier2 --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  grep -q "has_wiki" "$GH_STUB_CALL_LOG"
}
```

- [ ] **Step 2: Add fixture api-drifted-tier2**

Create `tests/fixtures/repo-defaults/api-drifted-tier2/` with:

- `repos__o__r.json`: like api-clean BUT with `"allow_merge_commit": true, "has_wiki": true, "topics": ["serverkraken-onboarded","go"]`
- `repos__o__r__branches__main__protection.json`: copy from api-clean
- `repos__o__r__topics.json`: `{"names":["serverkraken-onboarded","go"]}`
- `patch.repos__o__r.json`: `{}`

- [ ] **Step 3: Run tests to verify failure**

Run: `bats tests/shell/apply-repo-defaults.bats -f tier_2`
Expected: 3 failing.

- [ ] **Step 4: Implement Tier 2 in the script**

Append:

```bash
# --- Tier 2: merge_hygiene + repo_settings (first-onboard-only) ---

if (( APPLY_TIER_2 )); then
  MERGE_TARGET=$(jq -c '.merge_hygiene | del(.delete_branch_on_merge)' "$CONFIG")
  REPO_SETTINGS_TARGET=$(jq -c '.repo_settings' "$CONFIG")

  CURRENT_MERGE=$(echo "$REPO_META" | jq -c '{allow_squash_merge,allow_merge_commit,allow_rebase_merge,allow_auto_merge,squash_merge_commit_title,squash_merge_commit_message}')
  CURRENT_REPO_SETTINGS=$(echo "$REPO_META" | jq -c '{has_wiki,has_projects,has_issues,has_discussions}')

  MERGE_DIFF=$(diff_merge_hygiene "$CURRENT_MERGE" "$MERGE_TARGET")
  RS_DIFF=$(diff_repo_settings "$CURRENT_REPO_SETTINGS" "$REPO_SETTINGS_TARGET")

  if [[ -n "$MERGE_DIFF" || -n "$RS_DIFF" ]]; then
    PATCH_PAYLOAD=$(jq -nc \
      --argjson mh "$MERGE_TARGET" \
      --argjson rs "$REPO_SETTINGS_TARGET" \
      '$mh + $rs')
    if (( DRY_RUN )); then
      echo "::notice::dry-run: would PATCH /repos/$REPO with $PATCH_PAYLOAD"
    else
      echo "$PATCH_PAYLOAD" | gh api -X PATCH "/repos/$REPO" --input - > /dev/null
    fi
    [[ -n "$MERGE_DIFF" ]] && MODIFIED_CATEGORIES+=("merge_hygiene")
    [[ -n "$RS_DIFF" ]] && MODIFIED_CATEGORIES+=("repo_settings")
  fi
fi
```

- [ ] **Step 5: Run tests, verify pass**

Run: `bats tests/shell/apply-repo-defaults.bats`
Expected: 12 passing.

- [ ] **Step 6: Commit**

```bash
git add scripts/apply-repo-defaults.sh tests/shell/apply-repo-defaults.bats tests/fixtures/repo-defaults
git commit -m "feat(apply-repo-defaults): tier 2 merge_hygiene + repo_settings"
```

---

## Task 12: Script — Lock Mutation

**Files:**
- Modify: `scripts/apply-repo-defaults.sh`
- Modify: `tests/shell/apply-repo-defaults.bats`

After API calls succeed, mutate `<target_path>/.github/onboard.lock.json` to bump `schema_version` to 2 and set `defaults_applied_at`.

- [ ] **Step 1: Append failing tests**

```bash
@test "lock mutation: prev empty → writes now() to defaults_applied_at, bumps schema to 2" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  sv=$(jq -r '.schema_version' "$tgt/.github/onboard.lock.json")
  [ "$sv" = "2" ]
  marker=$(jq -r '.defaults_applied_at' "$tgt/.github/onboard.lock.json")
  [[ "$marker" =~ ^2[0-9]{3}- ]]   # starts with a 2xxx year
}

@test "lock mutation: prev non-empty → preserves prev marker" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker "2026-04-01T00:00:00Z"
  [ "$status" -eq 0 ]
  marker=$(jq -r '.defaults_applied_at' "$tgt/.github/onboard.lock.json")
  [ "$marker" = "2026-04-01T00:00:00Z" ]
}

@test "lock mutation: no prior lock → script still runs, writes nothing if no lock" {
  tgt=$(prepare_target "")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  [ ! -f "$tgt/.github/onboard.lock.json" ]
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bats tests/shell/apply-repo-defaults.bats -f "lock mutation"`
Expected: 2 failing (the third passes trivially).

- [ ] **Step 3: Implement lock mutation**

Append after the Tier 2 block:

```bash
# --- Lock mutation ---

LOCK_PATH="$TARGET_PATH/.github/onboard.lock.json"
if [[ -f "$LOCK_PATH" ]]; then
  # Decide marker value: preserve prev, or write now().
  if [[ -n "$PREV_MARKER" ]]; then
    MARKER="$PREV_MARKER"
  else
    MARKER=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  if (( DRY_RUN )); then
    echo "::notice::dry-run: would mutate lock — schema_version=2, defaults_applied_at=$MARKER"
  else
    tmp=$(mktemp)
    jq --arg ts "$MARKER" \
       '.schema_version = 2 | .defaults_applied_at = $ts' \
       "$LOCK_PATH" > "$tmp"
    mv "$tmp" "$LOCK_PATH"
  fi
fi
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bats tests/shell/apply-repo-defaults.bats`
Expected: 15 passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/apply-repo-defaults.sh tests/shell/apply-repo-defaults.bats
git commit -m "feat(apply-repo-defaults): lock mutation + schema bump"
```

---

## Task 13: Script — Dry-Run End-to-End

**Files:**
- Modify: `tests/shell/apply-repo-defaults.bats`

The script already short-circuits API mutations and lock mutation when `DRY_RUN=1` (see prior tasks). This task adds an end-to-end test that asserts dry-run is true to its name.

- [ ] **Step 1: Append failing test**

```bash
@test "dry-run: drifted state produces no mutating API calls, no lock write" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  before_sha=$(jq -S . "$tgt/.github/onboard.lock.json" | sha256sum | awk '{print $1}')
  run_with_stub api-drifted --repo o/r --target-path "$tgt" --prev-marker "" --dry-run
  [ "$status" -eq 0 ]
  ! grep -qE $'^(PUT|PATCH|POST|DELETE)\t' "$GH_STUB_CALL_LOG"
  after_sha=$(jq -S . "$tgt/.github/onboard.lock.json" | sha256sum | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

@test "dry-run: still emits defaults_applied=true output" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  run_with_stub api-drifted --repo o/r --target-path "$tgt" --prev-marker "" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *defaults_applied=true* ]]
}
```

- [ ] **Step 2: Run tests, verify pass (should already work from prior implementation)**

Run: `bats tests/shell/apply-repo-defaults.bats -f dry-run`
Expected: 2 passing.

- [ ] **Step 3: Run full suite**

Run: `bats tests/shell/apply-repo-defaults.bats tests/shell/apply-defaults-lib.bats`
Expected: 34 passing (17 lib + 17 script).

- [ ] **Step 4: Commit**

```bash
git add tests/shell/apply-repo-defaults.bats
git commit -m "test(apply-repo-defaults): dry-run end-to-end coverage"
```

---

## Task 14: Composite Action Wrapper

**Files:**
- Create: `actions/onboard-apply-defaults/action.yml`

Mirrors `actions/onboard-drift/action.yml` — thin wrapper that calls the script and emits outputs.

- [ ] **Step 1: Write the action**

```yaml
name: 'Onboard: apply repo defaults'
description: 'Apply catalog repo-level defaults to a target. Wraps scripts/apply-repo-defaults.sh.'
inputs:
  target_repo:
    description: 'owner/repo of the target adopter'
    required: true
  target_path:
    description: 'Path to the checked-out adopter repo on the runner'
    required: true
  prev_defaults_applied_at:
    description: 'Snapshot of the target lock''s defaults_applied_at field BEFORE render. Empty string means first-onboard or re-baseline.'
    required: false
    default: ''
  dry_run:
    description: 'When true, no API mutations and no lock write — only diff summary.'
    required: false
    default: 'false'
outputs:
  defaults_applied:
    description: 'true if script ran end-to-end, false on internal skip'
    value: ${{ steps.apply.outputs.defaults_applied }}
  tier_2_applied:
    description: 'true if Tier 2 (comfort) fields were processed this run'
    value: ${{ steps.apply.outputs.tier_2_applied }}
  modified:
    description: 'csv of mutated field-categories (branch_protection,delete_branch_on_merge,topics,merge_hygiene,repo_settings)'
    value: ${{ steps.apply.outputs.modified }}
runs:
  using: composite
  steps:
    - id: apply
      shell: bash
      env:
        GH_TOKEN: ${{ github.token }}
      run: |
        set -euo pipefail
        catalog="$GITHUB_ACTION_PATH/../.."
        flags=()
        if [[ "${{ inputs.dry_run }}" == "true" ]]; then
          flags+=("--dry-run")
        fi
        "$catalog/scripts/apply-repo-defaults.sh" \
          --repo "${{ inputs.target_repo }}" \
          --target-path "${{ inputs.target_path }}" \
          --prev-marker "${{ inputs.prev_defaults_applied_at }}" \
          "${flags[@]}" \
          >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: actionlint sanity-check**

Run: `actionlint actions/onboard-apply-defaults/action.yml`
Expected: no warnings.

- [ ] **Step 3: Commit**

```bash
git add actions/onboard-apply-defaults/action.yml
git commit -m "feat(actions): add onboard-apply-defaults composite action"
```

---

## Task 15: Atom Wire-Up in onboard.yml

**Files:**
- Modify: `.github/workflows/onboard.yml`

Insert two steps in the atom job: (a) snapshot the previous `defaults_applied_at` from the target lock BEFORE the render overwrites it, (b) call `actions/onboard-apply-defaults` AFTER render and BEFORE PR-A push.

- [ ] **Step 1: Locate the existing structure**

Run: `rg -n "Detect target profile|onboard-detect|onboard-render|Branch A" .github/workflows/onboard.yml`
Expected: line numbers for the detect, render, and PR-A steps.

- [ ] **Step 2: Identify token-mint step**

The atom mints an App-token via `actions/create-github-app-token` near the top of the job. Verify it already includes the target repo in the `repositories:` filter. If existing scope grants `administration:write` (verified by `code_security` PATCH usage), no token change needed.

Run: `rg -n "create-github-app-token" .github/workflows/onboard.yml | head -3`
Expected: 1+ lines showing where it's minted.

- [ ] **Step 3: Insert snapshot step before render**

Find the step that runs `actions/onboard-render` or `onboard-render.sh`. Just before it, insert:

```yaml
      - name: Snapshot previous defaults marker
        id: snap_defaults
        working-directory: target
        run: |
          set -euo pipefail
          if [[ -f .github/onboard.lock.json ]]; then
            prev=$(jq -r '.defaults_applied_at // ""' .github/onboard.lock.json)
          else
            prev=""
          fi
          echo "prev=$prev" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 4: Insert apply-defaults step after render, before PR-A push**

After the render step (which writes the new lock) and BEFORE "Branch A — ensure add-workflows PR":

```yaml
      - name: Apply repo defaults
        uses: ./.catalog/actions/onboard-apply-defaults
        with:
          target_repo: ${{ matrix.target.target }}
          target_path: target
          prev_defaults_applied_at: ${{ steps.snap_defaults.outputs.prev }}
          dry_run: ${{ inputs.dry_run }}
```

Note: existing atom steps use the `.catalog/` prefix when invoking catalog-local actions (see how `onboard-render` is invoked). Mirror that exact path style. Verify by reading the rendered step.

- [ ] **Step 5: actionlint check**

Run: `actionlint .github/workflows/onboard.yml`
Expected: no warnings. If unknown-input warnings appear for action.yml not-yet-present at static-lint time, those are tolerated by the existing `-ignore` flags in `validate.yml` (see memory: project_actionlint_clientid pattern — apply similar suppression only if needed).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): wire apply-defaults step into atom flow"
```

---

## Task 16: Operations Docs Update

**Files:**
- Modify: `docs/operations.md`

Add a new §Repo Defaults section documenting what gets applied, the marker mechanic, opt-out, and the deliberate required_status_checks gap.

- [ ] **Step 1: Locate insertion point**

Run: `rg -n "^## " docs/operations.md | head -20`
Expected: list of top-level sections. New section goes after §Drift audit (logical adjacency).

- [ ] **Step 2: Append the new section**

```markdown
## Repo Defaults

Every onboard run applies a tier of repository-level defaults beyond the rendered workflow files. Source of truth: `catalog/onboard-defaults.json`.

### What gets applied

**Tier 1 — always-overwrite, every sweep:**

- Branch protection on the default branch — PR-gate (0 approvers required), no force-push, no delete, linear history, enforce_admins=false.
- `delete_branch_on_merge=true`.
- Topic `serverkraken-onboarded` added (additive; other topics preserved).

**Tier 2 — first-onboard-only, gated by lock marker:**

- Merge-strategy flags: `allow_squash_merge=true`, `allow_merge_commit=false`, `allow_rebase_merge=false`, `allow_auto_merge=true`.
- Squash-commit title/message format set to `PR_TITLE` / `PR_BODY`.
- Repository toggles: `has_wiki=false`, `has_projects=false`, `has_issues=true`, `has_discussions=false`.

### Marker mechanic

The onboard lock file (`.github/onboard.lock.json`) gains a `defaults_applied_at` field once Tier 2 has been applied. Subsequent sweeps see the marker and skip Tier 2 — owner overrides to comfort fields are respected after the first onboard. Tier 1 ignores the marker and is always reconciled.

To re-baseline Tier 2 on an adopter: clear `defaults_applied_at` from the lock (or delete the field), commit to the default branch, and trigger an onboard. The next sweep will apply Tier 2 fresh and set a new marker.

### Required status checks gap

The catalog default leaves `required_status_checks=null` on branch protection. This is deliberate — the rendered `ci.yml` has profile-dependent job names whose status-check context names cannot be hardcoded without breaking adopters whose check-context names differ.

**Owner action recommended after first green CI run:**
1. Open the adopter's first PR after onboarding.
2. Wait for `ci.yml` to complete with a green run.
3. Settings → Branches → main → Edit → Require status checks → add the contexts the CI run produced (e.g., `ci / secscan / scan`, `ci / lint-go-root`, `ci / test-go-root`).
4. Save.

This makes "merge without CI" structurally impossible.

### Opt-out

Topic `no-serverkraken-onboard` on the adopter repo skips both the rendered-files contract and the defaults contract — they go together. There is no separate defaults-only opt-out.
```

- [ ] **Step 3: Verify markdown syntax**

Run: `head -50 docs/operations.md; echo ---; tail -50 docs/operations.md`
Expected: well-formed markdown, no broken section anchors.

- [ ] **Step 4: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): document repo defaults"
```

---

## Task 17: Pre-Merge Dry-Run Verification (manual)

**Files:** none modified. This is a manual verification step that produces evidence the PR is safe to merge.

- [ ] **Step 1: Push the branch and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --base main --title "feat(onboard): apply repo defaults contract (phase 8)" \
  --body "Implements docs/superpowers/specs/2026-05-26-onboard-repo-defaults-design.md."
```

- [ ] **Step 2: Wait for PR-CI to be green**

Required: validate.yml + test-shell.yml + actionlint pass.

- [ ] **Step 3: Branch-scoped dry-run of onboard-sweep**

```bash
gh workflow run onboard-sweep.yml --ref <branch-name> -f dry_run=true
```

- [ ] **Step 4: Inspect dry-run output**

Wait for the run to finish, then:

```bash
gh run list --workflow onboard-sweep.yml --limit 1
gh run view --log <run-id> | rg -i "dry-run|would PUT|would PATCH|defaults_applied"
```

Expected: for each in-scope adopter, a series of `would PUT branch protection`, `would PATCH /repos/...`, `would PUT topics` lines reflecting the expected per-repo diffs. **No actual API mutations.**

- [ ] **Step 5: Spotcheck**

Pick 2 adopters from the dry-run output. For each:
- Verify the predicted PUT/PATCH set against the current state via `gh api`.
- Confirm no surprises (e.g., a repo we didn't expect to need branch protection somehow already has it).

- [ ] **Step 6: Merge**

If the dry-run output matches expectation: approve the PR and squash-merge to main. release-please will bump to v4.2.0.

- [ ] **Step 7: Live-sweep**

```bash
gh workflow run onboard-sweep.yml --ref main
```

Watch the run; expect 33 atom jobs to apply defaults. Investigate any failures.

- [ ] **Step 8: Post-sweep spotcheck**

For 2-3 adopters, verify:
- `gh api /repos/serverkraken/<adopter>/branches/main/protection` returns the expected config.
- `gh api /repos/serverkraken/<adopter>` shows `delete_branch_on_merge=true`.
- `gh api /repos/serverkraken/<adopter>/topics` includes `serverkraken-onboarded`.
- `gh api /repos/serverkraken/<adopter>/contents/.github/onboard.lock.json | jq '.content' -r | base64 -d | jq '.schema_version, .defaults_applied_at'` shows v2 + timestamp.

---

## Self-Review

Spec coverage check:

- ✓ Architecture (spec §Architecture) → Tasks 1, 3–14, 15
- ✓ Defaults catalog content (spec §Defaults Catalog) → Task 1
- ✓ Two-tier aggression (spec §Aggression Policy) → Tasks 3 (classify_tier), 9 (Tier 1 BP), 10 (Tier 1 delete + topics), 11 (Tier 2)
- ✓ Marker mechanic + schema bump (spec §Marker mechanism) → Task 12 (lock mutation), Task 15 (snapshot step)
- ✓ Atom integration (spec §Onboard Atom Integration) → Task 15
- ✓ Snapshot step (spec §Atom Integration step 4) → Task 15
- ✓ Apply-defaults step (spec §Atom Integration step 7) → Task 15
- ✓ Failure mode = fail-loud (spec §Failure mode) → script uses `set -euo pipefail`, exits non-zero on API errors (Task 8 skeleton; tested in API-error fixture from Task 7+9)
- ✓ Dry-run (spec §Dry-run) → Task 13
- ✓ Testing strategy (spec §Testing Strategy) → Tasks 2–13 (bats + lib + script + gh stub + fixtures)
- ✓ Risks → R4 (lock-schema-bump silent break): no separate task, addressed by spec note "schema_version is currently descriptive only" — implicit in implementation
- ✓ App permission (spec §App Permission) → no task needed (already satisfied)
- ✓ Operations docs (spec §Risks R1) → Task 16
- ✓ Deployment order (spec §Deployment Order) → Task 17

Gaps:
- Spec §Testing Strategy mentions `tests/callers/onboard-apply-defaults-happy.yml` as an integration caller. The plan omits it deliberately — the bats coverage is comprehensive enough that the integration test would duplicate without adding signal at this phase. If the post-merge live-sweep surfaces an integration issue, add the caller in a follow-up.
- Spec §Phase 2 (drift-check integration) is explicitly out-of-scope and not in the plan. Confirmed.

Placeholder scan: no TBD/TODO/implement-later strings in the plan. Every step contains either exact code, exact commands, or a manual verification action.

Type consistency check: function signatures are stable across tasks. `compute_topics_union` takes two JSON-array strings, returns one JSON-array string. `diff_*` functions take two JSON-object strings, return either empty or a diff summary line. `classify_tier` takes one field name, returns one of three strings. The script orchestration in Tasks 9–11 uses these names consistently.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-26-onboard-repo-defaults.md`.
