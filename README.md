# serverkraken/reusable-workflows

Versioned, tested catalog of GitHub Actions reusable workflows for the `serverkraken` organisation. Stop copying CI workflows between repos — reference them with a one-line `uses:`.

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

The complete input/output/secret schema of every reusable workflow is documented in the [design spec](docs/superpowers/specs/2026-05-16-reusable-workflows-design.md) §4.

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

## Composite actions

Reusable sub-steps used internally by the atoms. Available for advanced consumers:

| Action                                 | Purpose                                    |
|----------------------------------------|--------------------------------------------|
| `actions/install-trivy`                | Pinned Trivy CLI install (direct binary)   |
| `actions/ghcr-login`                   | GHCR login wrapper                         |
| `actions/compute-prerelease-tag`       | OCI-valid tag from branch + short SHA      |
| `actions/post-prerelease-comment`      | Idempotent PR comment with pull command    |

## Operations

See the [spec §9](docs/superpowers/specs/2026-05-16-reusable-workflows-design.md#9-operational-setup-org-level-one-time) for the GitHub App setup, Actions access policy, and private-key rotation runbook.

## License

[MIT](LICENSE).
