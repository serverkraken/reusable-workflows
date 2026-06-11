# serverkraken/reusable-workflows

Versioned, tested catalog of GitHub Actions reusable workflows for the `serverkraken` organisation. Stop copying CI workflows between repos — reference them with a one-line `uses:`.

## Quick start (adopters)

**Prerequisite** (one-time per repo):

- The `serverkraken-release-bot` GitHub App must be installed on the repo
  (org-wide install handles this automatically). No per-repo secret setup —
  `secrets: inherit` reaches the org-level App secrets.

**Then** dispatch the onboarding workflow from this catalog repo's Actions tab:

1. Open the **Actions** tab in the catalog repo and select the
   **onboard** workflow from the sidebar.
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
repo, pinned to `@v4` (the current catalog major). The skeleton sources are
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

## What it does

### `release.yml` (orchestrator)

End-to-end release pipeline:
1. release-please reads Conventional Commits and opens/updates a release PR.
2. Merging the release PR → tag `vX.Y.Z` + GitHub Release.
3. Floating tags `vX` and `vX.Y` are force-moved to the same commit (so consumers can pin `@v1` and float on minor/patch).
4. Multi-arch image built (linux/amd64 + linux/arm64) on native self-hosted runners.
5. Image is **signed** (Cosign keyless via OIDC) and **attested** (SLSA build provenance, pushed to registry alongside image).
6. SBOM (SPDX-JSON) attached to the GitHub Release.
7. Trivy scans the published image (vuln + secret + misconfig); release fails if HIGH/CRITICAL findings.

### `ci.yml` (PR-time security gate)

`trivy-fs` scans the source tree on every PR for vulnerabilities, embedded secrets, and Dockerfile/YAML misconfigurations. SARIF uploaded to the Code Scanning tab.

### `prerelease.yml` (feature-branch image)

Manual trigger to build a Docker image from any branch. Tag format: `<sanitized-branch>-<short-sha>` (e.g. `feat-auth-fix-a1b2c3d`) plus a moving `<sanitized-branch>` tag. Reviewers can `docker pull` to test. Trivy runs on the resulting image. A PR comment is posted/updated with the pull command.

### `cleanup.yml` (GHCR retention)

Weekly cron prunes old image versions: keeps the latest N stable `v*.*.*` versions; deletes prerelease/non-semver tags.

## Versioning

This catalog uses [Semantic Versioning](https://semver.org/) driven by [release-please](https://github.com/googleapis/release-please).

| Pin                                                          | Behavior                                |
|--------------------------------------------------------------|-----------------------------------------|
| `@v1`                                                        | Always latest 1.x.y                     |
| `@v1.2`                                                      | Always latest 1.2.x                     |
| `@v1.2.3`                                                    | Immutable, never changes                |

**Breaking changes** (any input/output/secret shape change) bump the major version. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Workflow contracts

The complete input/output/secret schema of every reusable workflow and composite action is documented in [`docs/contracts.md`](docs/contracts.md).

## Atomic workflows (advanced)

Most consumers should use `release.yml` (the orchestrator). For non-standard flows, the atoms are also reusable:

```yaml
# Example: PR-time security scan only
jobs:
  scan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@v1
```

| Atom                      | Purpose                                            |
|---------------------------|----------------------------------------------------|
| `semantic-release.yml`    | release-please + floating major/minor tags         |
| `docker-build.yml`        | multi-arch build + cosign + attestation + SBOM     |
| `docker-build-multi.yml`  | matrix fan-out over multiple Dockerfiles per repo  |
| `goreleaser.yml`          | goreleaser-action wrapper for CLI binary releases  |
| `helm-publish.yml`        | helm lint + package + OCI push to GHCR             |
| `trivy-image.yml`         | image vuln/secret/misconfig scan                   |
| `trivy-fs.yml`            | filesystem vuln/secret/misconfig scan              |
| `cleanup-images.yml`      | GHCR retention                                     |
| `lint-go.yml`             | `go vet` + golangci-lint                           |
| `test-go.yml`             | `go test` + coverage gate (default ≥ 80 %)         |
| `lint-python.yml`         | ruff check + format + mypy (poetry/uv/pip auto)    |
| `test-python.yml`         | pytest + coverage gate ≥ 80 % (poetry/uv/pip auto) |
| `lint-rust.yml`           | `cargo fmt --check` + `cargo clippy -D warnings`   |
| `test-rust.yml`           | `cargo test` + `cargo-llvm-cov` coverage gate      |
| `lint-helm.yml`           | `helm lint` + `ct lint`                            |

## Composite actions

Reusable sub-steps used internally by the atoms. Available for advanced consumers:

| Action                                 | Purpose                                    |
|----------------------------------------|--------------------------------------------|
| `actions/install-trivy`                | Pinned Trivy CLI install (direct binary)   |
| `actions/setup-sk-workflows`           | Install the Go onboarding CLI from release assets or source |
| `actions/ghcr-login`                   | GHCR login wrapper                         |
| `actions/compute-prerelease-tag`       | OCI-valid tag from branch + short SHA      |
| `actions/post-prerelease-comment`      | Idempotent PR comment with pull command    |
| `actions/setup-python-deps`            | Detect Python package manager (poetry/uv/pip-dev/pip-bare) + install deps |

## Local CLI preview

Build the onboarding CLI locally and render the same files the Go pipeline path
would produce into a scratch directory:

```bash
go build -o bin/sk-workflows ./cmd/sk-workflows
bin/sk-workflows preview \
  --repo-path ../target-repo \
  --out /tmp/sk-workflows-preview \
  --pin v4
```

The command writes `/tmp/sk-workflows-preview/profile.json`, rendered workflow
files, `.github/onboard.lock.json`, and a `key=value` summary on stdout. Pass
`--target-repo serverkraken/name` when you want GitHub metadata such as the
default branch, topics, and latest stable release.

## Operations

- **Setup, secret rotation, App permissions** — [`docs/operations.md`](docs/operations.md) §§1–6, plus spec [§9](docs/superpowers/specs/2026-05-16-reusable-workflows-design.md#9-operational-setup-org-level-one-time).
- **Onboarding adopters** — dispatch the **onboard** workflow from the catalog's **Actions** tab with a comma-separated target list. Renders all 4 adopter workflows + lock file via two PRs (add + cleanup). See [`docs/operations.md`](docs/operations.md) §5.
- **Drift audit** — [`drift-check.yml`](.github/workflows/drift-check.yml) runs weekly (Mon 06:00 UTC) and upserts a single rolling `Onboarding Drift Report` issue listing adopters that are `behind`, `modified`, or `no-lock`. See [`docs/operations.md`](docs/operations.md) §7.

## License

[MIT](LICENSE).
