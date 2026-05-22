# Phase 3 Documentation Drift Cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all active documentation drift items from `REVIEW-2026-05-22.md` § H and selected § J items via a single PR with 5 docs commits.

**Architecture:** Single PR, single worktree. All 5 commits use `docs:` prefix (release-please default config treats `docs:` as non-versioning — no version bump). C1–C3 sequential edits to `docs/contracts.md`. C4 edits `README.md`. C5 edits 3 misc files. No tests, no workflow logic changes, no script behavior changes.

**Tech Stack:** Markdown only. One YAML header-comment edit in `actions/setup-python-deps/action.yml`.

**Spec:** `docs/superpowers/specs/2026-05-22-phase-3-design.md`

**Repo style:** Conventional Commits, no Claude-attribution footer.

---

## Pre-Flight (do once)

- [ ] **Step 1: Verify working tree state**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git status -sb
```

Expected: `## main...origin/main` possibly `[ahead N]` (local-only spec/plan commits — fine, worktree branches from `origin/main`). Untracked `foo`/`GEMINI.md`/`REVIEW-2026-05-22.md` may be present — leave them.

- [ ] **Step 2: Fetch upstream**

```bash
git fetch origin --quiet && git log HEAD..origin/main --oneline
```

Expected: empty output.

- [ ] **Step 3: Worktree availability**

```bash
git worktree list
```

Expected: 4 unrelated existing worktrees, none touch `docs/`, `README.md`, or `actions/setup-python-deps/`. No collision.

---

## Task 1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees`** to create `.worktrees/phase-3-doc-drift` with branch `docs/phase-3-drift-cleanup` from `origin/main`.

- [ ] **Step 2: Confirm**

```bash
cd .worktrees/phase-3-doc-drift
pwd && git branch --show-current
```

Expected: branch is `docs/phase-3-drift-cleanup`.

---

## Commit C1: Add 10 missing atom contracts in `docs/contracts.md`

**Files:**
- Modify: `docs/contracts.md`

For each of the 10 atoms below, read the workflow file and produce a contract section using the existing format. The section goes in alphabetical order under `## Atomic Workflows` (line 9 of contracts.md).

### Background: the existing format (worked example)

The existing `semantic-release.yml` contract (lines 11–23 of contracts.md):

```markdown
### `semantic-release.yml`

| Kind    | Name                            | Type    | Required | Default                                   | Description |
|---------|---------------------------------|---------|----------|-------------------------------------------|-------------|
| input   | `runs_on`                       | string  | no       | `'["self-hosted","Linux","low-performance"]'` | JSON-encoded runner labels |
| input   | `release_please_config`         | string  | no       | `'release-please-config.json'`            | Path to release-please config |
| input   | `release_please_manifest`       | string  | no       | `'.release-please-manifest.json'`         | Path to release-please manifest |
| secret  | `release_please_app_client_id`  | —       | yes      | —                                         | GitHub App Client ID (e.g. `Iv23li…`) |
| secret  | `release_please_app_private_key`| —       | yes      | —                                         | PEM-formatted App private key |
| output  | `release_created`               | string  | —        | —                                         | `'true'` when a release was created |
| output  | `tag_name`                      | string  | —        | —                                         | e.g. `'v1.2.3'` |
| output  | `major_tag`                     | string  | —        | —                                         | e.g. `'v1'` |
| output  | `minor_tag`                     | string  | —        | —                                         | e.g. `'v1.2'` |

---
```

Each new contract follows this exact template:
- `### \`<name>.yml\`` header
- Markdown table with columns `Kind | Name | Type | Required | Default | Description`
- Rows in order: all `input` rows (file order), all `output` rows, all `secret` rows
- For each input: take `description:` text as Description column; take `default:` as Default column wrapped in backticks; mark Required as `**yes**` if `required: true`, `no` if `required: false` or absent
- For `secret:` rows: required is `**yes**`; if a secret is shared with other atoms (e.g. `release_please_app_*`), use the existing description text from `docker-build.yml`'s rows in contracts.md
- Separate each new section with `---` on its own line, blank-line-padded

