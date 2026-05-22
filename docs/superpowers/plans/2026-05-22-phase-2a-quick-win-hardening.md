# Phase 2a Quick-Win Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close seven Phase-2a findings from `REVIEW-2026-05-22.md` via three independent mechanical PRs that all unblock Cross-Repo Adopter usage.

**Architecture:** Three disjoint file sets, each a separate PR:
- **PR-D** — Bump the hardcoded `ref=v2` to `v3` in the 6 remaining cross-repo catalog-checkout sites, plus add a `# renovate-marker: catalog-major-ref` comment above every `echo "ref=vX"` line (including the 2 already at `v3`) so future major bumps are 1 grep away.
- **PR-E** — Add a top-level `permissions:` UNION block to `release.yml`; add `image_name`, `runs_on_amd64`, `runs_on_arm64`, `runs_on_merge` as optional inputs with `docker-build.yml`-identical defaults; pass them through to the `docker-build` nested job.
- **PR-F** — Change `pin_version` default from `v1` to `v3` at both occurrences in `onboard.yml`; add a one-line comment noting the bump-on-major rule.

All three are non-breaking on the caller side (additive inputs + default value change to a newer major).

**Tech Stack:** GitHub Actions reusable workflows (YAML), `actionlint`/`yamllint` for static lint, existing bats + integration tests must remain green.

**Spec:** `docs/superpowers/specs/2026-05-22-phase-2a-design.md`

**Repo style:** Conventional Commits, no Claude-attribution footer in commits or PR descriptions.

---

## Pre-Flight (do once before starting any PR)

- [ ] **Step 1: Verify working tree state**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git status -sb
```

Expected: `## main...origin/main` possibly with `[ahead N]` (local-only docs commits — the Phase-2a spec + this plan are committed locally but not yet pushed; that's fine, worktrees will branch from `origin/main` and skip those). Untracked `foo`/`GEMINI.md`/`REVIEW-2026-05-22.md` may be present — leave them alone.

- [ ] **Step 2: Fetch upstream**

```bash
git fetch origin --quiet && git log HEAD..origin/main --oneline
```

