# Reusable Workflows Catalog — Design

**Date:** 2026-05-16
**Status:** Draft (awaiting user review)
**Author:** Soenne + Claude
**Repo:** `serverkraken/reusable-workflows` (private, to be created)

---

## 1. Goal

Build a versioned, tested catalog of GitHub Actions reusable workflows for the `serverkraken` organisation. Each downstream repo currently maintains its own copies of nearly identical CI workflows. The catalog extracts those duplicates into `workflow_call` workflows that consumers reference as:

```yaml
uses: serverkraken/reusable-workflows/.github/workflows/<name>.yml@v1
```

The catalog itself uses release-please so consumers can pin a major (`@v1`) and float on backwards-compatible changes — exactly the pattern used by `actions/checkout`, `docker/build-push-action`, etc.

## 2. Scope

### In scope (this spec — "horizontal slice MVP")

Language-agnostic, most-duplicated concerns:

1. **`semantic-release.yml`** — release-please wrapper with floating major/minor tags
2. **`docker-build.yml`** — multi-arch (amd64 + arm64) distributed build with Cosign signing, SLSA provenance attestation, and SBOM generation
3. **`trivy-image.yml`** — image scan (vuln + secret + misconfig), SARIF upload
4. **`trivy-fs.yml`** — filesystem scan on PR-time (vuln + secret + misconfig)
5. **`cleanup-images.yml`** — GHCR retention with two-pass age + count logic
6. **`release.yml`** — opinionated orchestrator that chains the above for the common release flow

Plus the catalog's own self-CI, self-release, fixtures, composite actions, and Renovate configuration.

### Out of scope (future specs)

- **Language-specific lint/test atoms** (`lint-go.yml`, `test-python.yml`, `lint-rust.yml`, `lint-helm.yml`, etc.) — separate spec per language track.
- **Migration plans** for the ~6 repos currently on hand-rolled bash semantic-release — separate spec, decoupled from this catalog so the catalog can ship without waiting on org-wide migration.
- **GitHub Native Secret Scanning Push Protection** — requires GitHub Advanced Security (paid). Pragmatic substitute (`trivy-fs.yml` on PR-time) covered here.
- **Slack/Discord release notifications** — deferred to v1.x.
- **PR-comment slash-command trigger** (`/build-image` in PR comment) — documented as a recipe but not part of the MVP.

## 3. Architecture Overview

```
                  ┌──────────────────────────────────────────┐
                  │  CONSUMER REPO (private, e.g. blupod)    │
                  │                                          │
                  │  .github/workflows/                      │
                  │   ├── ci.yml          (PR-time gates)    │
                  │   ├── release.yml     (main → release)   │
                  │   ├── prerelease.yml  (manual dispatch)  │
                  │   └── cleanup.yml     (weekly cron)      │
                  └────────────┬─────────────────────────────┘
                               │  uses: …@v1
                               ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │              serverkraken/reusable-workflows                    │
   │                                                                 │
   │  ORCHESTRATOR (front door for most consumers)                   │
   │   └── release.yml  ── semantic-release → docker-build → trivy  │
   │                                                                 │
   │  ATOMIC WORKFLOWS (composable building blocks)                  │
   │   ├── semantic-release.yml  (release-please + floating tags)    │
   │   ├── docker-build.yml      (multi-arch + cosign + sbom)        │
   │   ├── trivy-image.yml       (vuln + secret + misconfig scan)    │
   │   ├── trivy-fs.yml          (PR-time fs scan)                   │
   │   └── cleanup-images.yml    (GHCR retention)                    │
   │                                                                 │
   │  COMPOSITE ACTIONS (sub-step boilerplate)                       │
   │   ├── actions/install-trivy/action.yml                          │
   │   ├── actions/ghcr-login/action.yml                             │
   │   ├── actions/compute-prerelease-tag/action.yml                 │
   │   └── actions/post-prerelease-comment/action.yml                │
   └─────────────────────────────────────────────────────────────────┘
```

### Three consumer-side patterns the MVP supports

| Consumer file       | Trigger                | Calls (catalog side)                                                        |
|---------------------|------------------------|-----------------------------------------------------------------------------|
| `release.yml`       | push → main            | `release.yml` (orchestrator) → semantic-release → docker-build → trivy      |
| `ci.yml`            | pull_request           | `trivy-fs.yml` (PR-time security gate, source-tree scan)                    |
| `prerelease.yml`    | workflow_dispatch      | `docker-build.yml` (prerelease=true) + `trivy-image.yml` on the built image |
| `cleanup.yml`       | weekly cron            | `cleanup-images.yml`                                                        |

