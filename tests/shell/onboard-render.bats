#!/usr/bin/env bats
# Tests for scripts/onboard-render.sh
#
# Contract (from spec § 6.2):
#   onboard-render.sh <catalog-path> <target-path> <profile-json-path> <pin-version>
#
# Writes 6 files into <target> plus a lock file:
#   .github/workflows/{ci,release,prerelease,cleanup}.yml
#   release-please-config.json
#   .release-please-manifest.json
#   .github/onboard.lock.json

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  DETECT="$REPO_ROOT/scripts/onboard-detect.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
  TARGET="$(mktemp -d)"
}

teardown() {
  rm -rf "$TARGET"
}

# Helper: detect a fixture and write profile.json into $TARGET.
seed_profile() {
  local fixture="$1"
  "$DETECT" --profile-json "$FIX/$fixture" > "$TARGET/profile.json"
}

@test "render: single-service produces 6 expected files + lock" {
  seed_profile "go-repo"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
  [ -f "$TARGET/.github/workflows/release.yml" ]
  [ -f "$TARGET/.github/workflows/prerelease.yml" ]
  [ -f "$TARGET/.github/workflows/cleanup.yml" ]
  [ -f "$TARGET/release-please-config.json" ]
  [ -f "$TARGET/.release-please-manifest.json" ]
  [ -f "$TARGET/.github/onboard.lock.json" ]
}

@test "render: lock file enumerates all rendered paths" {
  seed_profile "go-repo"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  files=$(jq -r '.files | keys[]' "$TARGET/.github/onboard.lock.json" | sort)
  expected=".github/workflows/ci.yml
.github/workflows/cleanup.yml
.github/workflows/prerelease.yml
.github/workflows/release.yml
.release-please-manifest.json
release-please-config.json"
  [ "$files" = "$expected" ]
}

@test "render: lock file catalog_version matches pin argument" {
  seed_profile "go-repo"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v3.1.4"
  v=$(jq -r '.catalog_version' "$TARGET/.github/onboard.lock.json")
  [ "$v" = "v3.1.4" ]
}

@test "render: lock file schema_version is 1" {
  seed_profile "go-repo"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  v=$(jq -r '.schema_version' "$TARGET/.github/onboard.lock.json")
  [ "$v" = "1" ]
}

@test "render: lock file files map contains sha256 hashes" {
  seed_profile "go-repo"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  ci_hash=$(jq -r '.files[".github/workflows/ci.yml"]' "$TARGET/.github/onboard.lock.json")
  [[ "$ci_hash" =~ ^sha256:[a-f0-9]{64}$ ]]
}

@test "render: errors on missing positional args" {
  run "$RENDER"
  [ "$status" -ne 0 ]
}

@test "render: errors when profile.json is missing" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/nope.json" "v1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile not found"* ]]
}

@test "render: pin is substituted into release.yml" {
  seed_profile "go-repo"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v3.2.1"
  grep -q "semantic-release.yml@v3.2.1" "$TARGET/.github/workflows/release.yml"
}

# ---- Variant-aware rendering (3.4) ----

@test "render: multi-image service produces docker-build-multi reference" {
  seed_profile "multi-dockerfile"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  grep -q "docker-build-multi.yml@v2" "$TARGET/.github/workflows/release.yml"
  ! grep -qE "docker-build\.yml@v2" "$TARGET/.github/workflows/release.yml"
}

@test "render: library-go has no docker job" {
  seed_profile "library-go"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  ! grep -q "docker-build" "$TARGET/.github/workflows/release.yml"
  ! grep -q "trivy-image" "$TARGET/.github/workflows/release.yml"
}

@test "render: cli-go-with-goreleaser includes goreleaser job" {
  seed_profile "cli-go-with-goreleaser"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  grep -q "goreleaser.yml@v2" "$TARGET/.github/workflows/release.yml"
}

@test "render: service-with-helm includes helm-publish job" {
  seed_profile "service-with-helm"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  grep -q "helm-publish.yml@v2" "$TARGET/.github/workflows/release.yml"
  grep -q "chart_path: charts/svc" "$TARGET/.github/workflows/release.yml"
}