Expected: empty output (no upstream commits we don't have).

- [ ] **Step 3: Verify worktree availability**

```bash
git worktree list
```

Expected: 4 unrelated existing worktrees (`docker-multi-perms`, `exclude-catalog`, `go-atoms-fix`, `go-cgo-toggle`). None touch `docker-build.yml`, `trivy-*.yml`, `release.yml`, or `onboard.yml`. No collision.

- [ ] **Step 4: Verify required tools**

```bash
command -v actionlint yamllint gh git
```

Expected: all four binaries print a path.

---

## PR-D: Cross-Repo Catalog-Ref Bump

**Concerns:** HIGH-1, INK-2, MED-25
**Branch:** `fix/cross-repo-catalog-ref-v3`
**Worktree:** `.worktrees/catalog-ref-v3`

### Task D1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees`** to create `.worktrees/catalog-ref-v3` with branch `fix/cross-repo-catalog-ref-v3` from `origin/main`.

- [ ] **Step 2: Confirm location**

```bash
cd .worktrees/catalog-ref-v3
pwd && git branch --show-current
```

Expected: path ends in `.worktrees/catalog-ref-v3`; branch is `fix/cross-repo-catalog-ref-v3`.

---

### Task D2: Bump `ref=v2` → `ref=v3` and add renovate-markers in `docker-build.yml`

**Files:**
- Modify: `.github/workflows/docker-build.yml` (4 sites: lines ~115-125, ~210-220, ~299-308, ~446-455)

The current pattern at each site looks like:

```bash
            # Cross-repo: catalog ref = v2 (floating)
            # Bump the hardcoded major in this block when a new major releases.
            echo "ref=v2" >> "$GITHUB_OUTPUT"
```

The target pattern is:

```bash
            # Cross-repo: catalog ref = v3 (floating)
            # renovate-marker: catalog-major-ref
            # Bump the hardcoded major in this block when a new major releases.
            echo "ref=v3" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 1: Find all 4 ref sites**

```bash
rg -n 'echo "ref=v' .github/workflows/docker-build.yml
```

Expected: 4 hits at lines 124, 220, 308, 455.

- [ ] **Step 2: Apply the bump + marker at all 4 sites**

For each of the 4 sites: change `v2` → `v3` in both the comment and the echo line. Insert the `# renovate-marker: catalog-major-ref` comment line directly above the `echo "ref=vX"` line. The comments around each site may differ slightly (some have only the "floating v2" comment, some have additional context). The minimum required edit is:

- `echo "ref=v2"` → `echo "ref=v3"`
- The comment `# Cross-repo: catalog ref = v2 (floating)` → `# Cross-repo: catalog ref = v3 (floating)` (where present)
- Add `# renovate-marker: catalog-major-ref` as a new line directly above the `echo` line

- [ ] **Step 3: Verify**

```bash
rg -n 'echo "ref=v' .github/workflows/docker-build.yml
rg -n 'renovate-marker' .github/workflows/docker-build.yml
```

Expected:
- 4 `echo "ref=v3"` hits at lines that shifted by the marker insertion (+1 each from the inserts).
- 4 `renovate-marker` hits, one directly above each `echo`.

- [ ] **Step 4: Lint**

```bash
yamllint -s .github/workflows/docker-build.yml
actionlint .github/workflows/docker-build.yml 2>&1 | rg -v 'client-id|client_id' || true
```

Expected: yamllint exits 0. actionlint may emit known noise about `create-github-app-token@v3` `client-id` (see memory `project_actionlint_clientid.md`) — ignore.

---

### Task D3: Bump + marker in `trivy-image.yml` and `trivy-fs.yml`

**Files:**
- Modify: `.github/workflows/trivy-image.yml:89`
- Modify: `.github/workflows/trivy-fs.yml:102`

- [ ] **Step 1: Apply the same edit to each file**

For each of `trivy-image.yml:89` and `trivy-fs.yml:102`: change `v2` → `v3` in the echo + nearby comment, insert `# renovate-marker: catalog-major-ref` above the `echo` line.

- [ ] **Step 2: Verify**

```bash
rg -n 'echo "ref=v' .github/workflows/trivy-image.yml .github/workflows/trivy-fs.yml
rg -n 'renovate-marker' .github/workflows/trivy-image.yml .github/workflows/trivy-fs.yml
```

Expected: 2 `echo "ref=v3"` hits, 2 `renovate-marker` hits.

- [ ] **Step 3: Lint both files**

```bash
yamllint -s .github/workflows/trivy-image.yml .github/workflows/trivy-fs.yml
```

Expected: exit 0.

---

### Task D4: Add renovate-marker to already-correct `v3` sites in lint-python + test-python

**Files:**
- Modify: `.github/workflows/lint-python.yml:70`
- Modify: `.github/workflows/test-python.yml:69`

These two files already have `echo "ref=v3"`. They get the marker for consistency so that `rg renovate-marker .github/workflows/` produces a complete inventory of ref sites.

- [ ] **Step 1: Add the marker above each `echo "ref=v3"`**

Insert `# renovate-marker: catalog-major-ref` as a new line directly above each existing `echo "ref=v3"` line. Do NOT change the `echo` line itself.

- [ ] **Step 2: Verify the full inventory**

```bash
rg -n 'renovate-marker: catalog-major-ref' .github/workflows/ | wc -l
rg -n 'echo "ref=v' .github/workflows/
```

Expected: `8` renovate-markers; `8` `echo "ref=v3"` lines (4 in docker-build.yml, 1 in trivy-image.yml, 1 in trivy-fs.yml, 1 in lint-python.yml, 1 in test-python.yml). No `v2` remaining.

- [ ] **Step 3: Lint both files**

```bash
yamllint -s .github/workflows/lint-python.yml .github/workflows/test-python.yml
```

Expected: exit 0.

---

### Task D5: Final verify + commit

- [ ] **Step 1: Full diff sanity-check**

```bash
git diff --stat origin/main..HEAD
git diff origin/main..HEAD | head -100
```

Expected: 5 files in the diffstat (`docker-build.yml`, `trivy-image.yml`, `trivy-fs.yml`, `lint-python.yml`, `test-python.yml`). Net add of comment lines + 6 `v2`→`v3` substitutions.

- [ ] **Step 2: Confirm no v2 remains anywhere**

```bash
rg 'echo "ref=v2"' .github/workflows/
```

Expected: empty output.

- [ ] **Step 3: Run actionlint across all changed files**

```bash
actionlint .github/workflows/docker-build.yml .github/workflows/trivy-image.yml .github/workflows/trivy-fs.yml .github/workflows/lint-python.yml .github/workflows/test-python.yml 2>&1 | rg -v 'client-id|client_id' | head -20
```

Expected: no errors other than the known client-id noise.

- [ ] **Step 4: Stage + commit**

```bash
git add .github/workflows/docker-build.yml .github/workflows/trivy-image.yml .github/workflows/trivy-fs.yml .github/workflows/lint-python.yml .github/workflows/test-python.yml
git commit -m "fix(docker-build,trivy): bump cross-repo catalog ref to v3"
```

Expected: 1 commit ahead of origin/main.

---

### Task D6: Push + open PR

- [ ] **Step 1: Push**

```bash
git push -u origin fix/cross-repo-catalog-ref-v3
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "fix(docker-build,trivy): bump cross-repo catalog ref to v3" --body "$(cat <<'EOF'
## Summary
- The cross-repo catalog-checkout in `docker-build.yml` (4 sites), `trivy-image.yml`, and `trivy-fs.yml` was still hardcoded to `ref=v2` despite the catalog being on v3 since 3.0.0. External adopters calling `*.yml@v3` were silently getting v2 composite actions checked out (`install-trivy`, `ghcr-login`, `compute-prerelease-tag`).
- Bumped all 6 sites to `v3`. Added `# renovate-marker: catalog-major-ref` above every `echo "ref=vX"` line (8 total — also added to the already-correct `lint-python.yml` and `test-python.yml` sites) so the next major bump is one `rg renovate-marker` away.

## Test plan
- [x] `rg 'echo "ref=v2"' .github/workflows/` returns nothing
- [x] `rg 'renovate-marker: catalog-major-ref' .github/workflows/ | wc -l` returns 8
- [x] `yamllint` clean on all 5 changed files
- [x] `actionlint` clean on all 5 changed files (modulo known `client-id` noise)
- [ ] CI integration `test-docker-build`, `test-trivy-image-*`, `test-trivy-fs-*` green (same-repo path is unaffected by the ref change)
EOF
)"
```

- [ ] **Step 3: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## PR-E: `release.yml` Cross-Repo Tauglichkeit

**Concerns:** HIGH-2, MED-2, MED-3
**Branch:** `fix/release-permissions-and-passthrough`
**Worktree:** `.worktrees/release-yml-passthrough`

### Task E1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees`** to create `.worktrees/release-yml-passthrough` with branch `fix/release-permissions-and-passthrough` from `origin/main`.

