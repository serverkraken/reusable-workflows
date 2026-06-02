# Workflow Contracts

This file aggregates the public API (inputs / outputs / secrets) of every reusable workflow and composite action in the catalog. Any change to these shapes that adds required inputs, removes inputs, or renames outputs is a **breaking change** and requires a major version bump.

Adding optional inputs with safe defaults, adding outputs, or changing internal step ordering is non-breaking.

---

## Atomic Workflows

### `cleanup-images.yml`

| Kind    | Name                   | Type   | Required | Default                     | Description |
|---------|------------------------|--------|----------|-----------------------------|-------------|
| input   | `package_name`         | string | no       | `${{ github.event.repository.name }}` | GHCR package name |
| input   | `keep_stable_versions` | number | no       | `10`                        | Min count of semver (`v*.*.*`) versions to keep |
| input   | `prerelease_age_days`  | number | no       | `14`                        | Delete non-semver tags older than N days |
| input   | `runs_on`              | string | no       | `'["self-hosted","Linux"]'` | JSON-encoded runner labels |

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

### `docker-build-multi.yml`

| Kind    | Name              | Type    | Required | Default                                         | Description |
|---------|-------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `images`          | string  | **yes**  | —                                               | JSON array of objects describing each image to build. Each entry must have `dockerfile` (path to the Dockerfile) and `image_name` (owner/repo[/suffix] passed through to docker-build.yml). Example: `'[{"dockerfile":"./Dockerfile","image_name":"acme/api"}, {"dockerfile":"./Dockerfile.worker","image_name":"acme/worker"}]'` |
| input   | `context`         | string  | no       | `'.'`                                           | Shared build context for every image (default: `.`). |
| input   | `tag`             | string  | no       | `''`                                            | Shared tag for every image. Empty → auto-compute (prerelease only). |
| input   | `prerelease`      | boolean | no       | `false`                                         | Prerelease build (no `:latest`, auto-compute tag if empty). |
| input   | `platforms`       | string  | no       | `'linux/amd64,linux/arm64'`                     | Comma-separated platform list forwarded to each nested docker-build. |
| input   | `build_args`      | string  | no       | `''`                                            | Newline-separated KEY=VALUE build args forwarded to each nested docker-build. |
| input   | `sign`            | boolean | no       | `true`                                          | Cosign keyless signing via OIDC (forwarded). |
| input   | `attest`          | boolean | no       | `true`                                          | SLSA build provenance attestation (forwarded). |
| input   | `sbom`            | boolean | no       | `true`                                          | SPDX-JSON SBOM via Syft (forwarded). |
| input   | `runs_on_amd64`   | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | Runner for amd64 build job (forwarded). |
| input   | `runs_on_arm64`   | string  | no       | `'["self-hosted","Linux","ARM64"]'`             | Runner for arm64 build job (forwarded). |
| input   | `runs_on_merge`   | string  | no       | `'["self-hosted","Linux","low-performance"]'`   | Runner for version + merge jobs (forwarded). |
| input   | `runs_on_parse`   | string  | no       | `'["self-hosted","Linux","low-performance"]'`   | Runner for the parse job (pure shell; low-performance is fine). |
| secret  | `release_please_app_client_id`  | — | **yes** | — | GitHub App Client ID with `contents:read` on the catalog repo. Forwarded to docker-build.yml. |
| secret  | `release_please_app_private_key`| — | **yes** | — | PEM private key for the GitHub App. Forwarded to docker-build.yml. |

---

### `goreleaser.yml`

| Kind    | Name                 | Type    | Required | Default                     | Description |
|---------|----------------------|---------|----------|-----------------------------|-------------|
| input   | `working_directory`  | string  | no       | `'.'`                       | Directory containing `go.mod` and `.goreleaser.yaml`. |
| input   | `goreleaser_version` | string  | no       | `'~> v2'`                   | goreleaser version constraint (e.g. `~> v2`, `v2.5.0`, `latest`). |
| input   | `snapshot`           | boolean | no       | `false`                     | Run in `--snapshot` mode (no publish). Useful for PR smoke tests. |
| input   | `runs_on`            | string  | no       | `'["self-hosted","Linux"]'` | JSON-encoded array of runner labels. |

---

### `helm-publish.yml`

