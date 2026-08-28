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

### `chart-image-bump.yml`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `values_file` | string | yes | — | Helm values file holding the image pins. |
| input | `images` | string | yes | — | JSON map of component path → image names, e.g. {"images/postfix": ["serverkraken/mailstack/postfix"]}. Rendered from the adopter manifest. |
| input | `releases` | string | yes | — | The `releases` output of semantic-release.yml. Only components listed there are bumped, so a component that did not release keeps its pin. |
| input | `key_template` | string | no | `images.{name}.tag` | Dotted path to the tag, with {name} for the image basename. |
| input | `commit` | boolean | no | `true` | Commit and push. Set false for dry runs and self-CI. |
| input | `ref` | string | no | `''` | Branch to check out, commit onto and push to. Empty keeps the caller's ref, which is right for the normal case (release job on the default branch). On a `pull_request` that ref is a DETACHED merge commit, where `git push` cannot work at all — pass a branch name to exercise the write path. |
| input | `commit_message` | string | no | `fix(chart): Image-Pins auf die frisch gebauten Versionen` | Commit message. Keep the fix(chart) prefix or release-please will not cut a chart release. |
| input | `runs_on` | string | no | `["self-hosted","Linux","low-performance"]` | JSON-encoded array of runner labels. |
| output | `changed` | — | — | — | "true" when at least one pin moved. |
| secret | `release_please_app_client_id` | — | yes | — | GitHub App Client ID (catalog checkout + push of the pin commit). |
| secret | `release_please_app_private_key` | — | yes | — | PEM private key for the GitHub App. |

Only components present in `releases` are touched, so a component that did
not release in this run keeps its existing pin. The key is derived from the
image BASENAME; two images whose names differ only in owner or namespace
collide on the same key and the workflow fails rather than guessing.

---

### `cleanup-images.yml`

| Kind    | Name                   | Type   | Required | Default                     | Description |
|---------|------------------------|--------|----------|-----------------------------|-------------|
| input   | `package_name`         | string | no       | `''`                                  | GHCR package name. Empty → the workflow falls back to `${{ github.event.repository.name }}`. |
| input   | `keep_stable_versions` | number | no       | `10`                        | Min count of semver (`v*.*.*`) versions to keep |
| input   | `prerelease_age_days`  | number | no       | `14`                        | Delete non-semver tags older than N days |
| input   | `runs_on`              | string | no       | `'["self-hosted","Linux"]'` | JSON-encoded runner labels |

A package that does not exist is a no-op: the job logs `not published (yet)`
and succeeds. Retention on a repo that has not cut its first release yet is
not an error, and a red weekly cron there would train people to ignore it.

---

### `docker-build.yml`

**Deliberate exception to the `runs_on` rule.** Every other atom takes a single
`runs_on`; this one takes three. The multi-arch build distributes across
*native* runners rather than emulating under QEMU, so the amd64 job, the arm64
job and the metadata/merge jobs run on genuinely different pools — one input
cannot express that, and collapsing them would either force emulation or pin
all three to the same pool. `docker-build-multi.yml` adds a fourth,
`runs_on_parse`, for the same reason.

The cost is that a consumer without a matching self-hosted pool overrides three
inputs instead of one:

```yaml
with:
  runs_on_amd64: '["ubuntu-latest"]'
  runs_on_arm64: '["ubuntu-24.04-arm"]'
  runs_on_merge: '["ubuntu-latest"]'
```