### Runner pool (parameterized per workflow via `runs_on` input)

Defaults match existing serverkraken self-hosted labels. Consumers without matching runners override `runs_on` to `ubuntu-latest`.

| Default                                          | Used for                                            |
|--------------------------------------------------|-----------------------------------------------------|
| `[self-hosted, Linux]`                           | generic Linux work (fs scan, version step, etc.)    |
| `[self-hosted, Linux, X64, performance]`         | native amd64 image build matrix arm                 |
| `[self-hosted, Linux, ARM64]`                    | native arm64 image build matrix arm                 |
| `[self-hosted, Linux, low-performance]`          | metadata/release jobs (pure shell + GitHub API)     |

The multi-arch image build always distributes across native X64 and ARM64 runners — never QEMU emulation on a single runner.

### Versioning of the catalog itself

release-please on this repo produces `vX.Y.Z` tags. A follow-up step force-moves `vX` and `vX.Y` to the same commit, so consumers can pin `@v1`, `@v1.2`, or `@v1.2.3`. Prerelease versions (those containing `-`) skip the floating-tag move.

**A breaking change to any reusable workflow's `inputs` / `outputs` / `secrets` shape is a major bump.** The contract surface is documented as a header comment at the top of each workflow file and aggregated in `docs/contracts.md`.

## 4. Per-Workflow Contracts

### 4.1 `semantic-release.yml` (atomic)

```yaml
on:
  workflow_call:
    inputs:
      runs_on:                 # default: '["self-hosted","Linux","low-performance"]'
        type: string
      release_please_config:   # default: 'release-please-config.json'
        type: string
      release_please_manifest: # default: '.release-please-manifest.json'
        type: string
    outputs:
      release_created:         # 'true' | 'false'
      tag_name:                # 'v2.3.1'
      major_tag:               # 'v2'
      minor_tag:               # 'v2.3'
    secrets:
      release_please_app_id:         # required. Numeric App ID of org-installed serverkraken-release-bot GitHub App
      release_please_app_private_key: # required. PEM-formatted private key from the GitHub App

permissions:
  contents: write
  pull-requests: write
  issues: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false
```

**Auth + release-please + floating-tag flow** (in this order, in the single `release` job):

```yaml
- uses: actions/create-github-app-token@v2
  id: app-token
  with:
    app-id: ${{ secrets.release_please_app_id }}
    private-key: ${{ secrets.release_please_app_private_key }}

- uses: actions/checkout@v6
  with:
    token: ${{ steps.app-token.outputs.token }}     # required so the floating-tag git-push bypasses branch protection
    fetch-depth: 0

- uses: googleapis/release-please-action@v4
  id: release
  with:
    token: ${{ steps.app-token.outputs.token }}
    config-file: ${{ inputs.release_please_config }}
    manifest-file: ${{ inputs.release_please_manifest }}

- name: Move floating major/minor tags
  if: |
    steps.release.outputs.release_created == 'true' &&
    !contains(steps.release.outputs.tag_name, '-')
  env:
    NEW_TAG: ${{ steps.release.outputs.tag_name }}
  run: |
    VERSION="${NEW_TAG#v}"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
    git config user.name  'serverkraken-release-bot[bot]'
    git config user.email '<app-id>+serverkraken-release-bot[bot]@users.noreply.github.com'
    git tag -f "v$MAJOR"
    git tag -f "v$MAJOR.$MINOR"
    git push origin "v$MAJOR" "v$MAJOR.$MINOR" --force
```

The `actions/create-github-app-token@v2` step mints a fresh 1h installation token at the start of each run. No PAT, no rotation.

### 4.2 `docker-build.yml` (atomic)

