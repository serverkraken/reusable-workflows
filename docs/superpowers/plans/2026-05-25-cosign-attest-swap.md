# Cosign-based SLSA Provenance Attest Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `actions/attest-build-provenance@v4` with `cosign attest --type slsaprovenance` so `attest: true` (Default) works on free-tier private GitHub repos. v4 major release.

**Architecture:** Single PR, four workflow files modified, one integration-test job added. Same OIDC trust-root as the existing `cosign sign` path; attestation stored as OCI sidecar at `<image>@<digest>` instead of via GitHub's Artifact-Attestations API. Permissions `attestations:write` + `artifact-metadata:write` removed (only `packages:write` + `id-token:write` needed).

**Tech Stack:** GitHub Actions reusable workflows (YAML), `sigstore/cosign-installer@v4.1.2`, SLSA v1.0 in-toto provenance predicate, `actionlint` + `yamllint` for local validation, bash heredoc for predicate generation.

**Spec:** `docs/superpowers/specs/2026-05-25-cosign-attest-swap-design.md`

---

## Pre-flight: Worktree setup

### Task 0.1: Sync main + create worktree

**Files:** none (git only)

- [ ] **Step 1: Sync local main**

```bash
git fetch origin main
git checkout main
git pull --rebase origin main
```

Expected: `Your branch is up to date with 'origin/main'.`

- [ ] **Step 2: Verify no other in-flight worktrees on this work**

```bash
git worktree list
```

Expected: nothing matching `cosign-attest`. If something matches, ask Soenne which worktree owns the work before continuing (per `CLAUDE.md` global rule).

- [ ] **Step 3: Create worktree + branch**

```bash
git worktree add .worktrees/cosign-attest-swap -b feat/cosign-attest-swap main
```

Expected: `Preparing worktree (new branch 'feat/cosign-attest-swap')`

- [ ] **Step 4: Verify worktree exists**

```bash
git worktree list
```

Expected: new entry `.worktrees/cosign-attest-swap [feat/cosign-attest-swap]`.

All subsequent Tasks 1–5 execute **from inside `.worktrees/cosign-attest-swap`**. Always use absolute paths when reading/editing.

---

## Task 1: Replace the attest step in `docker-build.yml`

**Files:**
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/docker-build.yml`

Two edits in this file: (1) widen the Cosign-Installer conditional so Cosign is installed when only `attest: true` is set (not just `sign: true`); (2) replace the `actions/attest-build-provenance@v4` step with `cosign attest`.

- [ ] **Step 1: Widen Cosign-Installer conditional**

Find the Install-Cosign step. Currently (around line 385-387):

```yaml
      - name: Install Cosign
        if: inputs.sign
        uses: sigstore/cosign-installer@v4.1.2
```

Replace with:

```yaml
      - name: Install Cosign
        if: inputs.sign || inputs.attest
        uses: sigstore/cosign-installer@v4.1.2
```

Why: the new attest step uses the `cosign` CLI, so we need the installer present whenever `attest: true` is set, not just when `sign: true`.

- [ ] **Step 2: Replace the attest step**

Find the existing attest step (around line 396-402):

```yaml
      - name: Attest build provenance
        if: inputs.attest
        uses: actions/attest-build-provenance@v4
        with:
          subject-name: ghcr.io/${{ needs.version.outputs.image_name }}
          subject-digest: ${{ steps.merge_step.outputs.digest }}
          push-to-registry: true
