# Onboarding Workflow — Design

**Date:** 2026-05-16
**Status:** Draft (awaiting user review)
**Author:** Soenne + Claude
**Repo:** `serverkraken/reusable-workflows`
**Catalog version at time of writing:** v1.1.1

---

## 1. Goal

Build a `workflow_dispatch`-triggered workflow in this catalog repo (`.github/workflows/onboard.yml`) that automates adoption of the catalog's reusable workflows by other `serverkraken/*` repositories. One dispatch can target one repo or many. For each target the workflow opens two pull requests:

- **PR A — "add new workflows"**: drops in `ci.yml`, `release.yml`, `prerelease.yml`, `cleanup.yml` (rendered from `docs/adopter-templates/`), plus `release-please-config.json` + `.release-please-manifest.json` seeded from the target's current language and version.
- **PR B — "remove legacy workflows"**: deletes a curated retirement list of hand-rolled CI files. Only opened if the target actually contains any of those files.

The split gives the adopter a staging-friendly path: merge PR A → verify one or two releases run cleanly → merge PR B to retire the old flow.

This replaces today's manual onboarding (copy templates, hand-edit version, hand-craft release-please config, hand-open PRs).

---

## 2. Scope

### In scope

1. Single workflow file `.github/workflows/onboard.yml` (workflow_dispatch).
2. Two composite actions: `actions/onboard-detect/` (language + version) and `actions/onboard-render/` (template rendering).
3. Two bats-tested shell scripts: `scripts/onboard-detect.sh`, `scripts/onboard-render.sh`.
4. Two new templates: `docs/adopter-templates/release-please-config.json.tmpl`, `docs/adopter-templates/release-please-manifest.json.tmpl`.
5. Status tracking doc: `docs/onboarding-status.md`, auto-updated by the workflow.
6. Self-CI: dry-run-only integration test in `validate.yml` or `integration.yml`; bats coverage for the two scripts.
7. Operations docs update (`docs/operations.md` §5 new): note that no additional App setup is required.

### Out of scope (future)

- **Auto-detection of non-default Dockerfile paths**: templates pin `./Dockerfile`; adopters edit the generated PR if their path differs. Defer to V2.
- **PR-comment-driven retries** (`/onboard rerun` etc.).
- **Slack/Discord notifications.**
- **Rollback / un-onboard workflow**: an adopter can `git revert` PR A.
- **Auto-discovery of `serverkraken/*` repos**: status doc is seeded once via a one-shot script; no continuous discovery (would require `read:org` on the bot).
- **Onboarding of language-specific lint/test atoms**: those atoms don't exist in the catalog yet (separate future spec).

---

## 3. Architecture Overview

```
.github/workflows/
  onboard.yml                       # NEW — workflow_dispatch, matrix per target

actions/
  onboard-detect/action.yml         # NEW — language + version detection
  onboard-render/action.yml         # NEW — render adopter templates → workspace

scripts/                            # NEW — bats-testable shell
  onboard-detect.sh
  onboard-render.sh

docs/adopter-templates/             # EXTENDED
  ci.yml                            # existing
  release.yml                       # existing
  prerelease.yml                    # existing
  cleanup.yml                       # existing
  release-please-config.json.tmpl   # NEW
  release-please-manifest.json.tmpl # NEW

docs/onboarding-status.md           # NEW — status table maintained by the workflow

tests/
  shell/onboard-detect.bats         # NEW
  shell/onboard-render.bats         # NEW
  fixtures/onboard/                 # NEW
    go-repo/        (go.mod)
    python-poetry/  (pyproject.toml)
    rust-cargo/     (Cargo.toml)
    helm-chart/     (Chart.yaml)
    node-package/   (package.json)
    simple/         (no language signals)
    ambiguous/      (multiple signals → expected: error)
```

### Workflow topology