```yaml
on:
  workflow_call:
    inputs:
      tag:                     # default: '' (auto-compute via compute-prerelease-tag when prerelease=true)
        type: string
      prerelease:              # default: false. true → skip :latest, auto-compute tag if `tag` is empty
        type: boolean
      image_name:              # default: ${{ github.repository }}
        type: string
      dockerfile:              # default: './Dockerfile'
        type: string
      context:                 # default: '.'
        type: string
      platforms:               # default: 'linux/amd64,linux/arm64'
        type: string
      build_args:              # default: '' (newline KEY=VALUE)
        type: string
      sign:                    # default: true. Cosign keyless via OIDC
        type: boolean
      attest:                  # default: true. SLSA build provenance
        type: boolean
      sbom:                    # default: true. SPDX-JSON via Syft
        type: boolean
      runs_on_amd64:           # default: '["self-hosted","Linux","X64","performance"]'
        type: string
      runs_on_arm64:           # default: '["self-hosted","Linux","ARM64"]'
        type: string
      runs_on_merge:           # default: '["self-hosted","Linux","low-performance"]'
        type: string
    outputs:
      image_ref:               # 'ghcr.io/serverkraken/foo:v2.3.1'
      digest:                  # 'sha256:…' of the manifest list
      sbom_artifact:           # 'sbom-spdx' artifact name (also attached to release if called via orchestrator)

permissions:
  contents: read
  packages: write
  id-token: write              # required for Cosign keyless + SLSA attestation
  attestations: write          # required for actions/attest-build-provenance
  pull-requests: write         # required for post-prerelease-comment composite action

concurrency:
  group: ${{ github.workflow }}-${{ inputs.tag }}
  cancel-in-progress: ${{ inputs.prerelease }}
```

**Internal job structure** (matches existing `smarthome-jukebox-go/docker-build.yml` pattern):

```
version
  └── (compute tag; for prerelease: use compute-prerelease-tag composite action)
build (matrix: amd64, arm64; native runners)
  ├── checkout
  ├── ghcr-login (composite)
  ├── docker/setup-buildx-action@v4
  ├── docker/build-push-action@v7 (push-by-digest, cache scoped per arch)
  └── upload digest artifact
merge
  ├── download digests
  ├── ghcr-login (composite)
  ├── docker buildx imagetools create … (manifest list with all tags)
  ├── (if sign)   cosign sign --yes ghcr.io/…@<digest>
  ├── (if attest) actions/attest-build-provenance@v2 (push-to-registry: true)
  ├── (if sbom)   anchore/sbom-action@v0 → upload artifact
  └── (if prerelease && has PR) post-prerelease-comment composite action
```

### 4.3 `trivy-image.yml` (atomic)

```yaml
on:
  workflow_call:
    inputs:
      image_ref:               # required. 'ghcr.io/serverkraken/foo:v2.3.1'
        type: string
        required: true
      scanners:                # default: 'vuln,secret,misconfig'
        type: string
      severity:                # default: 'HIGH,CRITICAL'
        type: string
      ignore_unfixed:          # default: true
        type: boolean
      fail_on_findings:        # default: true
        type: boolean
      paths_ignore:            # default: '' (newline-separated)
        type: string
      upload_sarif:            # default: true (auto-skipped on forks)
        type: boolean
      trivy_version:           # default: pinned (see note below)
        type: string
      runs_on:                 # default: '["self-hosted","Linux"]'
        type: string
    outputs:
      findings_count:          # integer
      sarif_path:              # 'trivy-image-sarif' artifact

permissions:
  contents: read
  security-events: write       # SARIF upload to code-scanning tab

concurrency:
  group: ${{ github.workflow }}-${{ inputs.image_ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Uses direct Trivy CLI install via the `install-trivy` composite action — **never** `aquasecurity/trivy-action` (org learned this from `juke.gallery-rest`: reliability issues led to migrating away).

**Renovate annotation for `trivy_version`**: the default is pinned in the workflow source with a comment that Renovate's custom-manager parses:

```yaml
# renovate: datasource=github-releases depName=aquasecurity/trivy
TRIVY_VERSION: 0.69.3
```

The Renovate config in §5.4 must include the matching `customManagers` block. Existing pattern in `serverkraken/strassenfuchs-tiles/renovate.json`.

### 4.4 `trivy-fs.yml` (atomic, new)

```yaml
on:
  workflow_call:
    inputs:
      scanners:                # default: 'vuln,secret,misconfig'
        type: string
      severity:                # default: 'HIGH,CRITICAL'
        type: string
      paths_ignore:            # default: '' (newline-separated)
        type: string
      upload_sarif:            # default: true
        type: boolean
      trivy_version:           # default: pinned
        type: string
      runs_on:                 # default: '["self-hosted","Linux"]'
        type: string
    outputs:
      findings_count:
      sarif_path:              # 'trivy-fs-sarif' artifact