```

Replace with:

```yaml
      - name: Attest build provenance (cosign SLSA v1.0)
        if: inputs.attest
        env:
          IMG: ghcr.io/${{ needs.version.outputs.image_name }}
          DIGEST: ${{ steps.merge_step.outputs.digest }}
          REPO: ${{ github.repository }}
          REF: ${{ github.ref }}
          SHA: ${{ github.sha }}
          RUN_ID: ${{ github.run_id }}
          WORKFLOW: ${{ github.workflow }}
        run: |
          set -euo pipefail
          BUILD_STARTED="$(date -u -Iseconds)"
          cat > predicate.json <<EOF
          {
            "buildType": "https://github.com/actions/runner/buildTypes/workflow/v1",
            "builder": {
              "id": "https://github.com/${REPO}/.github/workflows/${WORKFLOW}@${REF}"
            },
            "invocation": {
              "configSource": {
                "uri": "git+https://github.com/${REPO}@${REF}",
                "digest": {"sha1": "${SHA}"},
                "entryPoint": "${WORKFLOW}"
              },
              "parameters": {},
              "environment": {}
            },
            "metadata": {
              "buildInvocationId": "${REPO}/actions/runs/${RUN_ID}",
              "buildStartedOn": "${BUILD_STARTED}",
              "completeness": {"parameters": true, "environment": false, "materials": false},
              "reproducible": false
            },
            "materials": [
              {
                "uri": "git+https://github.com/${REPO}@${REF}",
                "digest": {"sha1": "${SHA}"}
              }
            ]
          }
          EOF
          cosign attest --yes --type slsaprovenance \
            --predicate predicate.json "${IMG}@${DIGEST}"
```

- [ ] **Step 3: Static-validate the file**

```bash
actionlint .github/workflows/docker-build.yml
```

Expected: no output (= passes). If `actionlint` flags `client-id` or `unknown input`, ignore — `validate.yml` ignore-list policy still applies (memory: `project_actionlint_clientid`).

- [ ] **Step 4: YAML-validate**

```bash
yamllint .github/workflows/docker-build.yml
```

Expected: no output (= passes). If indentation errors appear in the new attest step's heredoc block, the most likely cause is mixing tabs and spaces — re-edit with spaces only.

---

## Task 2: Permissions cleanup across 4 workflows

**Files:**
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/docker-build.yml`
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/docker-build-multi.yml`
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/release.yml`
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/integration.yml`

Remove `attestations: write` and `artifact-metadata: write` from the top-level `permissions:` block in each file. They are no longer needed (cosign uses `packages: write` for OCI sidecar push and `id-token: write` for OIDC, both already declared).

- [ ] **Step 1: Edit `docker-build.yml`**

Find the top-level `permissions:` block (around line 80-89):

```yaml
permissions:
  contents: read
  packages: write
  id-token: write
  attestations: write
  # actions/attest-build-provenance@v4 additionally writes to GitHub's new
  # Artifact Metadata storage API. Without this, the attestation itself
  # still succeeds but a noisy warning is emitted on every release.
  artifact-metadata: write
  pull-requests: write
```

Replace with:

```yaml
permissions:
  contents: read
  packages: write
  id-token: write
  pull-requests: write
```

- [ ] **Step 2: Edit `docker-build-multi.yml`**

Find the top-level `permissions:` block (around line 104-107):

```yaml
permissions:
  contents: read
  packages: write
  id-token: write
  attestations: write
  # nested docker-build's permission ceiling — declare here so the nested
  # attest-build-provenance step doesn't get capped down.
  artifact-metadata: write
```

Replace with:

```yaml
permissions:
  contents: read
  packages: write
  id-token: write
```

- [ ] **Step 3: Edit `release.yml`**

Find the top-level `permissions:` block (around line 80-94):

```yaml
permissions:
  # UNION of nested calls: semantic-release (contents/pull-requests/issues:write),
  # docker-build (packages/id-token/attestations/artifact-metadata:write +
  # pull-requests:write), trivy-image (security-events:write, packages:read, actions:read).
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
```

Replace with:

```yaml
permissions:
  # UNION of nested calls: semantic-release (contents/pull-requests/issues:write),
  # docker-build (packages/id-token:write + pull-requests:write),
  # trivy-image (security-events:write, packages:read, actions:read).
  # Required so cross-repo callers (`uses: …/release.yml@v4`) don't hit the
  # strict-intersection permission-ceiling on the nested workflow_call jobs.
  contents: write
  packages: write
  id-token: write
  pull-requests: write
  issues: write
  security-events: write
  actions: read
```

- [ ] **Step 4: Edit `integration.yml`**

Find the top-level `permissions:` block + the explanatory comment (around line 9-25):

```yaml
# Workflow_call permission cap: the called atoms (docker-build,
# docker-build-multi, trivy-*, semantic-release) declare what they need.
# This block has to at minimum mirror the union, otherwise nested
# permissions are capped down. artifact-metadata was added Anfang 2026
# for attest-build-provenance@v4's metadata persistence path.
# contents:write + issues:write are needed by semantic-release (added
# 2026-05-22 with the test-semantic-release-dry-run integration job).
permissions:
  contents: write
  packages: write
  id-token: write
  attestations: write
  artifact-metadata: write
  security-events: write
  pull-requests: write
  issues: write
  actions: read
