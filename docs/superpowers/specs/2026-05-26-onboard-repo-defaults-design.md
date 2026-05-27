# Onboard Repo Defaults — Design

**Date:** 2026-05-26
**Status:** Approved, pending implementation plan

## Problem

Adopter repos currently get rendered workflow files via `onboard.yml`, plus one repo-level setting (`security_and_analysis.code_security.status=enabled` for private repos, set inline in the atom). Everything else — branch protection, merge strategy, repository toggles, topics — is left at GitHub defaults or to the adopter owner.

This leaves a sharp edge that surfaced as Bug B during the 2026-05-26 sweep: skytrack had no branch protection on `main`. After the sweep force-pushed the `chore/onboard-reusable-workflows` branch, GitHub auto-reopened the merged PR #15 with new commits on its head ref. The owner could (and did) merge that reopened PR directly without any review or CI-gate. Lock-file from a force-pushed branch landed on `main`, drift-check then saw it as `stale-lock` because the rendered files diverged from a re-render against the current catalog.

The Skytrack scenario is just the visible symptom. The deeper miss: adopter onboarding sets up the workflow contract but not the repository-level policy contract that makes those workflows enforceable. PR-gates, status-check requirements, branch-deletion semantics, merge-history shape — all unset across the 33 in-scope repos.

The catalog needs to extend the onboarding contract to include these repo-level policy defaults, applied idempotently by every sweep, with a clear escape hatch for opt-out.

## Solution

Add a new tier to the onboard atom: **repo-defaults**, applied by the atom right after render and before PR-A push.

- **Declarative source of truth** in `catalog/onboard-defaults.json` — JSON, single file, schema-versioned.
- **Bash entry-point** in `scripts/apply-repo-defaults.sh <owner/repo>` with `--dry-run` and (later) `--check-only` flags. Calls GitHub API directly via `gh`, never gomplate or other render-time tools.
- **Reusable function library** in `scripts/lib/apply-defaults-lib.sh` for testable computation (diffs, classifications) separated from API side-effects.
- **Thin composite action** at `actions/onboard-apply-defaults/action.yml` wrapping the script for atom consumption, mirroring `actions/onboard-drift/action.yml`.
- **Two-tier aggression policy**: security-relevant fields always re-applied every sweep; comfort fields applied only on first onboard, tracked by a new `defaults_applied_at` marker in the onboard lock file (schema bumped to v2).
- **Existing opt-out topic** `no-serverkraken-onboard` covers defaults too — already-removed repos stay out, no new opt-out surface.

Atom integration is one new step and one extended token-scope mint. App permissions already include `administration:write` (verified by current `code_security` PATCH usage).

## Architecture

```
catalog/
  onboard-defaults.json              source of truth for defaults

scripts/
  apply-repo-defaults.sh             entry point: <owner/repo> [--dry-run]
  lib/apply-defaults-lib.sh          pure functions, no API side effects

actions/
  onboard-apply-defaults/
    action.yml                       thin wrapper, calls the script

.github/workflows/onboard.yml        new step in atom: actions/onboard-apply-defaults
                                     after render, before PR-A push

tests/shell/
  apply-repo-defaults.bats           script-level tests, gh CLI stubbed
  apply-defaults-lib.bats            pure-function tests
tests/callers/
  onboard-apply-defaults-happy.yml   integration test (workflow_call exercise)
tests/fixtures/repo-defaults/
  lock-v1-no-marker.json
  lock-v2-with-marker.json
  api-bp-*.json
  api-repo-settings-*.json
  api-topics-*.json
```

The script's contract:

- Reads `catalog/onboard-defaults.json` (relative to repo root or via `$CATALOG_ROOT`).
- Reads the target's checked-out tree at `<target_path>` to get the current lock file (for `defaults_applied_at` snapshot).
- Calls GitHub API via `gh api` with the token from `$GH_TOKEN`.
- Mutates `<target_path>/.github/onboard.lock.json` to add/update `defaults_applied_at` and bump `schema_version` to 2.
- Emits structured output (key=value lines) to stdout for sink-friendly capture into `$GITHUB_OUTPUT`.

## Defaults Catalog (onboard-defaults.json)