permissions:
  contents: read
  security-events: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Source pattern: `serverkraken/homelab-study/.github/workflows/trivy.yaml`. SARIF output + job summary with top-N findings + code-scanning upload.

### 4.5 `cleanup-images.yml` (atomic, cron-triggered)

```yaml
on:
  workflow_call:
    inputs:
      package_name:            # default: ${{ github.event.repository.name }}
        type: string
      keep_stable_versions:    # default: 10. Min versions kept across v* (semver) tags
        type: number
      prerelease_age_days:     # default: 14. Delete non-semver tags older than N days
        type: number
      runs_on:                 # default: '["self-hosted","Linux"]'
        type: string

permissions:
  packages: write
```

Two-pass logic using `actions/delete-package-versions@v5`:
1. Delete prerelease/non-semver tags older than `prerelease_age_days`.
2. Prune oldest stable `v*.*.*` versions over the `keep_stable_versions` threshold.

### 4.6 `release.yml` (orchestrator)

```yaml
on:
  workflow_call:
    inputs:
      build_image:             # default: true. false → release-only (e.g. library repos)
        type: boolean
      run_trivy:               # default: true (only when build_image)
        type: boolean
      dockerfile:              # default: './Dockerfile'
        type: string
      context:                 # default: '.'
        type: string
      platforms:               # default: 'linux/amd64,linux/arm64'
        type: string
      trivy_severity:          # default: 'HIGH,CRITICAL'
        type: string
    secrets:
      release_please_app_id:          # pass-through to semantic-release.yml
      release_please_app_private_key: # pass-through to semantic-release.yml

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
```

Internal chaining (atoms called with `secrets: inherit` so the App secrets reach `semantic-release.yml` without re-mapping):

```
semantic-release.yml  (secrets: inherit)
   ↓ (if release_created && build_image)
docker-build.yml      (tag: needs.release.outputs.tag_name, prerelease: false, secrets: inherit)
   ↓ (if run_trivy)
trivy-image.yml       (image_ref: needs.build.outputs.image_ref, secrets: inherit)
```

If `release_created == false`, all downstream jobs short-circuit and the workflow exits green.

## 5. Composite Actions & Cross-Cutting Concerns

### 5.1 Composite actions

| Action                          | Used by                                | Purpose                                                                                |
|---------------------------------|----------------------------------------|----------------------------------------------------------------------------------------|
| `actions/install-trivy`         | `trivy-image`, `trivy-fs`              | Direct CLI install at pinned version (no `aquasecurity/trivy-action`)                  |
| `actions/ghcr-login`            | `docker-build` (×3 jobs), `trivy-image` | Wraps `docker/login-action@v3` with GHCR defaults                                       |
| `actions/compute-prerelease-tag` | `docker-build` (when `prerelease: true`) | Sanitize branch name (slash→dash, lowercase, OCI-valid), combine with short SHA. Outputs: `tag_with_sha`, `moving_tag` |
| `actions/post-prerelease-comment` | `docker-build` (when prerelease + PR)  | Idempotent PR comment (`peter-evans/find-comment` + `create-or-update-comment`) with pull command + trivy status |

### 5.2 Concurrency standard

Every workflow declares its concurrency group explicitly:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Rationale: PR-time scans can be superseded by newer commits (`cancel-in-progress: true`). Releases and main-branch builds always run to completion (`cancel-in-progress: false`) so no half-tagged image is left behind.

Exception: `docker-build.yml` keys on `inputs.tag` (not `github.ref`) so concurrent prerelease builds for different branches don't block each other.

### 5.3 Permissions minimum per workflow

| Workflow                  | Permissions                                                                      |
|---------------------------|----------------------------------------------------------------------------------|
| `semantic-release.yml`    | `contents: write`, `pull-requests: write`, `issues: write`                       |
| `docker-build.yml`        | `contents: read`, `packages: write`, `id-token: write`, `attestations: write`, `pull-requests: write` |
| `trivy-image.yml` / `trivy-fs.yml` | `contents: read`, `security-events: write`                                |
| `cleanup-images.yml`      | `packages: write`                                                                |
| `release.yml` (orchestrator) | Union of all above; `secrets: inherit` from caller                            |

Permissions are declared at the workflow level (not job level) to keep them grep-able.

### 5.4 Renovate configuration

`.github/renovate.json5`:

