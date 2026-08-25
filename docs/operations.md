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
| `pin_version` | What `@version` the rendered templates pin to. Default `v4` on `next`. |
| `use_go_cli` | Default `true`. Uses `sk-workflows` for detection, rendering, and repo defaults. Set `false` only as Bash rollback during a suspected Go regression. |
| `add_branch_name` / `cleanup_branch_name` | Escape hatches. Default branch names are bot-owned and force-pushed each run. |
| `target_repo` | The repo to onboard. **The same expression feeds both `actions/checkout` and `TARGET_REPO`** (`onboard.yml:271` and `:445`), so the identity the scripts render *for* is always the checkout they render *from* — they cannot diverge through this workflow. Invoking `scripts/onboard-*.sh` by hand with mismatched values is outside that contract (audit H-1). |
| `rendered_against` | Full catalog tag recorded in the lock (e.g. `v4.18.4`). Empty → falls back to `pin_version`. The weekly sweep compares this field against `git describe --tags --abbrev=0` to spot stale bot PRs. |

### 5.3 What it produces

Per target, up to two PRs:

- **PR A** on `chore/onboard-reusable-workflows`: adds `ci.yml`, `release.yml`, `prerelease.yml`, `cleanup.yml`, `release-please-config.json`, `.release-please-manifest.json` — plus `ci-android.yml` for Flutter apps with an `android/` directory. Always opened when the rendered diff is non-empty.
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

### 5.7 Go engine and rollback

On `next`, onboarding uses the Go `sk-workflows` CLI by default for detect, render, and repo-default application. The workflow installs the CLI once per target job via `actions/setup-sk-workflows`; the composite actions still keep Bash implementations as fallback during the v4 rollout window.

If a Go-specific regression is suspected, re-run the same dispatch with `use_go_cli: false`. Keep the failed Go run URL and the Bash rerun URL in the incident or PR so the parity gap can be fixed before rollout continues. Do not remove Bash fallback during v4; removal needs a separate major-version plan.

Repos with `.github/onboard.yml` require `use_go_cli: true` — see § 11.4.

---

## 6. v2.0.0 — App-Token Catalog Checkout

Adopters pinning `@v2` (or `pin_version: v2` at onboard time) must pass `secrets: inherit` on every atom call. The atoms `trivy-fs.yml`, `trivy-image.yml`, `docker-build.yml`, and `e2e-kind.yml` mint a catalog-scoped App token from the org-level App credentials (see §1.3) and use it to clone the private catalog repo. Without `secrets: inherit`, the call fails immediately with "required secret missing". (Since v3.0.0 the secret name is `RELEASE_PLEASE_APP_CLIENT_ID`; `@v2.x` callers still use the older `RELEASE_PLEASE_APP_ID`.)

### 6.1 Why this exists

GitHub's "Allow other repos to call this workflow" setting governs `uses:` resolution but **not** `actions/checkout` of a private third repo. Before v2.0.0, atoms used the caller's `GITHUB_TOKEN` for the catalog-checkout step, which works only when caller and catalog are the same repo (self-CI) or both are public. Private-to-private adoption required minting a token with read access to the catalog.

### 6.2 What the App private key reaches, and why

`secrets: inherit` hands the **App private key** — not just a minted token — to
every atom that declares those secrets, and each mints its own scoped token.
The minted tokens are correctly scoped; the key is not. Anyone who can move the
`v4` tag can therefore exfiltrate the key and mint tokens for every repo the
App is installed on.

This is the generic shape of any *App + `secrets: inherit`* architecture, and
it presupposes that the catalog itself is compromised. Two things already
narrow it:

- `v4` moves only through `semantic-release.yml`, which tags the released
  commit (verified read-back since v4.18.2, not the checked-out HEAD).
- Adding a new consumer of the key is a deliberate decision. `cleanup-images.yml`
  was left **without** a catalog checkout for exactly this reason — the fix for
  its probe (audit D-12) stayed inline rather than gaining an App-token mint.

Closing it properly means minting once centrally and passing the *token*
downward, which changes the calling contract of every atom. It is tracked as
audit **D-1** and deliberately not fixed alongside smaller items.

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
| `stale-lock` | Hashes match, but a re-render at current catalog HEAD would produce different files — also when `.github/onboard.yml` changed since the last render | Re-dispatch `onboard.yml` to pick up the template (or manifest) change |
| `error` | Drift could not be evaluated: the drift action failed (target inaccessible, malformed lock), or the re-render itself broke (detect or render exited non-zero — `render_error` names the phase). Not a clean bill of health, and never reported as `clean` | Read `render_error` in the report row; click through to the matrix job for the failing target |

### 7.3 Manual dispatch

