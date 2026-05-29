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

## Onboard sweep (weekly auto-update + auto-onboard)

`.github/workflows/onboard-sweep.yml` runs every Monday at 07:00 UTC (1h after
drift-check) and:

1. **Re-onboards** adopters with `status=behind` or `status=stale-lock` against
   the current catalog major (opens an Onboarding PR on the adopter).
2. **Fresh-onboards** `serverkraken/*` repositories not yet present in
   `docs/onboarding-status.md` (opens an Onboarding PR on the adopter).
3. **Skips** any repo with the GitHub topic `no-serverkraken-onboard`, plus any
   repo where the bot already has an open onboarding PR (`chore/onboard-reusable-workflows`
   or `chore/remove-legacy-workflows` branch).

Adopters with `status=modified` or `status=behind+modified` are NOT touched —
the sweep avoids overwriting hand-edits. Re-onboard those manually after
reviewing the diff in the drift report.

A summary comment is posted on the rolling "Onboarding Drift Report" Issue
after each run; if that Issue doesn't exist, the sweep opens its own
standalone Issue.

### Opting out

Add the GitHub topic **`no-serverkraken-onboard`** to any repository's
Settings → "Topics" field. The next sweep run will skip the repo. Existing
rows in `docs/onboarding-status.md` are left intact for history.

### Dry-run mode

Trigger via `workflow_dispatch` with `dry_run: true` to see what would be
dispatched without opening PRs. Useful before the first scheduled run after
a major catalog change.

### `no-lock` semantics

When sweep enumerate computes a drift status of `no-lock` for a repo listed in `docs/onboarding-status.md`, the repo is bucketed as **update**, not skipped. Background: a repo lands in the status-doc once the onboard atom runs against it, but the actual lock file (`.github/onboard.lock.json`) only lands on the default branch when the atom's PR-A is merged. If PR-A is never merged — common across a catalog major bump where the initial PR's version pin became stale — the repo stays in `no-lock` indefinitely. The sweep's atom is idempotent: it re-renders templates at the current catalog version, force-pushes the existing bot branch, and edits the existing PR (if any) to the current pin. Bucketing `no-lock` as update unblocks that flow.

The `behind+modified` status remains skipped: those repos have local modifications on top of an older lock, and the sweep must not silently overwrite hand edits. Owners of `behind+modified` repos must re-onboard manually or accept the modifications first.

### gomplate is installed in enumerate

The `enumerate` job installs gomplate before the bucketing loop. Gomplate is required by the `stale-lock` render-and-compare detection path inside `scripts/onboard-drift.sh`. Without gomplate, that path is conservative-on-failure and silently returns `clean`, causing stale-lock adopters to be falsely classified and skipped. Installation is idempotent and shared by all per-repo drift-status calls in the same enumerate step.

---

## Repo Defaults

Every onboard run applies a tier of repository-level defaults beyond the rendered workflow files. Source of truth: `catalog/onboard-defaults.json`.

### What gets applied

**Tier 1 — always-overwrite, every sweep:**

- Branch protection on the default branch — PR-gate (0 approvers required), no force-push, no delete, linear history, enforce_admins=false.
- `delete_branch_on_merge=true`.
- Topic `serverkraken-onboarded` added (additive; other topics preserved).

**Tier 2 — first-onboard-only, gated by lock marker:**