### Worked example: `lint-go.yml` (full transcription)

Reading `.github/workflows/lint-go.yml` produces:

```markdown
### `lint-go.yml`

| Kind  | Name                    | Type    | Required | Default                                | Description |
|-------|-------------------------|---------|----------|----------------------------------------|-------------|
| input | `runs_on`               | string  | no       | `'["self-hosted","Linux","X64"]'`      | JSON-encoded array of runner labels. |
| input | `working_directory`     | string  | no       | `'.'`                                  | Component sub-path. Atom resolves all paths relative to this. |
| input | `go_version`            | string  | no       | `''`                                   | Go toolchain version. Empty → read from `<working_directory>/go.mod`. |
| input | `golangci_lint_version` | string  | no       | `'v2.12.2'`                            | golangci-lint version (e.g. `v2.12.2`). Must be `v2.1.0+` to be compatible with golangci-lint-action@v9. |
| input | `cgo_enabled`           | boolean | no       | `false`                                | Set `CGO_ENABLED=1` (true) or `0` (false). Mirror the value used in `test-go.yml` for cgo-dependent packages. |

---
```

(No outputs, no secrets — the file has neither. Description column copies the workflow's own `description:` text verbatim, with light Markdown formatting for code spans.)

### Sub-steps C1.1–C1.10

The 10 atoms to add (in alphabetical order under `## Atomic Workflows`):

| # | Atom | Source file | Input count |
|---|------|---|---|
| C1.1 | `docker-build-multi.yml` | `.github/workflows/docker-build-multi.yml` | 13 |
| C1.2 | `goreleaser.yml` | `.github/workflows/goreleaser.yml` | 5 |
| C1.3 | `helm-publish.yml` | `.github/workflows/helm-publish.yml` | 5 |
| C1.4 | `lint-go.yml` | `.github/workflows/lint-go.yml` | 5 |
| C1.5 | `lint-helm.yml` | `.github/workflows/lint-helm.yml` | 5 |
| C1.6 | `lint-python.yml` | `.github/workflows/lint-python.yml` | 5 + 2 secrets |
| C1.7 | `lint-rust.yml` | `.github/workflows/lint-rust.yml` | 4 |
| C1.8 | `test-go.yml` | `.github/workflows/test-go.yml` | 5 |
| C1.9 | `test-python.yml` | `.github/workflows/test-python.yml` | 6 + 2 secrets |
| C1.10 | `test-rust.yml` | `.github/workflows/test-rust.yml` | 5 |

### Placement: re-order under `## Atomic Workflows`

The existing contracts.md has these sections under `## Atomic Workflows` in non-alphabetical order: `semantic-release`, `docker-build`, `trivy-image`, `trivy-fs`, `cleanup-images`. After C1, the full alphabetical order under `## Atomic Workflows` must be:

1. `cleanup-images.yml`
2. `docker-build.yml`
3. `docker-build-multi.yml` (NEW)
4. `goreleaser.yml` (NEW)
5. `helm-publish.yml` (NEW)
6. `lint-go.yml` (NEW)
7. `lint-helm.yml` (NEW)
8. `lint-python.yml` (NEW)
9. `lint-rust.yml` (NEW)
10. `semantic-release.yml`
11. `test-go.yml` (NEW)
12. `test-python.yml` (NEW)
13. `test-rust.yml` (NEW)
14. `trivy-fs.yml`
15. `trivy-image.yml`

To achieve this: reorder the 5 existing sections to alphabetical AND insert the 10 new sections in the correct alphabetical slot.

### Step procedure for C1

- [ ] **Step 1: Read each of the 10 workflow files in turn** (one batch, no individual commits per atom):

```bash
for f in docker-build-multi goreleaser helm-publish lint-go lint-helm lint-python lint-rust test-go test-python test-rust; do
  echo "=== $f.yml ==="
  cat .github/workflows/$f.yml
done | head -800
```

Use the file content to fill in the `description:`, `default:`, `required:` fields per row.

- [ ] **Step 2: For atoms with `secrets:` (lint-python, test-python)**

These use the same `release_please_app_client_id` and `release_please_app_private_key` secrets as `docker-build.yml`. Use the EXACT secret rows from the existing `docker-build.yml` table in contracts.md (lines 47–48):

```markdown
| secret  | `release_please_app_client_id`  | — | **yes** | — | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret  | `release_please_app_private_key`| — | **yes** | — | App private key for the catalog-checkout token (since v2.0.0) |
```

- [ ] **Step 3: Reorder existing sections + insert new ones**

Edit `docs/contracts.md` so that under `## Atomic Workflows` (line 9), the 15 `### <name>.yml` sections appear in the alphabetical order listed above. Each section is followed by `---` on a blank-padded line.

- [ ] **Step 4: Sanity-check the section count**

```bash
rg '^### ' docs/contracts.md | wc -l
```

Expected: at least **22** after C1 (was 12, plus 10 new atoms = 22). The other counts come from C3 (+1 for `onboard-drift`).

- [ ] **Step 5: Markdown rendering spot-check**

```bash
head -200 docs/contracts.md
```

Visually confirm: alphabetical order, tables render, `---` separators in place, no broken backticks or missing pipes.

- [ ] **Step 6: Commit C1**

```bash
git add docs/contracts.md
git commit -m "docs(contracts): add 10 missing atom tables"
```

---

## Commit C2: Sync `release.yml` + `semantic-release.yml` contracts with Phase 2a/2b additions

**Files:**
- Modify: `docs/contracts.md`

### C2.1 — `release.yml` table

Add 4 new input rows to the existing `release.yml` table (it lives under `## Orchestrator`, NOT under `## Atomic Workflows` — so its position is unchanged by C1's reordering).

Find the row:
```markdown
| input   | `trivy_severity`                | string  | no       | `'HIGH,CRITICAL'`            | Pass-through to trivy-image |
```

Insert these 4 rows IMMEDIATELY AFTER `trivy_severity` and BEFORE the `secrets:` rows:

```markdown
| input   | `image_name`                    | string  | no       | `''`                                            | Pass-through to docker-build (default: caller repo) |
| input   | `runs_on_amd64`                 | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | Pass-through to docker-build (amd64 build job) |
| input   | `runs_on_arm64`                 | string  | no       | `'["self-hosted","Linux","ARM64"]'`             | Pass-through to docker-build (arm64 build job) |
| input   | `runs_on_merge`                 | string  | no       | `'["self-hosted","Linux","low-performance"]'`   | Pass-through to docker-build (version + merge jobs) |
```

### C2.2 — `semantic-release.yml` table

Add the `dry_run` input row to the existing `semantic-release.yml` table.

Find the row:
```markdown
| input   | `release_please_manifest`       | string  | no       | `'.release-please-manifest.json'`         | Path to release-please manifest |
```

Insert this row IMMEDIATELY AFTER `release_please_manifest` and BEFORE the `secret:` rows:

```markdown
| input   | `dry_run`                       | boolean | no       | `false`                                   | When true, run release-please without creating PRs/releases or moving floating tags (integration-test use only) |
```

### Step procedure for C2

- [ ] **Step 1: Apply the C2.1 edit to the `release.yml` orchestrator table**

Use the Edit tool with the `trivy_severity` row as old_string anchor. The new_string is the `trivy_severity` row + 4 new rows (do NOT modify the `trivy_severity` row itself; just append after it).

- [ ] **Step 2: Apply the C2.2 edit to the `semantic-release.yml` atom table**

Use the Edit tool with the `release_please_manifest` row as old_string anchor. The new_string is the `release_please_manifest` row + 1 new `dry_run` row.

- [ ] **Step 3: Verify**

```bash
rg -n 'image_name|runs_on_amd64|runs_on_arm64|runs_on_merge|dry_run' docs/contracts.md
```

Expected: shows the 4 new rows in the `release.yml` table and the 1 new row in `semantic-release.yml`.

- [ ] **Step 4: Commit C2**

```bash
git add docs/contracts.md
git commit -m "docs(contracts): sync release.yml + semantic-release.yml schemas with phase 2a/2b additions"
```

---

## Commit C3: Fix `onboard-*` Internal Action contracts

**Files:**
- Modify: `docs/contracts.md`

### C3.1 — Add `profile_json` output to `onboard-detect`

In the `### actions/onboard-detect` table (around lines 151–162 of contracts.md before C1/C2; the line number shifts after C1 — search by content). Find the row:

```markdown
| output | `default_branch` | string | — | — | Default branch of `target_repo` |
```

Insert this row IMMEDIATELY AFTER `default_branch`:

```markdown
| output | `profile_json` | string | — | — | Full structured detection profile (JSON-encoded) |
```

### C3.2 — Rewrite `onboard-render` table

The current table at lines 164–172 (pre-C1) lists removed `release_type` + `current_version` inputs. Replace the ENTIRE `### actions/onboard-render` section with:

```markdown
### `actions/onboard-render`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `catalog_path` | string | yes | — | Path to checked-out catalog repo |
| input | `target_path` | string | yes | — | Path to checked-out target repo (rendered files written here) |
| input | `profile_json` | string | yes | — | Detection profile JSON from `onboard-detect` (forwarded as multi-line input) |
| input | `pin_version` | string | no | `'v3'` | Catalog `@version` to pin rendered templates to |
```

### C3.3 — Add new `onboard-drift` section

Insert IMMEDIATELY AFTER the rewritten `onboard-render` section (after C3.2's table), still under `## Internal Composite Actions`:

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

(Leading blank line for separation from `onboard-render`.)

### Step procedure for C3

- [ ] **Step 1: Read the actual action files to verify the input/output shapes are correct**

```bash
cat actions/onboard-detect/action.yml
cat actions/onboard-render/action.yml
cat actions/onboard-drift/action.yml
cat scripts/onboard-drift.sh | head -25   # output contract documented in script header
```

Confirm the table contents above match the actual files. If discrepancies exist, correct the table to match the actual file (file is source of truth).

- [ ] **Step 2: Apply C3.1 — add `profile_json` output to `onboard-detect`**

Use the Edit tool with the `default_branch` row as anchor.

- [ ] **Step 3: Apply C3.2 — rewrite `onboard-render` table**

Use the Edit tool. old_string = the entire current `### actions/onboard-render` section (header + table). new_string = the replacement above.

- [ ] **Step 4: Apply C3.3 — insert new `onboard-drift` section**

Use the Edit tool. old_string = the last line of the rewritten `onboard-render` table (the `pin_version` row), with a blank line after it. new_string = the same `pin_version` row + the new `onboard-drift` section.

- [ ] **Step 5: Verify the count**

```bash
rg '^### ' docs/contracts.md | wc -l
```

Expected: **23** (was 22 after C1; +1 from `onboard-drift`).

- [ ] **Step 6: Commit C3**

```bash
git add docs/contracts.md
git commit -m "docs(contracts): fix onboard-* internal action contracts"
```

---

## Commit C4: README corrections

**Files:**
- Modify: `README.md`

### C4.1 — Coverage threshold 90 → 80

Find these two rows in the README's "Atomic workflows (advanced)" table (around lines 115 and 117):

```markdown
| `test-go.yml`             | `go test` + coverage gate (default ≥ 90 %)         |
...
| `test-python.yml`         | pytest + coverage gate ≥ 90 % (poetry/uv/pip auto) |
```

Replace BOTH `90 %` with `80 %`:

```markdown
| `test-go.yml`             | `go test` + coverage gate (default ≥ 80 %)         |
...
| `test-python.yml`         | pytest + coverage gate ≥ 80 % (poetry/uv/pip auto) |
```

### C4.2 — Contracts link target

Find this block (around lines 89–91):

```markdown
## Workflow contracts

The complete input/output/secret schema of every reusable workflow is documented in the [design spec](docs/superpowers/specs/2026-05-16-reusable-workflows-design.md) §4.
```

Replace with:

```markdown
## Workflow contracts

The complete input/output/secret schema of every reusable workflow and composite action is documented in [`docs/contracts.md`](docs/contracts.md).
```

### C4.3 — Add `setup-python-deps` to composite-actions table

Find the table (around lines 126–131):

```markdown
| Action                                 | Purpose                                    |
|----------------------------------------|--------------------------------------------|
| `actions/install-trivy`                | Pinned Trivy CLI install (direct binary)   |
| `actions/ghcr-login`                   | GHCR login wrapper                         |
| `actions/compute-prerelease-tag`       | OCI-valid tag from branch + short SHA      |
| `actions/post-prerelease-comment`      | Idempotent PR comment with pull command    |
```

Insert a new row for `setup-python-deps`, alphabetically positioned after `post-prerelease-comment`:

```markdown
| Action                                 | Purpose                                    |
|----------------------------------------|--------------------------------------------|
| `actions/install-trivy`                | Pinned Trivy CLI install (direct binary)   |
| `actions/ghcr-login`                   | GHCR login wrapper                         |
| `actions/compute-prerelease-tag`       | OCI-valid tag from branch + short SHA      |
| `actions/post-prerelease-comment`      | Idempotent PR comment with pull command    |
| `actions/setup-python-deps`            | Detect Python package manager (poetry/uv/pip-dev/pip-bare) + install deps |
```

### Step procedure for C4

- [ ] **Step 1: Apply C4.1**

Two Edit operations — one for each `90 %` → `80 %` replacement. Be sure to use distinct surrounding context (e.g., `test-go.yml` vs `test-python.yml`) so each Edit's old_string is unique.

- [ ] **Step 2: Apply C4.2**

Edit the contracts-link block.

- [ ] **Step 3: Apply C4.3**

Edit the composite-actions table to insert the `setup-python-deps` row.

- [ ] **Step 4: Verify**

```bash
rg -n '90 %' README.md
rg -n 'docs/superpowers/specs/2026-05-16-reusable-workflows-design.md' README.md
rg -n 'setup-python-deps' README.md
```

Expected:
- First rg: empty (no more `90 %` references)
- Second rg: 1 hit only — the line in the Operations section that legitimately links to the design spec (line ~135). The Workflow contracts section (line ~91) must NO LONGER reference it.
- Third rg: 1+ hit showing the new composite-actions row.

- [ ] **Step 5: Commit C4**

```bash
git add README.md
git commit -m "docs(readme): fix coverage threshold, contracts link, add setup-python-deps row"
```

---

## Commit C5: Misc cleanup

**Files:**
- Modify: `actions/setup-python-deps/action.yml`
- Modify: `docs/onboarding-status.md`
- Modify: `docs/superpowers/backlog.md`

### C5.1 — `setup-python-deps` header comment

Find this block (lines 8–10 of `actions/setup-python-deps/action.yml`):

```yaml
# Probe order: poetry.lock > uv.lock > pyproject.toml[project.optional-dependencies.dev] > requirements.txt.
# Hard error if none of the above is present.
```

Replace with:

```yaml
# Probe order (content first, lockfile as fallback):
#   [tool.poetry] in pyproject.toml  → poetry
#   uv.lock present  OR  [tool.uv] in pyproject.toml  → uv
#   [project.optional-dependencies].dev in pyproject.toml  → pip-dev
#   requirements.txt  → pip-bare
# Hard error if none of the above is present.
```

### C5.2 — `onboarding-status.md` line 10 stale prose

Find this block (lines 7–11):

```markdown
| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|

(The table is intentionally empty here. Run the seed script locally — described in `docs/operations.md` §5 — to populate the rows.)
| serverkraken/blupod-ui | 2026-05-21 | v3 | [PR](https://github.com/serverkraken/blupod-ui/pull/27) | — | add-open, no-legacy |
```

Replace with:

```markdown
| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/blupod-ui | 2026-05-21 | v3 | [PR](https://github.com/serverkraken/blupod-ui/pull/27) | — | add-open, no-legacy |
```

(Removes the blank line + stale prose so the table data row sits immediately after the separator.)

### C5.3 — `backlog.md` "Lint und Test Atoms" entry removal

Find this block (lines 5–14 of `docs/superpowers/backlog.md`):

```markdown
## Lint- und Test-Atoms (Sprach-spezifisch)

Reusable workflows pro Sprache und Anliegen:
`lint-go.yml`, `lint-python.yml`, `lint-rust.yml`, `lint-helm.yml`,
`test-go.yml`, `test-python.yml`, `test-rust.yml`.

- **Warum ausgeklammert:** Mischt Template-Rendering mit Sprach-Toolchain-Wissen (golangci-lint, ruff, mypy, clippy, pytest, cargo-llvm-cov). Verdoppelt jeden Onboarding-Spec, dem es zugeschlagen wird.
- **Scope eines Folge-Specs:** ein Atom pro Sprache, jeweils mit Coverage-Threshold-Input (Default 90). Vorlagen: `serverkraken/blupod-ui` (Python), `serverkraken/flow` (Go). Adopter-Templates referenzieren die Atoms aus `ci.yml`.
- **Abhängigkeiten:** Keine. Kann parallel zur Smarter-Onboarding-Arbeit laufen.
- **Referenzen aus existierenden Specs:** `2026-05-16-reusable-workflows-design.md` § "Out of Scope (future specs)", `2026-05-16-onboarding-workflow-design.md` § "Out of scope (future)".

```

Delete the entire block (the heading `##` line through the trailing blank line). After deletion, the next section (`## Repo-Hygiene-Bootstrapping`) becomes the first backlog item, sitting directly after the intro paragraph at line 3.

### Step procedure for C5

- [ ] **Step 1: Apply C5.1** to `actions/setup-python-deps/action.yml`.

- [ ] **Step 2: Apply C5.2** to `docs/onboarding-status.md`.

- [ ] **Step 3: Apply C5.3** to `docs/superpowers/backlog.md`.

- [ ] **Step 4: Verify all 3 files**

```bash
rg -n 'poetry.lock > uv.lock' actions/setup-python-deps/action.yml
rg -n 'table is intentionally empty' docs/onboarding-status.md
rg -n 'Lint- und Test-Atoms' docs/superpowers/backlog.md
```

All three should return EMPTY (the stale strings are gone).

```bash
yamllint -s actions/setup-python-deps/action.yml
```

Expected: exit 0.

- [ ] **Step 5: Commit C5**

```bash
git add actions/setup-python-deps/action.yml docs/onboarding-status.md docs/superpowers/backlog.md
git commit -m "docs: misc cleanup (onboarding-status, backlog, setup-python-deps header)"
```

---

## Task X: Push + open PR

- [ ] **Step 1: Final state check**

```bash
git log --oneline origin/main..HEAD
git diff --stat origin/main..HEAD
```

Expected:
- 5 commits ahead of origin/main with the exact subject lines:
  ```
  docs: misc cleanup (onboarding-status, backlog, setup-python-deps header)
  docs(readme): fix coverage threshold, contracts link, add setup-python-deps row
  docs(contracts): fix onboard-* internal action contracts
  docs(contracts): sync release.yml + semantic-release.yml schemas with phase 2a/2b additions
  docs(contracts): add 10 missing atom tables
  ```
- 5 files in the cumulative diffstat: `docs/contracts.md`, `README.md`, `actions/setup-python-deps/action.yml`, `docs/onboarding-status.md`, `docs/superpowers/backlog.md`.

- [ ] **Step 2: Final verification block**

```bash
# contracts.md section count must be 23
rg '^### ' docs/contracts.md | wc -l
# README no longer has 90% threshold
rg '90 %' README.md
# README no longer has the stale contracts link in the Workflow contracts section
rg -n 'docs/superpowers/specs/2026-05-16-reusable-workflows-design.md' README.md
# setup-python-deps row in README composite-actions table
rg -n 'setup-python-deps' README.md
# onboarding-status.md table is clean (no stale prose)
rg -n 'table is intentionally empty' docs/onboarding-status.md
# backlog no longer has "Lint und Test Atoms" entry
rg -n 'Lint- und Test-Atoms' docs/superpowers/backlog.md
# setup-python-deps action header is now content-first
rg -n 'content first, lockfile as fallback' actions/setup-python-deps/action.yml
```

Expected:
- Line 1 (contracts count): `23`
- Lines 2,3,5,6: empty (stale content gone)
- Lines 4,7: 1+ hit (new content present)

- [ ] **Step 3: Push**

```bash
git push -u origin docs/phase-3-drift-cleanup
```

- [ ] **Step 4: Open PR**

```bash
gh pr create --title "docs: phase 3 documentation drift cleanup" --body "$(cat <<'EOF'
## Summary
- Added 10 missing atom contract tables in `docs/contracts.md` (lint-go, test-go, lint-python, test-python, lint-rust, test-rust, lint-helm, goreleaser, docker-build-multi, helm-publish). Re-sorted the Atomic Workflows section alphabetically.
- Synced existing atom contracts with Phase 2a/2b schema additions: `release.yml` gets `image_name` + 3 `runs_on_*` passthroughs (PR #91); `semantic-release.yml` gets `dry_run` (PR #96).
- Fixed `onboard-*` internal action contracts: `onboard-detect` now lists the `profile_json` output; `onboard-render` table rewritten to match the post-smarter-onboarding schema (`profile_json` input replaces removed `release_type`/`current_version`); new `onboard-drift` section.
- README corrections: test atom coverage threshold says 80 (not 90); Workflow contracts section links to `docs/contracts.md` (not the design spec); composite-actions table includes `setup-python-deps`.
- Misc cleanup: `setup-python-deps` action header comment now describes the actual content-first probe order; `onboarding-status.md` no longer carries a stale "intentionally empty" disclaimer; `backlog.md` no longer lists the (shipped) Lint und Test Atoms feature.

## Test plan
- [x] `yamllint` clean on `actions/setup-python-deps/action.yml` (only comment changed)
- [x] No workflow files touched — production CI behavior unchanged
- [x] `rg '^### ' docs/contracts.md | wc -l` returns 23
- [x] No stale-content matches remain (90 %, stale contracts link, stale prose, removed backlog entry)
- [ ] CI: `validate.yml` and `integration.yml` green (no functional changes expected to affect either)
EOF
)" 2>&1 | tail -3
```

- [ ] **Step 5: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## Acceptance Criteria (mirrors spec § 8)

- [ ] PR merged: 10 new `### <name>.yml` sections in `docs/contracts.md`, alphabetically sorted under `## Atomic Workflows`.
- [ ] `release.yml` and `semantic-release.yml` contract tables match the workflow files byte-for-byte on the new inputs.
- [ ] `onboard-detect`, `onboard-render`, `onboard-drift` tables match the corresponding `action.yml` files.
- [ ] README: coverage threshold 80, contracts link points at `docs/contracts.md`, composite-actions table has 5 rows.
- [ ] `setup-python-deps/action.yml` header probe-order matches the actual detection code at lines 50–66.
- [ ] `onboarding-status.md` table renders cleanly.
- [ ] `backlog.md` does not list the Lint und Test Atoms feature.
- [ ] All CI green; no version bump (all `docs:` commits → release-please default config treats as non-versioning).
- [ ] `rg '^### ' docs/contracts.md | wc -l` returns 23.