| Kind    | Name            | Type    | Required | Default                                        | Description |
|---------|-----------------|---------|----------|------------------------------------------------|-------------|
| input   | `tag`           | string  | no       | `''`                                           | Image tag; empty → auto-compute when `prerelease=true` |
| input   | `prerelease`    | boolean | no       | `false`                                        | Skip `:latest`, auto-compute tag if `tag` is empty |
| input   | `image_name`    | string  | no       | `''`                                           | Image name (owner/repo). Empty → the workflow falls back to `${{ github.repository }}`. |
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
| output  | `moving_ref`    | string  | —        | —                                              | `ghcr.io/<image_name>:<moving_tag>`, or empty when the run published no moving tag. Pushed only after signing, so it always resolves to the same digest as `image_ref` |
| output  | `digest`        | string  | —        | —                                              | Manifest-list digest `sha256:…` |
| output  | `tag`           | string  | —        | —                                              | Final tag (auto-computed if input was empty) |
| secret  | `release_please_app_client_id`  | — | **yes** | — | App Client ID for the catalog-checkout token (since v3.0.0; was `release_please_app_id` in v2.x) |
| secret  | `release_please_app_private_key`| — | **yes** | — | App private key for the catalog-checkout token (since v2.0.0) |
| secret  | `dockerhub_username`            | — | no | — | Docker Hub username. Empty skips the login and base-image pulls fall back to anonymous — rate-limited **per egress IP**, which a whole runner pool shares. |
| secret  | `dockerhub_token`               | — | no | — | Docker Hub PAT. See `dockerhub_username`. Authenticated pulls count against the **account** instead. |

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
| output  | `matrix`          | string  | —        | —                                               | JSON matrix built from `images`: `{"include": [{dockerfile, image_name}, ...]}`. Reflects the dispatch decision, not the build results — per-image digests are deliberately not surfaced (call `docker-build.yml` directly for those). |

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
| input   | `ref`                | string  | no       | `''`                        | Git ref (usually the freshly created tag) to check out. Empty keeps the caller's ref. In non-snapshot mode goreleaser needs a tag AT the checked-out commit, so a caller that creates the tag in the same run must pass it here. |
| input   | `runs_on`            | string  | no       | `'["self-hosted","Linux"]'` | JSON-encoded array of runner labels. |

---

### `helm-publish.yml`

| Kind    | Name           | Type    | Required | Default                     | Description |
|---------|----------------|---------|----------|-----------------------------|-------------|
| input   | `chart_path`   | string  | **yes**  | —                           | Directory containing `Chart.yaml`. |
| input   | `oci_registry` | string  | **yes**  | —                           | OCI registry path (host + namespace) to push to, without the chart name. Example: `ghcr.io/serverkraken/charts`. |
| input   | `helm_version` | string  | no       | `'v3.16.3'`                 | Helm CLI version to install (e.g. `v3.16.3`, `latest`). |
| input   | `dry_run`      | boolean | no       | `false`                     | Lint and package only; skip registry login + push. |
| input   | `runs_on`      | string  | no       | `'["self-hosted","Linux"]'` | JSON-encoded array of runner labels. |
| input   | `ref`          | string  | no       | `''`                        | Git ref (tag/branch/SHA) to check out before packaging. Callers whose release job creates the version-bump commit and tag in the same run (release-please) must pass the released tag here; empty keeps the default event-SHA checkout. |

---

### `kube-lint.yml`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `manifests_path` | string | no | `kubernetes/apps` | Path to lint (passed to kube-linter lint). |
| input | `config_path` | string | no | `''` | Path to a .kube-linter.yaml. Empty → catalog baseline. |
| input | `kube_linter_version` | string | no | `''` | Override kube-linter version (empty → composite default). |
| input | `fail_on_findings` | boolean | no | `true` | Exit non-zero when kube-linter reports findings. |
| input | `upload_sarif` | boolean | no | `true` | Upload SARIF to GitHub code-scanning. Auto-skipped on forks. |
| input | `report_slug` | string | no | `''` | Suffix that makes this call's SARIF category and artifact name unique. Required when a repo calls this atom more than once in the same workflow: GitHub keeps one analysis per category, so a shared category makes the second upload REPLACE the first, and the shared artifact name fails the run outright. Empty (the default) keeps the historical names, so single-call adopters are unaffected. |
| input | `runs_on` | string | no | `["self-hosted","Linux"]` | JSON-encoded array of runner labels. |
| output | `findings_count` | — | — | — | Number of kube-linter findings. |
| secret | `release_please_app_client_id` | — | yes | — | GitHub App Client ID with contents:read on the catalog repo. |
| secret | `release_please_app_private_key` | — | yes | — | PEM private key for the GitHub App. |

