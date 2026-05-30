# Onboard Sweep — Minor-Version-Aware Stale-PR Guard

**Date:** 2026-05-30
**Status:** Approved (brainstormed 2026-05-30)
**Follows:** PR #137 (`fix/onboard-sweep-stale-pr-guard`, merged 2026-05-26) — that
fix made the duplicate-PR guard skip only on a *current-major* title match
(`@v4\b`), unblocking cross-major cutovers. This spec generalises the guard one
level down: detect drift on the *minor* axis so within-major catalog evolution
(`v4.4.0 → v4.7.0`) also re-triggers onboarding for already-open bot PRs.

## Problem

The onboard-sweep `enumerate` job skips any adopter whose open bot PR title
already matches the current catalog major (`@${CURRENT}` with `CURRENT=v4`).
After the 2026-05-25 / 2026-05-27 sweep runs created 28 PRs at `v4.4.0`, the
catalog moved through `v4.4.1 → v4.4.2 → v4.5.0 → v4.5.1 → v4.6.0 → v4.7.0`
without ever re-touching those PRs. The 2026-05-30 sweep run reported
`update=0 onboard=0 skipped=33` (28× `:open-pr`, 5× `:clean`) — every adopter
correctly had drift, but the title-only guard masked it.

Sample evidence: <https://github.com/serverkraken/reusable-workflows/actions/runs/26677746197>

Concretely, the rendered content in those 28 bot branches misses every
catalog change after v4.4.0, including two defaults-fixes (`v4.4.2` switched
`squash_merge_commit_message` default to `BLANK`; `v4.5.1` fixed
branch-protection on missing-rules 404), Flutter atoms (`v4.5.0` / `v4.6.0`),
and prerelease callers (`v4.7.0`). Merging any of them today would propagate
known-superseded workflows into the adopter.

## Scope

- `.github/workflows/onboard-sweep.yml` — `enumerate` job's duplicate-PR guard
  (call out to new script + new `CURRENT_MINOR` output on the version step).
- `.github/workflows/onboard.yml` — new optional input `rendered_against`,
  threaded into the render step.
- `scripts/onboard-render.sh` — writes the new lock field.
- `scripts/onboard-sweep-stale-pr-check.sh` — new helper script extracted from
  the guard so bats can drive it (mirrors existing
  `scripts/onboard-sweep-drift-status.sh` pattern).
- New bats coverage for the guard's lock-compare branch.

Out of scope: any change to `catalog_version` (still major-pinned to `v4`),
adopter-side `uses:` lines (still `@v4`), drift-status logic on adopter `main`,
or the `chore/remove-legacy-workflows` PR-B independently (see Design § PR B).

## Design

### Lock schema (additive)

`scripts/onboard-render.sh:165-171` currently emits:

```json
{
  "schema_version": "1",
  "catalog_version": "v4",
  "rendered_at": "2026-05-30T08:00:00Z",
  "files": { ".github/workflows/ci.yml": "sha256:..." }
}
```

Add one optional field:

```json
{
  "schema_version": "1",
  "catalog_version": "v4",
  "rendered_against": "v4.7.0",
  "rendered_at": "2026-05-30T08:00:00Z",
  "files": { ".github/workflows/ci.yml": "sha256:..." }
}
```

Semantics:

- `catalog_version` stays the major pin used by `uses:`-rendered consumers
  (downstream adopters keep floating on `@v4`).
- `rendered_against` is the full minor tag of the catalog checkout at render
  time (`git describe --tags --abbrev=0` from the catalog root). It is purely
  informational for tooling — adopters never read it.
- Field is **optional**: missing field on legacy locks is interpreted by the
  guard as "pre-this-spec rendering" (i.e. unconditionally stale).