```
parse-inputs (ubuntu-latest)
  └─ outputs.matrix = JSON array of {repo, owner, name}

onboard (matrix: target ∈ matrix, fail-fast: false)
  ├─ mint App token scoped to target repo
  ├─ actions/checkout (target repo) into ./target
  ├─ actions/checkout (catalog @workflow_sha) into ./.catalog   # catalog-checkout pattern
  ├─ ./.catalog/actions/onboard-detect   → outputs: language, current_version, default_branch
  ├─ ./.catalog/actions/onboard-render   → writes 6 files into ./target
  ├─ Branch A: chore/onboard-reusable-workflows
  │   ├─ reset to default branch HEAD, stage rendered files, commit
  │   ├─ git diff empty? → close existing PR (if any) and skip
  │   └─ force-push, gh pr create (or gh pr edit if open)
  ├─ Branch B: chore/remove-legacy-workflows
  │   ├─ reset to default branch HEAD, git rm legacy files that exist, commit
  │   ├─ no files matched? → close existing PR (if any) and skip
  │   └─ force-push, gh pr create (or gh pr edit if open)
  │       — body references PR A as a soft "merge after" gate
  └─ emit per-target outputs: status, language, version, pr_add_url, pr_cleanup_url

finalize (ubuntu-latest, if: always())
  ├─ aggregate matrix outputs → GitHub step-summary table
  └─ update docs/onboarding-status.md → direct commit on main
       (commits via the catalog's release bot App, signed with workflow identity)
```

---

## 4. Workflow contract (`onboard.yml`)

```yaml
on:
  workflow_dispatch:
    inputs:
      target_repos:
        description: 'Comma-separated owner/repo list (e.g. serverkraken/blupod-ui,serverkraken/flow)'
        required: true
        type: string
      language:
        description: 'Override auto-detection (auto runs detection)'
        required: false
        type: choice
        default: auto
        options: [auto, go, python, rust, helm, node, simple]
      dry_run:
        description: 'Render files + log diff; do NOT push or open PRs'
        required: false
        type: boolean
        default: false
      pin_version:
        description: 'Catalog @version that rendered templates pin to'
        required: false
        type: string
        default: v1
      add_branch_name:
        description: 'Override branch name for PR A (escape hatch)'
        required: false
        type: string
        default: chore/onboard-reusable-workflows
      cleanup_branch_name:
        description: 'Override branch name for PR B (escape hatch)'
        required: false
        type: string
        default: chore/remove-legacy-workflows
```

No `secrets:` block — the workflow consumes the catalog's existing org-level secrets (`RELEASE_PLEASE_APP_ID`, `RELEASE_PLEASE_APP_PRIVATE_KEY`) directly.

### 4.1 Input validation (in `parse-inputs` job)

- Each entry in `target_repos` must match the regex `^serverkraken/[A-Za-z0-9._-]+$`. Mismatched entries fail the job with an explicit error before any matrix slot starts. This prevents typos from accidentally targeting external repos and guards against the App-installation-scope edge case.
- Empty `target_repos` (after trimming) fails with `::error::target_repos is empty`.
- Duplicate entries are deduplicated silently.

---

## 5. Language & version detection (`actions/onboard-detect`)

The composite action sources `scripts/onboard-detect.sh` and runs it against the target checkout.

### 5.1 Language signals

| File present | Detected language | release-please `release-type` |
|---|---|---|
| `go.mod` | go | `go` |
| `pyproject.toml` | python | `python` |
| `Cargo.toml` | rust | `rust` |
| `Chart.yaml` | helm | `helm` |
| `package.json` | node | `node` |
| (none) | simple | `simple` |

**Rules:**
- Files are checked at the **repo root only**, not recursively. Mono-repos with mixed languages are out of scope for V1.
- **Ambiguity** (multiple signals match): script exits 1 with `::error::ambiguous language signals: <list>; rerun with explicit language input`.
- **Override**: if `inputs.language != auto`, detection is skipped entirely.

### 5.2 Version detection

```bash
current_version=$(gh release list --repo "$TARGET" --limit 1 --json tagName -q '.[0].tagName' \
  | sed 's/^v//' \
  || echo "")
[[ -z "$current_version" ]] && current_version="0.0.0"
```