- [ ] **Step 2: Confirm location**

```bash
cd .worktrees/release-yml-passthrough
pwd && git branch --show-current
```

---

### Task E2: Add the four new inputs to `release.yml`

**Files:**
- Modify: `.github/workflows/release.yml:46-47` (insert after existing `trivy_severity` input, before `secrets:`)

- [ ] **Step 1: Find the insertion point**

```bash
rg -n 'trivy_severity|secrets:' .github/workflows/release.yml | head -5
```

Expected: `trivy_severity` at ~line 43, `secrets:` at ~line 47.

- [ ] **Step 2: Insert the four new inputs**

Find this section (the end of the `inputs:` block, just before `secrets:`):

```yaml
      trivy_severity:
        required: false
        type: string
        default: 'HIGH,CRITICAL'
    secrets:
```

Replace with:

```yaml
      trivy_severity:
        required: false
        type: string
        default: 'HIGH,CRITICAL'
      image_name:
        description: 'Image name. Default: caller repo (owner/repo). Passed through to docker-build.yml.'
        required: false
        type: string
        default: ''
      runs_on_amd64:
        required: false
        type: string
        default: '["self-hosted","Linux","X64","performance"]'
      runs_on_arm64:
        required: false
        type: string
        default: '["self-hosted","Linux","ARM64"]'
      runs_on_merge:
        required: false
        type: string
        default: '["self-hosted","Linux","low-performance"]'
    secrets:
```