---

### `kube-validate.yml`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `manifests_paths` | string | no | `kubernetes` | Newline-separated validate roots (e.g. kubernetes/apps). |
| input | `kustomize_args` | string | no | `--load-restrictor=LoadRestrictionsNone --enable-helm --enable-alpha-plugins --enable-exec` | Args passed verbatim to `kustomize build`. |
| input | `schema_locations` | string | no | `default https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json` | Newline-separated kubeconform -schema-location values. |
| input | `skip_kinds` | string | no | `Secret` | Comma-separated kinds passed to kubeconform -skip. |
| input | `strict` | boolean | no | `true` | Pass -strict to kubeconform. |
| input | `ignore_missing_schemas` | boolean | no | `true` | Pass -ignore-missing-schemas to kubeconform. |
| input | `sops` | boolean | no | `false` | Decrypt in-tree SOPS generators via ksops during build. Requires the sops_age_key secret. |
| input | `kustomize_version` | string | no | `''` | Override kustomize version (empty → composite default). |
| input | `kubeconform_version` | string | no | `''` | Override kubeconform version (empty → composite default). |
| input | `runs_on` | string | no | `["self-hosted","Linux"]` | JSON-encoded array of runner labels. |
| secret | `sops_age_key` | — | no | — | AGE secret key for SOPS decryption (required only when sops: true). |
| secret | `release_please_app_client_id` | — | yes | — | GitHub App Client ID with contents:read on the catalog repo. |
| secret | `release_please_app_private_key` | — | yes | — | PEM private key for the GitHub App. |

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

### `lint-shell.yml`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `paths` | string | no | `**/*.sh` | Newline-separated globs to check. Matching NOTHING is an ERROR, not a pass: sonst faerbt ein driftender Glob das Gate dauerhaft gruen. |
| input | `severity` | string | no | `style` | shellcheck minimum severity: error, warning, info or style. |
| input | `shellcheck_version` | string | no | `''` | Override shellcheck version (empty → composite default). |
| input | `follow_sources` | boolean | no | `true` | Pass -x so `source lib/common.sh` is checked too. |
| input | `scan_shebangs` | boolean | no | `true` | Also check tracked files WITHOUT a .sh suffix whose first line is a shell shebang. A linter that silently skips `scripts/deploy` checks half the scripts in many repos. Scoped by the same `paths` globs with the .sh requirement dropped, so it never widens into a whole-repo scan. |
| input | `shfmt` | boolean | no | `false` | Also run `shfmt -d` (format check). |
| input | `sarif` | boolean | no | `true` | Upload SARIF to GitHub code-scanning. Auto-skipped on forks. |
| input | `fail_on_findings` | boolean | no | `true` | Exit non-zero when shellcheck reports findings. |
| input | `report_slug` | string | no | `''` | Suffix that makes this call's SARIF category and artifact name unique. Required when a repo calls this atom more than once in the same workflow. |
| input | `runs_on` | string | no | `["self-hosted","Linux"]` | JSON-encoded array of runner labels. |
| output | `findings_count` | — | — | — | Number of shellcheck findings — und der LEERE String, wenn shellcheck gar nicht durchlief. Ein Aufrufer muss auf `== '0'` pruefen, nicht auf `!= '0'`. |
| output | `file_count` | — | — | — | Number of files the paths globs matched, gesetzt BEVOR das Atom bei null Treffern abbricht. Damit laesst sich "am gewollten Check gescheitert" von "vorher abgestuerzt" unterscheiden: leer heisst, der Collect-Schritt lief nicht. |
| secret | `release_please_app_client_id` | — | yes | — | GitHub App Client ID with contents:read on the catalog repo. |
| secret | `release_please_app_private_key` | — | yes | — | PEM private key for the GitHub App. |

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