# ---- Monorepo rendering (3.5) ----

@test "render: monorepo-go produces release-please-config.json with packages map" {
  seed_profile "monorepo-go"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  pkgs=$(jq -r '.packages | keys | sort | join(",")' "$TARGET/release-please-config.json")
  [ "$pkgs" = "services/api,services/worker" ]
}

@test "render: monorepo-go release.yml has per-component docker-build jobs" {
  seed_profile "monorepo-go"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  grep -q "docker-build-services-api:" "$TARGET/.github/workflows/release.yml"
  grep -q "docker-build-services-worker:" "$TARGET/.github/workflows/release.yml"
}

# ---- Golden-file fixtures (3.6) ----
#
# golden_check renders a fixture into a tmp dir whose basename is "repo"
# (so $REPO substitution is deterministic), strips rendered_at from the
# lock file, then either rewrites tests/fixtures/onboard/<fixture>/expected
# (UPDATE_GOLDEN=1) or diffs against it. The hashes inside onboard.lock.json
# stay — they are the reproducibility contract.

golden_check() {
  local fixture="$1"
  # Use a fixed basename so $REPO substitution is reproducible across runs.
  local target="$TARGET/repo"
  mkdir -p "$target"

  "$DETECT" --profile-json "$FIX/$fixture" > "$target/_profile.json"
  "$RENDER" "$REPO_ROOT" "$target" "$target/_profile.json" "v2"
  rm "$target/_profile.json"

  local lock="$target/.github/onboard.lock.json"
  if [[ -f "$lock" ]]; then
    jq 'del(.rendered_at)' "$lock" > "$lock.det" && mv "$lock.det" "$lock"
  fi

  if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
    rm -rf "$FIX/$fixture/expected"
    mkdir -p "$FIX/$fixture/expected"
    cp -R "$target/." "$FIX/$fixture/expected/"
    skip "UPDATE_GOLDEN — rewrote $fixture/expected"
  fi

  diff -r "$FIX/$fixture/expected" "$target"
}

@test "golden: go-repo"                { golden_check "go-repo"; }
@test "golden: go-cgo"                 { golden_check "go-cgo"; }
@test "golden: go-cgo-transitive"      { golden_check "go-cgo-transitive"; }
@test "golden: multi-dockerfile"       { golden_check "multi-dockerfile"; }
@test "golden: library-go"             { golden_check "library-go"; }
@test "golden: cli-go-with-goreleaser" { golden_check "cli-go-with-goreleaser"; }
@test "golden: service-with-helm"      { golden_check "service-with-helm"; }
@test "golden: monorepo-go"            { golden_check "monorepo-go"; }
@test "golden: release-eligibility-mixed" { golden_check "release-eligibility-mixed"; }
@test "golden: containerfile-only"     { golden_check "containerfile-only"; }
@test "golden: flutter-app"            { golden_check "flutter-app"; }

# ---- ci.yml lint+test atom golden tests (Task 11) ----
#
# render_ci_for_profile runs the renderer against an inline JSON profile and
# a tmpdir target, then echoes the rendered ci.yml path on stdout. Each
# @test below compares that path against a hand-curated golden under
# tests/shell/golden/ci/<case>.yml via `diff -u`.

render_ci_for_profile() {
  local profile_json="$1"
  local profile="$BATS_TEST_TMPDIR/profile-$$.json"
  local target="$BATS_TEST_TMPDIR/target-$$"
  printf '%s' "$profile_json" > "$profile"
  mkdir -p "$target"
  bash "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$profile" "v4" >&2
  echo "$target/.github/workflows/ci.yml"
}

render_release_for_profile() {
  local profile="$1"
  local target="$BATS_TEST_TMPDIR/render-release-$$"
  mkdir -p "$target"
  printf '%s' "$profile" > "$target/_profile.json"
  "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$target/_profile.json" "v4" >&2
  echo "$target/.github/workflows/release.yml"
}