```json5
{
  $schema: 'https://docs.renovatebot.com/renovate-schema.json',
  extends: [
    'config:recommended',
    ':dependencyDashboard',
    ':semanticCommits',
    'group:allNonMajor',
  ],
  timezone: 'Europe/Berlin',
  schedule: ['before 6am on monday'],
  labels: ['dependencies'],
  ignorePaths: ['tests/fixtures/**'],  // fixtures are intentionally outdated
  packageRules: [
    {
      description: 'GitHub Actions — auto-merge minor+patch (gated by integration tests)',
      matchManagers: ['github-actions'],
      matchUpdateTypes: ['minor', 'patch'],
      automerge: true,
      automergeType: 'pr',
      groupName: 'GitHub Actions',
    },
    {
      description: 'Supply-chain actions move in lockstep',
      matchPackagePatterns: ['^sigstore/', '^actions/attest-', '^anchore/sbom-action'],
      groupName: 'Supply chain actions',
    },
    {
      description: 'Docker actions',
      matchPackagePatterns: ['^docker/'],
      groupName: 'Docker actions',
    },
    {
      description: 'Major updates always require review',
      matchUpdateTypes: ['major'],
      automerge: false,
      labels: ['dependencies', 'major'],
    },
  ],
  vulnerabilityAlerts: {
    labels: ['security'],
    automerge: true,
  },
  customManagers: [
    {
      // bump the Trivy CLI version pinned in workflow YAMLs via a `# renovate:` comment
      customType: 'regex',
      fileMatch: ['^\\.github/workflows/.+\\.ya?ml$', '^actions/.+/action\\.ya?ml$'],
      matchStrings: [
        '#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)\\s*\\n\\s*TRIVY_VERSION:\\s*[\'\"]?(?<currentValue>\\S+?)[\'\"]?\\s*$',
      ],
      datasourceTemplate: 'github-releases',
      depNameTemplate: 'aquasecurity/trivy',
      extractVersionTemplate: '^v(?<version>.*)$',
    },
  ],
}
```

Auto-merge for minor/patch is safe **because** the integration tests in Section 6.2 gate every Renovate PR. Without them, auto-merge would be reckless. The `customManagers` block enables Renovate to bump the Trivy CLI version inline via `# renovate:` annotation (see §4.3).

## 6. Self-CI and Release of the Catalog Itself

### 6.1 `.github/workflows/validate.yml` (PR + push, static)

```yaml
name: validate
on: [pull_request, push]
concurrency: { group: validate-${{ github.ref }}, cancel-in-progress: true }
jobs:
  actionlint:
    runs-on: [self-hosted, Linux]
    steps:
      - uses: actions/checkout@v6
      - uses: rhysd/actionlint@v1
  yamllint:
    runs-on: [self-hosted, Linux]
    steps:
      - uses: actions/checkout@v6
      - run: pipx run yamllint .github/ actions/
```

### 6.2 `.github/workflows/integration.yml` (PR, dog-fooding)

```yaml
name: integration
on: [pull_request]
concurrency: { group: integration-${{ github.ref }}, cancel-in-progress: true }

jobs:
  test-docker-build:
    uses: ./.github/workflows/docker-build.yml
    with:
      tag: pr-${{ github.event.number }}-${{ github.event.pull_request.head.sha }}
      prerelease: true
      context: tests/fixtures/minimal-go
      image_name: ${{ github.repository }}/test-fixture
      sign: false        # Cosign only on main releases
      attest: false
      sbom: true

  test-trivy-image-happy:
    needs: test-docker-build
    uses: ./.github/workflows/trivy-image.yml
    with:
      image_ref: ${{ needs.test-docker-build.outputs.image_ref }}
      fail_on_findings: false  # fixture image is intentionally clean

  test-trivy-fs-happy:
    uses: ./.github/workflows/trivy-fs.yml
    with:
      paths_ignore: 'tests/fixtures/with-secret/**'

  test-trivy-fs-failure:
    uses: ./.github/workflows/trivy-fs.yml
    with:
      paths_ignore: ''   # secret fixture is now in scope; trivy MUST fail
      upload_sarif: false
    continue-on-error: true

  assert-trivy-fs-fails:
    needs: test-trivy-fs-failure
    if: needs.test-trivy-fs-failure.result != 'failure'
    runs-on: [self-hosted, Linux]
    steps:
      - run: |
          echo "::error::trivy-fs should have failed on the secret fixture but didn't"
          exit 1
```

