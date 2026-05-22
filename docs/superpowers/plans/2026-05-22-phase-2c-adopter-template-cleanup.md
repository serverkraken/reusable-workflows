# Phase 2c Adopter-Template Cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the 4 V1-era static adopter templates + 2 dead sed-style JSON `.tmpl` files, and rewrite the README "Quick start (adopters)" section to pivot adopters to `onboard.yml` as the canonical onboarding entrypoint.

**Architecture:** Single PR, single commit, single worktree. Pure documentation change — no workflow, script, or test edits. Reduces `docs/adopter-templates/` to two subdirectories (`skeletons/` and `configs/`) that are unambiguously inputs to the onboarding renderer.

**Tech Stack:** Markdown (README), file system (deletes). No code, no tests.

**Spec:** `docs/superpowers/specs/2026-05-22-phase-2c-design.md`

**Repo style:** Conventional Commits, no Claude-attribution footer in commits or PR descriptions.

---

## Pre-Flight (do once before starting)

- [ ] **Step 1: Verify working tree state**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git status -sb
```

Expected: `## main...origin/main` possibly with `[ahead N]` (the Phase-2c spec and this plan are local-only docs commits — that's fine). Untracked `foo`/`GEMINI.md`/`REVIEW-2026-05-22.md` may be present — leave them alone.

- [ ] **Step 2: Fetch upstream**

```bash
git fetch origin --quiet && git log HEAD..origin/main --oneline
```