render_prerelease_for_profile() {
  local profile="$1"
  local target="$BATS_TEST_TMPDIR/render-prerelease-$$"
  mkdir -p "$target"
  printf '%s' "$profile" > "$target/_profile.json"
  "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$target/_profile.json" "v4" >&2
  echo "$target/.github/workflows/prerelease.yml"
}

@test "ci.yml renders lint+test jobs for a single go component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-go.yml" "$rendered"
}

@test "ci.yml emits SK_* override expressions for Go test atom" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service", "cgo": false,
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "coverage_threshold: \${{ fromJSON(vars.SK_COVERAGE_THRESHOLD || '80') }}" "$rendered"
  grep -cF "go_version: \${{ vars.SK_GO_VERSION || '' }}" "$rendered" | grep -qx 2
  grep -qF "golangci_lint_version: \${{ vars.SK_GOLANGCI_LINT_VERSION || 'v2.12.2' }}" "$rendered"
  grep -qF "cgo_enabled: \${{ fromJSON(vars.SK_CGO_ENABLED || 'false') }}" "$rendered"
}

@test "ci.yml emits SK_CGO_ENABLED || 'true' branch when profile sets cgo:true" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service", "cgo": true,
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  # Both lint-go and test-go branches must carry the 'true' fallback.
  grep -cF "cgo_enabled: \${{ fromJSON(vars.SK_CGO_ENABLED || 'true') }}" "$rendered" | grep -qx 2
}

@test "ci.yml emits SK_* override expressions for Python test atom" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["python"], "primary_language": "python",
      "release_please_type": "python", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  # python_version appears in BOTH lint-python and test-python — enforce count=2
  # so a regression that drops it from one block fails the test.
  grep -cF "python_version: \${{ vars.SK_PYTHON_VERSION || '' }}" "$rendered" | grep -qx 2
  # coverage_threshold appears only on test-python — presence check is sufficient.
  grep -qF "coverage_threshold: \${{ fromJSON(vars.SK_COVERAGE_THRESHOLD || '80') }}" "$rendered"
}

@test "ci.yml renders lint+test jobs for a single python component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["python"], "primary_language": "python",
      "release_please_type": "python", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-python.yml" "$rendered"
}

@test "ci.yml renders lint+test jobs for a single rust component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["rust"], "primary_language": "rust",
      "release_please_type": "rust", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-rust.yml" "$rendered"
}

@test "ci.yml emits SK_* override expressions for Rust test atom" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["rust"], "primary_language": "rust",
      "release_please_type": "rust", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  # rust_toolchain appears in BOTH lint-rust and test-rust — enforce count=2
  # so a regression that drops it from one block fails the test.
  grep -cF "rust_toolchain: \${{ vars.SK_RUST_TOOLCHAIN || '' }}" "$rendered" | grep -qx 2
  # Other three SK_* vars appear in exactly one job each — presence check is sufficient.
  grep -qF "cargo_llvm_cov_version: \${{ vars.SK_CARGO_LLVM_COV_VERSION || '0.6.16' }}" "$rendered"
  grep -qF "clippy_args: \${{ vars.SK_CLIPPY_ARGS || '-D warnings' }}" "$rendered"
  grep -qF "coverage_threshold: \${{ fromJSON(vars.SK_COVERAGE_THRESHOLD || '80') }}" "$rendered"
}

@test "ci.yml renders lint job for a single helm component (no test-helm)" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["helm"], "primary_language": "helm",
      "release_please_type": "helm", "role": "chart",
      "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": "Chart.yaml"}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-helm.yml" "$rendered"
}

@test "ci.yml renders mixed monorepo (go service + helm chart)" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": true,
    "components": [
      {"path": "services/api", "languages": ["go"], "primary_language": "go",
       "release_please_type": "go", "role": "service",
       "dockerfiles": [{"path":"services/api/Dockerfile","image_name":"$REPO-api","image_name_source":"derived"}],
       "release_signals": {"goreleaser_config": null, "chart_yaml": null}},
      {"path": "charts/web", "languages": ["helm"], "primary_language": "helm",
       "release_please_type": "helm", "role": "chart",
       "dockerfiles": [],
       "release_signals": {"goreleaser_config": null, "chart_yaml": "charts/web/Chart.yaml"}}
    ],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/monorepo-mixed.yml" "$rendered"
}