Pattern: every atom gets ≥1 happy-path caller + ≥1 failure-path caller. Failure-path uses `continue-on-error: true` + a downstream assertion job that explicitly verifies failure occurred.

### 6.3 `.github/workflows/release.yml` (push main, eats own dog food)

```yaml
name: release
on:
  push: { branches: [main] }
concurrency: { group: release-main, cancel-in-progress: false }
permissions:
  contents: write
  pull-requests: write
  issues: write
jobs:
  release:
    uses: ./.github/workflows/semantic-release.yml
    secrets: inherit   # passes org-level RELEASE_PLEASE_APP_ID + RELEASE_PLEASE_APP_PRIVATE_KEY
```

The catalog consumes its own `semantic-release.yml`. If the atom breaks, the catalog cannot release — strong correction signal.

### 6.4 What the catalog does NOT self-test

- No `trivy-image.yml` self-call (catalog produces no container images).
- No `cleanup-images.yml` self-call (same reason).
- No coverage threshold (catalog is YAML, not code; coverage applies only to consumers in future `test-*.yml` atoms).

## 7. Testing Strategy & Fixtures

### 7.1 Layered approach

| Layer        | Tool                | What it catches                                            |
|--------------|---------------------|------------------------------------------------------------|
| Static       | `actionlint`        | Workflow syntax errors, unused secrets, expression typos   |
| Static       | `yamllint`          | YAML hygiene (indent, trailing whitespace, line length)    |
| Integration  | Caller workflows    | End-to-end behavior of each atom against fixtures          |
| Unit (when needed) | `bats` + `bashcov` | Any non-trivial shell extracted to `scripts/*.sh` (≥90% line) |

### 7.2 Fixture directory

```
tests/fixtures/
  minimal-go/              # Dockerfile + main.go (~10 lines). For docker-build happy path.
    Dockerfile
    main.go
  with-secret/             # .env-example with fake AWS key. For trivy-fs failure path.
    .env-example           # named to avoid accidental git-ignore matches
    Dockerfile             # COPY → image (also used for trivy-image secret scan if needed)
  with-cve/                # Image base with known HIGH CVE. For trivy-image failure path.
    Dockerfile             # FROM <pinned-old-alpine>; Renovate ignores this path
  minimal-release-please/  # config + manifest for semantic-release atom test
    release-please-config.json
    .release-please-manifest.json
```

**Fixture maintenance rule**: Renovate ignores `tests/fixtures/**` (configured in `renovate.json5`). Otherwise auto-merge would update our intentionally-outdated CVE test images and make failure tests green.

### 7.3 Bats — when, not by default

Only introduce `bats` when a workflow ends up with non-trivial inline bash. Likely candidates:
- `compute-prerelease-tag/action.yml` (branch name sanitization)
- `cleanup-images.yml` (retention logic)

If/when bats is introduced:
```
tests/shell/
  compute-prerelease-tag.bats    # cases: slash → dash, lowercase, OCI-valid, edge cases
  cleanup-retention.bats         # keep-N-stable + age-based-prerelease logic
```

Use `bashcov` for ≥90% line coverage on `scripts/*.sh` only.

### 7.4 Local validation with `act`

For maintainers, pre-PR-push validation:

```bash
act pull_request -W .github/workflows/integration.yml --container-architecture linux/amd64
```

Documented in `CONTRIBUTING.md`.

## 8. Adopter Onboarding

### 8.1 Per-consumer setup

**Step 1** — *No per-consumer secret setup required.* The `serverkraken-release-bot` GitHub App is installed org-wide; auth secrets (`RELEASE_PLEASE_APP_ID`, `RELEASE_PLEASE_APP_PRIVATE_KEY`) live as org-level secrets visible to all private repos. Consumers just use `secrets: inherit` in their workflow call.

**Step 2** — Release-please files in repo root:

```jsonc
// .release-please-manifest.json
{ ".": "0.0.0" }
```

```jsonc
// release-please-config.json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "packages": {
    ".": {
      "release-type": "simple",
      "include-component-in-tag": false,
      "bump-minor-pre-major": true,
      "draft": false,
      "prerelease": false
    }
  }
}
```

**Step 3** — Four workflow files (copy-paste from `docs/adopter-templates/` in the catalog repo):

