# Operations Runbook

Operational setup and maintenance procedures for the `serverkraken/reusable-workflows` catalog.

---

## 1. One-time GitHub App Setup

The catalog uses the `serverkraken-release-bot` GitHub App for release authentication. No PAT required; ephemeral 1-hour tokens are minted at runtime.

### 1.1 Create the App

1. Navigate to `https://github.com/organizations/serverkraken/settings/apps` and click **New GitHub App**.
2. Set the following permissions:
   - Contents: Read and write
   - Pull requests: Read and write
   - Issues: Read and write
   - Metadata: Read-only
3. Disable webhooks.
4. Set installation scope to "Only on this account".
5. Note the numeric **App ID** from the app settings page.

### 1.2 Install the App

1. From the app settings page, click **Install App**.
2. Install on the `serverkraken` org with access to **All repositories**.

### 1.3 Configure Org Secrets

Add both secrets as org-level secrets with **Repository access = All private repositories**, so downstream consumers reach them via `secrets: inherit`:

| Secret name                       | Value |
|-----------------------------------|-------|
| `RELEASE_PLEASE_APP_CLIENT_ID`    | GitHub App **Client ID** from the App's settings page (e.g. `Iv23li…`). Since v3.0.0 — older catalog versions used `RELEASE_PLEASE_APP_ID` (numeric). |
| `RELEASE_PLEASE_APP_PRIVATE_KEY`  | Full PEM contents (including `-----BEGIN RSA PRIVATE KEY-----` header/footer) |

---

## 2. Actions Access Policy

The catalog repo must allow other private repos in the org to call its reusable workflows:

```bash
gh api -X PUT \
  /repos/serverkraken/reusable-workflows/actions/permissions/access \
  -f access_level=organization
```

Equivalent UI path: **Settings → Actions → General → Access → "Accessible from repositories in the 'serverkraken' organization"**.

---

## 3. Private-Key Rotation

Private keys are rotated **on suspicion of compromise**, not on a fixed schedule. Multiple keys can coexist on a GitHub App, enabling zero-downtime rotation.

### Rotation procedure

1. Go to the App settings page → **Private keys** → **Generate a private key**.
2. Download the new PEM file.
3. Update the `RELEASE_PLEASE_APP_PRIVATE_KEY` org secret with the new PEM contents.
4. Trigger a release run (or wait for the next natural push to main) and confirm it succeeds.
5. Once one successful run is confirmed, return to **Private keys** and delete the old key.

No PAT-style 90-day calendar reminder is needed — key material doesn't weaken with elapsed time.

---

## 4. Renovate Dashboard

The catalog uses Renovate for dependency updates. Expect:

- **Weekly PRs** (before 6 AM Monday, Europe/Berlin): minor + patch updates for GitHub Actions, grouped.
- **Auto-merge**: minor and patch action updates auto-merge when the integration workflow passes.
- **Major updates**: never auto-merged; require manual review.
- **Fixture paths excluded**: `tests/fixtures/**` is excluded so intentionally outdated CVE/secret fixtures are not updated by Renovate.
- **Trivy CLI**: bumped via a `# renovate: datasource=...` annotation in the workflow YAML; the `customManagers` block in `.github/renovate.json5` handles this.

The Renovate Dependency Dashboard issue is created in this repo and lists pending/blocked updates.

---

## 5. Onboarding Workflow

`onboard.yml` (workflow_dispatch + workflow_call) adopts the catalog into other `serverkraken/*` repos. Reuses the existing `serverkraken-release-bot` App — **no new App setup, permissions, or org secrets required**.

### 5.1 Prerequisites

- `docs/onboarding-status.md` must exist. Initial seed (one-time): `scripts/seed-onboarding-status.sh` (requires local `gh` CLI authenticated against `serverkraken`).
- `serverkraken-release-bot` App is already installed org-wide (see §1.2).
- Catalog `main` branch protection must allow the App actor to push directly (already required by `catalog-release.yml`).

### 5.2 Dispatching an onboarding run

UI: **Actions → onboard → Run workflow**.

| Input | Notes |
|---|---|
| `target_repos` | Comma-separated `serverkraken/<name>` list. Validated against `^serverkraken/[A-Za-z0-9._-]+$`. |
| `language` | `auto` runs detection. Set explicitly to break detection ambiguity. |
| `dry_run` | `true` renders + logs diff, no PRs opened. Use for first-time verification. |
| `pin_version` | What `@version` the rendered templates pin to. Default `v1`. |
| `add_branch_name` / `cleanup_branch_name` | Escape hatches. Default branch names are bot-owned and force-pushed each run. |

### 5.3 What it produces

Per target, up to two PRs:

- **PR A** on `chore/onboard-reusable-workflows`: adds `ci.yml`, `release.yml`, `prerelease.yml`, `cleanup.yml`, `release-please-config.json`, `.release-please-manifest.json`. Always opened when the rendered diff is non-empty.
- **PR B** on `chore/remove-legacy-workflows`: deletes a curated list of legacy workflow names (`semantic-release.yml`, `docker-build.yml`, `trivy.yml`, `trivy.yaml`, `build.yml`, `publish.yml`). Only opened when at least one matches in the target.

### 5.4 Idempotency

Branches are bot-owned and force-reset to `default_branch` HEAD on every run. Empty-diff cases close any open PR on that branch. Re-running on a fully-onboarded repo is a no-op.

### 5.5 Manual acceptance flow (first run after a change to the workflow)

1. Pick one low-risk target (recommend a fresh throwaway repo first, then one of the smallest production repos).
2. Dispatch with `dry_run: true` — verify the step summary's diff matches expectations.
3. Re-dispatch with `dry_run: false` — review PR A in the target repo, merge it, push one `feat:` / `fix:` commit, verify the release-please PR opens and a release runs end-to-end.
4. Merge PR B once a release has run green.
5. Move to bulk: dispatch with a comma-separated list of all candidate repos.

### 5.6 Failure handling

`fail-fast: false` ensures one target's failure doesn't abort the rest. Each target's status is in the run's step summary and `docs/onboarding-status.md`. Re-running with the same inputs is safe and skips already-applied changes.

---

## 6. v2.0.0 — App-Token Catalog Checkout

Adopters pinning `@v2` (or `pin_version: v2` at onboard time) must pass `secrets: inherit` on every atom call. The atoms `trivy-fs.yml`, `trivy-image.yml`, and `docker-build.yml` mint a catalog-scoped App token from the org-level App credentials (see §1.3) and use it to clone the private catalog repo. Without `secrets: inherit`, the call fails immediately with "required secret missing". (Since v3.0.0 the secret name is `RELEASE_PLEASE_APP_CLIENT_ID`; `@v2.x` callers still use the older `RELEASE_PLEASE_APP_ID`.)

### 6.1 Why this exists

GitHub's "Allow other repos to call this workflow" setting governs `uses:` resolution but **not** `actions/checkout` of a private third repo. Before v2.0.0, atoms used the caller's `GITHUB_TOKEN` for the catalog-checkout step, which works only when caller and catalog are the same repo (self-CI) or both are public. Private-to-private adoption required minting a token with read access to the catalog.

### 6.2 App permissions

The catalog-scoped token needs `contents: read`. The existing `serverkraken-release-bot` App already has it. **Additionally**, the App needs `workflows: write` so it can push `.github/workflows/*.yml` into target repos via the onboarding workflow's PR-A flow — verify this is granted on the App settings page if you skipped it during the original v1.0 setup.

### 6.3 Migration