```

Replace with:

```yaml
# Workflow_call permission cap: the called atoms (docker-build,
# docker-build-multi, trivy-*, semantic-release) declare what they need.
# This block has to at minimum mirror the union, otherwise nested
# permissions are capped down. contents:write + issues:write are needed
# by semantic-release (added 2026-05-22 with the test-semantic-release-dry-run
# integration job). attestations / artifact-metadata permissions removed in
# v4 — cosign-based attest uses packages:write (sidecar push) + id-token:write
# (OIDC), both already covered.
permissions:
  contents: write
  packages: write
  id-token: write
  security-events: write
  pull-requests: write
  issues: write
  actions: read
```

- [ ] **Step 5: Static-validate all four files**

```bash
actionlint \
  .github/workflows/docker-build.yml \
  .github/workflows/docker-build-multi.yml \
  .github/workflows/release.yml \
  .github/workflows/integration.yml
```

Expected: no output.

- [ ] **Step 6: YAML-lint all four files**

```bash
yamllint \
  .github/workflows/docker-build.yml \
  .github/workflows/docker-build-multi.yml \
  .github/workflows/release.yml \
  .github/workflows/integration.yml
```

Expected: no output.

---

## Task 3: File-header docstrings + input descriptions

**Files:**
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/docker-build.yml`
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/release.yml`

Three edits: update the docstring at the top of `docker-build.yml`, update the `attest:` input description in both `docker-build.yml` and `release.yml`.

- [ ] **Step 1: Update the top-of-file docstring in `docker-build.yml`**

Find the file-header comment block (lines 1-6 or thereabouts). It currently mentions the GitHub Artifact Attestations API. Find this passage:

```
# Reusable workflow: build a multi-arch image distributed across native
# amd64/arm64 self-hosted runners, push by digest, stitch a manifest list,
# optionally cosign-sign, optionally attest build provenance via the
# GitHub Artifact Attestations API, optionally generate an SBOM artifact.
```

Replace with:

```
# Reusable workflow: build a multi-arch image distributed across native
# amd64/arm64 self-hosted runners, push by digest, stitch a manifest list,
# optionally cosign-sign, optionally attest build provenance as a
# cosign-attached SLSA v1.0 in-toto predicate (free-tier-compatible:
# stored as OCI sidecar at <image>@<digest>, verified with
# `cosign verify-attestation --type slsaprovenance`),
# optionally generate an SBOM artifact.
```

(If the existing wording is slightly different — same workflow file has been edited many times — preserve the surrounding lines and only swap the "attest" sentence.)

- [ ] **Step 2: Update the `attest:` input description in `docker-build.yml`**

Find the `attest:` input definition (around line 41):

```yaml
      attest:
        required: false
        type: boolean
        default: true
```

If it has a `description:`, replace its text with the line below. If not, add one:

```yaml
      attest:
        description: 'Generate SLSA v1.0 build provenance attestation for the image. Uses cosign keyless signing (free-tier compatible). Verify with `cosign verify-attestation --type slsaprovenance`.'
        required: false
        type: boolean
        default: true
```

- [ ] **Step 3: Update the `attest:` input description in `release.yml`**

Find the `attest:` input (around line 33):

```yaml
      attest:
        description: 'Generate SLSA build provenance attestation for the image.'
        required: false
        type: boolean
        default: true
```

Replace with:

```yaml
      attest:
        description: 'Generate SLSA v1.0 build provenance attestation for the image. Uses cosign keyless signing (free-tier compatible). Verify with `cosign verify-attestation --type slsaprovenance`.'
        required: false
        type: boolean
        default: true
