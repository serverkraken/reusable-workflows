# Workflow Contracts

This file aggregates the public API (inputs / outputs / secrets) of every reusable workflow and composite action in the catalog. Any change to these shapes that adds required inputs, removes inputs, or renames outputs is a **breaking change** and requires a major version bump.

Adding optional inputs with safe defaults, adding outputs, or changing internal step ordering is non-breaking.

---

## Atomic Workflows

### `semantic-release.yml`

| Kind    | Name                            | Type    | Required | Default                                   | Description |
|---------|---------------------------------|---------|----------|-------------------------------------------|-------------|
| input   | `runs_on`                       | string  | no       | `'["self-hosted","Linux","low-performance"]'` | JSON-encoded runner labels |
| input   | `release_please_config`         | string  | no       | `'release-please-config.json'`            | Path to release-please config |
| input   | `release_please_manifest`       | string  | no       | `'.release-please-manifest.json'`         | Path to release-please manifest |
| secret  | `release_please_app_client_id`  | —       | yes      | —                                         | GitHub App Client ID (e.g. `Iv23li…`) |
| secret  | `release_please_app_private_key`| —       | yes      | —                                         | PEM-formatted App private key |
| output  | `release_created`               | string  | —        | —                                         | `'true'` when a release was created |
| output  | `tag_name`                      | string  | —        | —                                         | e.g. `'v1.2.3'` |
| output  | `major_tag`                     | string  | —        | —                                         | e.g. `'v1'` |
| output  | `minor_tag`                     | string  | —        | —                                         | e.g. `'v1.2'` |

---

### `docker-build.yml`

| Kind    | Name            | Type    | Required | Default                                        | Description |
|---------|-----------------|---------|----------|------------------------------------------------|-------------|
| input   | `tag`           | string  | no       | `''`                                           | Image tag; empty → auto-compute when `prerelease=true` |
| input   | `prerelease`    | boolean | no       | `false`                                        | Skip `:latest`, auto-compute tag if `tag` is empty |
| input   | `image_name`    | string  | no       | `${{ github.repository }}`                     | Image name (owner/repo) |
| input   | `dockerfile`    | string  | no       | `'./Dockerfile'`                               | Path to Dockerfile |
| input   | `context`       | string  | no       | `'.'`                                          | Docker build context |
| input   | `platforms`     | string  | no       | `'linux/amd64,linux/arm64'`                    | Comma-separated platform list; only listed platforms are built |
| input   | `build_args`    | string  | no       | `''`                                           | Newline-separated KEY=VALUE build args |
| input   | `sign`          | boolean | no       | `true`                                         | Cosign keyless signing via OIDC |
| input   | `attest`        | boolean | no       | `true`                                         | SLSA build provenance attestation |
| input   | `sbom`          | boolean | no       | `true`                                         | SPDX-JSON SBOM via Syft |
| input   | `runs_on_amd64` | string  | no       | `'["self-hosted","Linux","X64","performance"]'`| Runner for amd64 build job |
| input   | `runs_on_arm64` | string  | no       | `'["self-hosted","Linux","ARM64"]'`            | Runner for arm64 build job |
| input   | `runs_on_merge` | string  | no       | `'["self-hosted","Linux","low-performance"]'`  | Runner for version + merge jobs |
| output  | `image_ref`     | string  | —        | —                                              | `ghcr.io/<image_name>:<tag>` |
| output  | `digest`        | string  | —        | —                                              | Manifest-list digest `sha256:…` |
| output  | `tag`           | string  | —        | —                                              | Final tag (auto-computed if input was empty) |
| secret  | `release_please_app_client_id`  | — | **yes** | — | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret  | `release_please_app_private_key`| — | **yes** | — | App private key for the catalog-checkout token (since v2.0.0) |

---

### `trivy-image.yml`

| Kind    | Name              | Type    | Required | Default                      | Description |
|---------|-------------------|---------|----------|------------------------------|-------------|
| input   | `image_ref`       | string  | **yes**  | —                            | Full image reference, e.g. `ghcr.io/org/repo:v1.2.3` |
| input   | `scanners`        | string  | no       | `'vuln,secret,misconfig'`    | Trivy scanner list |
| input   | `severity`        | string  | no       | `'HIGH,CRITICAL'`            | Severity levels to report |
| input   | `ignore_unfixed`  | boolean | no       | `true`                       | Pass `--ignore-unfixed` to Trivy |
| input   | `fail_on_findings`| boolean | no       | `true`                       | Exit non-zero when findings exist |
| input   | `paths_ignore`    | string  | no       | `''`                         | Newline-separated paths to skip |
| input   | `upload_sarif`    | boolean | no       | `true`                       | Upload SARIF to code-scanning (auto-skipped on forks) |
| input   | `trivy_version`   | string  | no       | `''`                         | Override Trivy version |
| input   | `runs_on`         | string  | no       | `'["self-hosted","Linux"]'`  | JSON-encoded runner labels |
| output  | `findings_count`  | string  | —        | —                            | Number of severity-matching findings |
| secret  | `release_please_app_client_id`  | — | **yes** | — | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret  | `release_please_app_private_key`| — | **yes** | — | App private key for the catalog-checkout token (since v2.0.0) |

---

### `trivy-fs.yml`

