# Workflow Contracts

This file aggregates the public API (inputs / outputs / secrets) of every reusable workflow and composite action in the catalog. Any change to these shapes that adds required inputs, removes inputs, or renames outputs is a **breaking change** and requires a major version bump.

Adding optional inputs with safe defaults, adding outputs, or changing internal step ordering is non-breaking.

---

## Atomic Workflows

### `build-flutter-android.yml`

PR-time Android compile gate: runs `flutter build apk --<build_mode>` with no
release semantics — no signing, no upload, no version handling. Complements
`release-flutter-android.yml`. Typically called from the rendered
`ci-android.yml` (paths-filtered; NOT suitable as a required check).

| Kind    | Name                 | Type    | Required | Default                                         | Description |
|---------|----------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`            | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory`  | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `java_version`       | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`    | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`    | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`   | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `build_mode`         | string  | no       | `'debug'`                                       | `debug` \| `profile` \| `release`; debug needs no keystore |
| input   | `flavor`             | string  | no       | `''`                                            | Build flavor (empty = no `--flavor` flag) |
| input   | `sdk_cache`          | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (off — key rotates per Flutter release) |
| input   | `timeout_minutes`    | number  | no       | `45`                                            | Job timeout |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |

---

### `cleanup-images.yml`

| Kind    | Name                   | Type   | Required | Default                     | Description |
|---------|------------------------|--------|----------|-----------------------------|-------------|
| input   | `package_name`         | string | no       | `${{ github.event.repository.name }}` | GHCR package name |
| input   | `keep_stable_versions` | number | no       | `10`                        | Min count of semver (`v*.*.*`) versions to keep |
| input   | `prerelease_age_days`  | number | no       | `14`                        | Delete non-semver tags older than N days |
| input   | `runs_on`              | string | no       | `'["self-hosted","Linux"]'` | JSON-encoded runner labels |

A package that does not exist is a no-op: the job logs `not published (yet)`
and succeeds. Retention on a repo that has not cut its first release yet is
not an error, and a red weekly cron there would train people to ignore it.

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
| input   | `ref`           | string  | no       | `''`                                           | Git ref (tag/branch/SHA) to check out before building. Release callers whose run creates the bump commit and tag (release-please) should pass the released tag; empty keeps the default event-SHA checkout. |
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
| input   | `ref`             | string  | no       | `''`                                            | Git ref to check out before building (forwarded to docker-build). Release callers should pass the released tag; empty keeps the default event-SHA checkout. |
| input   | `runs_on_parse`   | string  | no       | `'["self-hosted","Linux","low-performance"]'`   | Runner for the parse job (pure shell; low-performance is fine). |
| input   | `caller_id`       | string  | no       | `''`                                            | Optional caller identifier appended to the concurrency group for parallel callers. |
| secret  | `release_please_app_client_id`  | — | **yes** | — | GitHub App Client ID with `contents:read` on the catalog repo. Forwarded to docker-build.yml. |
| secret  | `release_please_app_private_key`| — | **yes** | — | PEM private key for the GitHub App. Forwarded to docker-build.yml. |

---

### `e2e-kind.yml`

Kubernetes e2e atom: provisions a kind toolchain (kind/kubectl/cilium-cli via
`setup-kind-toolchain`, Helm via azure/setup-helm) and runs a consumer-owned
script that owns the kind-cluster lifecycle end to end. On failure, collects
per-cluster diagnostics (nodes, pods, events, `kind export logs`) into the
`e2e-kind-diagnostics` artifact. Cleanup is unconditional and self-asserting:
every kind cluster is deleted after the job, and a leftover cluster fails the
job even on an otherwise-green run — required on the long-lived self-hosted
runner pods.

| Kind    | Name                  | Type    | Required | Default                                         | Description |
|---------|-----------------------|---------|----------|--------------------------------------------------|-------------|
| input   | `runs_on`             | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded array of runner labels |
| input   | `script`              | string  | **yes**  | —                                                | Consumer e2e script path (relative to `working_directory`), e.g. `test/e2e/run.sh`. Owns the kind-cluster lifecycle |
| input   | `working_directory`   | string  | no       | `'.'`                                            | Component sub-path |
| input   | `timeout_minutes`     | number  | no       | `45`                                             | Job timeout in minutes |
| input   | `kind_version`        | string  | no       | `''`                                             | kind version (leading v). Empty → `setup-kind-toolchain` pinned default |
| input   | `kubectl_version`     | string  | no       | `''`                                             | kubectl version (leading v). Empty → `setup-kind-toolchain` pinned default |
| input   | `cilium_cli_version`  | string  | no       | `''`                                             | cilium-cli version (leading v). Empty → `setup-kind-toolchain` pinned default |
| input   | `helm_version`        | string  | no       | `'v3.16.3'`                                      | Helm CLI version |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |

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
| input   | `ref`          | string  | no       | `''`                        | Git ref (tag/branch/SHA) to check out before packaging. Callers whose release job creates the version-bump commit and tag in the same run (release-please) must pass the released tag here; empty keeps the default event-SHA checkout. |

---

### `lint-flutter.yml`

Runs `dart format --set-exit-if-changed` + `flutter analyze`.

| Kind    | Name                | Type    | Required | Default                                         | Description |
|---------|---------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`           | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory` | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `java_version`      | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`   | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`   | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`  | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `sdk_cache`         | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (since v4; off — key rotates per Flutter release) |
| input   | `timeout_minutes`   | number  | no       | `30`                                            | Job timeout (since v4) |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |

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
| input | `unittest`          | boolean | no       | `false`                     | Run helm-unittest (`tests/*_test.yaml` in each chart) after linting. |

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