Expected: empty output (no upstream commits we don't have).

- [ ] **Step 3: Verify worktree availability**

```bash
git worktree list
```

Expected: 4 unrelated existing worktrees (`docker-multi-perms`, `exclude-catalog`, `go-atoms-fix`, `go-cgo-toggle`). None touch `README.md` or `docs/adopter-templates/`. No collision.

- [ ] **Step 4: Confirm the 6 files to delete exist**

```bash
ls -1 docs/adopter-templates/ci.yml \
      docs/adopter-templates/release.yml \
      docs/adopter-templates/prerelease.yml \
      docs/adopter-templates/cleanup.yml \
      docs/adopter-templates/release-please-config.json.tmpl \
      docs/adopter-templates/release-please-manifest.json.tmpl
```

Expected: all 6 paths print without error. The 6 files must exist for this plan to be valid.

- [ ] **Step 5: Confirm the 2 active subdirectories are intact**

```bash
ls docs/adopter-templates/configs/ docs/adopter-templates/skeletons/
```

Expected: `configs/` lists 3 `.tmpl` files (release-please-config.json.tmpl, release-please-config.monorepo.json.tmpl, release-please-manifest.json.tmpl); `skeletons/` lists 4 `.tmpl` files (ci, cleanup, prerelease, release).

---

## Task 1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees`** to create `.worktrees/remove-static-templates` with branch `refactor/remove-static-adopter-templates` from `origin/main`.

- [ ] **Step 2: Confirm location**

```bash
cd .worktrees/remove-static-templates
pwd && git branch --show-current
```

Expected: path ends in `.worktrees/remove-static-templates`; branch is `refactor/remove-static-adopter-templates`.

---

## Task 2: Delete the 6 files

**Files:**
- Delete: `docs/adopter-templates/ci.yml`
- Delete: `docs/adopter-templates/release.yml`
- Delete: `docs/adopter-templates/prerelease.yml`
- Delete: `docs/adopter-templates/cleanup.yml`
- Delete: `docs/adopter-templates/release-please-config.json.tmpl`
- Delete: `docs/adopter-templates/release-please-manifest.json.tmpl`

- [ ] **Step 1: Remove all 6 files via git rm**

Use `git rm` (not `rm`) so the deletes are staged:

```bash
git rm docs/adopter-templates/ci.yml \
       docs/adopter-templates/release.yml \
       docs/adopter-templates/prerelease.yml \
       docs/adopter-templates/cleanup.yml \
       docs/adopter-templates/release-please-config.json.tmpl \
       docs/adopter-templates/release-please-manifest.json.tmpl
```

Expected: 6 lines printed, each `rm '...'`.

- [ ] **Step 2: Verify the directory now contains only the 2 active subdirs**

```bash
ls docs/adopter-templates/
```

Expected: exactly two entries — `configs` and `skeletons`. No `.yml` or `.tmpl` files at the top level.

- [ ] **Step 3: Verify staged state**

```bash
git status --short
```

Expected: 6 lines, all `D ` (capital D, deleted-and-staged), listing the 6 deleted files. No other entries.

---

## Task 3: Rewrite README Quick Start section

**Files:**
- Modify: `README.md` (replace lines 5-22, keep line 24+ `## What it does` and everything after)

- [ ] **Step 1: Apply the exact text replacement**

Use the Edit tool to replace this block (lines 5-22 of `README.md`):

**Old text** (this is the full content to find — include the blank line at the end):
```
## Quick start (adopters)

**Prerequisites** (one-time per repo):

1. `release-please-config.json` in repo root (see [release-please docs](https://github.com/googleapis/release-please) for `release-type` per language).
2. `.release-please-manifest.json` in repo root with initial version, e.g. `{ ".": "0.0.0" }`.
3. The `serverkraken-release-bot` GitHub App must be installed on the repo (org-wide install handles this automatically).

**Then** copy templates from [`docs/adopter-templates/`](docs/adopter-templates/) into `.github/workflows/` of your repo:

| Template          | Trigger              | Purpose                                              |
|-------------------|----------------------|------------------------------------------------------|
| `release.yml`     | push → main          | Full release pipeline (release-please → image build → trivy) |
| `ci.yml`          | pull_request         | PR-time security scan (trivy-fs)                     |
| `prerelease.yml`  | workflow_dispatch    | Manual image build from a feature branch             |
| `cleanup.yml`     | weekly cron          | GHCR retention                                       |

That's the complete onboarding. No per-repo secret setup — `secrets: inherit` reaches the org-level App secrets.
```

**New text** (replacement):
```
## Quick start (adopters)

**Prerequisite** (one-time per repo):

- The `serverkraken-release-bot` GitHub App must be installed on the repo
  (org-wide install handles this automatically). No per-repo secret setup —
  `secrets: inherit` reaches the org-level App secrets.

**Then** dispatch the onboarding workflow from this catalog repo's Actions tab:

1. Open [`onboard.yml`](.github/workflows/onboard.yml) in the catalog's
   Actions tab.
2. Click "Run workflow" and set `target_repos: owner/repo` (comma-separated
   for multiple). Leave other inputs at their defaults.
3. Onboarding produces two PRs in the target repo:
   **PR-A** adds the rendered workflows + `.github/onboard.lock.json` +
   release-please configs; **PR-B** removes any superseded legacy workflows.
4. Merge PR-A. Push a `feat:`/`fix:` commit. release-please opens a release
   PR. Merge it → image build + trivy scan + release run automatically.

See [`docs/operations.md`](docs/operations.md) §5 for the full onboarding
contract and operator-facing knobs.

### What gets rendered

The onboarding renders 4 workflows in `.github/workflows/` of the target
repo, pinned to `@v3` (the current catalog major). The skeleton sources are
the canonical reference for what each contains:

- [`ci.yml.tmpl`](docs/adopter-templates/skeletons/ci.yml.tmpl) — lint + test + trivy-fs (pull_request)
- [`release.yml.tmpl`](docs/adopter-templates/skeletons/release.yml.tmpl) — release-please → image build → trivy-image (push → main)
- [`prerelease.yml.tmpl`](docs/adopter-templates/skeletons/prerelease.yml.tmpl) — manual image build (workflow_dispatch)
- [`cleanup.yml.tmpl`](docs/adopter-templates/skeletons/cleanup.yml.tmpl) — GHCR retention (weekly cron)

All four expose `SK_*` repo/org variables for per-adopter overrides — see
the rendered files for the full list, or [`docs/contracts.md`](docs/contracts.md)
for the upstream workflow input schemas.

### Manual setup (advanced)

If the onboarding workflow doesn't fit (target repo outside the
serverkraken org, GitHub App not installed, etc.), compose the atoms
directly. See [`docs/contracts.md`](docs/contracts.md) for each workflow's
input/output/secret schema and the
[`docs/adopter-templates/skeletons/`](docs/adopter-templates/skeletons/)
directory for reference renders that you can adapt by hand.
```

- [ ] **Step 2: Verify the replacement landed correctly**

```bash
sed -n '1,50p' README.md
```

Expected: line 1 is the `# serverkraken/reusable-workflows` header; line 5 is the new `## Quick start (adopters)`; the section is followed (after a blank line) by `## What it does` — unchanged from origin/main.

```bash
rg -n '## What it does' README.md
```

Expected: exactly 1 hit. The replacement must NOT have accidentally removed or duplicated the next section header.

---

## Task 4: Final verification

- [ ] **Step 1: Confirm no stale references in active docs**

```bash
rg 'docs/adopter-templates/(ci|release|prerelease|cleanup)\.yml' README.md CONTRIBUTING.md scripts/ .github/
```

Expected: empty output. No active doc or script references the deleted files.

- [ ] **Step 2: Confirm no stale references to the deleted sed-style tmpls**

```bash
rg 'docs/adopter-templates/release-please-(config|manifest)\.json\.tmpl' README.md CONTRIBUTING.md scripts/ .github/
```

Expected: empty output. (The active `configs/`-prefixed paths under `scripts/onboard-render.sh` are NOT matched by this pattern — only the deleted top-level files would be.)

- [ ] **Step 3: Confirm active subdirectories are untouched**

```bash
ls docs/adopter-templates/configs/ docs/adopter-templates/skeletons/
```

Expected: same content as Pre-Flight Step 5 — 3 files in `configs/`, 4 files in `skeletons/`.

- [ ] **Step 4: Spot-check Markdown rendering**

Open `README.md` in your editor's Markdown preview (or just `head -50 README.md` to eyeball). Confirm:
- The new "Quick start (adopters)" section reads cleanly as Markdown.
- The 4 skeleton links use the correct path `docs/adopter-templates/skeletons/<name>.yml.tmpl`.
- The links to `docs/operations.md` and `docs/contracts.md` use the correct relative paths.
- No stray conflict markers or doubled headings.

```bash
rg '<<<<<<<|>>>>>>>|=======' README.md
```

Expected: empty (no merge-conflict residue).

---

## Task 5: Commit + push + open PR

- [ ] **Step 1: Stage the README change** (deletes are already staged from Task 2)

```bash
git add README.md
git status --short
```

Expected: 7 lines total — 6 `D ` (deleted files) + 1 `M ` (README.md). No other entries.

- [ ] **Step 2: Diff sanity-check**

```bash
git diff --cached --stat
```

Expected: 7 files in the diffstat. README.md should show roughly `-18, +36` (the old 18-line section replaced by ~36 new lines of richer prose).

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(docs): remove static adopter templates, pivot README to onboard.yml"
```

Expected: 1 commit ahead of origin/main, 7 files changed.

- [ ] **Step 4: Push**

```bash
git push -u origin refactor/remove-static-adopter-templates
```

- [ ] **Step 5: Open PR**

```bash
gh pr create --title "refactor(docs): remove static adopter templates, pivot README to onboard.yml" --body "$(cat <<'EOF'
## Summary
- The 4 static adopter templates under `docs/adopter-templates/{ci,release,prerelease,cleanup}.yml` were V1-era hand-written copies that pinned `@v1` and produced a functionally weaker setup than `onboard.yml` (no lint/test atoms, no `SK_*` overrides, no App-token catalog checkout). Adopters following the README's "copy these templates" instruction landed on the weaker path. Deleted.
- Also deleted the 2 dead sed-style JSON templates at the top of `adopter-templates/` (`release-please-config.json.tmpl`, `release-please-manifest.json.tmpl`) — the active gomplate versions live under `adopter-templates/configs/` and are the ones `scripts/onboard-render.sh` actually uses. Top-level versions had no callers and were drift bait.
- Rewrote `README.md` "Quick start (adopters)" to pivot adopters to `onboard.yml` as the canonical entrypoint: 4-step flow (dispatch → 2 PRs → merge → release runs). The "What gets rendered" section now links directly to the skeleton sources as the single source of truth — no risk of doc drift when skeletons evolve.
- Added a small "Manual setup (advanced)" subsection that points non-App adopters at `docs/contracts.md` + the skeleton directory as a reference, rather than maintaining a dedicated second template set.

## Test plan
- [x] `rg 'docs/adopter-templates/(ci|release|prerelease|cleanup)\.yml' README.md CONTRIBUTING.md scripts/ .github/` is empty
- [x] `rg 'docs/adopter-templates/release-please-(config|manifest)\.json\.tmpl' README.md CONTRIBUTING.md scripts/ .github/` is empty
- [x] `docs/adopter-templates/{skeletons,configs}/` directories untouched (live render inputs)
- [x] README renders cleanly as Markdown
- [ ] CI: validate.yml + integration.yml green (no workflow changes, expected pass)
EOF
)"
```

- [ ] **Step 6: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## Acceptance Criteria (mirrors spec § 8)

- [ ] PR merged: the 6 files no longer exist on `main`.
- [ ] `rg 'docs/adopter-templates/(ci|release|prerelease|cleanup)\.yml' README.md CONTRIBUTING.md scripts/ .github/` empty.
- [ ] README "Quick start (adopters)" section pivots to `onboard.yml` with the 4-step flow and the skeleton link-list.
- [ ] `docs/adopter-templates/` contains exactly two entries: `configs/` and `skeletons/`.
- [ ] CI `validate.yml` and `integration.yml` green on the branch (no workflow changes — expected pass).
- [ ] Commit-message Conventional: `refactor(docs):` prefix, no Claude footer.