| Kind    | Name           | Type    | Required | Default                     | Description |
|---------|----------------|---------|----------|-----------------------------|-------------|
| input   | `chart_path`   | string  | **yes**  | —                           | Directory containing `Chart.yaml`. |
| input   | `oci_registry` | string  | **yes**  | —                           | OCI registry path (host + namespace) to push to, without the chart name. Example: `ghcr.io/serverkraken/charts`. |
| input   | `helm_version` | string  | no       | `'v3.15.0'`                 | Helm CLI version to install (e.g. `v3.15.0`, `latest`). |
| input   | `dry_run`      | boolean | no       | `false`                     | Lint and package only; skip registry login + push. |
| input   | `runs_on`      | string  | no       | `'["self-hosted","Linux"]'` | JSON-encoded array of runner labels. |

---

### `lint-go.yml`

| Kind  | Name                    | Type    | Required | Default                                | Description |
|-------|-------------------------|---------|----------|----------------------------------------|-------------|
| input | `runs_on`               | string  | no       | `'["self-hosted","Linux","X64"]'`      | JSON-encoded array of runner labels. |
| input | `working_directory`     | string  | no       | `'.'`                                  | Component sub-path. Atom resolves all paths relative to this. |
| input | `go_version`            | string  | no       | `''`                                   | Go toolchain version. Empty → read from `<working_directory>/go.mod`. |
| input | `golangci_lint_version` | string  | no       | `'v2.12.2'`                            | golangci-lint version (e.g. `v2.12.2`). Must be `v2.1.0+` to be compatible with golangci-lint-action@v9. |
| input | `cgo_enabled`           | boolean | no       | `false`                                | Set `CGO_ENABLED=1` (true) or `0` (false). Mirror the value used in `test-go.yml` for cgo-dependent packages. |

---

### `lint-helm.yml`

| Kind  | Name                | Type    | Required | Default                     | Description |
|-------|---------------------|---------|----------|-----------------------------|-------------|
| input | `runs_on`           | string  | no       | `'["self-hosted","Linux"]'` | JSON-encoded array of runner labels. |
| input | `working_directory` | string  | no       | `'.'`                       | Repo root for `ct` (`charts_dir` is relative to this). |
| input | `charts_dir`        | string  | no       | `'charts'`                  | Directory containing one or more charts (relative to `working_directory`). |
| input | `helm_version`      | string  | no       | `'v3.16.3'`                 | Helm CLI version. |
| input | `ct_version`        | string  | no       | `'v3.11.0'`                 | chart-testing (`ct`) version. |

---

### `lint-python.yml`

| Kind   | Name                            | Type   | Required | Default                     | Description |
|--------|---------------------------------|--------|----------|-----------------------------|-------------|
| input  | `runs_on`                       | string | no       | `'["self-hosted","Linux"]'` | JSON-encoded array of runner labels. |
| input  | `working_directory`             | string | no       | `'.'`                       | Component sub-path. |
| input  | `python_version`                | string | no       | `''`                        | Python version. Empty → read from `<working_directory>/pyproject.toml`. |
| secret | `release_please_app_client_id`  | —      | **yes**  | —                           | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret | `release_please_app_private_key`| —      | **yes**  | —                           | App private key for the catalog-checkout token (since v2.0.0) |

---

### `lint-rust.yml`

| Kind  | Name             | Type   | Required | Default                           | Description |
|-------|------------------|--------|----------|-----------------------------------|-------------|
| input | `runs_on`        | string | no       | `'["self-hosted","Linux","X64"]'` | JSON-encoded array of runner labels. |
| input | `working_directory` | string | no    | `'.'`                             | Crate root directory. |
| input | `rust_toolchain` | string | no       | `''`                              | rustup toolchain. Empty → rustup reads `rust-toolchain.toml` if present, else stable. |
| input | `clippy_args`    | string | no       | `'-D warnings'`                   | Extra arguments to clippy after `--`. |

---

### `semantic-release.yml`