```json
{
  "_schema_version": 1,
  "_doc": "Source of truth for serverkraken adopter defaults. Modify here, sweep propagates.",

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

### Risky-field notes

**`required_pull_request_reviews: {required_approving_review_count: 0, ...}`** — PR is required (cannot push directly to `main`), but zero approvers needed. This is the minimum config that produces a PR-gate without requiring sock-puppet reviews. Note: an empty object or a `null` value for this field would disable the PR-gate entirely and allow direct pushes — this default is deliberately not null.

**`required_status_checks: null`** — Deliberately left null. The catalog-rendered `ci.yml` has profile-dependent job names (`lint-go-<suffix>`, `test-python-<suffix>`, etc.) plus a universal `secscan` job that invokes a reusable workflow whose check-context name has the form `<caller-job> / <called-job>`. Hardcoding the wrong context name would block all PRs on a subset of adopters until owners manually intervene. The catalog default leaves status-check enforcement off; owners add specific contexts via the GitHub UI after their first green CI run. Documented in `docs/operations.md` follow-up.

**`enforce_admins: false`** — Admins (typically the owner) can bypass protection in emergencies without needing the org-admin to temporarily disable rules.

**`required_linear_history: true`** combined with **`allow_merge_commit: false`** — squash and rebase are the only merge paths. Eliminates merge-bubble noise in `main` history.

**`allow_auto_merge: true`** — Renovate and release-please can self-merge after CI green without a manual click. Saves owner workload.

**`delete_branch_on_merge: true`** — This is the security-relevant Tier-1 default that directly addresses the Skytrack scenario. After a PR merges, GitHub deletes the head branch. A subsequent force-push from the sweep to that branch name cannot reopen a stale PR because the merged PR's branch no longer exists; the sweep will create a fresh branch + fresh PR.

**`topics_additive: ["serverkraken-onboarded"]`** — Only adds, never removes. Other topics (language tags, project tags) are preserved verbatim. Enables a future sweep-enumerate variant that filters by topic instead of parsing `onboarding-status.md`.

## Aggression Policy

Two tiers, hardcoded in `scripts/lib/apply-defaults-lib.sh` (`classify_tier()`).

### Tier 1: always-overwrite (every sweep run)

| Field | Reason |
|---|---|
| `branch_protection.*` (all fields, full PUT) | Security core. Manual removal must be self-correcting. |
| `delete_branch_on_merge` | Security: prevents the Skytrack PR-reopen scenario. |
| `topics_additive` | Idempotent (set union). No state to "respect". |

Tier-1 application is gated only by the `no-serverkraken-onboard` opt-out topic.

### Tier 2: first-onboard-only

| Field | Catalog value |
|---|---|
| `allow_squash_merge` | true |
| `allow_merge_commit` | false |
| `allow_rebase_merge` | false |
| `allow_auto_merge` | true |
| `squash_merge_commit_title` | `PR_TITLE` |
| `squash_merge_commit_message` | `PR_BODY` |
| `has_wiki` | false |
| `has_projects` | false |
| `has_issues` | true |
| `has_discussions` | false |

Applied once on initial onboard, then never re-applied unless the owner explicitly re-baselines.

### Marker mechanism

The onboard lock file gains a new field:

```json
{
  "schema_version": 2,
  "catalog_version": "v4",
  "rendered_at": "2026-05-26T17:10:08Z",
  "defaults_applied_at": "2026-05-26T18:00:00Z",
  "files": { ... }
}
```

Schema migration:

- **schema_version absent or 1, no `defaults_applied_at`**: this run applies both tiers. `defaults_applied_at = now()`, `schema_version = 2`. Retroactive baseline for the 33 currently in-scope repos.
- **schema_version 2, `defaults_applied_at` present**: this run applies Tier 1 only. `defaults_applied_at` preserved.
- **schema_version 2, `defaults_applied_at` missing or empty**: same as the first case. Lets the owner re-baseline by clearing the field.

The atom's snapshot-step (run after target checkout, before render) reads the old lock and exports the previous `defaults_applied_at` as a step-output. The render step overwrites the lock file without that field. The apply-defaults step then writes either `now()` (first run / re-baseline) or the preserved old value back into the new lock.

## Onboard Atom Integration

New step inserted into the atom job sequence between render and PR-A:

```
1. Mint App-token (existing scopes + administration is already granted)
2. Checkout target/
3. Detect → profile.json
4. NEW: Snapshot prev_defaults_applied_at from old lock if present
5. Enable code_security (existing)
6. Render templates → writes new files including lock (without defaults_applied_at)
7. NEW: actions/onboard-apply-defaults
       Inputs: target_path=target, target_repo, prev_defaults_applied_at, dry_run
       Effects:
         - Tier 1 always (BP + delete-on-merge + topics)
         - Tier 2 if prev_defaults_applied_at is empty
         - Lock mutation: write defaults_applied_at + bump schema_version to 2