### `secret-scan.yml`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `config_path` | string | no | `''` | Path to a .gitleaks.toml. Empty → gitleaks built-in ruleset. |
| input | `gitleaks_version` | string | no | `''` | Override gitleaks version (empty → composite default). |
| input | `fail_on_findings` | boolean | no | `true` | Exit non-zero when gitleaks reports findings. |
| input | `upload_sarif` | boolean | no | `true` | Upload SARIF to GitHub code-scanning. Auto-skipped on forks. |
| input | `report_slug` | string | no | `''` | Suffix that makes this call's SARIF category and artifact name unique. Required when a repo calls this atom more than once in the same workflow: GitHub keeps one analysis per category, so a shared category makes the second upload REPLACE the first, and the shared artifact name fails the run outright. Empty (the default) keeps the historical names, so single-call adopters are unaffected. |
| input | `fetch_depth` | number | no | `0` | Checkout fetch-depth (0 = full history; needed for PR-diff/full scans). |
| input | `no_git` | boolean | no | `false` | Scan files under scan_path without git history (gitleaks --no-git). |
| input | `scan_path` | string | no | `.` | Directory to scan when no_git: true. |
| input | `runs_on` | string | no | `["self-hosted","Linux"]` | JSON-encoded array of runner labels. |
| output | `findings_count` | — | — | — | Number of gitleaks findings. |
| secret | `release_please_app_client_id` | — | yes | — | GitHub App Client ID with contents:read on the catalog repo. |
| secret | `release_please_app_private_key` | — | yes | — | PEM private key for the GitHub App. |

`report_slug` is required when a repo calls this atom more than once in the
same run: GitHub's code-scanning API refuses two SARIF uploads under one
category, and two artifacts of the same name are equally ambiguous.

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

### `tofu-plan.yml`

**Vertrauensgrenze — vor dem Einbau lesen.** Dieses Atom fuehrt die
OpenTofu-Konfiguration des Adopters mit echten Credentials aus. `tofu plan` ist
nicht rein deklarativ: der offizielle `external`-Provider startet waehrend des
Plans ein beliebiges Programm, und dieser Kindprozess erbt die komplette
Umgebung des Schritts — die Backend-Credentials und die `TF_VAR_*`
eingeschlossen. Daraus folgt: **jeder Pull Request, der eine `.tf`-Datei aendern
kann, kann die an dieses Atom uebergebenen Secrets lesen.** Das gilt auch fuer
einen PR aus demselben Repository; der eingebaute Riegel gegen
`pull_request_target` und `workflow_run` haelt fremde Forks und die falsche
Revision fern, nicht Leute mit Branch-Zugriff.