The defaults are byte-identical to `docker-build.yml` lines 49-60 (verified consistency).

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/release.yml
```

Expected: exit 0.

---

### Task E3: Add the top-level `permissions:` block

**Files:**
- Modify: `.github/workflows/release.yml` — insert a new block between `secrets:` end and `concurrency:` start

The permissions block is the UNION of nested calls (semantic-release.yml, docker-build.yml, trivy-image.yml). See spec §3.2.

- [ ] **Step 1: Find the insertion point**

```bash
rg -n '^concurrency:|^permissions:' .github/workflows/release.yml
```

Expected: only `concurrency:` at ~line 53. No existing `permissions:` block.

- [ ] **Step 2: Insert the permissions block**

Find this:

```yaml
    secrets:
      release_please_app_client_id:
        required: true
      release_please_app_private_key:
        required: true

concurrency:
```

Replace with:

```yaml
    secrets:
      release_please_app_client_id:
        required: true
      release_please_app_private_key:
        required: true

permissions:
  # UNION of nested calls: semantic-release (contents/pull-requests/issues:write),
  # docker-build (packages/id-token/attestations/artifact-metadata:write +
  # pull-requests:write), trivy-image (security-events:write + actions/packages:read).
  # Required so cross-repo callers (`uses: …/release.yml@v3`) don't hit the
  # strict-intersection permission-ceiling on the nested workflow_call jobs.
  contents: write
  packages: write
  id-token: write
  attestations: write
  artifact-metadata: write
  pull-requests: write
  issues: write
  security-events: write
  actions: read

concurrency:
```

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/release.yml
actionlint .github/workflows/release.yml 2>&1 | rg -v 'client-id|client_id' || true
```

Expected: yamllint exit 0; actionlint no errors except known client-id noise.

---

### Task E4: Pass the new inputs through to the `docker-build` nested job

**Files:**
- Modify: `.github/workflows/release.yml` — extend the `with:` block of the `docker-build` job

- [ ] **Step 1: Find the docker-build job**

```bash
rg -n 'docker-build:|image_name|runs_on_' .github/workflows/release.yml
```

Expected: `docker-build:` job header at ~line 62; no existing `image_name` / `runs_on_` keys.

- [ ] **Step 2: Extend the `with:` block**

Find this:

```yaml
  docker-build:
    needs: semantic-release
    if: needs.semantic-release.outputs.release_created == 'true' && inputs.build_image
    uses: ./.github/workflows/docker-build.yml
    secrets: inherit
    with:
      tag: ${{ needs.semantic-release.outputs.tag_name }}
      prerelease: false
      dockerfile: ${{ inputs.dockerfile }}
      context: ${{ inputs.context }}
      platforms: ${{ inputs.platforms }}
      sign: ${{ inputs.sign }}
      attest: ${{ inputs.attest }}
      sbom: ${{ inputs.sbom }}
```

Replace with:

```yaml
  docker-build:
    needs: semantic-release
    if: needs.semantic-release.outputs.release_created == 'true' && inputs.build_image
    uses: ./.github/workflows/docker-build.yml
    secrets: inherit
    with:
      tag: ${{ needs.semantic-release.outputs.tag_name }}
      prerelease: false
      image_name: ${{ inputs.image_name }}
      dockerfile: ${{ inputs.dockerfile }}
      context: ${{ inputs.context }}
      platforms: ${{ inputs.platforms }}
      sign: ${{ inputs.sign }}
      attest: ${{ inputs.attest }}
      sbom: ${{ inputs.sbom }}
      runs_on_amd64: ${{ inputs.runs_on_amd64 }}
      runs_on_arm64: ${{ inputs.runs_on_arm64 }}
      runs_on_merge: ${{ inputs.runs_on_merge }}
```