8. PR-A branch + push + create/edit (commits updated lock + rendered files)
9. PR-B (remove-legacy, unchanged)
10. Finalize / status-doc-update (existing)
```

Step 4 (snapshot):

```yaml
- id: snap
  name: Snapshot previous defaults marker
  working-directory: target
  run: |
    set -euo pipefail
    if [[ -f .github/onboard.lock.json ]]; then
      prev=$(jq -r '.defaults_applied_at // ""' .github/onboard.lock.json)
    else
      prev=""
    fi
    echo "prev_defaults_applied_at=$prev" >> "$GITHUB_OUTPUT"
```

Step 7 (apply): consumes the snapshot via input, runs the script, captures outputs (`defaults_applied=true|false`, `tier_2_applied=true|false`, `modified=<csv>`).

### Failure mode

`apply-defaults` step is **fail-loud**: any non-zero exit fails the atom job. The atom matrix's `fail-fast: false` keeps the other repos running. Sweep summary surfaces the failure count. A token-scope error or API outage stops PR-A from being created — better than landing rendered workflows in a repo whose policy contract failed to apply.

### Dry-run

`apply-repo-defaults.sh --dry-run` performs no API mutations and no lock mutation. Instead it:

- Fetches current state for each field.
- Computes diff vs catalog target.
- Writes a markdown diff table into `$GITHUB_STEP_SUMMARY`.
- Emits `defaults_applied=false`, `would_change=<csv>` outputs.
- Exits 0 unless a fetch itself errors.

Forwarded from the workflow_dispatch `dry_run` input through to the script.

### Sweep behavior

Sweep invokes the onboard atom per repo. After this feature ships:

- The 33 currently in-scope repos: first sweep applies Tier 1 + Tier 2 (retroactive baseline), bumps locks to schema v2, sets `defaults_applied_at`.
- Subsequent sweeps: only Tier 1 fires for each. No-ops for repos whose state already matches.
- Newly-added repos (post-merge): both tiers on their first onboard, Tier 1 on subsequent.

## Testing Strategy

Catalog convention: `tests/shell/*.bats` for unit tests, `tests/callers/*.yml` for integration via reusable-workflow exercise. Coverage target ≥ 90% lines on shell code (existing `.bashcovrc` setup).

### tests/shell/apply-repo-defaults.bats

Stubs `gh` CLI via PATH-prepend. The stub logs every invocation to `$BATS_TEST_TMPDIR/gh-calls.log` and returns canned responses from `tests/fixtures/repo-defaults/`. Selected via env var `ONBOARD_DEFAULTS_TEST_FIXTURE=<name>`.

Test cases:

- first-onboard applies both tiers, sets `defaults_applied_at`
- subsequent run with marker applies only Tier 1
- schema-migration v1 lock without marker becomes v2 with marker, Tier 2 retroactively applied
- dry-run produces no API calls and only diff output in summary
- idempotent: second consecutive non-dry run produces zero mutating gh-calls
- topics additive: existing topics preserved, `serverkraken-onboarded` added if absent, no-op if present
- branch protection correct: GET only, no PUT
- branch protection missing: PUT with full config from catalog
- branch protection drift (e.g., `enforce_admins=true` in target, false in catalog): PUT-overwrite
- Tier 2 field drift with marker present (e.g., `allow_merge_commit=true`): not corrected — Tier 2 respects the marker
- fail-loud: token without `administration:write` (mocked 403 response): exits 2 with parseable error message
- fail-mid-tier-1: BP API 500: exits non-zero, lock marker not updated
- config-file missing: exits 1 with parse error message
- invalid JSON in config: exits 1

### tests/shell/apply-defaults-lib.bats

Pure-function tests, no `gh` stubbing needed:

- `diff_branch_protection()`: identical inputs return empty diff
- `diff_branch_protection()`: context-list reorder not flagged as diff
- `diff_repo_settings()`: lists only Tier-2 fields by classification
- `compute_topics_union()`: dedupes input, preserves existing order, appends new
- `classify_tier()`: returns deterministic field list per tier

### tests/callers/onboard-apply-defaults-happy.yml

Reusable-workflow-style caller invoked from `validate.yml` on PR CI. Targets a fresh fixture repo (set up in advance under `serverkraken/<fixture-repo>` or simulated via a temp directory). Asserts the action's outputs and that the lock file ends in the expected state.

### Out of test scope

- Real API calls against GitHub: covered by pre-merge dry-run dispatch and post-merge manual sweep. End-to-end correctness is verified once via manual sweep against the 33 repos.

## Phase 2 — Drift-Check Integration (separate spec)

Not implemented in this spec. The library is structured so a later `--check-only` flag adds drift-detection without code duplication:

- `apply-repo-defaults.sh --check-only <owner/repo>`: read-only inspection, returns `status=clean|defaults-drift`, `modified=<csv>`.
- `drift-check.yml`'s `check` matrix job calls it after the existing render-and-compare, merges output into the rolling issue body.

The `apply-defaults-lib.sh` diff functions already return structured diffs suitable for this consumer.

## App Permission

Pre-condition: `serverkraken-release-bot` App has `administration:write` on repository permissions. **Verified satisfied** by inspection of the existing `code_security` PATCH usage in `onboard.yml:184`, which requires the same scope and is known to work for the org.

No org-admin action required to ship this feature.

## YAGNI — Out of Scope

- **Per-repo override config**: deferred to the existing `feat/per-repo-override-vars` spec (vars-based override of catalog values). The defaults JSON has no per-repo branching; if an adopter needs a different default, they remove themselves with the opt-out topic until per-repo overrides land in a separate spec.
- **CODEOWNERS rendering**: separate template feature, unrelated.
- **Dependabot config**: Renovate is installed org-wide, redundant.
- **Secret-Scanning / GHAS toggles**: paid-only, breaks the free-tier constraint.
- **GitHub Actions settings** (allowed actions list, default workflow permissions): adjacent security surface, separate spec.
- **Bot-bypass allowance** for branch protection: owner merges manually today, the complexity of bypass-allowance configuration is not justified.

## Risks

**R1: With `required_status_checks=null`, an owner can still merge a PR without CI passing.**
The PR-gate forces all changes through a PR, `delete_branch_on_merge=true` prevents the merged-PR-reopen pattern, but a determined owner can click "Merge pull request" before CI completes. Mitigation: documentation in `docs/operations.md` instructs owners to add the rendered ci.yml's check contexts to branch protection after the first green run. Accepted residual risk — automating this requires knowing profile-dependent job names, which is out of scope.

**R2: First post-feature sweep triggers 33 simultaneous policy-set operations.**
Mitigation: pre-merge dry-run dispatch shows the change set before any API write. Branch protection PUT is per-repo (no rate cliff at GitHub scale). The atom is already matrixed and stable at 33 parallel jobs from the existing render flow.

**R3: An owner who wants merge_commit enabled cannot re-disable via `allow_merge_commit=true` because the marker prevents Tier-2 re-write.**
Status: by design. The marker is one-shot. Owner can re-baseline by clearing `defaults_applied_at` from the lock and triggering a sweep. Alternatively the catalog default itself can be revisited.

**R4: Lock-schema bump to v2 silently breaks tooling that reads schema_version=1.**
Mitigation: the only schema-version reader in-repo is `scripts/onboard-drift.sh` which uses `jq -r '.catalog_version'`, not `.schema_version`. Search confirms no other consumer. Schema_version is currently descriptive only. New v2 readers (this feature) require v2; old v1 readers ignore the new field.

**R5: `actions/onboard-apply-defaults` step failure blocks PR-A creation.**
Status: by design (fail-loud). The cost of a failed atom job is small; landing rendered workflows without their enforcing policy is the worse outcome.

## Deployment Order

1. **PR α**: full implementation — scripts, lib, tests, JSON-config, composite action, lock schema bump to v2, atom wire-up, `docs/operations.md` updates. Bats coverage ≥ 90%. Actionlint and yamllint pass.
2. **Pre-merge verification**: branch-dispatch `onboard-sweep.yml` with `dry_run=true`. Confirm the per-repo diff outputs show the expected Tier-1 + Tier-2 changes against the current state. No API mutations occur.
3. **Merge**: release-please bumps minor version (catalog feature addition, no breaking changes to existing workflow_call inputs).
4. **Post-merge sweep**: manual `gh workflow run onboard-sweep.yml --ref main`. Expect 33 atom jobs, each applying Tier 1 (mostly mutating because no BP exists today) and Tier 2 (one-shot retroactive baseline).
5. **Spotcheck**: pick 2–3 adopters from the run, verify branch protection is set, `delete_branch_on_merge=true`, topic added, lock at schema_v2 with `defaults_applied_at` populated.
6. **Phase 2** (later, separate spec): drift-check integration via `--check-only`.

## Success Criteria

- All in-scope (non-opt-out) adopters end the first post-merge sweep with branch protection on `main` matching the catalog config, `delete_branch_on_merge=true`, `serverkraken-onboarded` topic present, lock at schema_v2.
- The Skytrack scenario is structurally constrained: after merge the branch is deleted, the next force-push creates a fresh branch + fresh PR rather than reopening a merged PR, and direct push to `main` is blocked by the PR-gate. (Owner-initiated merge-without-CI remains possible until they opt-in to required status checks via the GitHub UI — see Risk R1.)
- Bats test suite has ≥ 90% line coverage on the new scripts.
- Subsequent sweeps are idempotent: zero gh-API mutations for repos whose policy already matches.
- Owners who explicitly opt out via the existing topic remain untouched.