Das Atom kann diese Grenze nicht selbst ziehen — es kennt weder das `on:` des
Aufrufers noch dessen Branch-Schutz. Ziehen muss sie der Adopter: den
aufrufenden Job an ein geschuetztes `environment` mit Required Reviewers
haengen, sodass ein Mensch den Lauf freigibt, bevor die Secrets an den Runner
gehen — oder kurzlebige, nur lesende Credentials uebergeben, deren Diebstahl
nichts wert ist.

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input  | `working_directory` | string | no | `tofu` | OpenTofu stack directory. |
| input  | `tofu_version` | string | no | `''` | Override OpenTofu version (empty → composite default). |
| input  | `backend_config` | string | no | `''` | Newline-separated `-backend-config=` arguments (bucket, endpoint, region). Credentials do NOT belong here — use the secrets. |
| input  | `comment_on_pr` | boolean | no | `true` | Post the plan as a sticky PR comment. |
| input  | `plan_json` | boolean | no | `false` | Upload `tofu show -json` as an artifact. OFF by default: unlike the human-readable output, the JSON does NOT redact values marked sensitive, so anyone who can download the artifact reads them in clear text. |
| input  | `lock` | boolean | no | `true` | Take a state lock during plan. |
| input  | `lock_timeout` | string | no | `60s` | Value for -lock-timeout. |
| input  | `runs_on` | string | no | `["self-hosted","Linux"]` | JSON-encoded array of runner labels. |
| output | `has_changes` | — | — | — | true when the plan contains changes, false when it does not — und der LEERE String, wenn der Plan nicht durchlief: Fork-PR (das Atom ueberspringt sich) ODER Plan-Fehler. Ein Aufrufer muss `== 'true'` pruefen, nicht `!= 'false'`. Wer "keine Aenderungen" von "nicht gelaufen" unterscheiden will, liest `plan_status`. |
| output | `summary_line` | — | — | — | The plan summary line, e.g. "2 to add, 1 to change, 0 to destroy". |
| output | `plan_status` | — | — | — | `success`, wenn `tofu plan` durchlief (mit oder ohne Aenderungen), `failed` bei einem unerwarteten Exit-Code, und der LEERE String, wenn der Plan-Schritt gar nicht erst startete (Fork-PR, Abbruch im Backend-Init). Fuer Aufrufer mit `always()` oder `continue-on-error` ist das der einzige Weg, einen Fehlschlag von "es gibt nichts zu tun" zu unterscheiden. |
| secret | `release_please_app_client_id` | — | yes | — | GitHub App Client ID with contents:read on the catalog repo. |
| secret | `release_please_app_private_key` | — | yes | — | PEM private key for the GitHub App. |
| secret | `backend_access_key` | — | no | — | S3-compatible backend access key → AWS_ACCESS_KEY_ID. |
| secret | `backend_secret_key` | — | no | — | S3-compatible backend secret key → AWS_SECRET_ACCESS_KEY. |
| secret | `tf_vars` | — | no | — | Newline-separated KEY=VALUE pairs, exported as TF_VAR_key. |

---

### `tofu-validate.yml`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `working_directories` | string | no | `tofu` | Newline-separated OpenTofu stack directories. |
| input | `tofu_version` | string | no | `''` | Override OpenTofu version (empty → composite default). |
| input | `tflint` | boolean | no | `true` | Also run tflint in each directory. |
| input | `lockfile_readonly` | boolean | no | `true` | Pass -lockfile=readonly to `tofu init`, so a PR that would silently change .terraform.lock.hcl fails instead of drifting the provider pins unnoticed. |
| input | `runs_on` | string | no | `["self-hosted","Linux"]` | JSON-encoded array of runner labels. |
| output | `checked_directories` | — | — | — | Number of directories validated. |
| secret | `release_please_app_client_id` | — | yes | — | GitHub App Client ID with contents:read on the catalog repo. |
| secret | `release_please_app_private_key` | — | yes | — | PEM private key for the GitHub App. |

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
| input   | `ref`                            | string  | no       | `''`                                           | Branch to check out, commit onto and push to. Empty keeps the caller's ref, which is right for the normal case (release job on the default branch). On a `pull_request` that ref is a DETACHED merge commit, where `git push` cannot work at all — pass a branch name to exercise the write path. |
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
| input   | `dry_run`                       | boolean | no       | `false`                                         | Trockenlauf: reicht `dry_run` an semantic-release durch. Weil die nachgelagerten Jobs an `release_created == 'true'` haengen und release-please im Trockenlauf gar keine Ausgabe setzt, entfallen Build und Scan von selbst — kein Tag, kein Image, kein Release. |
| input   | `runs_on_release`               | string  | no       | `'["self-hosted","Linux","low-performance"]'` | Runner-Labels fuer den semantic-release-Schritt, als JSON-Array. Durchgereicht. |
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

## Operational Workflows

`onboard.yml` is an operational tool, not an atom adopters compose into their
CI. It is listed here because it does expose a `workflow_call` surface, and an
undocumented callable surface is exactly what the contract gate exists to
catch. Its inputs are **not** semver-protected — they may change without a
major bump.