```

- [ ] **Step 4: Static-validate**

```bash
actionlint .github/workflows/docker-build.yml .github/workflows/release.yml
yamllint .github/workflows/docker-build.yml .github/workflows/release.yml
```

Expected: no output.

---

## Task 4: Commit the feat! change

**Files:** none (git commit only)

This is the v4-Major-Bump commit. It must use the `feat!:` Conventional-Commit marker so release-please cuts a 4.0.0 release post-merge.

- [ ] **Step 1: Stage the modified files**

```bash
git status
```

Expected output should list exactly:
```
modified:   .github/workflows/docker-build.yml
modified:   .github/workflows/docker-build-multi.yml
modified:   .github/workflows/release.yml
modified:   .github/workflows/integration.yml
```

If something else is dirty, stop and ask Soenne — don't auto-include unrelated changes.

```bash
git add .github/workflows/docker-build.yml \
        .github/workflows/docker-build-multi.yml \
        .github/workflows/release.yml \
        .github/workflows/integration.yml
```

- [ ] **Step 2: Commit with `feat!:` marker**

```bash
git commit -m "$(cat <<'EOF'
feat!: switch to cosign-based SLSA provenance (free-tier compatible)

BREAKING CHANGE: `attest: true` now produces a cosign-attached SLSA v1.0
attestation stored as OCI sidecar at <image>@<digest>, replacing the
GitHub Artifact Attestations API call. This makes attest work on
free-tier private repos. Consumers verifying with `gh attestation verify`
must switch to `cosign verify-attestation --type slsaprovenance`. Input
contract is unchanged; only the implementation differs.

Top-level `attestations: write` and `artifact-metadata: write` permissions
are removed from docker-build.yml, docker-build-multi.yml, release.yml,
and integration.yml — cosign only needs packages:write + id-token:write,
both already declared. Bypass-callers that still declare the removed
permissions are unaffected (additive).

Cosign-Installer conditional widened to `inputs.sign || inputs.attest`
so the binary is present when only attest is enabled.
EOF
)"
```

Expected: commit succeeds. `git log -1 --format=%s` should show `feat!: switch to cosign-based SLSA provenance (free-tier compatible)`.

---

## Task 5: Add the `assert-attestation-verifies` integration job

**Files:**
- Modify: `.worktrees/cosign-attest-swap/.github/workflows/integration.yml`

Add a new job after the existing `test-docker-build` happy-path job, which verifies the cosign attestation that test-docker-build just produced.

- [ ] **Step 1: Locate insertion point**

Find the `test-docker-build` job definition (around line 39-50). It ends with:

```yaml
      sign: true
      attest: true
      sbom: true
```

Immediately after this job (before the next job comment `# ----- trivy-image happy path ...`), insert the new job.

- [ ] **Step 2: Add the assert job**

```yaml
  # ----- attestation verification (proves the cosign attest step produced
  # a sigstore-bundled SLSA predicate at the OCI sidecar location) -----
  assert-attestation-verifies:
    needs: test-docker-build
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      packages: read
    steps:
      - name: Install Cosign
        uses: sigstore/cosign-installer@v4.1.2
      - name: GHCR login (read-only)
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ACTOR: ${{ github.actor }}
        run: |
          echo "$GH_TOKEN" | cosign login ghcr.io -u "$ACTOR" --password-stdin
      - name: Verify cosign SLSA attestation
        env:
          IMG_REF: ${{ needs.test-docker-build.outputs.image_ref }}
        run: |
          set -euo pipefail
          # OIDC identity: cosign attest was invoked from docker-build.yml on this
          # branch, so the cert SAN contains the docker-build.yml workflow path
          # (NOT integration.yml). The regexp matches any ref-suffix.
          cosign verify-attestation \
            --type slsaprovenance \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com \
            --certificate-identity-regexp '^https://github\.com/serverkraken/reusable-workflows/\.github/workflows/docker-build\.yml@' \
            "$IMG_REF" > /tmp/att.json
          # Sanity-check: a verified attestation has a non-empty payload
          jq -e '.payload' /tmp/att.json > /dev/null
          echo "Cosign SLSA attestation verifies for $IMG_REF"
```

- [ ] **Step 3: Static-validate**

```bash
actionlint .github/workflows/integration.yml
yamllint .github/workflows/integration.yml
```

Expected: no output.

- [ ] **Step 4: Commit the assert job**

```bash
git add .github/workflows/integration.yml
git commit -m "chore(integration): verify cosign attestation in CI

Adds assert-attestation-verifies job that runs after test-docker-build
and confirms the cosign SLSA attestation produced by docker-build.yml
can be verified end-to-end via cosign verify-attestation."
```

