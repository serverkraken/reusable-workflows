# Catalog Checkout via App Token — Design

**Date:** 2026-05-16
**Status:** Draft (V1-hard chosen by user)
**Catalog version at time of writing:** `v1.2.0` (after merge of #9)
**Target version:** `v2.0.0` (breaking)

---

## 1. Problem

When a private adopter repo calls a reusable workflow from `serverkraken/reusable-workflows` (also private), the atoms internally do:

```yaml
- uses: actions/checkout@v6
  with:
    repository: serverkraken/reusable-workflows
    ref: ${{ github.workflow_sha }}
    path: .catalog
```

without an explicit `token:`. The default `${{ github.token }}` is the **caller's** `GITHUB_TOKEN`, scoped to the caller's repo only. Cross-private-repo checkout fails with `Repository not found`.

Surfaced in `serverkraken/blupod-ui` run [25970095764](https://github.com/serverkraken/blupod-ui/actions/runs/25970095764) after `onboard.yml` shipped PR A. The catalog `Actions → Access` setting (org-wide) governs `uses: org/repo/.github/workflows/x.yml` resolution but NOT `actions/checkout` of a private third repo.

Affects every atom with the catalog-checkout pattern: `docker-build.yml` (4 jobs), `trivy-fs.yml` (1 job), `trivy-image.yml` (1 job). Latent until the first cross-private-private adoption.

## 2. Decision

**V1-hard: every atom that does catalog-checkout mints a catalog-scoped App token from declared (required) secrets and injects it into `actions/checkout`.**

The catalog bumps to `v2.0.0`. Adopters pinning `@v1` continue to work on `v1.2.0` (broken cross-private-private — unchanged from today). Adopters who migrate to `@v2` get the working path.

## 3. Atom contract changes

For each of `trivy-fs.yml`, `trivy-image.yml`, `docker-build.yml`:

```yaml
on:
  workflow_call:
    inputs: ...
    secrets:                                # NEW
      release_please_app_id:
        required: true
        description: 'GitHub App ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'
```

Per job (each job that has catalog-checkout):

```yaml
steps:
  - uses: actions/create-github-app-token@v2  # NEW (per job)
    id: catalog-token
    with:
      app-id: ${{ secrets.release_please_app_id }}
      private-key: ${{ secrets.release_please_app_private_key }}
      owner: serverkraken
      repositories: reusable-workflows

  - uses: actions/checkout@v6
    with:
      repository: serverkraken/reusable-workflows
      ref: ${{ github.workflow_sha }}
      token: ${{ steps.catalog-token.outputs.token }}   # NEW
      path: .catalog
  # ... rest unchanged
```

Note: the same App that release-please uses is reused. No new App setup, no new org secret, no new permission (the App has `contents: read` on every repo in the org by §1.1 of operations.md plus the newly-added Workflows permission).

## 4. Orchestrator (`release.yml`) propagation

The orchestrator declares the App secrets already (`required: true`) and inherits them to `semantic-release.yml`. After the change, also needs:

```yaml
docker-build:
  uses: ./.github/workflows/docker-build.yml
  secrets: inherit                          # NEW
  with: ...

trivy-image:
  uses: ./.github/workflows/trivy-image.yml
  secrets: inherit                          # NEW
  with: ...
```

## 5. Adopter template changes

Templates today:

| Template | Calls | Currently has `secrets: inherit`? | Needed? |
|---|---|---|---|
| `ci.yml` | `trivy-fs.yml` | no | **yes** (NEW) |
| `release.yml` | `release.yml` (orchestrator) | yes | unchanged |
| `prerelease.yml` | `docker-build.yml`, `trivy-image.yml` | no | **yes** (NEW) |
| `cleanup.yml` | `cleanup-images.yml` (no catalog-checkout) | no | unchanged |

Cleanup-images is unchanged: it doesn't use catalog-checkout (it interacts with the GHCR API directly via the App actor's API, not the catalog repo).

## 6. Self-CI (`integration.yml`)

The integration workflow calls atoms directly without `secrets: inherit`. After the change, each atom call needs `secrets: inherit`:

```yaml
test-docker-build:
  uses: ./.github/workflows/docker-build.yml
  secrets: inherit                          # NEW
  with: ...
```

Three jobs affected: `test-docker-build`, `test-docker-build-cve`, `test-trivy-fs-happy`, `test-trivy-fs-failure`, `test-trivy-image-happy`, `test-trivy-image-cve`. `test-cleanup-images` does NOT need this. `test-onboard-dry-run` already inherits.

## 7. Migration path for adopters

- `blupod-ui` is the only adopter and currently has an OPEN PR A pinning `@v1`. After v2.0.0 ships:
  - Re-dispatch `onboard.yml` with `pin_version: v2` against `serverkraken/blupod-ui`. Idempotent: force-pushes new template content to the same branch, refreshes the PR body. PR A now renders templates pinning `@v2` and `secrets: inherit` is present.
  - Adopter merges the refreshed PR A. New flow works end-to-end.
- Future adopters: `onboard.yml` defaults to `pin_version: v1`. Operators should set `pin_version: v2` explicitly until the default is bumped.

## 8. Versioning impact

- This catalog releases as `v2.0.0`.
- The breaking-change footer (`BREAKING CHANGE:` or `feat!:`) on the merge commit drives release-please into a major bump.
- The floating tag `v1` stays at `v1.2.0`; `v2` is created and points at `v2.0.0`.
- Adopters pinning `@v1` see no change; adopters pinning `@v2` get the new behavior.

## 9. Out of scope

- No new App setup (reuses existing `serverkraken-release-bot` org-wide install).
- No PAT alternative.
- No new bats test (this is YAML plumbing; covered by self-CI which exercises the changed code paths after the change).
- No backport of the fix to `@v1` — `v1` remains as-is. Operators wanting the App-token path migrate to `@v2`.

## 10. Decisions log

| ID | Decision | Rationale |
|---|---|---|
| AT-1 | V1-hard: secrets `required: true`, major bump | User-chosen. Sauberer Contract; the App secret is the only sane way to call atoms across private repos, so requiring it explicitly is honest. |
| AT-2 | Reuse `RELEASE_PLEASE_APP_*` secrets (not a new secret pair) | Same App, same permissions, same install scope. Renaming would be ceremony for no benefit. |
| AT-3 | Mint a fresh token per job, not per workflow run | `actions/create-github-app-token@v2` returns a 1h token. Jobs can run hours apart in matrix builds; per-job mint keeps tokens fresh and per-job-scoped. |
| AT-4 | Scope tokens to `repositories: reusable-workflows` only | Narrow blast radius — token can read catalog, can't write anywhere. |
| AT-5 | `cleanup-images.yml` unchanged | Doesn't use catalog-checkout. |
| AT-6 | No new bats test | Pure YAML/orchestration; self-CI integration covers it. |
| AT-7 | Adopter migration via onboard.yml re-dispatch | Idempotent and already implemented; no new tool needed. |