**Cross-repo `workflow_call` is refused.** The `guard-caller` job fails the run
unless `github.repository` is `serverkraken/reusable-workflows`. The workflow
mints repo-admin tokens for whatever `target_repos` names and pushes to the
catalog's own `main`, so accepting a call from elsewhere would hand both to the
caller. A fork driving its own org has to change that constant.

### `onboard.yml`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `target_repos` | string | yes | — | Comma-separated owner/repo list (e.g. serverkraken/blupod-ui,serverkraken/flow) |
| input | `language` | string | no | `auto` | auto = detect, otherwise force release-type (go, python, rust, helm, node, flutter, gitops, simple) |
| input | `dry_run` | boolean | no | `true` | Render + log diff; do NOT push or open PRs. Defaults to true here (unlike the dispatch form) so a programmatic caller has to opt IN to mutating adopter repos. |
| input | `use_go_cli` | boolean | no | `true` | Use sk-workflows for detect, render, and repo-default application. Set false to use the Bash fallback. |
| input | `pin_version` | string | no | `v4` | Catalog @version that rendered templates pin to |
| input | `rendered_against` | string | no | `''` | Full catalog tag for the lock file. Empty → fall back to pin_version. |
| input | `add_branch_name` | string | no | `chore/onboard-reusable-workflows` | Branch for PR A (add new workflows) |
| input | `cleanup_branch_name` | string | no | `chore/remove-legacy-workflows` | Branch for PR B (remove legacy workflows) |

---

## Composite Actions

### `actions/install-trivy`

| Kind  | Name      | Type   | Required | Default | Description |
|-------|-----------|--------|----------|---------|-------------|
| input | `version` | string | no       | `''`    | Trivy version to install; empty → uses pinned default |

### `actions/install-gitleaks`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `version` | string | no | `''` | gitleaks version (with or without leading v). Empty → pinned default. |

### `actions/install-kube-linter`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `version` | string | no | `''` | kube-linter version (with or without leading v). Empty → pinned default. |

### `actions/install-shellcheck`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `version` | string | no | `''` | shellcheck version (no leading v). Empty → pinned default. |
| input | `shfmt` | string | no | `'false'` | When "true", also install shfmt. |
| input | `shfmt_version` | string | no | `''` | shfmt version (no leading v). Empty → pinned default. |

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

### `actions/dockerhub-login`

Optional login to `docker.io`, so base-image pulls count against an account
instead of the runner's shared egress IP. Does nothing when either input is
empty — repos without the credentials stay unaffected.

| Kind  | Name       | Type   | Required | Default | Description |
|-------|------------|--------|----------|---------|-------------|
| input | `username` | string | no       | `''`    | Docker Hub username. Empty = skip login. |
| input | `token`    | string | no       | `''`    | Docker Hub PAT. Empty = skip login. |

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

### `actions/setup-kube-toolchain`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `kustomize_version` | string | no | `''` | kustomize version (no leading v). Empty → pinned default. |
| input | `kubeconform_version` | string | no | `''` | kubeconform version (no leading v). Empty → pinned default. |
| input | `sops` | string | no | `false` | When "true", also install sops + ksops for SOPS decryption. |

### `actions/setup-tofu-toolchain`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `tofu_version` | string | no | `''` | OpenTofu version (no leading v). Empty → pinned default. |
| input | `tflint` | string | no | `'false'` | When "true", also install tflint. |
| input | `tflint_version` | string | no | `''` | tflint version (no leading v). Empty → pinned default. |