- Merge-strategy flags: `allow_squash_merge=true`, `allow_merge_commit=false`, `allow_rebase_merge=false`, `allow_auto_merge=true`.
- Squash-commit title/message format set to `PR_TITLE` / `BLANK`. (`PR_BODY` was the original default; it caused release-please's conventional-commits parser to fail on Renovate PRs whose body contained markdown code blocks with unbalanced parens.)
- Repository toggles: `has_wiki=false`, `has_projects=false`, `has_issues=true`, `has_discussions=false`.

### Marker mechanic

The onboard lock file (`.github/onboard.lock.json`) gains a `defaults_applied_at` field once Tier 2 has been applied. Subsequent sweeps see the marker and skip Tier 2 — owner overrides to comfort fields are respected after the first onboard. Tier 1 ignores the marker and is always reconciled.

To re-baseline Tier 2 on an adopter: clear `defaults_applied_at` from the lock (or delete the field), commit to the default branch, and trigger an onboard. The next sweep will apply Tier 2 fresh and set a new marker.

### Required status checks gap

The catalog default leaves `required_status_checks=null` on branch protection. This is deliberate — the rendered `ci.yml` has profile-dependent job names whose status-check context names cannot be hardcoded without breaking adopters whose check-context names differ.

**Owner action recommended after first green CI run:**
1. Open the adopter's first PR after onboarding.
2. Wait for `ci.yml` to complete with a green run.
3. Settings → Branches → main → Edit → Require status checks → add the contexts the CI run produced (e.g., `ci / secscan / scan`, `ci / lint-go-root`, `ci / test-go-root`).
4. Save.

This makes "merge without CI" structurally impossible.

### Opt-out

Topic `no-serverkraken-onboard` on the adopter repo skips both the rendered-files contract and the defaults contract — they go together. There is no separate defaults-only opt-out.

---

## Repo Defaults

Every onboard run applies a tier of repository-level defaults beyond the rendered workflow files. Source of truth: `catalog/onboard-defaults.json`.

### What gets applied

**Tier 1 — always-overwrite, every sweep:**

- Branch protection on the default branch — PR-gate (0 approvers required), no force-push, no delete, linear history, enforce_admins=false.
- `delete_branch_on_merge=true`.
- Topic `serverkraken-onboarded` added (additive; other topics preserved).

**Tier 2 — first-onboard-only, gated by lock marker:**

- Merge-strategy flags: `allow_squash_merge=true`, `allow_merge_commit=false`, `allow_rebase_merge=false`, `allow_auto_merge=true`.
- Squash-commit title/message format set to `PR_TITLE` / `BLANK`. (`PR_BODY` was the original default; it caused release-please's conventional-commits parser to fail on Renovate PRs whose body contained markdown code blocks with unbalanced parens.)
- Repository toggles: `has_wiki=false`, `has_projects=false`, `has_issues=true`, `has_discussions=false`.

### Marker mechanic

The onboard lock file (`.github/onboard.lock.json`) gains a `defaults_applied_at` field once Tier 2 has been applied. Subsequent sweeps see the marker and skip Tier 2 — owner overrides to comfort fields are respected after the first onboard. Tier 1 ignores the marker and is always reconciled.

To re-baseline Tier 2 on an adopter: clear `defaults_applied_at` from the lock (or delete the field), commit to the default branch, and trigger an onboard. The next sweep will apply Tier 2 fresh and set a new marker.

### Required status checks gap

The catalog default leaves `required_status_checks=null` on branch protection. This is deliberate — the rendered `ci.yml` has profile-dependent job names whose status-check context names cannot be hardcoded without breaking adopters whose check-context names differ.

**Owner action recommended after first green CI run:**
1. Open the adopter's first PR after onboarding.
2. Wait for `ci.yml` to complete with a green run.
3. Settings → Branches → main → Edit → Require status checks → add the contexts the CI run produced (e.g., `ci / secscan / scan`, `ci / lint-go-root`, `ci / test-go-root`).
4. Save.

This makes "merge without CI" structurally impossible.

### Opt-out

Topic `no-serverkraken-onboard` on the adopter repo skips both the rendered-files contract and the defaults contract — they go together. There is no separate defaults-only opt-out.

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

## Per-Adopter Overrides via Repository Variables

The rendered `ci.yml` (and `prerelease.yml`) in every onboarded adopter pulls a small set of tunable inputs from **GitHub repository variables**. Adopters set them at `Settings → Secrets and variables → Actions → Variables tab → New repository variable`. The override is picked up at the next CI run — no code change, no PR, no re-onboarding.

> **Variables, not Secrets.** GitHub's Settings UI has two adjacent tabs. The override mechanism reads from the *Variables* tab. A value created in *Secrets* will not resolve via `vars.*` and the template default will silently apply.

| Variable | Atom Input | Atoms Affected | Default | Type |
|---|---|---|---|---|
| `SK_COVERAGE_THRESHOLD` | `coverage_threshold` | test-go, test-python, test-rust | `80` | number |
| `SK_CGO_ENABLED` | `cgo_enabled` | lint-go, test-go | profile auto-detect | boolean |
| `SK_GO_VERSION` | `go_version` | lint-go, test-go | (read from `go.mod`) | string |
| `SK_PYTHON_VERSION` | `python_version` | lint-python, test-python | (read from `pyproject.toml`) | string |
| `SK_RUST_TOOLCHAIN` | `rust_toolchain` | lint-rust, test-rust | (rustup default) | string |
| `SK_GOLANGCI_LINT_VERSION` | `golangci_lint_version` | lint-go | `v2.12.2` | string |
| `SK_CLIPPY_ARGS` | `clippy_args` | lint-rust | `-D warnings` | string |
| `SK_CARGO_LLVM_COV_VERSION` | `cargo_llvm_cov_version` | test-rust | `0.6.16` | string |
| `SK_SIGN` | `sign` | docker-build, docker-build-multi (release + prerelease) | `true` | boolean |
| `SK_ATTEST` | `attest` | docker-build, docker-build-multi (release + prerelease) | `true` | boolean |
| `SK_SBOM` | `sbom` | docker-build, docker-build-multi (release + prerelease) | `true` | boolean |
| `SK_TRIVY_SEVERITY` | `severity` | trivy-fs (ci.yml secscan), trivy-image (prerelease scan) | `HIGH,CRITICAL` | string |
| `SK_TRIVY_VERSION` | `trivy_version` | trivy-fs, trivy-image | (install-trivy default) | string |
| `SK_FLUTTER_DART_DEFINE_SECRETS` | `dart_define_secret_names` | release-flutter-android (release.yml) | (empty) | string (comma-list of secret names) |

**Org-level layering** (catalog maintainers): set a variable at the organization level (`https://github.com/organizations/serverkraken/settings/variables/actions`) to provide an org-wide default. Repo-level values override org-level. A change to the org var propagates to every non-overriding adopter on the next CI run, no re-rendering required.

**`SK_CGO_ENABLED` override-wins semantic:** the onboard render uses an auto-detected boolean from the adopter's Go source / `go.mod` as the template default. Setting `SK_CGO_ENABLED = true` forces cgo on (auto-detect missed a transitive dep); setting `= false` forces it off (false-positive). Either value wins over the profile-derived default.

**`SK_FLUTTER_DART_DEFINE_SECRETS`:** a comma-separated list of *secret names* (not values) that the rendered `release.yml` forwards to `release-flutter-android`'s `dart_define_secret_names`, which injects each as `--dart-define=NAME=$VALUE` at build time. The secrets themselves must exist at org or repo level; `secrets: inherit` makes them available. Example value: `SUPABASE_URL,SUPABASE_ANON_KEY`. Empty (default) means no dart-defines.

**What's not in this list and why:**

- `fail_on_findings`, `ignore_unfixed` — change CI semantics, belong in code review.
- `runs_on` — catalog-side global, not adopter-tunable.
- `working_directory`, `image_name`, `dockerfile`, `tag`, `prerelease` — per-component or build-derived.
- `paths_ignore` — multi-line strings, awkward in Variables UI.

## Release-Eligibility per Dockerfile

By default, `release.yml` ships **only the bare `Dockerfile` (or `Containerfile`)** to GHCR on release-please-driven releases. Any `Dockerfile.*` / `Containerfile.*` variant (e.g. `Dockerfile.dev`, `Dockerfile.debug`) is **excluded** from release builds and only ships via the manual `prerelease.yml` workflow_dispatch path.

**Prerelease callers (stack-aware).** The renderer emits up to two prerelease workflows:

- `prerelease.yml` — **manual** (`workflow_dispatch`). For docker components it builds a prerelease image (+ trivy scan). For a Flutter app it calls `release-flutter-android` with `create_release: true` and `workflow_dispatch` inputs `version` (empty → auto `<latest>-rc.<run_number>`) and `prerelease` (default `true`); dart-defines come from `vars.SK_FLUTTER_DART_DEFINE_SECRETS`. A Flutter package (no `android/`) renders a no-op.
- `prerelease-on-push.yml` — **automatic** on push to `develop`. Rendered **only** when the repo carries the `sk-prerelease-on-push` topic. Same stack-aware build jobs as `prerelease.yml`, with no manual inputs (Flutter uses the auto-rc version). The trigger branch is baked at render time (`develop`) because GitHub does not evaluate expressions in `on:`.

### Convention

| File matches | `release_eligible` default |
|---|---|
| `Dockerfile` / `Containerfile` (exact) | `true` |
| `Dockerfile.*` / `Containerfile.*` (any extension) | `false` |

### Per-file override

To opt a variant IN for release (e.g. `Dockerfile.worker` for a worker image that ships alongside the main service):

```dockerfile
# Dockerfile.worker
# onboard:release=true
FROM alpine:3.19
...
```

To opt the bare `Dockerfile` OUT of release (e.g. a dev-only repo with no production Dockerfile):

```dockerfile
# Dockerfile
# onboard:release=false
FROM alpine:3.19
...
```

Only the first 5 lines of the file are scanned. Override wins over convention. The annotation extends the existing `# onboard:image=<name>` convention from `read_image_override`.

### If no Dockerfile is release-eligible

The rendered `release.yml` simply omits the docker-build job. release-please + any other release-signal jobs (goreleaser, helm-publish) continue to run. `onboard-detect` emits a `no_release_eligible` warning into the onboard run's step summary so this isn't a silent surprise.

---

## 9. Flutter Atom Set (v4.x+)

Three Flutter `workflow_call` atoms plus a shared composite action:

| Reusable workflow | Purpose |
|---|---|
| `lint-flutter.yml`            | `dart format --set-exit-if-changed` (over `lib test bin integration_test tool`) + `flutter analyze` |
| `test-flutter.yml`            | `flutter test --coverage` + LCOV line-coverage gate (default 80) |
| `release-flutter-android.yml` | pubspec-version sync → APK and/or AAB build → keystore sign → attach to existing GitHub Release |

The shared toolchain (Java + Android SDK + Flutter + `pub get` + optional `build_runner`) lives in `actions/setup-flutter-toolchain/action.yml`. Because that composite is catalog-local, all three atoms mint a catalog-scoped App token and check the catalog out into `.catalog/` first — the same pattern as `lint-python.yml`. Callers therefore MUST pass `secrets: inherit`.

### 9.1 Adopter integration

The onboard renderer auto-detects Flutter components (a `pubspec.yaml` declaring the Flutter SDK) and emits `lint-flutter` + `test-flutter` in `ci.yml`; when the component also has an `android/` dir it emits `release-flutter-android` in `release.yml` and sets release-please `release-type: dart`. Adopters thread dart-defines by setting the `SK_FLUTTER_DART_DEFINE_SECRETS` repo variable (comma-list of secret names — see §Per-Adopter Overrides). The rendered `release.yml` looks like the block below, which also serves as the reference for hand-wiring a repo the renderer has not onboarded:

```yaml
jobs:
  release-please:
    uses: serverkraken/reusable-workflows/.github/workflows/semantic-release.yml@v4
    secrets: inherit

  android-build:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@v4
    with:
      version: ${{ needs.release-please.outputs.tag_name }}    # vX.Y.Z; atom strips the leading v
      dart_define_secret_names: "SUPABASE_URL,SUPABASE_ANON_KEY"
      prerelease: true
    secrets: inherit
```

The adopter sets the four keystore secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`) at org or repo level. `dart_define_secret_names` is a comma-list of secret names forwarded as `--dart-define=NAME=$VALUE`; the values must be free of shell-splitting whitespace (URLs, tokens, JWTs are fine).

### 9.2 Manual / ad-hoc (pre)release builds

The `release-flutter-android.yml` atom carries a `create_release` input. When `true`, the atom creates the GitHub Release at the resolved tag itself (instead of expecting release-please to have made it) and marks it prerelease when `prerelease: true`. With an empty `version`, the atom derives `<latest-tag>-rc.<run_number>` via `git describe`. A `workflow_call` atom can't be triggered by `workflow_dispatch` directly, so adopters add a thin manual caller:

```yaml
# .github/workflows/manual-release.yml
name: manual-release
on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Tag to build (empty → auto <latest>-rc.<run_number>)'
        required: false
        type: string
        default: ''
      prerelease:
        type: boolean
        default: true
permissions:
  contents: write
jobs:
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@v4
    with:
      version: ${{ inputs.version }}
      create_release: true
      prerelease: ${{ inputs.prerelease }}
      dart_define_secret_names: "SUPABASE_URL,SUPABASE_ANON_KEY"
    secrets: inherit
```

This replaces the per-adopter hand-rolled `manual-apk-build.yml` pattern. Available since v4.x (additive input — `create_release` defaults `false`, so existing release-please callers are unaffected).

### 9.3 Self-CI

`self-ci.yml` runs `lint-flutter-happy` + `test-flutter-happy` against `tests/fixtures/flutter-app`. `integration.yml` runs `test-release-flutter-android` (with `create_release: true` + an explicit fixture tag) → `cleanup-flutter-release`: the atom self-creates a throwaway prerelease on the catalog repo, builds+signs the fixture APK, attaches it, then cleanup deletes the release (`--cleanup-tag`). An explicit fixture version is passed so CI never touches the catalog's real `vX` tag namespace; the auto-derive path is exercised by real adopters. The fixture's `android/release.keystore.b64` is a throwaway keystore; the catalog repo holds matching `ANDROID_*` + `GREETING` secrets (alias `catalogtest`, store/key password `catalog-fixture-storepw` — JDK PKCS12 keystores use the store password as the key password).

### 9.4 Out of scope (Phase-2)

- iOS build.
- Play-Store upload — atom gains `upload_to_play_store` + `play_store_track` inputs; the renderer gains a repo-topic-detection branch so adopters opt in via a topic.
- pubspec.yaml commit-back — adopters wire release-please `extra-files` if they want the bump persisted on `main`.