### `release-flutter-android.yml`

Builds a signed Android APK and/or AAB and attaches it to a GitHub Release.

| Kind    | Name                       | Type    | Required | Default                                         | Description |
|---------|----------------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`                  | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory`        | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `version`                  | string  | no       | `''`                                            | Semver (leading v optional). Empty only with `create_release=true` → derives `<latest>-rc.<run_number>` from the newest exact `vX.Y.Z` tag (none → `0.0.0`) |
| input   | `create_release`           | boolean | no       | `false`                                         | Create the Release at the resolved tag before upload (manual/ad-hoc builds) |
| input   | `java_version`             | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`          | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`          | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`         | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `build_apk`                | boolean | no       | `true`                                          | Build a release APK |
| input   | `build_aab`                | boolean | no       | `false`                                         | Build a release AAB |
| input   | `flavor`                   | string  | no       | `''`                                            | Build flavor (empty = no `--flavor`) |
| input   | `prerelease`               | boolean | no       | `false`                                         | Mark the GitHub Release as prerelease |
| input   | `dart_define_secret_names` | string  | no       | `''`                                            | Comma-separated secret names forwarded as `--dart-define=NAME=$VALUE` |
| input   | `artefact_name_prefix`     | string  | no       | `''`                                            | Prefix for renamed artefacts (empty = repo name) |
| input   | `sdk_cache`                | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (since v4; off — key rotates per Flutter release) |
| input   | `timeout_minutes`          | number  | no       | `45`                                            | Job timeout (since v4) |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |
| secret  | `ANDROID_KEYSTORE_BASE64`        | — | **yes** | — | Base64-encoded release keystore |
| secret  | `ANDROID_STORE_PASSWORD`         | — | **yes** | — | Keystore store password |
| secret  | `ANDROID_KEY_ALIAS`              | — | **yes** | — | Key alias inside the keystore |
| secret  | `ANDROID_KEY_PASSWORD`           | — | **yes** | — | Key password |

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
| output  | `paths_released`                | string  | —        | —                                         | JSON array of released package paths, e.g. `'["."]'`; `'[]'` when idle |
| output  | `releases`                      | string  | —        | —                                         | JSON object `{"<path>":{"tag_name","version","major","minor"}}`; `'{}'` when idle |

---

### `test-flutter.yml`

Runs `flutter test --coverage` and enforces a line-coverage threshold.

| Kind    | Name                 | Type    | Required | Default                                         | Description |
|---------|----------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`            | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory`  | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `java_version`       | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`    | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`    | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`   | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `coverage_threshold` | number  | no       | `80`                                            | Minimum line coverage percentage (0-100) |
| input   | `sdk_cache`          | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (since v4; off — key rotates per Flutter release) |
| input   | `timeout_minutes`    | number  | no       | `45`                                            | Job timeout (since v4) |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |

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
| input  | `coverage_source`               | string | no       | `''`                        | What coverage measures (`--cov=<value>`). Leave empty when the project configures it itself via `[tool.coverage.run] source` or pytest `addopts`; with neither, the run fails loudly instead of reporting a gate it never ran. |
| output | `coverage_pct`                  | string | —        | —                           | Measured line coverage, or `N/A` when no report was produced. |
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
| input   | `files_ignore`    | string  | no       | `''`                         | Newline-separated files to skip |
| input   | `upload_sarif`    | boolean | no       | `true`                       | Upload SARIF to code-scanning (auto-skipped on forks) |
| input   | `report_slug`     | string  | no       | `''`                         | Suffix making the SARIF category and artifact name unique; set it when calling this atom more than once per workflow |
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
| input   | `platforms`       | string  | no       | `''`                         | Comma-separated platforms to scan; empty scans only the one Trivy picks (`linux/amd64`) |
| input   | `trivy_version`   | string  | no       | `''`                         | Override Trivy version |
| input   | `runs_on`         | string  | no       | `'["self-hosted","Linux"]'`  | JSON-encoded runner labels |
| output  | `findings_count`  | string  | —        | —                            | Number of severity-matching findings |
| secret  | `release_please_app_client_id`  | — | **yes** | — | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret  | `release_please_app_private_key`| — | **yes** | — | App private key for the catalog-checkout token (since v2.0.0) |

The SARIF `category` and the SARIF artifact name carry a slug derived from
`image_ref` (`ghcr.io/org/repo/postfix:v1` → `repo-postfix`), so several scans
in one run stay separable. A shared category would make each upload replace the
previous image's code-scanning results; a shared artifact name leaves reports
nobody can attribute to an image. `docker-build.yml` suffixes its SBOM artifact
the same way.

