# Phase 3 — Documentation Drift Cleanup (Design Spec)

**Datum:** 2026-05-22
**Quelle:** `REVIEW-2026-05-22.md` § H (Documentation-Drift), § J (Loose Ends — selective)
**Scope:** Single PR, 5 commits — bring `docs/contracts.md`, `README.md`, `docs/onboarding-status.md`, `docs/superpowers/backlog.md`, and `actions/setup-python-deps/action.yml` into sync with the current code state.
**Konsumiert von:** Implementation Plan (writing-plans next)
**Vorgänger:** Phase 2a (Release 3.10.2), Phase 2b (Release 3.11.0 pending), Phase 2c (gemerged)

---

## 1. Goal

Eliminate the active documentation drift items from the catalog review. After Phase 3, every public-facing doc is consistent with the code as of the current main branch:

- `docs/contracts.md` documents all 16 atoms + 9 composite actions, not the 7 atoms + 7 actions it knows today
- `README.md` advertises the correct coverage threshold, points at the right contracts file, and lists all composite actions
- `docs/onboarding-status.md` no longer carries a stale "table intentionally empty" disclaimer that contradicts the actual data rows
- `docs/superpowers/backlog.md` reflects that the lint/test atoms feature is shipped
- `actions/setup-python-deps/action.yml` header comment accurately describes the probe order

## 2. Scope

### In Scope