```yaml
# .github/workflows/release.yml
on: { push: { branches: [main] } }
jobs:
  release:
    uses: serverkraken/reusable-workflows/.github/workflows/release.yml@v1
    secrets: inherit   # passes org-level RELEASE_PLEASE_APP_ID + RELEASE_PLEASE_APP_PRIVATE_KEY through
```

```yaml
# .github/workflows/ci.yml
on: { pull_request: {} }
jobs:
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@v1
```

```yaml
# .github/workflows/prerelease.yml
# Trigger from UI (branch dropdown) or CLI: `gh workflow run prerelease.yml --ref feat/foo`
on:
  workflow_dispatch: {}
jobs:
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@v1
    with:
      prerelease: true       # docker-build auto-computes tag from branch + short-SHA
  scan:
    needs: build
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-image.yml@v1
    with: { image_ref: ${{ needs.build.outputs.image_ref }} }
```

```yaml
# .github/workflows/cleanup.yml
on:
  schedule: [{ cron: '0 3 * * 0' }]
  workflow_dispatch: {}
jobs:
  cleanup:
    uses: serverkraken/reusable-workflows/.github/workflows/cleanup-images.yml@v1
```

### 8.2 Migration path for the ~6 repos on hand-rolled bash

Per repo:
1. Add `release-please-config.json` + `.release-please-manifest.json`, with the manifest's initial version set to the *current* tag (e.g. `"0.4.2"` if HEAD is at `v0.4.2`).
2. Verify the `serverkraken-release-bot` GitHub App is installed on this repo (org-wide install handles this automatically unless "Selected repositories" was chosen).
3. Delete the old hand-rolled `semantic-release.yml`; add the new `release.yml` from the template above.
4. The first release-please PR is created on the next `feat:`/`fix:` commit. Manually sanity-check the changelog before merging.