---

### `version-badges.yml`

| Kind    | Name                             | Type    | Required | Default                                        | Description |
|---------|----------------------------------|---------|----------|------------------------------------------------|-------------|
| input   | `runs_on`                        | string  | no       | `'["self-hosted","Linux","low-performance"]'`  | JSON-encoded runner labels |
| input   | `manifest_path`                  | string  | no       | `'.release-please-manifest.json'`              | release-please manifest (package path → version) |
| input   | `config_path`                    | string  | no       | `'release-please-config.json'`                 | release-please config (optional; release-type, package-name, include-component-in-tag) |
| input   | `readme_path`                    | string  | no       | `'README.md'`                                  | README carrying the `<!-- version-badges:start/end -->` markers |
| input   | `badges_dir`                     | string  | no       | `'docs/badges'`                                | Output directory for the SVG files |
| input   | `commit`                         | boolean | no       | `true`                                         | Commit + push the result (false for dry runs / self-CI) |
| input   | `commit_message`                 | string  | no       | `'chore(badges): update version badges [skip ci]'` | Commit message |
| secret  | `release_please_app_client_id`   | —       | **yes**  | —                                              | App Client ID (catalog checkout + badge commit) |
| secret  | `release_please_app_private_key` | —       | **yes**  | —                                              | App private key |
| output  | `changed`                        | string  | —        | —                                              | `'true'` when README or a badge file changed |
| output  | `badges`                         | string  | —        | —                                              | Number of badges rendered |

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
| input   | `trivy_fail_on_findings`        | boolean | no       | `true`                                          | Pass-through to trivy-image; set false to report findings without failing the release |
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

### `sk-workflows` CLI

`actions/setup-sk-workflows` is part of the documented composite-action surface. The installed `sk-workflows` binary is an operational helper used by onboarding and drift workflows, but its subcommands and stdout keys are not semver-protected public catalog contracts yet. External automation should call the reusable workflows or composite actions above; local operator use such as `sk-workflows preview` is supported as a rollout tool and may evolve with `next`.

### `actions/ghcr-login`

Logs in to `ghcr.io` using the workflow actor and `GITHUB_TOKEN` by default.

| Kind  | Name       | Type   | Required | Default              | Description |
|-------|------------|--------|----------|----------------------|-------------|
| input | `username` | string | no       | `${{ github.actor }}` | GHCR username |
| input | `token`    | string | no       | `${{ github.token }}` | GHCR token |

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
| input | `trivy_status` | string | no    | `''`    | Optional Trivy result line appended to the comment |
| input | `commit_sha` | string | no      | `''`    | Optional commit SHA; empty derives a short SHA from the image tag |
| input | `github_token` | string | no    | `${{ github.token }}` | Token with `pull-requests:write` permission |

### `actions/setup-flutter-toolchain`

Shared by the lint-flutter, test-flutter, build-flutter-android, and release-flutter-android atoms:
setup-java → setup-android (`platform-tools` only) → subosito/flutter-action
→ `flutter pub get` → optional build_runner.

| Kind  | Name                | Type   | Required | Default     | Description |
|-------|---------------------|--------|----------|-------------|-------------|
| input | `java-version`      | string | no       | `'17'`      | Java major version |
| input | `java-distribution` | string | no       | `'temurin'` | Distribution slug for actions/setup-java |
| input | `flutter-channel`   | string | no       | `'stable'`  | Flutter release channel |
| input | `flutter-version`   | string | no       | `''`        | Specific Flutter version (empty = latest on channel) |
| input | `use-build-runner`  | string | no       | `'true'`    | Run build_runner after pub get |
| input | `working-directory` | string | no       | `'.'`       | Flutter project root |
| input | `sdk-cache`         | string | no       | `'false'`   | Cache the Flutter SDK via actions/cache (off: key rotates per Flutter stable) |

### `actions/setup-kind-toolchain`

Installs kind + kubectl + cilium-cli for kind-based e2e jobs (direct pinned
binary installs, mirroring `setup-kube-toolchain`). Each tool is skipped when
the requested version already answers on PATH — the actions-runner-image
bakes all three into `/usr/local/bin`; otherwise it downloads to a
job-private dir prepended onto PATH.

| Kind  | Name                 | Type   | Required | Default | Description |
|-------|----------------------|--------|----------|---------|-------------|
| input | `kind_version`       | string | no       | `''`    | kind version (leading v). Empty → pinned default |
| input | `kubectl_version`    | string | no       | `''`    | kubectl version (leading v). Empty → pinned default |
| input | `cilium_cli_version` | string | no       | `''`    | cilium-cli version (leading v). Empty → pinned default |

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
| input | `rendered_against` | string | no | `''` | Full catalog tag recorded in `.github/onboard.lock.json`; empty falls back to `pin_version` |
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
| output | `render_error` | string | — | — | Render-and-compare failure reason when stale-lock detection could not run |