Adopters on `@v1` are unaffected (those atoms don't declare the secrets). To move to `@v2`:

1. Re-dispatch `onboard.yml` against the target with `pin_version: v2`. The rendered templates pin `@v2` and include `secrets: inherit` on every job that calls a catalog atom.
2. Merge the refreshed PR A.
3. The cleanup PR (if applicable) is unchanged — it only deletes files.

### 6.4 What templates ship with `secrets: inherit`

| Template | Calls | `secrets: inherit` |
|---|---|---|
| `ci.yml` | `trivy-fs.yml` | yes (since v2.0.0) |
| `release.yml` | `release.yml` (orchestrator) | yes (always) |
| `prerelease.yml` | `docker-build.yml`, `trivy-image.yml` | yes (since v2.0.0) |
| `cleanup.yml` | `cleanup-images.yml` (no catalog-checkout) | no (not needed) |

### 6.5 Job-level permissions required by adopter templates (since v2.0.4)

The atom callers in `ci.yml`, `prerelease.yml`, and `release.yml` ship with explicit `permissions:` blocks at the job level. This is needed because the workflow_call permission cap is the intersection of caller-grant and called-workflow declaration — without an explicit grant the called workflow can't access scopes like `actions: read` (used by `codeql-action/upload-sarif@v4` for run-metadata telemetry).

| Adopter template job | Permissions granted |
|---|---|
| `ci.yml :: secscan` | `contents: read`, `security-events: write`, `actions: read` |
| `prerelease.yml :: build` | `contents: read`, `packages: write`, `id-token: write`, `attestations: write`, `artifact-metadata: write`, `pull-requests: write` |
| `prerelease.yml :: scan` | `contents: read`, `security-events: write`, `packages: read`, `actions: read` |
| `release.yml :: release` | union of all of the above (orchestrator runs every sub-atom) |

These are the maxima the atoms ever request; if you tighten any of them, the corresponding feature breaks (e.g. dropping `security-events: write` silently disables SARIF upload).

---

## 7. Drift Audit

Weekly central audit that flags adopters whose rendered onboarding files have either fallen behind the current catalog major or been hand-edited away from what we'd render today.

### 7.1 What it does

`.github/workflows/drift-check.yml` runs every Monday at 06:00 UTC (plus `workflow_dispatch` for ad-hoc runs). For each adopter listed as onboarded in `docs/onboarding-status.md`:

1. Mint an App token scoped to that target repo, check it out.
2. Run `actions/onboard-drift` which compares the SHA-256 hashes recorded in `target/.github/onboard.lock.json` against the working-tree files at the same paths.
3. Also compare the lock's `catalog_version` against the catalog's current major (derived from `git describe --tags --abbrev=0`).

All results land in a single rolling Issue in this repo titled exactly `Onboarding Drift Report`. The Issue body is overwritten on each run — no Issue list spam from a weekly cron.

### 7.2 Status taxonomy

| Status | Meaning | Remediation |
|---|---|---|
| `clean` | Hashes match + lock version equals current major | None |
| `modified` | At least one rendered file's hash differs (hand-edited or hand-deleted) | Re-dispatch `onboard.yml` against the target to refresh, then review the diff |
| `behind` | Lock's `catalog_version` is older than current major (e.g. lock `v2`, catalog `v3`) | Re-dispatch `onboard.yml` with `pin_version: v3` (or current major) |
| `behind+modified` | Both | Re-dispatch `onboard.yml`; the bot PR will reset hand-edits and bump the pin in one shot |
| `no-lock` | `.github/onboard.lock.json` is missing — adopter was onboarded before Phase 3 added the lock file | Re-dispatch `onboard.yml` once to write the lock |
| `error` | Drift action failed (target inaccessible, malformed lock, …) | Click through to the matrix job for the failing target |

### 7.3 Manual dispatch

```bash
gh workflow run drift-check.yml --repo serverkraken/reusable-workflows
# or, to scope to specific repos without touching the status doc:
gh workflow run drift-check.yml \
  --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/blupod-ui,serverkraken/flow
```

### 7.4 What it does NOT do

- No auto-update PRs. Drift is read-only audit; remediation is always a manual `onboard.yml` dispatch — that keeps the human in the loop for renames, image-name overrides, and component-shape changes that detection might re-classify.
- No comparison against a hypothetical re-render at catalog HEAD ("what would change if we re-rendered today?"). That's effectively what `onboard.yml` dispatch does, so duplicating it in drift-check would be redundant.

### 7.5 Reproducibility guarantee

`scripts/onboard-drift.sh`'s comparison only works because the renderer (`scripts/onboard-render.sh` + gomplate templates) is deterministic for any given `(profile.json, pin)` tuple. A bats test (`tests/shell/onboard-drift.bats :: byte-reproducible`) guards this — re-rendering the fixture twice produces byte-identical files, hash-matching the lock. If a future change to the renderer ever breaks this guarantee, drift-check would flag every adopter as `modified` until they re-onboard.

---

## 8. Lint and test atoms

Per-language lint and test atoms callable via `workflow_call`. Each atom accepts a `runs_on` input. Build-heavy atoms (`lint-go`, `test-go`, `lint-rust`, `test-rust`) default to `[self-hosted, Linux, X64]`; the lighter atoms (`lint-python`, `test-python`, `lint-helm`) default to `[self-hosted, Linux]`. Callers without a matching runner pool can override to `ubuntu-latest`.

| Atom                  | Purpose                                            |
|-----------------------|----------------------------------------------------|
| `lint-go.yml`         | `go vet` + golangci-lint                           |
| `test-go.yml`         | `go test` + coverage gate (default ≥ 80 %)         |
| `lint-python.yml`     | ruff check + format + mypy (poetry/uv/pip auto)    |
| `test-python.yml`     | pytest + coverage gate ≥ 80 % (poetry/uv/pip auto) |
| `lint-rust.yml`       | `cargo fmt --check` + `cargo clippy -D warnings`   |
| `test-rust.yml`       | `cargo test` + `cargo-llvm-cov` coverage gate      |
| `lint-helm.yml`       | `helm lint` + `ct lint`                            |

The test atoms expose a `coverage_threshold` input (default `80`) so consumers can tighten or loosen the gate per repo. The Python atoms reuse the `actions/setup-python-deps` composite to auto-detect Poetry / uv / pip-bare project layouts.