@test "ci.yml renders secscan-only for an unsupported language" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["node"], "primary_language": "node",
      "release_please_type": "node", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [],
    "warnings": [{"code":"no_lint_test_atom","primary_language":"node","message":"no lint/test atom for primary_language=node; rendered ci.yml will fall back to secscan only"}]
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/unsupported-node.yml" "$rendered"
}

@test "ci.yml secscan wires SK_TRIVY_SEVERITY and SK_TRIVY_VERSION" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [], "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "severity: \${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}" "$rendered"
  grep -qF "trivy_version: \${{ vars.SK_TRIVY_VERSION || '' }}" "$rendered"
}

# === Flutter ci.yml ===

@test "ci.yml renders lint+test jobs for a single flutter component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-flutter.yml" "$rendered"
}

@test "ci.yml flutter test job carries the coverage SK_ override" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "lint-flutter.yml@v4" "$rendered"
  grep -qF "test-flutter.yml@v4" "$rendered"
  grep -qF "coverage_threshold: \${{ fromJSON(vars.SK_COVERAGE_THRESHOLD || '80') }}" "$rendered"
}

# ---- release.yml SK_SIGN/SK_ATTEST/SK_SBOM threading (Task 6) ----

@test "release.yml emits SK_SIGN/SK_ATTEST/SK_SBOM expressions on single-Dockerfile case" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "sign: \${{ fromJSON(vars.SK_SIGN || 'true') }}" "$rendered"
  grep -qF "attest: \${{ fromJSON(vars.SK_ATTEST || 'true') }}" "$rendered"
  grep -qF "sbom: \${{ fromJSON(vars.SK_SBOM || 'true') }}" "$rendered"
}

@test "release.yml emits SK_*  on multi-Dockerfile case" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [
        {"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true},
        {"path":"Dockerfile.worker","image_name":"serverkraken/svc-worker","image_name_source":"derived","release_eligible":true}
      ],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "sign: \${{ fromJSON(vars.SK_SIGN || 'true') }}" "$rendered"
  grep -qF "attest: \${{ fromJSON(vars.SK_ATTEST || 'true') }}" "$rendered"
  grep -qF "sbom: \${{ fromJSON(vars.SK_SBOM || 'true') }}" "$rendered"
}

@test "release.yml omits docker-build job when no Dockerfile is release-eligible" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile.dev","image_name":"serverkraken/svc-dev","image_name_source":"derived","release_eligible":false}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  ! grep -q "docker-build" "$rendered"
}

# ---- prerelease.yml SK_SIGN/SK_ATTEST/SK_SBOM threading (Task 7) ----

@test "prerelease.yml emits SK_SIGN/SK_ATTEST/SK_SBOM expressions" {
  rendered=$(render_prerelease_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "sign: \${{ fromJSON(vars.SK_SIGN || 'true') }}" "$rendered"
  grep -qF "attest: \${{ fromJSON(vars.SK_ATTEST || 'true') }}" "$rendered"
  grep -qF "sbom: \${{ fromJSON(vars.SK_SBOM || 'true') }}" "$rendered"
}

# === Flutter release.yml ===

@test "release.yml renders release-flutter-android when flutter_android=true" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "release-flutter-android.yml@v4" "$rendered"
  grep -qF "version: \${{ needs.release-please.outputs.tag_name }}" "$rendered"
  grep -qF "dart_define_secret_names: \${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}" "$rendered"
}

@test "release.yml omits release-flutter-android when flutter_android=false" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/pkg",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "library", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "warnings": []
  }')
  ! grep -q "release-flutter-android" "$rendered"
}

@test "release.yml does not error when release_signals lacks the flutter_android key" {
  # Guards the missing-key-safe `has` check in release.yml.tmpl: a profile
  # whose release_signals omits flutter_android entirely (e.g. a non-Flutter
  # repo, or a legacy profile) must still render without a gomplate error and
  # emit no release-flutter-android job.
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  [ -f "$rendered" ]
  ! grep -q "release-flutter-android" "$rendered"
}