| Kind    | Name              | Type    | Required | Default                      | Description |
|---------|-------------------|---------|----------|------------------------------|-------------|
| input   | `scanners`        | string  | no       | `'vuln,secret,misconfig'`    | Trivy scanner list |
| input   | `severity`        | string  | no       | `'HIGH,CRITICAL'`            | Severity levels to report |
| input   | `paths_ignore`    | string  | no       | `''`                         | Newline-separated paths to skip |
| input   | `upload_sarif`    | boolean | no       | `true`                       | Upload SARIF to code-scanning (auto-skipped on forks) |
| input   | `trivy_version`   | string  | no       | `''`                         | Override Trivy version |
| input   | `ignore_unfixed`  | boolean | no       | `true`                       | Pass `--ignore-unfixed` to Trivy |
| input   | `fail_on_findings`| boolean | no       | `true`                       | Exit non-zero when findings exist |
| input   | `runs_on`         | string  | no       | `'["self-hosted","Linux"]'`  | JSON-encoded runner labels |
| output  | `findings_count`  | string  | —        | —                            | Number of severity-matching findings |
| secret  | `release_please_app_client_id`  | — | **yes** | — | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret  | `release_please_app_private_key`| — | **yes** | — | App private key for the catalog-checkout token (since v2.0.0) |

---

### `cleanup-images.yml`

| Kind    | Name                   | Type   | Required | Default                     | Description |
|---------|------------------------|--------|----------|-----------------------------|-------------|
| input   | `package_name`         | string | no       | `${{ github.event.repository.name }}` | GHCR package name |
| input   | `keep_stable_versions` | number | no       | `10`                        | Min count of semver (`v*.*.*`) versions to keep |
| input   | `prerelease_age_days`  | number | no       | `14`                        | Delete non-semver tags older than N days |
| input   | `runs_on`              | string | no       | `'["self-hosted","Linux"]'` | JSON-encoded runner labels |

---

## Orchestrator

### `release.yml`

| Kind    | Name                            | Type    | Required | Default                      | Description |
|---------|---------------------------------|---------|----------|------------------------------|-------------|
| input   | `build_image`                   | boolean | no       | `true`                       | `false` → release-only (library repos) |
| input   | `run_trivy`                     | boolean | no       | `true`                       | Run trivy-image after build (only when `build_image`) |
| input   | `dockerfile`                    | string  | no       | `'./Dockerfile'`             | Pass-through to docker-build |
| input   | `context`                       | string  | no       | `'.'`                        | Pass-through to docker-build |
| input   | `platforms`                     | string  | no       | `'linux/amd64,linux/arm64'`  | Pass-through to docker-build |
| input   | `trivy_severity`                | string  | no       | `'HIGH,CRITICAL'`            | Pass-through to trivy-image |
| secret  | `release_please_app_client_id`  | —       | yes      | —                            | Pass-through to semantic-release |
| secret  | `release_please_app_private_key`| —       | yes      | —                            | Pass-through to semantic-release |

---

## Composite Actions

### `actions/install-trivy`

| Kind  | Name      | Type   | Required | Default | Description |
|-------|-----------|--------|----------|---------|-------------|
| input | `version` | string | no       | `''`    | Trivy version to install; empty → uses pinned default |

### `actions/ghcr-login`

No inputs. Logs in to `ghcr.io` using `GITHUB_TOKEN`.

### `actions/compute-prerelease-tag`

| Kind   | Name           | Type   | Required | Default | Description |
|--------|----------------|--------|----------|---------|-------------|
| input  | `branch`       | string | yes      | —       | Branch name (sanitized to OCI-valid slug) |
| input  | `short_sha`    | string | yes      | —       | 7-char short SHA |
| output | `tag_with_sha` | string | —        | —       | e.g. `feat-my-branch-a1b2c3d` |
| output | `moving_tag`   | string | —        | —       | e.g. `feat-my-branch` (moving tag for the branch) |

### `actions/post-prerelease-comment`

| Kind  | Name        | Type   | Required | Default | Description |
|-------|-------------|--------|----------|---------|-------------|
| input | `image_ref` | string | yes      | —       | Full image reference for the pull command |
| input | `pr_number` | string | yes      | —       | PR number to comment on |

---

## Internal Composite Actions

These are not intended for external consumption — they exist to factor `onboard.yml`. Their inputs/outputs are not part of the catalog's semver-protected surface.

### `actions/onboard-detect`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `repo_path` | string | yes | — | Path to checked-out target repo on the runner |
| input | `language_override` | string | no | `'auto'` | `auto` runs file-signal detection; otherwise forces the value |
| input | `target_repo` | string | yes | — | `owner/repo` of target (for `gh` API lookups) |
| input | `github_token` | string | yes | — | Token with read access to `target_repo` |
| output | `language` | string | — | — | Detected language |
| output | `release_type` | string | — | — | release-please release-type (1:1 with language for V1) |
| output | `current_version` | string | — | — | Current version (no leading `v`); `0.0.0` if no release found |
| output | `default_branch` | string | — | — | Default branch of `target_repo` |

### `actions/onboard-render`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `catalog_path` | string | yes | — | Path to checked-out catalog repo |
| input | `target_path` | string | yes | — | Path to checked-out target repo (rendered files written here) |
| input | `release_type` | string | yes | — | release-please release-type |
| input | `current_version` | string | yes | — | Current version, no leading `v` |
| input | `pin_version` | string | no | `'v1'` | Catalog `@version` to pin rendered templates to |