- [ ] **Step 3: Lint**

```bash
yamllint -s .github/workflows/release.yml
```

Expected: exit 0.

---

### Task E5: Final verify + commit

- [ ] **Step 1: Full diff**

```bash
git diff --stat origin/main..HEAD
git diff origin/main..HEAD
```

Expected: 1 file (`.github/workflows/release.yml`), net add of ~35 lines (4 input blocks + 9-line permissions block + 4 passthrough lines + comments).

- [ ] **Step 2: actionlint final pass**

```bash
actionlint .github/workflows/release.yml 2>&1 | rg -v 'client-id|client_id'
```

Expected: no errors.

- [ ] **Step 3: Stage + commit**

```bash
git add .github/workflows/release.yml
git commit -m "fix(release): add cross-repo-ready permissions and passthrough inputs"
```

---

### Task E6: Push + open PR

- [ ] **Step 1: Push**

```bash
git push -u origin fix/release-permissions-and-passthrough
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "fix(release): add cross-repo-ready permissions and passthrough inputs" --body "$(cat <<'EOF'
## Summary
- `release.yml` had no top-level `permissions:` block. Same-repo callers relied on GHA's relaxed-ceiling behavior. Cross-repo callers (`uses: serverkraken/reusable-workflows/.github/workflows/release.yml@v3`) inherited the caller's permissions and hit the strict-intersection ceiling on the nested `docker-build` / `trivy-image` jobs. Added a UNION-of-nested-calls permissions block.
- Added four optional inputs — `image_name`, `runs_on_amd64`, `runs_on_arm64`, `runs_on_merge` — defaults byte-identical to `docker-build.yml`. Passed through to the nested `docker-build` job. Unblocks adopters with multi-image repos or non-standard runner pools.

## Test plan
- [x] `yamllint` and `actionlint` clean on the modified file
- [x] Schema unchanged for existing inputs; all new inputs are `required: false` with defaults — no caller break
- [ ] CI smoke (the catalog itself has no caller of `release.yml`; integration covers `docker-build.yml` directly)
EOF
)"
```

- [ ] **Step 3: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## PR-F: `onboard.yml` pin_version Default

**Concerns:** HIGH-5
**Branch:** `fix/onboard-pin-version-v3-default`
**Worktree:** `.worktrees/onboard-pin-v3`

### Task F1: Create worktree

- [ ] **Step 1: Invoke `superpowers:using-git-worktrees`** to create `.worktrees/onboard-pin-v3` with branch `fix/onboard-pin-version-v3-default` from `origin/main`.

- [ ] **Step 2: Confirm location**

```bash
cd .worktrees/onboard-pin-v3
pwd && git branch --show-current
```

---

### Task F2: Change default at the `workflow_dispatch` site

**Files:**
- Modify: `.github/workflows/onboard.yml` around line 24-28

- [ ] **Step 1: Find both pin_version sites**

```bash
rg -n 'pin_version:|default: v[0-9]' .github/workflows/onboard.yml | head -10
```

Expected: `pin_version:` declarations at lines 24 (under `workflow_dispatch`) and ~52 (under `workflow_call`); `default: v1` at lines 28 and 55.

- [ ] **Step 2: Edit the workflow_dispatch site (line ~24-28)**

Find this:

```yaml
      pin_version:
        description: 'Catalog @version that rendered templates pin to'
        required: false
        type: string
        default: v1
```

Replace with:

```yaml
      # pin_version: Catalog @version that rendered templates pin to.
      # When a new catalog major releases, bump this default and the matching
      # one in the workflow_call inputs block below.
      pin_version:
        description: 'Catalog @version that rendered templates pin to'
        required: false
        type: string
        default: v3
```

---

### Task F3: Change default at the `workflow_call` site

**Files:**
- Modify: `.github/workflows/onboard.yml` around line 50-55

- [ ] **Step 1: Edit the workflow_call site**