| Kind    | Name                            | Type    | Required | Default                                   | Description |
|---------|---------------------------------|---------|----------|-------------------------------------------|-------------|
| input   | `runs_on`                       | string  | no       | `'["self-hosted","Linux","low-performance"]'` | JSON-encoded runner labels |
| input   | `release_please_config`         | string  | no       | `'release-please-config.json'`            | Path to release-please config |
| input   | `release_please_manifest`       | string  | no       | `'.release-please-manifest.json'`         | Path to release-please manifest |
| input   | `dry_run`                       | boolean | no       | `false`                                   | When true, run release-please without creating PRs/releases or moving floating tags (integration-test use only) |
| secret  | `release_please_app_client_id`  | —       | **yes**  | —                                         | GitHub App Client ID (e.g. `Iv23li…`) |
| secret  | `release_please_app_private_key`| —       | **yes**  | —                                         | PEM-formatted App private key |
| output  | `release_created`               | string  | —        | —                                         | `'true'` when a release was created |
| output  | `tag_name`                      | string  | —        | —                                         | e.g. `'v1.2.3'` |
| output  | `major_tag`                     | string  | —        | —                                         | e.g. `'v1'` |
| output  | `minor_tag`                     | string  | —        | —                                         | e.g. `'v1.2'` |

---

### `test-go.yml`

| Kind  | Name                 | Type    | Required | Default                           | Description |
|-------|----------------------|---------|----------|-----------------------------------|-------------|
| input | `runs_on`            | string  | no       | `'["self-hosted","Linux","X64"]'` | JSON-encoded array of runner labels. |
| input | `working_directory`  | string  | no       | `'.'`                             | Component sub-path. |
| input | `go_version`         | string  | no       | `''`                              | Go toolchain version. Empty → read from `<working_directory>/go.mod`. |
| input | `coverage_threshold` | number  | no       | `80`                              | Minimum line coverage percentage (integer 0-100). |
| input | `cgo_enabled`        | boolean | no       | `false`                           | Set `CGO_ENABLED=1` (true) or `0` (false). Required true for cgo-dependent packages like `go-sqlite3`. |

---

### `test-python.yml`

| Kind   | Name                            | Type   | Required | Default                     | Description |
|--------|---------------------------------|--------|----------|-----------------------------|-------------|
| input  | `runs_on`                       | string | no       | `'["self-hosted","Linux"]'` | JSON-encoded array of runner labels. |
| input  | `working_directory`             | string | no       | `'.'`                       | Component sub-path. |
| input  | `python_version`                | string | no       | `''`                        | Python version. Empty → read from `<working_directory>/pyproject.toml`. |
| input  | `coverage_threshold`            | number | no       | `80`                        | Minimum line coverage percentage (integer 0-100). |
| secret | `release_please_app_client_id`  | —      | **yes**  | —                           | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret | `release_please_app_private_key`| —      | **yes**  | —                           | App private key for the catalog-checkout token (since v2.0.0) |

---

### `test-rust.yml`

| Kind  | Name                    | Type   | Required | Default                           | Description |
|-------|-------------------------|--------|----------|-----------------------------------|-------------|
| input | `runs_on`               | string | no       | `'["self-hosted","Linux","X64"]'` | JSON-encoded array of runner labels. |
| input | `working_directory`     | string | no       | `'.'`                             | Crate root directory. |
| input | `rust_toolchain`        | string | no       | `''`                              | rustup toolchain. Empty → rustup defaults. |
| input | `coverage_threshold`    | number | no       | `80`                              | Minimum line coverage percentage (integer 0-100). |
| input | `cargo_llvm_cov_version`| string | no       | `'0.6.16'`                        | cargo-llvm-cov release version (bare semver — `taiki-e/install-action` rejects a leading `v`). |

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

## Orchestrator

### `release.yml`

| Kind    | Name                            | Type    | Required | Default                                         | Description |
|---------|---------------------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `build_image`                   | boolean | no       | `true`                                          | `false` → release-only (library repos) |
| input   | `run_trivy`                     | boolean | no       | `true`                                          | Run trivy-image after build (only when `build_image`) |
| input   | `dockerfile`                    | string  | no       | `'./Dockerfile'`                                | Pass-through to docker-build |
| input   | `context`                       | string  | no       | `'.'`                                           | Pass-through to docker-build |
| input   | `platforms`                     | string  | no       | `'linux/amd64,linux/arm64'`                     | Pass-through to docker-build |
| input   | `sign`                          | boolean | no       | `true`                                          | Pass-through to docker-build (Cosign keyless signing via OIDC) |
| input   | `attest`                        | boolean | no       | `true`                                          | Pass-through to docker-build (SLSA build provenance attestation) |
| input   | `sbom`                          | boolean | no       | `true`                                          | Pass-through to docker-build (SPDX-JSON SBOM via Syft) |
| input   | `trivy_severity`                | string  | no       | `'HIGH,CRITICAL'`                               | Pass-through to trivy-image |
| input   | `image_name`                    | string  | no       | `''`                                            | Pass-through to docker-build (default: caller repo) |
| input   | `runs_on_amd64`                 | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | Pass-through to docker-build (amd64 build job) |
| input   | `runs_on_arm64`                 | string  | no       | `'["self-hosted","Linux","ARM64"]'`             | Pass-through to docker-build (arm64 build job) |
| input   | `runs_on_merge`                 | string  | no       | `'["self-hosted","Linux","low-performance"]'`   | Pass-through to docker-build (version + merge jobs) |
| secret  | `release_please_app_client_id`  | —       | **yes**  | —                                               | Pass-through to semantic-release |
| secret  | `release_please_app_private_key`| —       | **yes**  | —                                               | Pass-through to semantic-release |