### `actions/tofu-stack-exec`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `command` | string | yes | — | plan \| plan-destroy \| apply \| unlock |
| input | `working_directory` | string | yes | — | OpenTofu stack directory. |
| input | `backend_config` | string | no | `''` | Newline-separated -backend-config= arguments. |
| input | `plan_file` | string | no | `'tfplan'` | Pfad der tfplan (Ausgabe bei plan, Eingabe bei apply). |
| input | `lock` | string | no | `'true'` | State-Lock nehmen. |
| input | `lock_timeout` | string | no | `'60s'` | Wert fuer -lock-timeout. |
| input | `lock_id` | string | no | `''` | Lock-ID fuer command=unlock. |
| input | `tf_vars` | string | no | `''` | Newline-separated KEY=VALUE, wird zu TF_VAR_key. |
| input | `encryption_passphrase` | string | no | `''` | Passphrase fuer die native Plan- und State-Verschluesselung. |
| input | `allow_unencrypted_fallback` | string | no | `'false'` | Einmalige Migration; danach abschalten. |
| input | `backend_access_key` | string | no | `''` | S3-kompatibler Access Key. |
| input | `backend_secret_key` | string | no | `''` | S3-kompatibler Secret Key. |
| output | `has_changes` | string | — | — | true\|false bei plan/plan-destroy, sonst leer. |
| output | `summary_line` | string | — | — | Die Zusammenfassungszeile des Laufs. |
| output | `exec_status` | string | — | — | success\|failed, leer wenn der Schritt nicht startete. |

**Verschlüsselung.** Die Composite baut `TF_ENCRYPTION` selbst — der Adopter liefert
nur `encryption_passphrase`, kein HCL. Erzeugt wird `pbkdf2` + `aes_gcm` mit
`enforced = true` für `state` und `plan`; OpenTofu lehnt danach jeden
unverschlüsselten Zustand selbst ab. Das ist der Nachweis, nicht ein Test auf den
Metadaten-Präfix: `encrypted_metadata_alias` kann den Schlüssel umbenennen, und ein
Klartext-JSON kann den Präfix fälschen.

`command=plan` ohne Passphrase ist erlaubt (der Plan wird dann nicht gespeichert
weitergereicht) und meldet eine `::notice::`. `apply` und `plan-destroy` **verlangen**
sie und brechen sonst ab.

**Migration eines vorhandenen Klartext-States.** `enforced = true` verweigert das
Lesen. Der erste Lauf meldet dann:

```
failed to write backup file: encountered unencrypted payload
without unencrypted method configured
```

Dafür — und nur dafür — gibt es `allow_unencrypted_fallback: 'true'`. Genau einen
Lauf lang; der Schalter setzt eine `::warning::`, weil er den Schutz aufhebt, ohne
dass etwas rot wird.

### `actions/setup-python-deps`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `working_directory` | string | no | `.` | Project directory containing the lockfile or pyproject.toml. |
| input | `python_version` | string | no | `''` | Python version. Empty → read from <working_directory>/pyproject.toml. |
| input | `install_test_extras` | string | no | `false` | When true, install pytest + pytest-cov on the pip-bare path. |
| output | `pm` | — | — | — | Detected package manager. |
| output | `run_prefix` | — | — | — | Prefix to invoke tools. |

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

### `actions/onboard-apply-defaults`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `token` | string | yes | — | GitHub token with administration:write on the target repo |
| input | `target_repo` | string | yes | — | owner/repo of the target adopter |
| input | `target_path` | string | yes | — | Path to the checked-out adopter repo on the runner |
| input | `prev_defaults_applied_at` | string | no | `''` | Snapshot of the target lock's defaults_applied_at field BEFORE render. Empty string means first-onboard or re-baseline. |
| input | `dry_run` | string | no | `false` | When true, no API mutations and no lock write — only diff summary. |
| input | `use_go_cli` | string | no | `false` | When true, run sk-workflows apply-defaults (Go) instead of scripts/apply-repo-defaults.sh (Bash). |
| output | `defaults_applied` | — | — | — | true if script ran end-to-end in live mode; false in dry-run |
| output | `tier_2_applied` | — | — | — | true if Tier 2 (comfort) fields were processed this run (live mode only) |
| output | `modified` | — | — | — | Live mode only: csv of mutated field-categories (branch_protection,delete_branch_on_merge,topics,merge_hygiene,repo_settings) |
| output | `would_change` | — | — | — | Dry-run only: csv of field-categories that would be mutated |