- `schema_version` stays `"1"` — additive optional field does not warrant a
  bump (drift-status and lock-compare don't read this field).

### `onboard.yml` input (additive)

New optional input on the reusable workflow:

```yaml
inputs:
  rendered_against:
    description: |
      Full catalog tag (vX.Y.Z) that templates were rendered against.
      Defaults to inputs.pin_version when unset (backwards compatible).
      onboard-sweep.yml passes the catalog checkout's `git describe`.
    required: false
    type: string
    default: ""
```

Threaded into the render step's env as `RENDERED_AGAINST`; the renderer falls
back to `$PIN` when unset, preserving exact current behavior for direct
callers (e.g. the existing manual `workflow_dispatch` of `onboard.yml`).

### Sweep guard rewrite

Current logic (`onboard-sweep.yml:110-123`):

```bash
existing_current=$(gh api .../pulls
  -q '[.[] | select(...bot...)
            | select(.head.ref | test("^chore/(onboard|remove-legacy)..."))
            | select(.title | test("@" + env.CURRENT + "\\b"))
      ] | length')
if [[ "$existing_current" -gt 0 ]]; then skipped+=":open-pr"; continue; fi
```

New logic — extracted into `scripts/onboard-sweep-stale-pr-check.sh`
(mirrors `scripts/onboard-sweep-drift-status.sh`):

```bash
# Usage: onboard-sweep-stale-pr-check.sh <owner/repo> <current_minor>
# Stdout: status=<skip|stale|no-pr>
# Requires GH_TOKEN env var.
#
# Decision tree:
#   no open bot PR on chore/onboard-reusable-workflows         → status=no-pr
#   open PR + lock fetch + rendered_against == current_minor   → status=skip
#   open PR, anything else (404, missing field, API error)     → status=stale
```

`enumerate` then becomes:

```bash
case "$(scripts/onboard-sweep-stale-pr-check.sh "$full" "$CURRENT_MINOR")" in
  skip)  skipped_csv+="${full}:open-pr,"; continue ;;
  stale) ;; # fall through to drift / fresh-onboard
  no-pr) ;; # fall through to drift / fresh-onboard
esac
```

The helper uses the known branch name (no jq array juggling needed):

```bash
exists=$(gh api -X GET "/repos/$TARGET/pulls" -f state=open \
  -q '[.[] | select(.user.login == "serverkraken-release-bot[bot]")
            | select(.head.ref == "chore/onboard-reusable-workflows")
      ] | length' 2>/dev/null || echo 0)

[[ "$exists" -eq 0 ]] && { echo "no-pr"; exit 0; }

lock_b64=$(gh api \
  "/repos/$TARGET/contents/.github/onboard.lock.json?ref=chore/onboard-reusable-workflows" \
  -q '.content' 2>/dev/null || true)
lock_rendered=$(printf '%s' "$lock_b64" | base64 -d 2>/dev/null \
                | jq -r '.rendered_against // empty' 2>/dev/null || true)

[[ "$lock_rendered" == "$CURRENT_MINOR" ]] && echo "skip" || echo "stale"
```

Inputs to the rewrite:

- `current_minor` — new output on the `ver` step (`steps.ver.outputs.current_minor`),
  populated from the same `git describe --tags --abbrev=0` already running
  there. The major-parse line stays; we add `echo "current_minor=$tag"` next
  to `echo "current_major=$major"`.
- Title-match filter removed: branch-name *exact* equality (replacing the
  former regex alternation) already constrains to bot-owned PRs; cross-major
  stale PRs are on the same branch name and benefit from the same lock-compare.
- PR B (`chore/remove-legacy-workflows`) is **not** independently checked —
  it has no lock file. When the lock-compare decides "re-onboard", `onboard.yml`
  refreshes both PR A and PR B in one run.

### PR B (`remove-legacy`) — orphan case

When PR A was merged but PR B is still open (e.g. an earlier sweep landed
PR A, PR B was held back by required-review), `enumerate` finds no PR A
branch → no lock-compare → falls through to `drift-status`. If adopter `main`
is now up to date (drift `clean`), the adopter is correctly bucketed as
`:clean` (skip — PR B is the human's to merge or close). If `main` is still
behind, `behind` bucket triggers re-onboard, which idempotently force-pushes
PR B's branch. This is the same behavior as before the rewrite.

### Sweep workflow_call to `onboard.yml`

Both update- and onboard-batches pass the new input:

```yaml
update-batch:
  uses: ./.github/workflows/onboard.yml
  with:
    target_repos: ${{ needs.enumerate.outputs.update_targets }}
    language: auto
    pin_version: ${{ needs.enumerate.outputs.current_version }}      # v4
    rendered_against: ${{ needs.enumerate.outputs.current_minor }}   # v4.7.0
```

## Failure / edge cases

| Case | Guard behavior | Justification |
|---|---|---|
| Open PR present, lock-compare matches | skip `:open-pr` | content already current |
| Open PR present, `rendered_against` mismatches | fall through → onboard | re-render covers drift |
| Open PR present, lock 404 (legacy PR pre-spec) | fall through → onboard | conservative; one-time refresh |
| Open PR present, lock has no `rendered_against` field | fall through → onboard | additive-field absent → stale |
| Open PR present, `gh api` fails (5xx / rate-limit) | fall through → onboard | fail-open per design Frage 2 |
| No open PR | existing drift-status path | unchanged from PR #137 |

## Testing

New bats file `tests/shell/onboard-sweep-stale-pr-check.bats` drives
`scripts/onboard-sweep-stale-pr-check.sh` directly. Network calls are
intercepted via a `gh` shim on `$PATH` (same pattern as existing
`tests/shell/onboard-sweep-drift-status.bats`):

- **clean-current**: shim returns `length=1` then a base64 lock with
  `rendered_against == "v4.7.0"`; current minor `v4.7.0` → stdout `skip`.
- **stale-minor**: shim returns `length=1` then a lock with
  `rendered_against == "v4.4.0"`; current `v4.7.0` → stdout `stale`.
- **missing-field**: shim returns `length=1` then a pre-spec lock with no
  `rendered_against` field → stdout `stale`.
- **lock-404**: shim returns `length=1` then empty content for the lock
  fetch → stdout `stale`.
- **no-open-pr**: shim returns `length=0` → stdout `no-pr` (no second call).

Existing tests unaffected — additive lock field, identical render path when
`rendered_against` env is unset.

Manual integration verification after merge + v4.8.0 release:
trigger `onboard-sweep.yml` via `workflow_dispatch`. Expected output:
~28 adopters in `update_targets` (or split between update and onboard buckets
per their main-branch drift), `skipped` only for `:clean` and PRs whose
content already matches v4.8.0.

## Release & cutover

- Lock field addition is a `feat` commit → minor bump (v4.7.0 → v4.8.0).
- After release-please tags `v4.8.0`, the next nightly cron `onboard-sweep`
  run will:
  1. Enumerate 33 adopters.
  2. For each open PR: fetch lock → field missing → fall through.
  3. Re-onboard the lot, force-pushing fresh content to all 28 bot branches.
  4. From the *next* sweep onward, `rendered_against=v4.8.0` is present in
     all open PRs' locks; the guard skips them until v4.8.1+ ships.

No manual PR-closing is needed; the cutover is self-healing on the first
post-release sweep.

## Risks

- **API budget**: enumeration now does 1 extra `GET contents` per open bot PR
  (~30 calls max per sweep). Far under the GitHub App's 15k/hour rate limit.
- **Onboard waste when bot branch is already at current minor but lock was
  hand-edited to drop the field**: fail-open re-renders, no-op force-push to
  same SHA (CI doesn't re-trigger). Negligible cost.
- **`git describe` outputs a non-vX.Y.Z tag** (e.g. an alpha): unlikely in
  the catalog repo, but fail-open semantics absorb it — every lock compare
  mismatches, every adopter re-onboards. Self-correcting on the next stable
  tag.

## What this is NOT

- Not a refactor of `drift-status` (which already correctly detects within-
  major template evolution via render-and-compare against `main`).
- Not a deprecation of `catalog_version`. That field remains the major-pin
  contract for adopters' `uses:`.
- Not a change to `onboard-status.md` parsing or the `no-serverkraken-onboard`
  topic opt-out.