---

## Composite Actions

### `actions/install-trivy`

| Kind  | Name      | Type   | Required | Default | Description |
|-------|-----------|--------|----------|---------|-------------|
| input | `version` | string | no       | `''`    | Trivy version to install; empty → uses pinned default |

### `actions/setup-sk-workflows`

| Kind   | Name                | Type   | Required | Default                          | Description |
|--------|---------------------|--------|----------|----------------------------------|-------------|
| input  | `version`           | string | no       | `''`                             | Catalog release tag to install, e.g. `v4.2.0`. Empty uses the action ref when it is a `v*` tag |
| input  | `repository`        | string | no       | `serverkraken/reusable-workflows` | Repository containing `sk-workflows` release assets |
| input  | `github_token`      | string | no       | `''`                             | Optional token for downloading release assets from private repositories |
| input  | `install_dir`       | string | no       | `''`                             | Install directory. Empty uses `${RUNNER_TEMP}/sk-workflows/bin` |
| input  | `build_from_source` | string | no       | `'false'`                        | `true` builds from the checked-out catalog source instead of downloading a release asset |
| output | `path`              | string | —        | —                                | Full path to the installed binary |
| output | `version`           | string | —        | —                                | Resolved release tag, or `source` when built from source |
| output | `source`            | string | —        | —                                | Installation source: `release` or `source` |

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
| input | `use_go_cli` | string | no | `'false'` | `true` runs `sk-workflows detect`; the wrapper prefers an installed `sk-workflows` binary on `PATH` |
| output | `language` | string | — | — | Detected language |
| output | `release_type` | string | — | — | release-please release-type (1:1 with language for V1) |
| output | `current_version` | string | — | — | Current version (no leading `v`); `0.0.0` if no release found |
| output | `default_branch` | string | — | — | Default branch of `target_repo` |
| output | `profile_json` | string | — | — | Full structured detection profile (JSON-encoded) |

### `actions/onboard-render`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `catalog_path` | string | yes | — | Path to checked-out catalog repo |
| input | `target_path` | string | yes | — | Path to checked-out target repo (rendered files written here) |
| input | `profile_json` | string | yes | — | Detection profile JSON from `onboard-detect` (forwarded as multi-line input) |
| input | `pin_version` | string | no | `'v1'` | Catalog `@version` to pin rendered templates to |
| input | `use_go_cli` | string | no | `'false'` | `true` runs `sk-workflows render`; the wrapper prefers an installed `sk-workflows` binary on `PATH` |

### `actions/onboard-drift`

| Kind | Name | Type | Required | Default | Description |
|---|---|---|---|---|---|
| input | `target_path` | string | yes | — | Path to checked-out adopter repo (contains `.github/onboard.lock.json`) |
| input | `current_version` | string | yes | — | Current catalog major (e.g. `v3`) used to compute `behind`/`clean` |
| input | `use_go_cli` | string | no | `'false'` | `true` runs `sk-workflows drift`; the wrapper prefers an installed `sk-workflows` binary on `PATH` |
| output | `status` | string | — | — | One of `clean` / `modified` / `behind` / `behind+modified` / `no-lock` |
| output | `modified` | string | — | — | Comma-separated list of paths whose hash differs from lock (or has the `(missing)` suffix) |
| output | `lock_version` | string | — | — | `catalog_version` field from `.github/onboard.lock.json` (empty when `no-lock`) |