Expected: commit succeeds. `git log -2 --format=%s` should show the assert commit on top of the `feat!:` commit.

---

## Task 6: Push branch + open PR

**Files:** none (git + gh only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/cosign-attest-swap
```

Expected: branch created on remote, tracking set.

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat!: switch to cosign-based SLSA provenance (free-tier compatible)" --body "$(cat <<'EOF'
## Summary

- Replace `actions/attest-build-provenance@v4` (GitHub Artifact Attestations API, requires Team/Enterprise on private repos) with `cosign attest --type slsaprovenance` (OCI sidecar, works on every plan)
- Remove top-level `attestations: write` + `artifact-metadata: write` permissions from `docker-build.yml`, `docker-build-multi.yml`, `release.yml`, `integration.yml` — cosign needs only `packages: write` + `id-token: write`, both already declared
- Widen Cosign-Installer conditional to `sign || attest` so the binary is present whenever attest runs without sign
- Add `assert-attestation-verifies` integration job that runs `cosign verify-attestation` against the test-fixture image

## Why

Free-tier private repos cannot use the GitHub Artifact Attestations API. The catalog defaulted `attest: true`, which silently broke for those adopters. This swap keeps the input contract identical, swaps the implementation to a free-tier-compatible path with the same OIDC trust-root that the existing `sign: true` flow already uses.

## Breaking change

Consumers verifying with `gh attestation verify` must switch to `cosign verify-attestation --type slsaprovenance`. Input contract on the catalog side is unchanged.

## Test plan

- [ ] `actionlint` + `yamllint` PR checks green
- [ ] `test-docker-build` happy path green (produces image + cosign attestation sidecar)
- [ ] `assert-attestation-verifies` green (verifies the produced attestation)
- [ ] `test-docker-build-cve` green (build with `attest: false` produces no attestation, no assert needed)
- [ ] `test-release-end-to-end` green (release.yml nested call works with reduced permissions)
- [ ] Post-merge: release-please cuts 4.0.0, force-moves `v4` floating tag
- [ ] Post-merge manual smoke: Soenne validates `release.yml@v4` works on a free-tier private repo

## Spec

`docs/superpowers/specs/2026-05-25-cosign-attest-swap-design.md`
EOF
)"
```

Expected: PR URL returned. Capture it for Task 7.

PR body style: no Claude attribution footer, no emoji (memory: `feedback_pr_style`, `feedback_no_emoji_use_glyphs`).

- [ ] **Step 3: Watch PR checks**

```bash
gh pr checks --watch
```

Expected: all checks eventually green. If `actionlint` or `yamllint` fail, fix in the worktree, commit, push.

If `test-docker-build` fails with a cosign error, the most likely causes are:
- Cosign-Installer step didn't run (check the conditional `inputs.sign || inputs.attest` in `docker-build.yml`)
- OIDC token missing — verify `id-token: write` is still in the top-level permissions of both `docker-build.yml` AND `integration.yml`

If `assert-attestation-verifies` fails with a cert-identity-regexp mismatch, the fallback is to loosen the regexp to `'.*docker-build\.yml.*'` as a hotfix in the same PR. Capture the actual cert subject from the failure log first to inform the fix.

---

## Task 7: Two-stage review

Per memory `feedback_phase_workflow_pattern` — every Phase-X PR gets two-stage review.

- [ ] **Step 1: Self-review the diff**

```bash
git diff main...feat/cosign-attest-swap
```

Scan for: typos in cosign commands, unintended permission removals, anything in the diff that wasn't in Tasks 1-5.

- [ ] **Step 2: Subagent code review**

Dispatch the `code-searcher` agent (or `feature-dev:code-reviewer`) with this prompt:

```
Review the diff between origin/main and HEAD on the current branch
(feat/cosign-attest-swap). The PR replaces actions/attest-build-provenance@v4
with cosign attest --type slsaprovenance across docker-build.yml, removes
attestations:write + artifact-metadata:write from four workflow files, and
adds an assert-attestation-verifies job to integration.yml.

Focus on:
1. Did anything sneak into the diff outside the four documented files?
2. Is the cosign attest predicate JSON well-formed (valid SLSA v1.0)?
3. Is the certificate-identity-regexp in assert-attestation-verifies correctly
   anchored for ref-suffix tolerance?
4. Are there any other workflow files in .github/workflows/ that still
   declare attestations:write or artifact-metadata:write that we missed?

Report under 200 words: high-confidence issues only, no nitpicks.

Spec: docs/superpowers/specs/2026-05-25-cosign-attest-swap-design.md
```

- [ ] **Step 3: Address review feedback**

If the reviewer raises legitimate concerns, fix and re-push. Use memory `superpowers:receiving-code-review` guidance — don't blindly agree or blindly defer.

- [ ] **Step 4: Wait for Soenne's approval**

Don't merge without explicit `ja`/`merge`/`go`. The two-stage rule: agent review → human review → merge.

---

## Task 8: Merge + post-merge follow-ups

**Files:** memory only (post-merge)

- [ ] **Step 1: Merge the PR**

After approval:

```bash
gh pr merge feat/cosign-attest-swap --squash --delete-branch
```

Expected: PR squashed onto main, branch deleted, release-please picks up the `feat!:` commit on its next run.

- [ ] **Step 2: Verify release-please opened a 4.0.0 PR**

Wait ~1 minute for the release-please workflow to run, then:

```bash
gh pr list --search 'chore(main): release'
```

Expected: a new PR titled `chore(main): release 4.0.0`. If it shows `3.x.x` instead, the `feat!:` parsing failed — investigate the commit message (must have `BREAKING CHANGE:` line in body OR `!` in type).

- [ ] **Step 3: Merge the release PR**

When the release-PR's checks are green:

```bash
gh pr merge --squash --delete-branch <release-PR-number>
```

This triggers semantic-release to tag `v4.0.0` and force-move the `v4` floating tag.

- [ ] **Step 4: Verify floating tag**

```bash
git fetch --tags origin
git rev-parse v4 v4.0.0
```

Expected: both refs resolve to the same commit (the release-PR merge commit).

- [ ] **Step 5: Manual smoke test on a private free-tier repo**

This step requires Soenne. Ask him to bump one of his private free-tier repos to `release.yml@v4` and trigger a release. Expected: release succeeds, image gets a cosign sidecar attestation in GHCR.

Verify locally on his machine:

```bash
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/<adopter-org>/<adopter-repo>/\.github/workflows/.+' \
  ghcr.io/<adopter-org>/<image>:<tag>
```

Expected: prints verification details.

- [ ] **Step 6: Update memory `troubleshooting_artifact_metadata_caller_cascade`**

Edit `/Users/msoent/.claude/projects/-Users-msoent-SourceCode-serverkraken-reusable-workflows/memory/troubleshooting_artifact_metadata_caller_cascade.md`:

Prepend an `**Obsolete since catalog v4.0.0**` block to the body, explaining that cosign-based attestation needs neither `attestations:write` nor `artifact-metadata:write`. Keep the original content for historical context.

- [ ] **Step 7: Update memory `reference_review_2026_05_22_roadmap`**

Mark Phase 8 Feature 0 (Cosign-attest swap) as DONE with the release date and tag (v4.0.0).

- [ ] **Step 8: Clean up worktree**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git worktree remove .worktrees/cosign-attest-swap
```

Expected: worktree removed, branch already deleted via `--delete-branch` in Step 1.

---

## Self-review checklist (run before handing off)

| Item | Status |
|---|---|
| Every spec concern (C-1 to C-6) has a corresponding task | C-1 → Task 1; C-2 → Task 2; C-3 → Task 5; C-4 → Task 3; C-5 → Task 4 commit; C-6 → Task 8 Step 6 |
| No `TBD`, `TODO`, `implement later` | none |
| Every code step shows actual code, not "similar to above" | yes — all four permission blocks shown in full, all heredoc shown in full |
| Worktree pattern matches `feedback_phase_workflow_pattern` | yes — `.worktrees/<name>` + dedicated branch + 2-stage review |
| Glyphs not emoji in PR body, commit, summary lines | yes — Task 5 echoes "Cosign SLSA attestation verifies" without emoji |
| `attest_provider` toggle NOT introduced | confirmed — single hard swap per Approach A |
| PR body has no Claude attribution footer | yes |