```bash
gh workflow run drift-check.yml --repo serverkraken/reusable-workflows
# or, to scope to specific repos without touching the status doc:
gh workflow run drift-check.yml \
  --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/blupod-ui,serverkraken/flow

# force Bash fallback for a suspected Go drift regression:
gh workflow run drift-check.yml \
  --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/blupod-ui \
  -f use_go_cli=false
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

Sweep dispatches `onboard.yml`, which defaults to the Go CLI on `next`. For
rollback testing, run the sweep manually with `use_go_cli: false`; scheduled
runs should stay on Go unless the current release is under incident rollback.

### `no-lock` semantics

When sweep enumerate computes a drift status of `no-lock` for a repo listed in `docs/onboarding-status.md`, the repo is bucketed as **update**, not skipped. Background: a repo lands in the status-doc once the onboard atom runs against it, but the actual lock file (`.github/onboard.lock.json`) only lands on the default branch when the atom's PR-A is merged. If PR-A is never merged — common across a catalog major bump where the initial PR's version pin became stale — the repo stays in `no-lock` indefinitely. The sweep's atom is idempotent: it re-renders templates at the current catalog version, force-pushes the existing bot branch, and edits the existing PR (if any) to the current pin. Bucketing `no-lock` as update unblocks that flow.

The `behind+modified` status remains skipped: those repos have local modifications on top of an older lock, and the sweep must not silently overwrite hand edits. Owners of `behind+modified` repos must re-onboard manually or accept the modifications first.

### gomplate is installed in enumerate

The `enumerate` job installs gomplate before the bucketing loop. Gomplate is required by the `stale-lock` render-and-compare detection path inside `scripts/onboard-drift.sh`. Without it, the re-render fails and the target reports `error` with the phase in `render_error`; the sweep buckets it as skipped, visibly and with the reason attached. That used to be a silent `clean`, which classified stale-lock adopters as healthy and dropped them from the report entirely — the installation is what keeps the check meaningful rather than what keeps it quiet. Installation is idempotent and shared by all per-repo drift-status calls in the same enumerate step.

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

Per-language lint and test atoms callable via `workflow_call`. Each atom accepts a `runs_on` input. Build-heavy atoms (`lint-go`, `test-go`, `lint-rust`, `test-rust`) default to `[self-hosted, Linux, X64]`; the lighter atoms (`lint-python`, `test-python`, `lint-helm`) default to `[self-hosted, Linux]`. Callers without a matching runner pool can override to `ubuntu-latest`. `e2e-kind` (below) is the heaviest atom in this set — it defaults to `[self-hosted, Linux, X64, performance]`, since it runs a full kind cluster plus CNI inside the runner pod's dind sidecar.

| Atom                  | Purpose                                            |
|-----------------------|----------------------------------------------------|
| `lint-go.yml`         | `go vet` + golangci-lint                           |
| `test-go.yml`         | `go test` + coverage gate (default ≥ 80 %)         |
| `lint-python.yml`     | ruff check + format + mypy (poetry/uv/pip auto)    |
| `test-python.yml`     | pytest + coverage gate ≥ 80 % (poetry/uv/pip auto) |
| `lint-rust.yml`       | `cargo fmt --check` + `cargo clippy -D warnings`   |
| `test-rust.yml`       | `cargo test` + `cargo-llvm-cov` coverage gate      |
| `lint-helm.yml`       | `helm lint` + `ct lint`                            |
| `e2e-kind.yml`        | Consumer-owned kind e2e script; diagnostics artifact on failure; guaranteed cluster cleanup |
| `version-badges.yml`  | Static SVG version badges + Component/Version/Tag table from the release-please manifest, committed to the repo (no external services) |

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
| `SK_KUSTOMIZE_VERSION` | `kustomize_version` | kube-validate | (composite default) | string |
| `SK_KUBECONFORM_VERSION` | `kubeconform_version` | kube-validate | (composite default) | string |
| `SK_KUBE_LINTER_VERSION` | `kube_linter_version` | kube-lint | (composite default) | string |
| `SK_GITLEAKS_VERSION` | `gitleaks_version` | secret-scan | (composite default) | string |
| `SK_FLUTTER_DART_DEFINE_SECRETS` | `dart_define_secret_names` | release-flutter-android (release.yml, prerelease.yml, prerelease-on-push.yml) | (empty) | string (comma-list of secret names) |

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
- `ci-android.yml` — **PR-time** Android compile gate. Rendered **only** when a component has `release_signals.flutter_android` (Flutter app with `android/`). Calls `build-flutter-android` (`flutter build apk --debug`, unsigned) and is paths-filtered to `android/**`, `pubspec.yaml`, `pubspec.lock` — pure Dart/docs PRs skip it entirely. Because the check does not appear on filtered PRs, it must **not** be configured as a required branch-protection check.

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

Four Flutter `workflow_call` atoms plus a shared composite action:

| Reusable workflow | Purpose |
|---|---|
| `lint-flutter.yml`            | `dart format --set-exit-if-changed` (over `lib test bin integration_test tool`) + `flutter analyze` |
| `test-flutter.yml`            | `flutter test --coverage` + LCOV line-coverage gate (default 80) |
| `build-flutter-android.yml`   | PR-time Android compile gate: `flutter build apk --<build_mode>` (default `debug`, unsigned) — no release semantics |
| `release-flutter-android.yml` | pubspec-version sync → APK and/or AAB build → keystore sign → attach to existing GitHub Release |

The shared toolchain (Java + Android SDK + Flutter + `pub get` + optional `build_runner`) lives in `actions/setup-flutter-toolchain/action.yml`. Because that composite is catalog-local, all four atoms mint a catalog-scoped App token and check the catalog out into `.catalog/` first — the same pattern as `lint-python.yml`. Callers therefore MUST pass `secrets: inherit`.

### 9.1 Adopter integration

The onboard renderer auto-detects Flutter components (a `pubspec.yaml` declaring the Flutter SDK) and emits `lint-flutter` + `test-flutter` in `ci.yml`; when the component also has an `android/` dir it emits `release-flutter-android` in `release.yml` and sets release-please `release-type: dart`. It also renders a paths-filtered `ci-android.yml` calling `build-flutter-android` for PR-time Android compile gates (see the `ci-android.yml` bullet in the Prerelease callers section above). Adopters thread dart-defines by setting the `SK_FLUTTER_DART_DEFINE_SECRETS` repo variable (comma-list of secret names — see §Per-Adopter Overrides). The rendered `release.yml` looks like the block below, which also serves as the reference for hand-wiring a repo the renderer has not onboarded:

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

The `release-flutter-android.yml` atom carries a `create_release` input. When `true`, the atom creates the GitHub Release at the resolved tag itself (instead of expecting release-please to have made it) and marks it prerelease when `prerelease: true`. With an empty `version`, the atom derives `<latest>-rc.<run_number>`, where `<latest>` is the newest exact `vX.Y.Z` tag (rolling `vX`/`vX.Y` and non-version tags are ignored; without a usable tag it falls back to `0.0.0`). A `workflow_call` atom can't be triggered by `workflow_dispatch` directly, so adopters add a thin manual caller:

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

## 10. GitOps Atom Set (v4.x+)

Three reusable atoms validate a GitOps repository's Kubernetes manifests and scan for leaked secrets. They install their CLIs as pinned, Renovate-managed binaries (`setup-kube-toolchain`, `install-kube-linter`, `install-gitleaks`), so no third-party setup actions are involved. Version pins are overridable via the `SK_KUSTOMIZE_VERSION` / `SK_KUBECONFORM_VERSION` / `SK_KUBE_LINTER_VERSION` / `SK_GITLEAKS_VERSION` repository variables (each: version pin for the corresponding tool; empty → catalog composite default).

| Atom | Does | Key inputs | Output |
|---|---|---|---|
| `kube-validate` | `kustomize build` every kustomization tree + `kubeconform` every standalone manifest under each root. Optional in-tree SOPS decryption via ksops (`sops: true`, requires the `sops_age_key` secret). | `manifests_paths`, `kustomize_args`, `schema_locations`, `skip_kinds`, `strict`, `sops` | pass/fail |
| `kube-lint` | `kube-linter lint → SARIF`; counts findings, uploads to code-scanning, gates on count. Empty `config_path` → catalog baseline (`configs/kube-linter.yaml`, upstream defaults). | `manifests_path`, `config_path`, `fail_on_findings`, `upload_sarif` | `findings_count` |
| `secret-scan` | `gitleaks detect → SARIF`; counts findings, uploads to code-scanning, gates on count. | `config_path`, `fail_on_findings`, `upload_sarif`, `fetch_depth`, `no_git`, `scan_path` | `findings_count` |

**`secret-scan` is general-purpose** — callable by any adopter, not just GitOps repos. By default it is git-history-aware: a `pull_request` event scans the PR diff (`base..head`), a `push` event scans the tip commit, and a manual/scheduled run scans full history (so `fetch_depth: 0` is the default). Setting `no_git: true` switches it to a filesystem scan of `scan_path` (gitleaks `--no-git`), used for one-off directory scans and deterministic fixture tests where git history is irrelevant.

All three mint a catalog-scoped App token (`secrets: inherit` covers it) to check out the catalog's composite actions, exactly like the existing security atoms. SARIF upload is auto-skipped on forks.

> **ksops decryption is not exercised in catalog self-CI** — committing a decryptable age key to the catalog would itself be a secret leak. The happy integration path runs `kube-validate` with `sops: false` against plaintext fixtures; the real ksops path is validated at adopter-onboard time against repos that hold the real `SOPS_AGE_KEY` and encrypted trees.

---

## 11. Adopter Manifest

Detection can infer language, Dockerfiles, and chart presence from the file
system, but not everything an adopter needs to declare. Some repos —
mailstack is the reference case — carry a shape detection cannot express on
its own: a root Go module with images built from sub-directories, image
names that don't follow the `$REPO-<dir>` convention, a chart that lives
next to code instead of alone, an e2e suite, or a list of who consumes the
repo's images. For those repos, drop an adopter manifest (`.github/onboard.yml`)
into the target repo before dispatching onboarding.

### 11.1 When you need it

Reach for the adopter manifest (`.github/onboard.yml`) when any of the following apply:

- **Root language marker + sub-directory Dockerfiles.** A `go.mod` (or
  equivalent) at the repo root plus `images/<name>/Dockerfile` sub-directories
  is exactly the shape detection cannot resolve on its own — see § 11.4.
- **Non-default image names or build contexts.** The derived name is
  `$REPO-<dir>`; if the org's GHCR package is named differently (e.g.
  `serverkraken/mailstack/postfix`), or a Dockerfile needs a build context
  other than its component directory (e.g. `COPY images/<name>/…` from the
  repo root), declare it explicitly.
- **A Helm chart next to application code.** Without a manifest, `type: helm`
  (or a component-level marker) is how a chart directory that shares a repo
  with Go/Python/Rust/Flutter code gets recognized and gets its own
  `lint-helm` + dry-run `helm-publish` jobs and release-please package.
- **An e2e suite.** There is no file-system signal for "run this kind-based
  e2e script on a schedule" — `workflows.e2e` is the only way in. The
  rendered `e2e.yml` runs on the optional schedule, on `workflow_dispatch`
  and on full-semver tag pushes (`v*.*.*`) only — the floating `v1`/`v1.2`
  tags and component tags (`postfix-v1.2.0`) do not trigger it — and it is
  serialised through one `concurrency` group (`e2e-kind`, no
  cancel-in-progress): a kind run claims the performance pool exclusively
  enough that parallel runs starve each other.
- **Declaring GitOps consumers.** Repos that other repos deploy from (via
  Renovate-managed image references) can inventory those consumers so they
  show up in the onboarding PR body and `docs/onboarding-status.md`.

A repo with none of the above onboards exactly as before — the manifest is
opt-in and entirely absent from every non-monorepo adopter today.

### 11.2 Schema v1

```yaml
schema: 1
components:                      # optional; absent → auto-detect as today
  - path: .
    language: go                 # optional; overrides detection
    dockerfiles:                 # optional; in addition to those found in `path`
      - path: images/tools/Dockerfile
        image: serverkraken/mailstack/tools
        context: .                           # optional, repo-relative; default = component path
        platforms: linux/amd64,linux/arm64   # optional; default = atom default
        scanners: vuln,secret                # optional; default = trivy-image default
        severity: CRITICAL                   # optional; default = SK_TRIVY_SEVERITY or HIGH,CRITICAL
        upload_sarif: false                  # optional; default = trivy-image default
        fail_on_findings: false              # optional; default = trivy-image default (true)
        release: true                        # optional; default by file name
  - path: images/postfix
    image: serverkraken/mailstack/postfix    # shorthand when `path` holds exactly one Dockerfile
    context: .                               # shorthand form of the same field
  - path: images/dovecot
    image: serverkraken/mailstack/dovecot
    context: .
  - path: images/unbound
    image: serverkraken/mailstack/unbound
    context: .
  - path: images/fangfrisch
    image: serverkraken/mailstack/fangfrisch
    context: .
  - path: images/olefy
    image: serverkraken/mailstack/olefy
    context: .
  - path: charts/mailstack
    type: helm
    unittest: true
    app_version: true            # optional; keep Chart.yaml's appVersion in step
workflows:                       # optional
  keep:                          # workflow files the adopter maintains itself
    - quality.yml
  e2e:
    script: test/e2e/run.sh
    schedule: "0 3 * * *"        # optional; dispatch + full-semver tag push (v*.*.*) are always on
release:                         # optional
  dispatch_trigger: true         # adds `workflow_dispatch: {}` to release.yml
  badges: true                   # version-badges job after each release (README markers required)
  chart_pins:                    # optional; pin the repo's own images in its chart
    values: charts/app/values.yaml
    key: images.{name}.tag       # optional; {name} = image basename
gitops:                          # optional; list of consuming repos
  - repo: serverkraken/homelab-mail-nue
    scope:                       # optional file globs; default = whole repo
      - kubernetes/apps/mailstack/**
      - bootstrap/templates/kubernetes/apps/mailstack/**
    mode: renovate               # default; `push` reserved, rejected in v1
```

Semantics:

- **`components:` present ⇒ authoritative and complete.** No mixing with
  auto-detected components (otherwise nobody can tell where a component
  came from). Inside a component, absent fields are still detected:
  languages, Dockerfiles in `path` itself, `release_signals` (goreleaser,
  nested `Chart.yaml`, Flutter), `cgo`.
- **Build context defaults to the component path** and can be overridden
  per component (`context`, shorthand) or per Dockerfile
  (`dockerfiles[].context`), repo-relative. All Dockerfiles of one
  component must resolve to the same context — `docker-build-multi` has a
  single shared `context` — and detect rejects mixed contexts. mailstack
  sets `context: .` on every image component because its Dockerfiles
  `COPY images/<name>/…` from the repo root.
- **`platforms` is per component, not per image.** It may be written on the
  component (shorthand) or on individual `dockerfiles[]` entries, but all
  Dockerfiles of one component must end up with the same value — the
  `docker-build-multi` atom takes a single `platforms` input and forwards it
  to every image it builds. Detect rejects a mismatch (including "explicit
  list on one file, atom default on another") with
  `Dockerfiles of component <path> must share one platforms value`. The
  value must be a comma-separated `os/arch[/variant]` list
  (`linux/amd64,linux/arm64/v8`); leave it out to take the atom's default,
  which is what nearly every adopter wants.
- **`scanners` / `upload_sarif` configure the per-image scan job** and are
  forwarded verbatim to `trivy-image`. Both are per Dockerfile (component
  shorthand available) and both are emitted **only when set**, so an adopter
  that takes the atom's defaults keeps rendering byte-identically. `scanners`
  must be a comma-separated subset of `vuln`, `secret`, `misconfig`,
  `license`, without repeats. Every release-eligible Dockerfile gets its own
  build and its own scan job, so the fields apply on any component. (Through
  v4.16.x a component with several images rendered as a single
  `docker-build-multi` call, which exposes no per-image outputs and therefore
  carried no scan job at all — those images shipped unscanned.) Real case:
  wartung's ansible image ships the
  `kubernetes` Ansible collection, whose bundled example manifests produce 41
  unfixable HIGH `misconfig` findings (KSV-0014, KSV-0118); `scanners:
  vuln,secret` is what keeps that image scannable at all.
- **`severity` / `fail_on_findings` configure the GATE**, not the scan. The
  distinction matters: `scanners` decides what is looked for, these two decide
  which findings count and whether they stop the release. Same per-Dockerfile
  scope, same component shorthand, same emitted-only-when-set rule as above.
  `severity` must be a comma-separated subset of `UNKNOWN`, `LOW`, `MEDIUM`,
  `HIGH`, `CRITICAL`, uppercase and without repeats — trivy accepts nothing
  else, and a threshold that silently differs from what the manifest reads
  would be worse than a render-time error.

  A manifest `severity` **wins over the repo-wide `SK_TRIVY_SEVERITY` var**:
  it was written for that one image, and a repo-wide value overriding it would
  defeat the reason it exists. Images without it keep rendering the var
  expression unchanged.

  Real case: mailstack's `crowdsec-sync` builds `FROM
  crowdsecurity/crowdsec`, and the upstream image's own binaries carry 62
  distinct CVEs (19 CRITICAL on v1.6.8, still 2 on v1.7.8) in the Go stdlib
  and `golang.org/x/*` they were compiled against. Nothing in that Dockerfile
  can fix them, `ignore_unfixed` does not help (the fixes exist upstream, they
  are just not in the image), and the repo's own build stage is clean. Scanning
  it is still worth it — the findings belong in code-scanning — but gating the
  mail stack's releases on someone else's build schedule is not. That is
  `fail_on_findings: false`, optionally with `severity: CRITICAL` to keep the
  step summary focused.
- **`app_version: true` keeps a chart's `appVersion` in step with its chart
  version.** release-please's `helm` strategy rewrites only `version:` —
  mailstack's chart reached 1.10.0 while its `appVersion` still read `v1.6.5`,
  and that stale value is what every resource's `app.kubernetes.io/version`
  label and the install notes show. The flag renders an `extra-files` entry so
  the generic updater picks up the `x-release-please-version` marker on the
  `appVersion` line; the marker has to be there, which is why this is opt-in
  rather than the default for every chart component.
- **`workflows.keep` protects hand-maintained workflows from the legacy scan.**
  The scan treats every workflow file it did not render as legacy, and its
  signatures misfire: wartung's `quality.yml` was proposed for deletion as
  "go test pipeline; replaced by test-go.yml" because it contains
  `go test -race`, although it also runs ansible-lint, yamllint, shellcheck
  and an Ansible test suite the catalog has no atom for. Deleting it would
  have been worse than noise — the file is a required status check, so its
  removal would have blocked every future merge. List such files here.
- **`release.chart_pins` moves the chart's own image pins after a release.**
  A repo whose chart deploys images built in the same repo has to bump those
  pins on every image release. Renovate cannot: its `helm-values` manager only
  recognises an `image:` key, so an `images.<name>.{repository,tag}` layout is
  invisible to it — mailstack accumulated three "Image-Pins nachziehen"
  commits by hand in one day before this existed. The rendered
  `chart-image-pins` job `needs:` every build job, so a pin can only move once
  the image is actually pushed; a pin bumped ahead of a ~25 min multi-arch
  build is what once left the cluster in ImagePullBackOff behind an Argo hook
  finalizer. The commit is a `fix(chart):` **without** `[skip ci]`, so
  release-please cuts the chart release that publishes the new pins. A key
  that does not exist in the values file fails the job rather than silently
  leaving a stale pin.
- **`type: helm`** marks a chart component; `unittest: true` renders the
  `helm-unittest` step (via the new `lint-helm` input). `type` is only
  needed when the directory has no language marker; a `Chart.yaml` at
  `path` implies it. Chart CI jobs (`lint-helm`, `helm-publish` dry-run) are
  driven purely by that component's own resolved `primary_language ==
  helm` — set by `type: helm` or by an auto-detected `Chart.yaml` inside
  the component's own directory — never by a `release_signals.chart_yaml`
  hit on some other component in the same repo. A chart directory that is
  declared as its own component is also **removed from the parent
  component's `release_signals.chart_yaml`**
  (`internal/app/detect/service.go`, `componentsFromManifest`), so the
  chart renders exactly one `helm-publish` job — from its own component —
  instead of a duplicate under the parent.
- **Chart components publish to the org-wide OCI namespace
  `ghcr.io/<owner>/charts`** (the chart name from `Chart.yaml` becomes the
  final segment, e.g. `ghcr.io/serverkraken/charts/mailstack`). This is the
  path mailstack already published to by hand; it is intentionally *not*
  `ghcr.io/<owner>/<repo>/charts`. The legacy block for a chart that is only
  a *signal* on a non-chart component (`release_signals.chart_yaml`, no
  manifest) keeps its pre-v4.14 `ghcr.io/<owner>/<repo>/charts` target for
  byte identity.
- **Chart-component CI and publish jobs are a manifest feature.** The
  `charts_dir` form of `lint-helm`, the `helm-publish` dry-run in `ci.yml`
  and the per-component `helm-publish` job in `release.yml` are rendered
  only when the profile carries a manifest. A chart repo whose `Chart.yaml`
  merely *sits* in a sub-directory (`calert/Chart.yaml`,
  `chart/Chart.yaml`) is detected as a non-root helm component but has no
  manifest, and keeps its previous rendering: a single `lint-helm` job with
  `working_directory: <chart path>` and no publish job. Adding a manifest is
  the deliberate step that opts such a repo into publishing its chart.
- **A manifest component with no detected language and at least one
  declared Dockerfile** (an image-only component — a plain build context
  with no source of its own, e.g. `images/postfix` in the mailstack
  example above) is exempt from the `no_lint_test_atom` warning: there is
  nothing to lint or test, only an image to build.
- **Dockerfile annotations stay valid;** the manifest wins on conflict.
  Their deprecation is a separate major-version step.
- **Unknown keys are errors,** not warnings. A typo must not silently fall
  back to a default. Unknown `schema` values are errors too.
- **`gitops[]`** is an inventory in v1: validated, copied into the profile,
  and surfaced in the onboarding PR body and `docs/onboarding-status.md`
  ("consumed by"). It is **not** written into the lock — the lock records
  `inputs.manifest_sha256`, so editing the `gitops` block already makes the
  lock stale; copying the list in as well would be a second place to keep in
  step for no gain. `mode: renovate` means the
  catalog does nothing active — rollout latency is governed by the
  consumer repo's Renovate preset. `mode: push` is reserved; v1 rejects it
  with "gitops mode push is not yet supported". `scope` is expressed in
  **file globs, never image references**; it documents both the template
  and the rendered copy on purpose.
- The manifest is a **render input**: its SHA-256 is recorded in the lock
  (`inputs.manifest_sha256`). See § 11.5.

A component's `dockerfiles[]` only lists Dockerfiles *in addition to* those
already found under `path` — a Dockerfile that the component directory
already contains is an error if also listed there ("already inventoried …
use the component-level shorthand"). The component-level `image`/`context`/
`platforms`/`release` shorthand (as used on `images/postfix` above) is only
valid when the component directory holds exactly one Dockerfile.

Every validation error is prefixed `.github/onboard.yml: line N:` — schema
must be `1` (unsupported schema values fail with the offending number
named); booleans are strictly `true`/`false` (`yes`/`1`/etc. fail; a quoted
`"true"` still parses, since quoting doesn't change the underlying value);
`language` must be one of `go`, `python`, `rust`, `helm`, `flutter`, `node`,
`generic`; `type` must be `helm`; `image` must match `^[A-Za-z0-9._/-]+$`;
`platforms` must be a comma-separated `os/arch[/variant]` list;
`workflows.e2e.script` must be a repo-relative path matching
`^[A-Za-z0-9._/-]+$`; `workflows.e2e.schedule` must be five cron fields made
of digits, `*`, `,`, `-`, `/` and names (no quotes or other punctuation);
`gitops[].repo` must be `owner/name`; component paths must be unique and
stay inside the repository, and two non-root components must not share a
directory basename — release-please derives the `package-name` (and hence
the tag prefix) from it, so `images/svc` and `charts/svc` would collide.

**The YAML the reader accepts.** `internal/manifest` implements the small
subset the schema needs rather than pulling in a YAML dependency, and
rejects the rest with a line number instead of guessing:

| Accepted | Rejected |
|---|---|
| block mappings (`key: value`, two-space indent) | tabs, odd indentation |
| block sequences, including `- key: value` items with **exactly one space** after the dash | nested sequences (`- - x`) |
| flow scalar lists (`scope: [a, b]`) | flow mappings (`{a: 1}`) |
| single- and double-quoted scalars (verbatim — no escape processing) | block scalars (`|`, `>`) |
| `#` comments, whole-line and trailing | anchors, aliases, tags (`&x`, `*x`, `!x`) |

Quoting changes nothing about a value: `dispatch_trigger: "true"` and
`dispatch_trigger: true` parse identically, and `"a\nb"` is the four
characters `a\nb`. Keep the manifest boring.

### 11.3 Per-component releases

When `components:` describes more than one path, release-please runs in
monorepo mode: one package per component, one combined release PR
(`separate-pull-requests: false`). Tags follow release-please's default
package-name prefix:

- The root component (`path: .`) keeps `include-component-in-tag: false` —
  its tag is plain `vX.Y.Z`.
- Sub-directory components get `include-component-in-tag: true` and a
  `package-name` set to the directory basename — `postfix-v1.2.0`,
  `demo-v0.3.0`.
- Chart components render with `release-type: helm` (release-please bumps
  `Chart.yaml`'s `version` directly); the chart's package name and prefix
  follow the same directory-basename rule as any sub-directory component.

**What the `helm` release strategy touches.** On each release of the chart
package, release-please rewrites `version:` in `Chart.yaml` through the YAML
document API — comments and formatting survive — and **never touches
`appVersion`**. The chart version itself is carried forward correctly: the
current value is seeded into `.release-please-manifest.json` at onboarding, so
the first release continues from where the chart already is.

**`appVersion` stays behind, and that is not a neutral state.** The value ends
up in every resource's `app.kubernetes.io/version` label and in the install
notes; a stale `appVersion` claims a version that runs nowhere (mailstack's
chart reached 1.10.0 while its `appVersion` still read `v1.6.5`). Opt out of
that with `app_version: true` in the manifest — see above; the chart then needs
the `x-release-please-version` marker on the `appVersion` line.

The second half of the earlier rationale — that image tags are bumped by
Renovate — only holds for charts with a **single** image. Renovate's
`helm-values` manager recognises exactly one `image:` key, which is precisely
why `chart_pins` exists: it sets the tags from the release itself.

Adopters migrating from a **root package with `Chart.yaml` in
`extra-files`** — which only rewrote the `appVersion` marker line — should
drop that `extra-files` entry (and the `x-release-please-version` marker
comment in `Chart.yaml`) when the chart becomes its own component. Leaving
it in place makes the root package keep editing a file the chart package now
owns.

**The root package excludes every sub-component path.** Release-please
feeds each package the commits that touch its path — and the root package's
path is `.`, which matches *every* commit in the repo. Without a guard a
`fix(postfix): …` commit under `images/postfix` would bump the root version
too, on top of the component's own release. The rendered
`release-please-config.json` therefore gives the root package

```json
    ".": {
      "release-type": "go",
      "exclude-paths": ["images/postfix", "charts/mailstack"],
      "include-component-in-tag": false
    }
```

listing every non-root component path (the key is omitted when the manifest
declares no non-root component). A commit that touches only a sub-component
now releases only that component; the root releases when something outside
every component path changes.

> **Re-onboarding a repo rendered from the monorepo template before
> v4.14:** the package naming changed. Sub-directory packages now use the
> directory **basename** as `package-name` (`postfix-v1.2.0`, not
> `images/postfix-v1.2.0`), and the root package carries no component in its
> tag at all. Before merging the re-onboarding PR, reconcile
> `.release-please-manifest.json` (its keys are paths — the values must be
> the versions actually released under the *new* tag names) and, if
> necessary, push the corresponding tags. Getting this wrong makes
> release-please re-release from `0.1.0`.

Each release job in the rendered `release.yml` is gated on whether its path
was actually released:

```yaml
if: contains(fromJSON(needs.release-please.outputs.paths_released), '<path>')
```

and tags its image with the version release-please assigned to that
specific path:

```yaml
tag: v${{ fromJSON(needs.release-please.outputs.releases)['<path>'].version }}
```

The practical effect: **a `fix(postfix): …` commit builds only postfix.**
Release-please still opens one combined PR covering every component that
changed, but the release job (and its Trivy scan, and its chart publish, if
any) only fires for the paths release-please actually released — an
unrelated component's image is never rebuilt just because something else in
the repo shipped a release.

Prerelease (`prerelease.yml`, manual `workflow_dispatch`) has no such
gating — it loops every release-eligible component and builds all of them,
since a prerelease is a manual, PR-scoped action rather than a
release-please decision.

`release.badges: true` renders a `version-badges` job after `release-please`
(gated on `paths_released != '[]'`). It calls `version-badges.yml`, which
writes one static SVG per package into `docs/badges/` and rewrites the README
block between `<!-- version-badges:start -->` and `<!-- version-badges:end -->`
with a badge line plus a Component | Version | Tag table, then commits with
`[skip ci]` via the release-bot App. Add the two markers to the README once —
the job fails loudly instead of touching a README without them. No external
services are involved, so the badges render in private repos.

`release.dispatch_trigger: true` adds `workflow_dispatch: {}` to the
rendered `release.yml` so a monorepo release can be re-run by hand.

### 11.4 Engines

The adopter manifest is parsed **only by the Go CLI** (`internal/manifest`).
The Bash detector (`scripts/onboard-detect.sh`) gets no parser — deliberately;
a second hand-rolled YAML-schema implementation would be a second bug class
for a rollback path the Go engine hasn't needed since 2026-07-26. If the
Bash engine finds `.github/onboard.yml` it fails loud instead of silently
ignoring the file or mis-detecting the repo:

```
::error::<repo>/.github/onboard.yml: adopter manifest present — the Bash detector does not support manifests; dispatch with use_go_cli=true (sk-workflows detect)
```

Practical consequences:

- **Onboarding** a manifest repo requires dispatching `onboard.yml` with
  `use_go_cli: true` (the default on `next` already — only relevant if
  someone forces Bash rollback per § 5.7).
- **Drift and sweep** hit the same wall: `onboard-drift.sh` checks for
  `.github/onboard.yml` before touching the lock, and reports `status=error`
  immediately for that target with `render_error` pointing at
  `use_go_cli=true` — not a `clean` result with the real failure buried in
  `render_error`, and not a lock-comparison result that never had a chance
  to run. A weekly `drift-check` or `onboard-sweep` run against a manifest
  adopter using the Bash engine therefore surfaces the problem directly in
  the drift report. Re-dispatch with `use_go_cli: true` to get a real
  reading.
- Without a manifest, nothing changes — Bash-engine adopters are unaffected.

Related: a repo with a root language marker *and* sub-directory Dockerfiles
but **no manifest** no longer silently mis-detects as an all-`generic`
monorepo (the fallback bug this feature also fixes). Instead it yields the
root component plus a `subdir_dockerfiles_unassigned` warning listing the
orphaned Dockerfiles and pointing at the manifest — honest instead of wrong.

**`path_unreadable`.** Detection walks the repo to find components and
Dockerfiles. If a directory cannot be read — a root-owned artifact tree left
behind on a self-hosted runner is the realistic case — everything below it is
missing from the profile. Detection does **not** abort: one unreadable
directory should not make onboarding impossible. It emits a `path_unreadable`
warning naming the path instead, because the alternative is worse: a component
silently absent from the profile renders no lint, test, scan or cleanup job,
and nothing says so. The warning appears in the onboarding PR body and the
run's step summary.

### 11.5 Lock and drift

`.github/onboard.lock.json` gains `inputs.manifest_sha256` (`sha256:<hex>`),
written only when a manifest exists. `drift-check` treats a changed,
added, or removed manifest as **`stale-lock`** (re-render required, not a
hand-edit) — the drift report's `Modified` column for that status lists
`.github/onboard.yml`.

A broken manifest shows up in one of two ways, and the difference matters
when reading a drift report:

- **Parse or validation failure** (unknown key, bad `platforms`, duplicate
  package name, …): the file is readable, so its SHA-256 is computed and
  compared — and it differs from the locked hash, because the last
  successful render used a different byte sequence. The target reports
  **`stale-lock`**, not `error`. The real message (`.github/onboard.yml:
  line N: …`) appears when the re-render is attempted, in `render_error`.
- **Read failure** (`EISDIR` because someone made `.github/onboard.yml` a
  directory, `EPERM`, an I/O error): there is nothing to hash, so drift
  cannot be evaluated at all — `sk-workflows drift` fails and the target is
  bucketed as **`error`**, never silently as `clean`. The same bucket
  covers the Bash engine meeting a manifest it cannot parse (§ 11.4), and
  any re-render that breaks in either engine — a missing gomplate, an
  unreadable scratch dir, a detector that exits non-zero.

### 11.6 GitOps consumers

`gitops[]` is an **inventory only** in v1 — nothing dispatches on it yet.
Each entry gets copied into the profile and the lock, and shown:

- In the onboarding PR body, under "Consumed by".
- In the `Consumers` column of `docs/onboarding-status.md`.

`mode: renovate` (the default, and the only value v1 accepts) means the
catalog does nothing active for the entry — rollout latency into that
consumer is governed entirely by the consumer repo's own Renovate preset.
`mode: push` is reserved for a future release-triggered dispatch and is
rejected today with "gitops mode push is not yet supported".

`scope` is expressed in **file globs, never image references** — it
documents which paths in the consumer repo reference this adopter's
images, not which image strings to match. This matters because of a rule
for GitOps repos that the manifest's `scope` relies on: **image references
in `bootstrap/templates/**/*.j2` must stay literal.** The moment a tag
becomes a template variable, Renovate's file-based managers stop matching
it, and the version has to move into a config file instead — a third copy
of the same value. Keep both the template and its rendered copy holding
the literal image reference so Renovate matches both.

### 11.7 Relation to Dockerfile annotations

The `# onboard:image=<name>` and `# onboard:release=<bool>` Dockerfile
comment annotations (see § Release-Eligibility per Dockerfile) are still
fully valid and unaffected by the manifest. Precedence when both are
present: **manifest wins**. The profile records which source produced the
image name via `image_name_source`: `manifest` > `override` (the
annotation) > `derived` (the `$REPO-<dir>` convention). Release eligibility
follows the same order — the annotation applies over the file-name
convention, and a manifest `release:` value overrides both. Deprecating the
annotations in favor of the manifest is a separate, future major-version
step; it is not part of this feature.