(Migration plan is a separate spec — not coupled to the catalog's release cadence.)

## 9. Operational Setup (org-level, one-time)

### 9.1 Repo creation

```bash
gh repo create serverkraken/reusable-workflows \
  --private \
  --description "Reusable GitHub Actions workflows for the serverkraken organization" \
  --source=. \
  --remote=origin
```

### 9.2 Actions access policy

The catalog repo must allow other private repos in the org to call its workflows:

```bash
gh api -X PUT \
  /repos/serverkraken/reusable-workflows/actions/permissions/access \
  -f access_level=organization
```

(Equivalent UI path: Settings → Actions → General → Access → "Accessible from repositories in the 'serverkraken' organization".)

### 9.3 GitHub App auth (the chosen approach)

Auth runs through the `serverkraken-release-bot` GitHub App installed org-wide. One-time setup, already completed:

1. App created at `https://github.com/organizations/serverkraken/settings/apps` with permissions `Contents: R+W`, `Pull requests: R+W`, `Issues: R+W`, `Metadata: R`. Webhooks disabled. Installation scope: "Only on this account".
2. App installed on `serverkraken` org with access to All repositories.
3. Org-level secrets:
   - `RELEASE_PLEASE_APP_ID` — numeric App ID
   - `RELEASE_PLEASE_APP_PRIVATE_KEY` — full PEM contents
   - Both with Repository access = "All private repositories" so consumers reach them via `secrets: inherit`.

At runtime, `actions/create-github-app-token@v2` mints a fresh 1-hour installation token from the App ID + Private Key at the start of every release run.

### 9.4 Private key rotation

GitHub App private keys are **rotated on suspicion of compromise, not on a fixed schedule** — they're cryptographic material managed in code, not credentials with elapsed time-based weakness. Practical rotation runbook (in `docs/operations.md`):

1. Generate a new private key from the App settings page.
2. Update the `RELEASE_PLEASE_APP_PRIVATE_KEY` org secret with the new PEM.
3. Wait one successful release run to confirm the new key works.
4. Delete the old private key from the App's "Private keys" section.

Multiple private keys can coexist on a GitHub App, enabling zero-downtime rotation. No PAT-style 90-day calendar reminder needed.

## 10. Decisions Log

| Decision                              | Choice                                     | Rationale (short)                                                       |
|---------------------------------------|--------------------------------------------|-------------------------------------------------------------------------|
| MVP shape                             | Horizontal slice (language-agnostic atoms) | Fastest path to deduplicating the ~6 repos already on bash flow.        |
| Release engine                        | release-please (googleapis/...@v4)         | Industry standard; better changelogs; release-PR review gate.           |
| Release-please auth                   | GitHub App (`serverkraken-release-bot`)    | Org-wide install eliminates per-consumer PAT setup; ephemeral 1h tokens; no rotation schedule; survives user account changes. |
| Floating major/minor tags             | Yes; skip on prereleases (`-` in tag)      | Matches `actions/checkout` convention; "stay on v2" semantics.          |
| Prerelease trigger                    | Manual `workflow_dispatch` only            | User preference: intentional usage, less CI noise.                      |
| Prerelease tag format                 | `<sanitized-branch>-<short-sha>` + moving `<branch>` tag | Unique-per-commit + easy-to-pull stable handle.                         |
| Composition model                     | Atoms + opinionated orchestrator           | Matches existing local pattern in `smarthome-jukebox-go`.               |
| Trivy install                         | Direct CLI                                 | `juke.gallery-rest` learned: `aquasecurity/trivy-action` is unreliable. |
| Secret scanning                       | Extend Trivy via `--scanners secret`       | Same binary; same CI time; Trivy uses Gitleaks ruleset under the hood.  |
| Image signing                         | Cosign keyless via OIDC                    | No key management; verifiable provenance; industry standard.            |
| Provenance attestation                | `actions/attest-build-provenance@v2`       | GitHub-native; one step; pushed to registry next to image.              |
| SBOM                                  | Syft via `anchore/sbom-action@v0`          | SPDX-JSON; attached to release; future CVE-cohort queries possible.     |
| Dependency updater                    | Renovate (`config:recommended`)            | Existing org convention; better grouping than Dependabot.               |
| Auto-merge policy                     | Minor + patch on actions; major manual     | Safe because integration tests gate every PR.                           |
| Concurrency policy                    | `cancel-in-progress` only for PR triggers  | Release runs are sacrosanct; PR scans are supersedable.                 |
| Test strategy                         | actionlint + yamllint + caller fixtures    | Bats only when non-trivial bash appears (not by default).               |
| `≥90% coverage` interpretation        | `coverage_threshold` input passed through to consumers | Coverage gates consumer apps, not YAML.                               |
| Renovate fixture handling             | `ignorePaths: ['tests/fixtures/**']`       | Failure-path fixtures must stay outdated to keep failing.               |

## 11. Out of Scope (future specs)

- **Language-track atoms**: `lint-go.yml`, `test-go.yml`, `lint-python.yml`, `test-python.yml`, `lint-rust.yml`, `test-rust.yml`, `lint-helm.yml`. Each gets its own spec.
- **Migration of existing repos** from hand-rolled bash to release-please. Separate spec, sequenced after catalog v1.0 is stable.
- **PR-comment slash-command trigger** (e.g., `/build-image` in comment fires prerelease). Documented as recipe; not part of MVP code.
- **Notification webhook** (Slack/Discord) on release. Likely v1.x feature.
- **GitHub Advanced Security** (Push Protection, Dependabot Alerts integration). Depends on org plan.
- **Custom Cosign verification policy** for deploys (Kyverno / Cosign Policy Controller integration). Belongs in the deploy/k8s repos, not here.

## 12. Risks & Open Questions

### Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Renovate auto-merge breaks an action contract without test catching it | Medium | Tests cover happy + failure paths per atom; major bumps never auto-merge. Manual review for major Action bumps. |
| GitHub App private key compromised | Low | Generate new key, update org secret, verify with one run, delete old key. Multiple keys can coexist for zero-downtime rotation. |
| Cosign keyless signing depends on Sigstore public infrastructure (Fulcio, Rekor) availability | Low | Verifiable signatures don't require Sigstore at verify-time once embedded; signing failures block release-but-leave-image-built. Document fallback if Sigstore is down: re-run after recovery. |
| Self-hosted runner pool labels change | Medium | All `runs_on` are inputs with documented defaults. Org-wide label change = single search/replace, no consumer churn. |
| First adopter discovers a contract bug | High (it's v1.0) | Pilot with 1-2 repos before announcing broadly. Bugfix → patch release → consumers floating on `@v1` get it automatically. |

### Open questions

None blocking. All major design forks resolved during brainstorming.

---

## Implementation handoff

After user approval of this spec, the `superpowers:writing-plans` skill produces a step-by-step implementation plan that decomposes this design into independent, testable units of work.