- Strips leading `v` from the latest GitHub Release tag (not git tag — only released versions count).
- Empty → seed manifest with `0.0.0` (release-please's "first release" baseline).
- Prereleases (`vX.Y.Z-rc.N`) are still used as-is; release-please handles them.

### 5.3 Default branch detection

```bash
default_branch=$(gh api "/repos/$TARGET" -q '.default_branch')
```

Used for branch reset and PR base.

### 5.4 Outputs (composite action)

| Output | Example |
|---|---|
| `language` | `go` |
| `release_type` | `go` |
| `current_version` | `2.4.0` |
| `default_branch` | `main` |

---

## 6. Template rendering (`actions/onboard-render`)

The composite action sources `scripts/onboard-render.sh`. It writes six files into the target checkout.

### 6.1 File mapping

| Source template | Output path in target | Substitution |
|---|---|---|
| `docs/adopter-templates/ci.yml` | `.github/workflows/ci.yml` | `@v1` → `@{pin_version}` |
| `docs/adopter-templates/release.yml` | `.github/workflows/release.yml` | `@v1` → `@{pin_version}` |
| `docs/adopter-templates/prerelease.yml` | `.github/workflows/prerelease.yml` | `@v1` → `@{pin_version}` |
| `docs/adopter-templates/cleanup.yml` | `.github/workflows/cleanup.yml` | `@v1` → `@{pin_version}` |
| `docs/adopter-templates/release-please-config.json.tmpl` | `release-please-config.json` | `{{RELEASE_TYPE}}` → detected `release_type` |
| `docs/adopter-templates/release-please-manifest.json.tmpl` | `.release-please-manifest.json` | `{{VERSION}}` → detected `current_version` |

### 6.2 Substitution mechanics

- All substitutions use `sed -i "s|<token>|<value>|g"`.
- **Why not `envsubst`**: adopter YAML templates contain literal `${{ … }}` GitHub-Actions expressions; envsubst would mangle them.
- **Why double-brace tokens** in the `.tmpl` files (`{{RELEASE_TYPE}}`, `{{VERSION}}`): they don't collide with any other syntax used in release-please JSON, and they're conventional Mustache-style placeholders.

### 6.3 New template contents

**`release-please-config.json.tmpl`** (extends the existing fixture at `tests/fixtures/minimal-release-please/release-please-config.json` with the catalog's standard changelog sections):

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "packages": {
    ".": {
      "release-type": "{{RELEASE_TYPE}}",
      "include-component-in-tag": false,
      "bump-minor-pre-major": true,
      "draft": false,
      "prerelease": false,
      "changelog-sections": [
        { "type": "feat", "section": "Features" },
        { "type": "fix", "section": "Bug Fixes" },
        { "type": "perf", "section": "Performance" },
        { "type": "refactor", "section": "Refactors" },
        { "type": "docs", "section": "Documentation", "hidden": false },
        { "type": "test", "section": "Tests", "hidden": true },
        { "type": "ci", "section": "CI", "hidden": true },
        { "type": "chore", "section": "Chores", "hidden": true }
      ]
    }
  }
}
```

**`release-please-manifest.json.tmpl`**:

```json
{
  ".": "{{VERSION}}"
}
```

---

## 7. Curated legacy retirement list

The cleanup branch (PR B) deletes only these filenames under `.github/workflows/` of the target, **if and only if they exist**:

```
semantic-release.yml
docker-build.yml
trivy.yml
trivy.yaml
build.yml
publish.yml
```

- Hardcoded list. Adding/removing entries is a code change to `scripts/onboard-render.sh` (or a sibling cleanup script) and a major or minor catalog bump depending on direction.
- **All other workflows** in the target's `.github/workflows/` are left strictly alone.
- The four new templates (`ci.yml` / `release.yml` / `prerelease.yml` / `cleanup.yml`) are written by PR A and would overwrite any existing same-named files in PR A — there is no need to delete them in PR B.

---

## 8. PR semantics & idempotency

### 8.1 Branch ownership

Both branches are bot-owned: a force-reset to `default_branch` HEAD is applied at every run, then changes are staged and force-pushed. Adopters must not commit to these branches — they're regenerated each dispatch.

### 8.2 PR A — add new workflows

| Step | Behavior |
|---|---|
| Detect existing PR | `gh pr list --repo $target --head $add_branch --state open --json number,url` |
| Empty diff (after render + stage) | If a PR is open → close it with comment "no changes needed". Skip. |
| Diff present, PR doesn't exist | `gh pr create` with title `chore: onboard serverkraken/reusable-workflows@{pin_version}`. |
| Diff present, PR exists | Force-push to the same branch (refreshes the PR) + `gh pr edit` to refresh body. Title preserved. |

PR A body template:

```markdown
## Onboard to serverkraken/reusable-workflows@{pin_version}

This PR drops in the standard reusable-workflow consumer files:

- `.github/workflows/ci.yml`        — PR-time fs scan
- `.github/workflows/release.yml`   — main → release (orchestrator)
- `.github/workflows/prerelease.yml`— manual dispatch image builds
- `.github/workflows/cleanup.yml`   — weekly GHCR retention
- `release-please-config.json`      — release-please config (release-type: `{release_type}`)
- `.release-please-manifest.json`   — seeded at current version `{current_version}`

**Detected language:** `{language}`
**Detected current version:** `{current_version}` (from latest GitHub release)
**Catalog version pinned:** `{pin_version}`

After merging:
1. Push a `feat:` / `fix:` commit to `{default_branch}` — `release.yml` should open a release-please PR.
2. Merge that release-please PR. A release + image build + Trivy scan should run end-to-end.
3. Once one full release has run green, merge the companion cleanup PR (if open) to retire legacy workflow files.

_Opened by the `onboard.yml` workflow in `serverkraken/reusable-workflows`._
```

### 8.3 PR B — remove legacy workflows

| Step | Behavior |
|---|---|
| Scan for matches | For each name in the retirement list, check if `.github/workflows/<name>` exists in the target. |
| No matches | If a PR is open → close it with comment "no legacy files to remove". Skip. |
| Matches present, PR doesn't exist | `gh rm` each match on the cleanup branch, commit, `gh pr create` titled `chore: remove legacy workflows superseded by reusable-workflows@{pin_version}`. |
| Matches present, PR exists | Force-push refreshed branch + `gh pr edit` body. |

PR B body template:

```markdown
## Retire legacy workflows

This PR removes the following files, which are now covered by reusable workflows from `serverkraken/reusable-workflows@{pin_version}`:

- {list of matched files, one per line}

**Soft dependency:** companion PR #{pr_a_number} ("onboard reusable-workflows") should be merged and have run at least one successful release before merging this PR. Otherwise this repo loses its release flow until the new one is exercised.

_Opened by the `onboard.yml` workflow in `serverkraken/reusable-workflows`._
```

### 8.4 Idempotency matrix

| State on re-run | PR A behavior | PR B behavior |
|---|---|---|
| Both PRs already merged, no legacy left | No diff → skip. | No matches → skip. |
| PR A merged, PR B still open | Templates already in main; no diff → skip. | Refresh PR B. |
| PR A open, PR B open | Refresh both. | Refresh both. |
| Adopter merged PR A and re-customized files | Templates re-rendered against default HEAD; diff vs adopter's customizations → a **new** PR A opened with the delta. **This surfaces template drift; adopter review decides whether to take the drift or close the PR.** | (unchanged) |
| All merged, but adopter manually re-added a legacy file | (unchanged) | New match → re-open PR B. |

Force-reset to default branch HEAD before applying changes is what makes the re-customization case behave correctly: the bot never preserves stale state on its branches.

---

## 9. Auth & permissions

### 9.1 App reuse

The existing `serverkraken-release-bot` GitHub App is reused unchanged. Per `docs/operations.md` §1.2, it is already installed org-wide with the permissions this workflow needs:

- `contents: write` — push branches, delete files
- `pull-requests: write` — open/edit/close PRs
- `issues: write` — write PR-thread comments
- `metadata: read` — `gh api /repos/...`

No new App, no new permissions, no per-repo opt-in required.

### 9.2 Per-target token minting

Each matrix slot mints a token scoped to **only** the target repo:

```yaml
- uses: actions/create-github-app-token@v2
  id: target-token
  with:
    app-id: ${{ secrets.RELEASE_PLEASE_APP_ID }}
    private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
    owner: ${{ matrix.target_owner }}
    repositories: ${{ matrix.target_name }}
```

This narrows blast radius: a bug in the workflow can only affect the target it currently has a token for, not the entire org.

### 9.3 Catalog-repo token (for status-doc commit)

The `finalize` job mints a separate token scoped to **only** `serverkraken/reusable-workflows`, used to commit the updated `docs/onboarding-status.md` directly to `main`. Direct commit (no PR) is acceptable because the status doc is bot-curated metadata, not human-authored content.

**Branch-protection prerequisite**: the catalog's `main` branch protection must include the `serverkraken-release-bot[bot]` actor in its bypass list (release-please already requires this — no new operational step). Documented in `docs/operations.md` §5 (new).

---

## 10. Error handling & exit semantics

- Matrix uses `fail-fast: false` so one target's failure doesn't abort the rest.
- A failing slot exits with a non-zero status and records `status=error` + `error_msg=<first error line>` in its job outputs.
- `finalize` runs with `if: always()` and writes the aggregate table regardless of slot status.
- Overall workflow conclusion: red if any slot is red (GitHub default).
- `dry_run=true` writes **nothing**: not to target repos, not to the status doc, not to any branch. It logs the rendered diff to the job log only.

### 10.1 Categorized failure modes

| Failure | Slot exit | Surfaced where |
|---|---|---|
| Token mint failed (App not installed on target) | 1 | `error_msg="App not installed on $target"` |
| Detect: ambiguous signals | 1 | `error_msg="ambiguous language: <list>"` |
| Detect: `gh api /repos/$target` returned 404 | 1 | `error_msg="repo not accessible: $target"` |
| Render: missing template file in catalog | 1 | `error_msg="template missing: <path>"` — workflow bug, fix in catalog |
| Push rejected (default branch protection blocking the bot) | 1 | `error_msg="push rejected to $branch"` |
| `gh pr create` failed | 1 | `error_msg=<gh stderr>` |

---

## 11. Runner

All jobs use `ubuntu-latest`. Onboarding is pure metadata / API work — no Docker build, no Trivy scan, no language toolchain. Consistent with `validate.yml` and `integration.yml`, and avoids any dependency on the self-hosted pool's health.

---

## 12. Testing strategy

### 12.1 bats unit tests

`tests/shell/onboard-detect.bats`:
- One test per language fixture: feed the fixture path, assert exit 0 + correct `language` output.
- Ambiguous-signals fixture: assert exit 1 + error message format.
- Override path: assert that explicit-language input bypasses detection.

`tests/shell/onboard-render.bats`:
- For each language, render against an empty workspace and assert:
  - All 6 files exist at the expected paths.
  - `release-please-config.json` contains `"release-type": "<expected>"`.
  - `.release-please-manifest.json` contains the seeded version.
  - The four YAML files contain `@<pin_version>` not `@v1` (if pin_version != v1).

### 12.2 Static validation

`validate.yml` already runs actionlint + yamllint against `.github/`, `actions/`, `tests/`. The new files inherit this for free.

### 12.3 Self-CI integration test

Add to `integration.yml`:

```yaml
test-onboard-dry-run:
  uses: ./.github/workflows/onboard.yml
  with:
    target_repos: serverkraken/reusable-workflows   # self-target for hermetic CI
    language: auto
    dry_run: true
```

The dry-run path exercises parse → detect → render → diff-log without ever pushing or opening a PR. This is the maximum self-CI coverage achievable without depending on a live external repo.

### 12.4 Acceptance (manual, one-time per release)

After spec → plan → implementation:

1. **First live run**: dispatch against a single low-risk repo (recommendation: create a throwaway `serverkraken/onboard-pilot` or pick `serverkraken/homelab-study` — small surface). Verify PR A renders correctly; merge it; verify a release runs end-to-end; merge PR B.
2. **Bulk run**: once the pilot is green, dispatch against the 6-repo hand-rolled-bash cohort. Watch the step-summary table and the status doc.

The acceptance procedure is documented in `CONTRIBUTING.md` once the workflow ships.

---

## 13. Status doc (`docs/onboarding-status.md`)

### 13.1 Format

```markdown
# Onboarding Status

_Last updated by the onboarding workflow: 2026-05-17T14:32:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/blupod-ui | 2026-05-17 | v1.1.1 | [#42](https://github.com/serverkraken/blupod-ui/pull/42) | [#43](https://github.com/serverkraken/blupod-ui/pull/43) | add-merged, cleanup-open |
| serverkraken/flow | — | — | — | — | not onboarded |
```

### 13.2 Status values

| Value | Meaning |
|---|---|
| `not onboarded` | Seeded row, workflow never ran against this repo |
| `add-open` | PR A open |
| `add-merged` | PR A merged, PR B not applicable or not yet merged |
| `cleanup-open` | PR B open (regardless of PR A state) |
| `complete` | Both PRs merged (or PR A merged + no legacy files to remove) |
| `no-legacy` | PR A merged + no legacy files found in target (terminal happy state) |
| `error` | Last run errored; see workflow run logs |

### 13.3 Update mechanics

- The `finalize` job rewrites only the rows for repos touched in the current run, by repo name as the primary key.
- New repos that were dispatched against and didn't already have a row get appended.
- Existing rows for non-targeted repos remain untouched.

**Staleness**: the doc captures state at the time of the last run. If a PR is merged between runs, the doc shows the pre-merge status until the next dispatch. Acceptable trade-off — the GitHub PR list is the live source of truth. The doc's value is "which repos have ever been touched + where is the PR".

### 13.4 Initial seeding

A one-shot script `scripts/seed-onboarding-status.sh` lists all `serverkraken/*` repos via `gh repo list serverkraken --limit 200 --json nameWithOwner` and writes a baseline `docs/onboarding-status.md` with all rows in `not onboarded` state. This is run **once, manually**, before the first onboarding dispatch. Re-seeding overwrites all `not onboarded` rows but leaves onboarded rows intact (script merges, doesn't truncate).

---

## 14. Decisions log

| ID | Decision | Rationale |
|---|---|---|
| OB-1 | Two-PR split (add + cleanup) instead of one combined PR | Staging-friendly: adopter merges add, verifies releases work, then merges cleanup. Minimizes risk of breaking the release flow during onboarding. |
| OB-2 | Composite actions + bats-tested shell scripts (Approach C) | Matches the existing pattern in this catalog (`install-trivy`, `compute-prerelease-tag`); keeps the workflow file thin and the logic testable. |
| OB-3 | `ubuntu-latest` for all jobs | Pure metadata work; no need for self-hosted pool dependency. Consistent with `validate.yml` / `integration.yml`. |
| OB-4 | Matrix with `fail-fast: false` | One target's failure must not block other targets in a bulk run. |
| OB-5 | Fixed bot-owned branch names + force-push | Branches are bot territory; force-reset to default HEAD each run is what makes the workflow idempotent. |
| OB-6 | Hardcoded curated legacy retirement list | Predictable, auditable. Org-specific glob expansion would be a footgun. |
| OB-7 | `dry_run` as a first-class input | Lets adopters and operators preview without risk. Essential for bulk runs. |
| OB-8 | Status doc committed directly to `main` (no PR) | Bot-curated metadata; PR overhead would be noise. Tokens are App-minted so the commit identity is the bot. |
| OB-9 | Repo-root-only language detection | Mono-repo handling is out of scope for V1; the org has no nested-language repos today that block this. |
| OB-10 | Reuse the existing `serverkraken-release-bot` App unchanged | App permissions and scope already cover all requirements. No new operational setup. |

---

## 15. Public surface (versioning impact)

`onboard.yml` is **not** a reusable workflow (no `workflow_call`). It is a dispatch-only operational tool for the catalog repo. **Its input contract is not subject to semver guarantees for adopters** — changes are noted in this catalog's CHANGELOG but don't bump the catalog's major version on their own.

The two new composite actions (`actions/onboard-detect/`, `actions/onboard-render/`) are **internal** to `onboard.yml`. They are not intended for external consumption and are flagged as such in `docs/contracts.md` (added under a separate "Internal Composite Actions" subsection rather than the public contracts table). Changes to their input/output shape do not bump the catalog's major version on their own.