| Concern | Findings | Outcome |
|---|---|---|
| **A. Missing atom contracts** | HIGH-9 | 10 new `### <name>.yml` sections in `docs/contracts.md` covering lint-go, test-go, lint-python, test-python, lint-rust, test-rust, lint-helm, goreleaser, docker-build-multi, helm-publish — each a complete Inputs/Outputs/Secrets table. |
| **B. Stale existing atom contracts** | (post-Phase 2a/2b) | Update `release.yml` table to add `image_name`, `runs_on_amd64`, `runs_on_arm64`, `runs_on_merge` (added in PR #91). Update `semantic-release.yml` table to add `dry_run` (added in PR #96). |
| **C. Internal action contracts** | MED-18, MED-19, LOW-11 | `onboard-detect`: + `profile_json` output. `onboard-render`: rewrite — remove `release_type`/`current_version` (gone in smarter-onboarding refactor), add `profile_json`. New `onboard-drift` section under Internal Composite Actions. |
| **D. README corrections** | MED-16, MED-17, LOW-10 | Coverage threshold `90` → `80`. Contracts link → `docs/contracts.md`. Composite-actions table: add `setup-python-deps` row. |
| **E. Misc** | LOW-7, MED-22, LOW-12 | `setup-python-deps/action.yml` header probe-order comment fixed. `onboarding-status.md` line 10 stale prose removed. `backlog.md` "Lint und Test Atoms" entry removed (feature is shipped). |

### Out of Scope (per spec convention)

- **DOC-9** (per-repo-override-vars Plan stale) — historical plans/specs are frozen documentation; Phase 2c established the same convention. Skip.
- **catalog-release.yml**, **drift-check.yml**, **validate.yml**, **integration.yml**, **onboard.yml** — none are `workflow_call`, so no public contract belongs in `docs/contracts.md`. `onboard.yml` operational behavior is documented in `docs/operations.md` § 5.

## 3. Background

### 3.1 contracts.md drift surfaces

Current `docs/contracts.md` (172 lines) covers:
- 5 atoms: `semantic-release`, `docker-build`, `trivy-image`, `trivy-fs`, `cleanup-images`
- 1 orchestrator: `release.yml`
- 4 public composite actions: `install-trivy`, `ghcr-login`, `compute-prerelease-tag`, `post-prerelease-comment`
- 2 internal composite actions: `onboard-detect`, `onboard-render`

Missing from contracts.md (16 atoms total exist in `.github/workflows/`, 10 absent):
- `lint-go`, `lint-python`, `lint-rust`, `lint-helm`
- `test-go`, `test-python`, `test-rust`
- `goreleaser`, `helm-publish`
- `docker-build-multi`

Missing internal composite action:
- `onboard-drift` (added in smarter-onboarding 2026-05-17)

Stale tables:
- `release.yml` — pre-Phase-2a, missing `image_name` + 3 `runs_on_*` inputs
- `semantic-release.yml` — pre-Phase-2b, missing `dry_run` input
- `onboard-render` — pre-smarter-onboarding, lists removed `release_type`/`current_version` inputs

### 3.2 README drift

`README.md` Quick Start was already rewritten in Phase 2c. Remaining drift items are in the "What it does" sections after Quick Start:

- Line ~63: contracts link points at `docs/superpowers/specs/2026-05-16-reusable-workflows-design.md` (internal planning doc) instead of `docs/contracts.md`
- Line ~87–89: claims test atoms default to ≥ 90% coverage; actual atom defaults are 80
- Line ~96–103 composite-actions table lists 4 actions; `setup-python-deps` (used by lint-python + test-python) is missing

### 3.3 Misc drift surfaces

- `actions/setup-python-deps/action.yml` line 8–9 header says "Probe order: poetry.lock > uv.lock > pyproject.toml[…dev] > requirements.txt". The actual code at lines 50–66 probes pyproject.toml content (`[tool.poetry]`) FIRST, then lockfile, then `[tool.uv]` content, etc. This is documented in the memory bank entry `troubleshooting_python_pm_detection.md` — the implementation is correct, the header comment is stale.
- `docs/onboarding-status.md` line 10 prose `(The table is intentionally empty here. Run the seed script locally — described in docs/operations.md §5 — to populate the rows.)` was written when the table had no data. Lines 11–14 now contain 4 real rows (blupod-ui, flow, skytrack-ui, skytrack). The prose is stale and breaks the Markdown table rendering on most viewers.
- `docs/superpowers/backlog.md` lines 5–14 describe "Lint und Test Atoms" as a deferred backlog item. The atoms shipped in the 2026-05-19 plan and are referenced from contracts.md (after Phase 3) and the README. The entry no longer belongs in "Spec-Kandidaten, die aus laufenden Brainstorms bewusst ausgeklammert wurden".

## 4. Design

### 4.1 Concern A — 10 new atom contracts in `docs/contracts.md`

Each new contract section follows the existing pattern (e.g., `semantic-release.yml` lines 11–23): `### <name>.yml` header, then a single Markdown table with columns `Kind | Name | Type | Required | Default | Description`. Sections separated by `---` horizontal rules.

**Insertion order:** alphabetical under `## Atomic Workflows`, replacing the current order. Final order:
1. `cleanup-images.yml` (existing)
2. `docker-build.yml` (existing)
3. `docker-build-multi.yml` (NEW)
4. `goreleaser.yml` (NEW)
5. `helm-publish.yml` (NEW)
6. `lint-go.yml` (NEW)
7. `lint-helm.yml` (NEW)
8. `lint-python.yml` (NEW)
9. `lint-rust.yml` (NEW)
10. `semantic-release.yml` (existing)
11. `test-go.yml` (NEW)
12. `test-python.yml` (NEW)
13. `test-rust.yml` (NEW)
14. `trivy-fs.yml` (existing)
15. `trivy-image.yml` (existing)

Per-atom content is derived mechanically from each workflow file's `inputs:`/`outputs:`/`secrets:` blocks. The implementer reads each `.github/workflows/<name>.yml` and produces a table row per declared input/output/secret. No editorial decisions — straight transcription with the existing column format.

### 4.2 Concern B — sync existing atom contracts with Phase 2a/2b additions

#### B.1 `release.yml` (currently lines 102–113)

Add 4 new rows (matching `with:` keys added by PR #91 in `release.yml`):

```markdown
| input   | `image_name`     | string  | no       | `''`                                            | Pass-through to docker-build (default: caller repo) |
| input   | `runs_on_amd64`  | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | Pass-through to docker-build (amd64 build job) |
| input   | `runs_on_arm64`  | string  | no       | `'["self-hosted","Linux","ARM64"]'`             | Pass-through to docker-build (arm64 build job) |
| input   | `runs_on_merge`  | string  | no       | `'["self-hosted","Linux","low-performance"]'`   | Pass-through to docker-build (version + merge jobs) |
```

Inserted after `trivy_severity` and before the `secrets:` block (matching the file's input order).

#### B.2 `semantic-release.yml` (currently lines 11–23)

Add 1 new row (matching PR #96):

```markdown
| input   | `dry_run`                       | boolean | no       | `false`                                   | When true, run release-please without creating PRs/releases or moving floating tags |
```

Inserted after `release_please_manifest` and before the `secrets:` block.

### 4.3 Concern C — onboard-* internal action contracts

#### C.1 `onboard-detect` (currently lines 151–162)

Add the missing `profile_json` output:

```markdown
| output | `profile_json` | string | — | — | Full structured detection profile (JSON-encoded) |
```

Inserted after the existing `default_branch` output row.

#### C.2 `onboard-render` (currently lines 164–172)

Replace the entire table — current schema is wrong (lists removed `release_type` + `current_version` inputs). New table matches `actions/onboard-render/action.yml` lines 7–20:

```markdown
| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `catalog_path` | string | yes | — | Path to checked-out catalog repo |
| input | `target_path` | string | yes | — | Path to checked-out target repo (rendered files written here) |
| input | `profile_json` | string | yes | — | Detection profile JSON from `onboard-detect` (forwarded as multi-line input) |
| input | `pin_version` | string | no | `'v3'` | Catalog `@version` to pin rendered templates to |
```

(Default `'v3'` reflects Phase 2a PR #92, where the default moved from v1 to v3.)

#### C.3 `onboard-drift` (NEW, inserted after `onboard-render`)

```markdown
### `actions/onboard-drift`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `target_path` | string | yes | — | Path to checked-out adopter repo (contains `.github/onboard.lock.json`) |
| input | `catalog_path` | string | yes | — | Path to checked-out catalog repo (read by helper scripts) |
| input | `catalog_current_version` | string | no | `''` | Current floating major (e.g. `v3`) — empty disables `behind` detection |
| output | `status` | string | — | — | One of `clean` / `modified` / `behind` / `behind+modified` / `no-lock` |
| output | `modified` | string | — | — | Comma-separated list of files with hash mismatch (empty when clean) |
| output | `lock_version` | string | — | — | `catalog_version` from the lock (absent on `no-lock`) |
| output | `current_version` | string | — | — | Value of `catalog_current_version` input (absent when input was empty) |
```

(Inputs derived from `actions/onboard-drift/action.yml` and `scripts/onboard-drift.sh`. Outputs from the script's stdout key=value contract documented in `scripts/onboard-drift.sh:15–19`.)

### 4.4 Concern D — README corrections

#### D.1 Coverage threshold (line ~87–89)

Find the existing text claiming `≥ 90%` and replace with `≥ 80%`. Exact replacement is implementer-localized (one-or-two-character change).

#### D.2 Contracts link (line ~63)

Find the link target `docs/superpowers/specs/2026-05-16-reusable-workflows-design.md` and change to `docs/contracts.md`. Link text remains "[design spec]" or similar — implementer adjusts wording to read naturally (e.g., "documented in [`docs/contracts.md`](docs/contracts.md) § per workflow").

#### D.3 Composite-actions table (line ~96–103)

Add a new row for `setup-python-deps`:

```markdown
| `setup-python-deps`        | Detects Python package manager (poetry/uv/pip-dev/pip-bare), sets up Python, installs deps |
```

Row positioning: alphabetical, after `post-prerelease-comment`.

### 4.5 Concern E — Misc

#### E.1 `setup-python-deps/action.yml` header (lines 8–9)

Replace the stale comment:

```yaml
# Probe order: poetry.lock > uv.lock > pyproject.toml[project.optional-dependencies.dev] > requirements.txt.
# Hard error if none of the above is present.
```

With the accurate content-first probe order (matching the actual detection code at lines 50–66):

```yaml
# Probe order (content first, lockfile as fallback):
#   [tool.poetry] in pyproject.toml  → poetry
#   uv.lock present  OR  [tool.uv] in pyproject.toml  → uv
#   [project.optional-dependencies].dev in pyproject.toml  → pip-dev
#   requirements.txt  → pip-bare
# Hard error if none of the above is present.
```

#### E.2 `onboarding-status.md` line 10

Remove the stale prose paragraph. The blank line that precedes it (line 9) also goes — the table data rows (lines 11–14) should sit directly after the table separator.

Before:
```
| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|

(The table is intentionally empty here. Run the seed script locally — described in `docs/operations.md` §5 — to populate the rows.)
| serverkraken/blupod-ui | ...
```

After:
```
| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/blupod-ui | ...
```

#### E.3 `backlog.md` lines 5–14

Remove the entire "Lint- und Test-Atoms (Sprach-spezifisch)" section (the `##` heading and its body). The feature shipped via the 2026-05-19 plan; entry no longer fits the backlog's "deferred future spec candidates" semantic.

After removal, the next backlog section (`## Repo-Hygiene-Bootstrapping`) becomes the first item.

## 5. Interface Contracts

This PR touches only documentation and one composite-action header comment. NO workflow inputs/outputs/secrets change. NO action behavior changes. Production callers see no behavioral difference.

Per file:

| File | Change-Class | Caller-Breaking? |
|---|---|---|
| `docs/contracts.md` | Additive + corrective (stale entries fixed to match shipped code) | NEIN |
| `README.md` | Corrective | NEIN |
| `docs/onboarding-status.md` | Cosmetic | NEIN |
| `docs/superpowers/backlog.md` | Cosmetic | NEIN |
| `actions/setup-python-deps/action.yml` | Header comment only — no executable change | NEIN |

Commit classes: all `docs:` → release-please default config treats these as non-versioning. No version bump from this PR.

## 6. Test Strategy

Static verification only — no test additions, no bats changes.

- `yamllint -s .github/workflows/` clean (no workflow files touched)
- `yamllint -s actions/setup-python-deps/action.yml` clean (only the header comment changed)
- `actionlint actions/setup-python-deps/action.yml` clean (comment-only edit, no schema change)
- Existing CI must remain green: `validate.yml`, `integration.yml` jobs all pass — no functional change should affect any of them.
- Self-check: `rg 'docs/superpowers/specs/2026-05-16-reusable-workflows-design.md' README.md` returns empty (stale link gone).
- Self-check: `rg '^### ' docs/contracts.md | wc -l` returns 23 (was 12 — 10 new atoms + 1 new internal action `onboard-drift`; existing sections updated in place, no new section count from C2/C3 modifications other than `onboard-drift`).
- Markdown rendering of `docs/contracts.md`, `README.md`, `docs/onboarding-status.md`, `docs/superpowers/backlog.md` must remain valid (visually inspect or use a Markdown linter if available — not blocking, just a self-check).

## 7. PR Plan

**Single PR — `docs/phase-3-drift-cleanup`**
- **Worktree:** `.worktrees/phase-3-doc-drift`
- **Branch:** `docs/phase-3-drift-cleanup` (from origin/main)
- **5 commits in this order** (C1→C2→C3→C4→C5):

| # | Commit message | Files touched |
|---|---|---|
| C1 | `docs(contracts): add 10 missing atom tables` | `docs/contracts.md` |
| C2 | `docs(contracts): sync release.yml + semantic-release.yml schemas with phase 2a/2b additions` | `docs/contracts.md` |
| C3 | `docs(contracts): fix onboard-* internal action contracts` | `docs/contracts.md` |
| C4 | `docs(readme): fix coverage threshold, contracts link, add setup-python-deps row` | `README.md` |
| C5 | `docs: misc cleanup (onboarding-status, backlog, setup-python-deps header)` | `docs/onboarding-status.md`, `docs/superpowers/backlog.md`, `actions/setup-python-deps/action.yml` |

PR-Body-Style: no Claude-attribution footer (Memory: `feedback_pr_style`).

Why sequential C1→C3 (not parallel): all three touch `docs/contracts.md`, conflict would arise from interleaving. Sequential edits keep the file history clean.

## 8. Acceptance Criteria

- [ ] PR merged: 10 new `### <name>.yml` sections present in `docs/contracts.md` for the missing atoms (alphabetically ordered).
- [ ] `release.yml` and `semantic-release.yml` tables in `docs/contracts.md` match the workflow files byte-for-byte on inputs/outputs/secrets.
- [ ] `onboard-detect`, `onboard-render`, `onboard-drift` tables match the corresponding `action.yml` files.
- [ ] README coverage threshold says `80`, contracts link points at `docs/contracts.md`, composite-actions table has 5 rows (incl. `setup-python-deps`).
- [ ] `setup-python-deps/action.yml` header probe-order matches the actual code at lines 50–66.
- [ ] `onboarding-status.md` table renders cleanly (no breaking prose between header and data rows).
- [ ] `backlog.md` no longer carries the "Lint und Test Atoms" entry.
- [ ] All CI green; no version bump (all `docs:` commits).
- [ ] `rg '^### ' docs/contracts.md | wc -l` returns 23.

## 9. Open Questions

Keine. Alle Entscheidungen aus Brainstorming fixiert:

1. ✓ Single PR (not split into contracts.md vs misc)
2. ✓ 5 commits with `docs:` prefixes (per-concern granularity)
3. ✓ Alphabetical ordering of atom contracts under `## Atomic Workflows`
4. ✓ Historical plans/specs are frozen documentation (DOC-9 out of scope per Phase 2c convention)
5. ✓ `setup-python-deps` row placement alphabetically under existing composite-actions table