Find this (the second `pin_version` block, under `workflow_call.inputs`):

```yaml
      pin_version:
        required: false
        type: string
        default: v1
```

Replace with:

```yaml
      pin_version:
        required: false
        type: string
        default: v3
```

(No comment needed here — the workflow_dispatch site above already carries the bump-on-major note.)

---

### Task F4: Verify

- [ ] **Step 1: Confirm no `v1` defaults remain**

```bash
rg -n 'default: v[0-9]' .github/workflows/onboard.yml
```

Expected: two hits, both showing `default: v3`.

- [ ] **Step 2: Lint**

```bash
yamllint -s .github/workflows/onboard.yml
actionlint .github/workflows/onboard.yml 2>&1 | rg -v 'client-id|client_id' || true
```

Expected: yamllint exit 0; actionlint no errors beyond known noise.

---

### Task F5: Commit

- [ ] **Step 1: Diff sanity-check**

```bash
git diff origin/main..HEAD
```

Expected: 1 file, ~6 line additions (the 3-line comment) + 2 `v1` → `v3` changes.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "fix(onboard): default pin_version to v3 (current major)"
```

---

### Task F6: Push + open PR

- [ ] **Step 1: Push**

```bash
git push -u origin fix/onboard-pin-version-v3-default
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "fix(onboard): default pin_version to v3 (current major)" --body "$(cat <<'EOF'
## Summary
- `onboard.yml` defaulted `pin_version` to `v1` at both the `workflow_dispatch` and `workflow_call` sites. The catalog has been on v3 since 3.0.0. A dispatch without an explicit override produced templates without App-token catalog checkout (v2+), without `artifact-metadata: write` (v2.0.4+), and without `SK_*` override vars (v3.9.0+).
- All four production adopters in `docs/onboarding-status.md` set `pin_version: v3` explicitly today, so no caller breaks.
- Added a bump-on-major comment so future major releases update both sites together.

## Test plan
- [x] Both defaults are now `v3`
- [x] `yamllint`/`actionlint` clean
- [ ] CI `test-onboard-dry-run` green (the dry-run test sets pin_version explicitly, so the default change does not affect it)
EOF
)"
```

- [ ] **Step 3: Return to repo root**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
```

---

## Wrap-Up

### Task W1: Sanity-check the three open PRs

- [ ] **Step 1: List recent open PRs**

```bash
gh pr list --author "@me" --state open --limit 5
```

Expected: three new PRs plus the existing release-please PR (#89 or its successor):
- `fix(docker-build,trivy): bump cross-repo catalog ref to v3`
- `fix(release): add cross-repo-ready permissions and passthrough inputs`
- `fix(onboard): default pin_version to v3 (current major)`

- [ ] **Step 2: Confirm CI on each**

```bash
for pr in $(gh pr list --author "@me" --state open --limit 5 --json number,title -q '.[] | select(.title | startswith("fix") and (contains("v3") or contains("permissions") or contains("pin_version"))) | .number'); do
  echo "=== PR #$pr ==="
  gh pr checks "$pr" 2>&1 | head -5
done
```

Expected: each PR's `validate.yml` (actionlint, yamllint) and `integration.yml` (test-docker-build, test-trivy-*, test-onboard-dry-run) all queue/pass.

---

## Acceptance Criteria (mirrors spec § 8)

- [ ] PR-D merged: `rg 'echo "ref=v2"' .github/workflows/` empty; `rg 'renovate-marker: catalog-major-ref' .github/workflows/ | wc -l` returns 8.
- [ ] PR-E merged: `release.yml` has top-level `permissions:` block; `image_name`, `runs_on_amd64/arm64/merge` as optional inputs; all four passed through to the `docker-build` job.
- [ ] PR-F merged: both `pin_version` defaults in `onboard.yml` are `v3`.
- [ ] `actionlint` and `yamllint` clean on all changed files (modulo known client-id noise).
- [ ] CI green on each branch.
- [ ] Three Conventional-Commits produce three patch bumps in the next release-please PR (or fold into the pending 3.10.1 if not yet merged).