@test "release-please-config renders release-type dart for flutter" {
  local target="$BATS_TEST_TMPDIR/rp-flutter-$$"
  mkdir -p "$target"
  printf '%s' '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }' > "$target/_profile.json"
  "$RENDER" "$REPO_ROOT" "$target" "$target/_profile.json" "v4" >&2
  jq -e '.packages["."]["release-type"] == "dart"' "$target/release-please-config.json"
}

@test "integration: rendered flutter-app ci.yml + release.yml pass actionlint and yamllint" {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint not installed"
  command -v yamllint  >/dev/null 2>&1 || skip "yamllint not installed"
  seed_profile "flutter-app"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4" >&2
  yamllint -d relaxed "$TARGET/.github/workflows/ci.yml" "$TARGET/.github/workflows/release.yml"
  actionlint "$TARGET/.github/workflows/ci.yml" "$TARGET/.github/workflows/release.yml"
}

# === Flutter manual prerelease.yml ===

@test "prerelease.yml renders release-flutter-android create_release for a flutter app" {
  rendered=$(render_prerelease_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  grep -qF "release-flutter-android.yml@v4" "$rendered"
  grep -qF "create_release: true" "$rendered"
  grep -qF "version: \${{ inputs.version }}" "$rendered"
  grep -qF "dart_define_secret_names: \${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}" "$rendered"
  ! grep -q "noop" "$rendered"
}

@test "prerelease.yml keeps noop for a flutter package (no android/)" {
  rendered=$(render_prerelease_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/pkg",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "library", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  grep -q "noop" "$rendered"
  ! grep -q "release-flutter-android" "$rendered"
}

@test "prerelease.yml does not error when release_signals lacks the flutter_android key" {
  # Guards the missing-key-safe `has` check in prerelease.yml.tmpl (mirrors the
  # release.yml guard test): a non-Flutter profile omits flutter_android, which
  # gomplate would error on with a bare `.flutter_android` access.
  rendered=$(render_prerelease_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  [ -f "$rendered" ]
  ! grep -q "release-flutter-android" "$rendered"
}

# === prerelease-on-push.yml (opt-in topic) ===

# Render the full set for an inline profile; echo the target dir.
render_target_for_profile() {
  local profile="$1"
  local target="$BATS_TEST_TMPDIR/render-onpush-$$"
  rm -rf "$target"; mkdir -p "$target"
  printf '%s' "$profile" > "$target/_profile.json"
  "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$target/_profile.json" "v4" >&2 || return 1
  echo "$target"
}

@test "prerelease-on-push.yml is rendered + locked when topic present (flutter)" {
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  [ -f "$tgt/.github/workflows/prerelease-on-push.yml" ]
  grep -qF "on:" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "branches: [develop]" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "release-flutter-android.yml@v4" "$tgt/.github/workflows/prerelease-on-push.yml"
  jq -e '.files[".github/workflows/prerelease-on-push.yml"]' "$tgt/.github/onboard.lock.json"
}

@test "prerelease-on-push.yml is NOT rendered when topic absent" {
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  [ ! -f "$tgt/.github/workflows/prerelease-on-push.yml" ]
  ! jq -e '.files[".github/workflows/prerelease-on-push.yml"]' "$tgt/.github/onboard.lock.json"
}

@test "prerelease-on-push.yml docker variant builds prerelease image" {
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  [ -f "$tgt/.github/workflows/prerelease-on-push.yml" ]
  grep -qF "docker-build.yml@v4" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "prerelease: true" "$tgt/.github/workflows/prerelease-on-push.yml"
}

@test "prerelease-on-push.yml does not error when release_signals lacks the flutter_android key" {
  # Mirrors the equivalent guards on release.yml and prerelease.yml: a docker
  # profile whose release_signals omits flutter_android must still render the
  # on-push template (when opted in via topic) without a gomplate error and
  # take the docker arm, not the Flutter arm.
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  [ -f "$tgt/.github/workflows/prerelease-on-push.yml" ]
  ! grep -q "release-flutter-android" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "docker-build.yml@v4" "$tgt/.github/workflows/prerelease-on-push.yml"
}
