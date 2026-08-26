#!/usr/bin/env bats

load 'lib/assertions'
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

# Every release-eligible image gets its OWN build and its OWN scan. The
# renderer used to collapse several images into one docker-build-multi call,
# which exposes no per-image outputs — so no scan job could be attached and
# those images shipped unscanned. The atom still exists for hand-written
# callers; the renderer must not reach for it.
@test "render: multi-image service produces one build+scan pair per image" {
  seed_profile "multi-dockerfile"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  local wf="$TARGET/.github/workflows/release.yml"
  refute_grep -q "docker-build-multi" "$wf"
  grep -q "docker-build.yml@v2" "$wf"
  # multi-dockerfile ships Dockerfile ($REPO) and Dockerfile.worker
  # (custom-worker); both must build AND scan, under valid job ids.
  [ "$(grep -cE '^  docker-build-[A-Za-z0-9_-]+:$' "$wf")" -eq 2 ]
  [ "$(grep -cE '^  scan-[A-Za-z0-9_-]+:$' "$wf")" -eq 2 ]
  [ "$(grep -c "trivy-image.yml@v2" "$wf")" -eq 2 ]
  # A `$` in an image name would produce an invalid job id and would also be
  # rewritten by the $REPO substitution into a slash-bearing string.
  refute_grep -qE '^  (docker-build|scan)[^:]*\$' "$wf"
}

@test "render: library-go has no docker job" {
  seed_profile "library-go"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  refute_grep -q "docker-build" "$TARGET/.github/workflows/release.yml"
  refute_grep -q "trivy-image" "$TARGET/.github/workflows/release.yml"
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

# Audit L-4: die Manifest-Fixture wird NICHT von `golden_check` geprueft — die
# Bash-Engine verweigert Adopter-Manifeste ("does not support manifests"), und
# das Paritaets-Gate traegt sie deshalb als begruendete Absage.
#
# Geprueft wird sie bisher ausschliesslich in `self-ci.yml` (Job
# `onboard-preview-manifest-golden`). Das ist eine echte Zusicherung, aber sie
# laeuft nur in der CI: lokal konnte niemand sehen, ob eine Template-Aenderung
# diesen Baum bricht.
#
# Beim Bauen habe ich mir das selbst bewiesen: ich hielt `rendered_against:
# v4.14.0` und `ghcr.io/go-root-multi-image/...` fuer Drift eines ungepflegten
# Baums und rendere ihn "richtig" neu — beides sind in Wahrheit bewusste
# Parameter des CI-Jobs (`-rendered-against v4.14.0`, Zielname = Fixture-
# Basisname). Der Job fiel prompt durch. Deshalb spiegelt dieser Test den
# CI-Aufruf exakt, statt einen zweiten, leicht abweichenden Renderpfad zu
# erfinden.
go_bin() {
  local bin="${BATS_RUN_TMPDIR:-$TARGET}/sk-workflows-golden"
  if [[ ! -x "$bin" ]]; then
    (cd "$REPO_ROOT" && go build -o "$bin" ./cmd/sk-workflows) >&2 || return 1
  fi
  printf '%s' "$bin"
}

# Spiegelt self-ci.yml :: onboard-preview-manifest-golden — gleiche Flags,
# gleiche Nachbearbeitung, gleicher Vergleich.
golden_check_preview() {
  local fixture="$1"
  command -v go        >/dev/null 2>&1 || skip "go nicht installiert"
  command -v gomplate  >/dev/null 2>&1 || skip "gomplate nicht installiert"
  local bin; bin="$(go_bin)" || { echo "go build fehlgeschlagen"; return 1; }

  local out="$TARGET/preview"
  # Kein -target-repo: das riefe `gh` fuer Branch-/Release-Metadaten. Ohne das
  # faellt target_repo auf den Fixture-Basisnamen zurueck und bleibt
  # deterministisch — genau wie in der CI.
  "$bin" preview -catalog-path "$REPO_ROOT" -repo-path "$FIX/$fixture" \
    -pin-version v4 -rendered-against v4.14.0 -out "$out"
  rm -f "$out/profile.json"

  local lock="$out/.github/onboard.lock.json"
  if [[ -f "$lock" ]]; then
    jq 'del(.rendered_at)' "$lock" > "$lock.tmp" && mv "$lock.tmp" "$lock"
  fi

  if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
    rm -rf "$FIX/$fixture/expected"
    mkdir -p "$FIX/$fixture/expected"
    cp -R "$out/." "$FIX/$fixture/expected/"
    skip "UPDATE_GOLDEN — rewrote $fixture/expected"
  fi

  diff -r "$FIX/$fixture/expected" "$out"
}

@test "golden: go-root-multi-image (Manifest-Fixture, wie self-ci)" {
  golden_check_preview "go-root-multi-image"
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
@test "golden: gitops-cluster"         { golden_check "gitops-cluster"; }

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

# Byte-identity guard for live chart adopters (calert-helm, helm-chart-tshock,
# smarthome-helm): their chart sits in a sub-directory, so detection yields a
# non-root helm component — but without a manifest they must keep rendering the
# single legacy lint-helm job (working_directory = the chart path), never the
# manifest-only charts_dir + helm-publish-dryrun pair.
@test "ci.yml keeps the legacy lint-helm block for a detected chart in a sub-directory" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/calert-helm",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": "calert", "languages": ["helm"], "primary_language": "helm",
      "release_please_type": "helm", "role": "helm-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-helm-subdir.yml" "$rendered"
  refute_grep -q "charts_dir" "$rendered"
  refute_grep -q "helm-publish" "$rendered"
}

@test "release.yml omits helm-publish for a detected chart in a sub-directory" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/calert-helm",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": "calert", "languages": ["helm"], "primary_language": "helm",
      "release_please_type": "helm", "role": "helm-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  refute_grep -q "helm-publish" "$rendered"
}

# The same shape *with* a manifest keeps the chart-component behaviour: this is
# what the manifest_sha256 gate buys the go-root-multi-image fixture.
@test "ci.yml + release.yml render chart-component jobs when a manifest is present" {
  profile='{
    "schema_version": 1, "target_repo": "serverkraken/mailstack",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "manifest_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "components": [{"path": "charts/mailstack", "languages": ["helm"], "primary_language": "helm",
      "release_please_type": "helm", "role": "helm-app", "dockerfiles": [], "unittest": true,
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }'
  ci=$(render_ci_for_profile "$profile")
  grep -qF "charts_dir: charts/mailstack" "$ci"
  grep -qF "unittest: true" "$ci"
  grep -q "helm-publish-dryrun-charts-mailstack:" "$ci"
  # Charts publish to the org-wide namespace (ghcr.io/<owner>/charts), the
  # path mailstack already used by hand — not ghcr.io/<owner>/<repo>/charts.
  grep -qF "oci_registry: ghcr.io/serverkraken/charts" "$ci"
  rel=$(render_release_for_profile "$profile")
  grep -q "helm-publish-charts-mailstack:" "$rel"
  grep -qF "oci_registry: ghcr.io/serverkraken/charts" "$rel"
  ! grep -qF "ghcr.io/serverkraken/mailstack/charts" "$rel"
}

# C3: a root chart component declared with `unittest: true` in the manifest
# threads the flag into the legacy (root) lint-helm block.
@test "ci.yml root helm component forwards unittest from the manifest" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/chart",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "manifest_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "components": [{"path": ".", "languages": ["helm"], "primary_language": "helm",
      "release_please_type": "helm", "role": "helm-app", "dockerfiles": [], "unittest": true,
      "release_signals": {"goreleaser_config": null, "chart_yaml": "Chart.yaml"}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "working_directory: ." "$rendered"
  grep -qF "unittest: true" "$rendered"
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

# === GitOps ci.yml ===

@test "ci.yml renders kube-validation jobs for a gitops component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/cluster",
    "default_branch": "main", "current_version": "0.0.0", "monorepo": false,
    "components": [{"path": ".", "languages": [], "primary_language": "gitops",
      "release_please_type": "simple", "role": "gitops",
      "dockerfiles": [], "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": [],
    "gitops": {"manifests_paths": ["kubernetes/apps","kubernetes/argo"],
      "has_kube_linter_config": true, "has_gitleaks_config": true, "sops": true}
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/gitops.yml" "$rendered"
}

@test "ci.yml gitops omits config_path when adopter has no own config" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/cluster",
    "default_branch": "main", "current_version": "0.0.0", "monorepo": false,
    "components": [{"path": ".", "languages": [], "primary_language": "gitops",
      "release_please_type": "simple", "role": "gitops",
      "dockerfiles": [], "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": [],
    "gitops": {"manifests_paths": ["kubernetes/apps"],
      "has_kube_linter_config": false, "has_gitleaks_config": false, "sops": false}
  }')
  grep -qF "kube-validate.yml@v4" "$rendered"
  grep -qF "kube-lint.yml@v4" "$rendered"
  grep -qF "secret-scan.yml@v4" "$rendered"
  refute_grep -q "config_path" "$rendered"
  grep -qF "sops: false" "$rendered"
}

# A gitops repo whose kubernetes/ holds only control dirs (bootstrap/components/
# flux-system) yields manifests_paths: []. The range then emits an empty `|-`
# block scalar — which must stay valid YAML (sops stays a sibling key, not
# swallowed). Pins that contract so a future trimming change can't silently
# break the rendered caller.
@test "ci.yml gitops with zero workload dirs renders empty manifests_paths and stays valid YAML" {
  command -v yamllint >/dev/null 2>&1 || skip "yamllint not installed"
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/cluster",
    "default_branch": "main", "current_version": "0.0.0", "monorepo": false,
    "components": [{"path": ".", "languages": [], "primary_language": "gitops",
      "release_please_type": "simple", "role": "gitops",
      "dockerfiles": [], "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": [],
    "gitops": {"manifests_paths": [],
      "has_kube_linter_config": false, "has_gitleaks_config": false, "sops": false}
  }')
  grep -qF "kube-validate.yml@v4" "$rendered"
  grep -qF "manifests_paths: |-" "$rendered"
  refute_grep -qE '^[[:space:]]+kubernetes/' "$rendered"
  grep -qF "sops: false" "$rendered"
  yamllint -d relaxed "$rendered"
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
  refute_grep -q "docker-build" "$rendered"
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
  refute_grep -q "release-flutter-android" "$rendered"
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
  refute_grep -q "release-flutter-android" "$rendered"
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
  refute_grep -q "noop" "$rendered"
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
  refute_grep -q "release-flutter-android" "$rendered"
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
  refute_grep -q "release-flutter-android" "$rendered"
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
  refute_grep -q "release-flutter-android" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "docker-build.yml@v4" "$tgt/.github/workflows/prerelease-on-push.yml"
}

@test "prerelease-on-push.yml multi-docker variant scans every image it pushes" {
  # Hiess bis zum L-1-Fix "renders docker-build-multi reference" und pruefte
  # genau das Gegenteil: `grep -qF docker-build-multi` plus ein
  # `refute_grep docker-build.yml` — der Test VERBOT also den Fan-out, der
  # ueberhaupt erst einen Scan ermoeglicht. docker-build-multi gibt keine
  # Outputs je Image heraus; an einen solchen Aufruf laesst sich kein
  # trivy-image haengen, und jedes gepushte Image ging ungescannt raus.
  # Dieselbe Zusicherung wie oben fuer release.yml.
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [
        {"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true},
        {"path":"Dockerfile.worker","image_name":"serverkraken/svc-worker","image_name_source":"derived","release_eligible":true}
      ],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  local wf="$tgt/.github/workflows/prerelease-on-push.yml"
  [ -f "$wf" ]
  refute_grep -q "docker-build-multi" "$wf"
  # Zwei Images -> zwei Builds, zwei Scans, unter gueltigen Job-IDs.
  [ "$(grep -cE '^  build-[A-Za-z0-9_-]+:$' "$wf")" -eq 2 ]
  [ "$(grep -cE '^  scan-[A-Za-z0-9_-]+:$' "$wf")" -eq 2 ]
  [ "$(grep -c "trivy-image.yml@v4" "$wf")" -eq 2 ]
  [ "$(grep -c "docker-build.yml@v4" "$wf")" -eq 2 ]
  grep -qF "prerelease: true" "$wf"
  # Beide Architekturen scannen: Trivy nimmt sonst nur linux/amd64.
  [ "$(grep -c "platforms: linux/amd64,linux/arm64" "$wf")" -eq 2 ]
  refute_grep -qE '^  (build|scan)[^:]*\$' "$wf"
}

@test "integration: rendered prerelease + prerelease-on-push pass actionlint and yamllint" {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint not installed"
  command -v yamllint  >/dev/null 2>&1 || skip "yamllint not installed"
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  yamllint -d relaxed "$tgt/.github/workflows/prerelease.yml" "$tgt/.github/workflows/prerelease-on-push.yml"
  actionlint "$tgt/.github/workflows/prerelease.yml" "$tgt/.github/workflows/prerelease-on-push.yml"
}

@test "render: lock rendered_against defaults to pin when env unset" {
  seed_profile "go-repo"
  unset RENDERED_AGAINST
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v3.1.4"
  v=$(jq -r '.rendered_against' "$TARGET/.github/onboard.lock.json")
  [ "$v" = "v3.1.4" ]
}

@test "render: lock rendered_against uses RENDERED_AGAINST env when set" {
  seed_profile "go-repo"
  RENDERED_AGAINST="v4.7.0" "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  v=$(jq -r '.rendered_against' "$TARGET/.github/onboard.lock.json")
  [ "$v" = "v4.7.0" ]
}

# ---- gitops variant render set (Task 5) ----

@test "render: gitops profile produces ci.yml only (no release-please set)" {
  seed_profile "gitops-cluster"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
  [ ! -f "$TARGET/.github/workflows/release.yml" ]
  [ ! -f "$TARGET/.github/workflows/prerelease.yml" ]
  [ ! -f "$TARGET/.github/workflows/cleanup.yml" ]
  [ ! -f "$TARGET/release-please-config.json" ]
  [ ! -f "$TARGET/.release-please-manifest.json" ]
  [ -f "$TARGET/.github/onboard.lock.json" ]
}

@test "render: gitops lock file lists ci.yml only" {
  seed_profile "gitops-cluster"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  files=$(jq -r '.files | keys[]' "$TARGET/.github/onboard.lock.json")
  [ "$files" = ".github/workflows/ci.yml" ]
}

# ---- ci-android.yml (build-flutter-android PR gate) ----
#
# Rendered ONLY when at least one component has release_signals.flutter_android
# — the same flag that gates release-flutter-android in the release skeletons.

@test "render: ci-android.yml emitted for flutter app with android dir" {
  seed_profile "flutter-app"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci-android.yml" ]
  grep -q "build-flutter-root:" "$TARGET/.github/workflows/ci-android.yml"
  grep -q "build-flutter-android.yml@v2" "$TARGET/.github/workflows/ci-android.yml"
  grep -q -- "- 'android/\*\*'" "$TARGET/.github/workflows/ci-android.yml"
  lock_entry=$(jq -r '.files[".github/workflows/ci-android.yml"]' "$TARGET/.github/onboard.lock.json")
  [[ "$lock_entry" =~ ^sha256: ]]
}

@test "render: ci-android.yml omitted for flutter package without android dir" {
  seed_profile "flutter-package"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ ! -f "$TARGET/.github/workflows/ci-android.yml" ]
  lock_entry=$(jq -r '.files[".github/workflows/ci-android.yml"] // "absent"' "$TARGET/.github/onboard.lock.json")
  [ "$lock_entry" = "absent" ]
}

@test "render: ci-android.yml omitted for non-flutter profile" {
  seed_profile "go-repo"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ ! -f "$TARGET/.github/workflows/ci-android.yml" ]
}

# --- Job-ID-Sicherheit (J-0a) und Kollisionen (J-0b) ------------------------

@test "ein Punkt im Komponentenpfad ergibt eine gueltige Job-ID" {
  # `services/v2.api` ergab die Job-ID `lint-go-services-v2.api`; actionlint:
  # "invalid job ID". GitHub verwirft dann die GANZE Datei, nicht nur den Job.
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": true,
    "components": [{"path": "services/v2.api", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  local wf="$tgt/.github/workflows/ci.yml"
  grep -qE '^  lint-go-services-v2-api:$' "$wf"
  refute_grep -qE '^  [A-Za-z0-9_-]*\.[A-Za-z0-9_-]*:$' "$wf"
}

@test "die Wurzelkomponente behaelt ihre unsuffixierten Job-Namen" {
  # Der Sanitizer wuerde "." zu "-" machen; die Wurzelerkennung muss davor
  # laufen. Beim ersten Anlauf tat sie das nicht und sechs Goldens brachen.
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  refute_grep -qE '^  [a-z-]+--' "$tgt/.github/workflows/release.yml"
}

@test "kollidierende Job-IDs werden abgewiesen, statt doppelte Keys zu rendern" {
  # `svc/x.y` und `svc/x-y` ergeben beide `svc-x-y`. Gerendert waere das
  # zweimal derselbe Job-Key — actionlint: "key ... is duplicated in jobs
  # section", und GitHub verwirft die Datei.
  local work; work="$(mktemp -d)"
  mkdir -p "$work/t"
  cat > "$work/p.json" <<'EOF2'
{"schema_version":1,"target_repo":"acme/svc","default_branch":"main","current_version":"0.1.0","monorepo":true,
 "components":[
  {"path":"svc/x.y","languages":["go"],"primary_language":"go","release_please_type":"go","role":"service","dockerfiles":[],
   "release_signals":{"goreleaser_config":null,"chart_yaml":null,"flutter_android":false}},
  {"path":"svc/x-y","languages":["go"],"primary_language":"go","release_please_type":"go","role":"service","dockerfiles":[],
   "release_signals":{"goreleaser_config":null,"chart_yaml":null,"flutter_android":false}}],
 "legacy_ci":[],"topics":[],"warnings":[]}
EOF2
  run "$RENDER" "$REPO_ROOT" "$work/t" "$work/p.json" "v4"
  rm -rf "$work"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dieselbe Job-ID"* ]]
}

# === .workflows: abweisen statt still weglassen (Audit M-5) ===
#
# `.workflows.e2e` entsteht nur aus einem Adopter-Manifest. Der Go-Renderer
# rendert daraus zusaetzlich `.github/workflows/e2e.yml` und nimmt sie in den
# Lock auf; diese Engine kennt das Feld nicht.
#
# Gemessen vor der Aenderung, dasselbe Profil durch beide Engines:
#   bash: rc=0, 4 Workflows  (ci, cleanup, prerelease, release)
#   go:   rc=0, 5 Workflows  (… + e2e.yml)
# Der Lock behauptete danach, vier Dateien seien der vollstaendige Stand — die
# Drift-Pruefung haette dem nie widersprochen.

@test "render: profile with .workflows is refused, not silently truncated" {
  seed_profile "go-repo"
  jq '. + {workflows: {e2e: {script: "./scripts/e2e.sh", schedule: "0 3 * * *"}}}' \
    "$TARGET/profile.json" > "$TARGET/profile-e2e.json"

  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile-e2e.json" "v4"
  [ "$status" -eq 1 ]
  [[ "$output" == *".workflows"* ]]
  # Der Grund muss im Text stehen: ein blosses rc=1 laesst offen, ob gomplate
  # fehlte oder das Profil unlesbar war.
  [[ "$output" == *"use_go_cli"* ]]

  # Nichts angefangen: kein halb gerenderter Baum, kein Lock, der einen
  # unvollstaendigen Stand als vollstaendig ausweist.
  [ ! -f "$TARGET/.github/workflows/ci.yml" ]
  [ ! -f "$TARGET/.github/onboard.lock.json" ]
}

@test "render: an empty workflows object is not a declaration" {
  # `"workflows": {}` steht in vielen Manifest-Profilen und erklaert nichts.
  # Ein Guard auf blosse Anwesenheit hat genau hier fuenf bestehende Tests
  # abgewiesen, die zu Recht durch diese Engine rendern.
  seed_profile "go-repo"
  jq '. + {workflows: {}}' "$TARGET/profile.json" > "$TARGET/profile-empty.json"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile-empty.json" "v4"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
}

@test "render: profile without .workflows is unaffected" {
  # Gegenprobe zur Abweisung — sonst koennte der Guard alles ablehnen und beide
  # Tests waeren trotzdem gruen.
  seed_profile "go-repo"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
  [ ! -f "$TARGET/.github/workflows/e2e.yml" ]
}

# === Schreibvorgänge ausserhalb des Ziels (Audit H-3) ===
#
# Ein Adopter-Repo, in dem `.github` ein Symlink nach aussen ist, liess beide
# Engines den Lock und alle vier Workflow-Dateien AUSSERHALB des Checkouts
# schreiben - mit rc=0. Auf einem self-hosted Runner ist das ein Schreibvorgang
# an einen beliebigen Ort, den der Job erreichen kann; der anschliessende
# Commit im Adopter-Repo findet dann nichts.
#
# Der Go-Renderer prueft dasselbe (ensureInsideTarget); ein eigener Go-Test
# haelt das fest, damit die Engines sich hier nicht unterscheiden.

@test "render: ein .github-Symlink nach aussen wird abgewiesen" {
  local outside="$BATS_TEST_TMPDIR/aussen"
  mkdir -p "$outside"
  seed_profile "go-repo"
  ln -s "$outside" "$TARGET/.github"

  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to write outside the target"* ]]

  # Nichts darf draussen gelandet sein - auch nicht die erste Datei.
  run bash -c "ls -A '$outside'"
  [ -z "$output" ]
}

@test "render: eine als Symlink vorliegende Zieldatei wird abgewiesen" {
  local outside="$BATS_TEST_TMPDIR/fremd.yml"
  echo "gehoert mir nicht" > "$outside"
  seed_profile "go-repo"
  mkdir -p "$TARGET/.github/workflows"
  ln -s "$outside" "$TARGET/.github/workflows/ci.yml"

  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to write through the symlink"* ]]
  [ "$(cat "$outside")" = "gehoert mir nicht" ]
}

@test "render: ein Ziel ohne Symlinks rendert unveraendert" {
  # Gegenprobe: die Pruefung darf den Normalfall nicht treffen.
  seed_profile "go-repo"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
  [ -f "$TARGET/.github/onboard.lock.json" ]
}

# --- ungueltiges Profil hinterlaesst keine halbe .github/ --------------------
#
# Gemessen an einem Profil mit leerem `components`: diese Engine rendert ci.yml
# erfolgreich, scheitert dann an release.yml (`map has no entry for key
# "monorepo"`) und beendet sich - die ci.yml bleibt liegen. Der Go-Renderer
# prueft vorab und schreibt nichts.
#
# Das ist nicht bloss unschoen: onboard-drift.sh rendert in ein
# Vergleichsverzeichnis, und ein Teilstand dort ergibt ein falsches
# Drift-Urteil ("Datei fehlt" statt "Render fehlgeschlagen").

_render_bad_profile() {  # <profil-inhalt>
  local prof="$BATS_TEST_TMPDIR/bad.json" target="$BATS_TEST_TMPDIR/out/demo"
  rm -rf "$BATS_TEST_TMPDIR/out"; mkdir -p "$target"
  printf '%s' "$1" > "$prof"
  run "$RENDER" "$REPO_ROOT" "$target" "$prof" v4
  LEFTOVER=$(cd "$target" && ls -A | wc -l | tr -d ' ')
}

@test "leeres components-Array wird abgewiesen, ohne eine Datei zu hinterlassen" {
  _render_bad_profile '{"components":[]}'
  [ "$status" -eq 1 ]
  [ "$LEFTOVER" -eq 0 ]
  [[ "$output" == *"components must not be empty"* ]]
}

@test "leeres Profil wird abgewiesen, ohne eine Datei zu hinterlassen" {
  _render_bad_profile ''
  [ "$status" -eq 1 ]
  [ "$LEFTOVER" -eq 0 ]
}

# Kaputtes JSON starb frueher im ersten `jq -r '.monorepo'` mit dessen rc=5.
# Ein Aufrufer, der auf rc==1 prueft, behandelt das falsch.
@test "kaputtes JSON endet mit rc=1, nicht mit jqs Rueckgabewert" {
  _render_bad_profile 'kaputt'
  [ "$status" -eq 1 ]
  [ "$LEFTOVER" -eq 0 ]
  [[ "$output" == *"invalid profile JSON"* ]]
}

@test "ein Array statt eines Objekts wird abgewiesen" {
  _render_bad_profile '[]'
  [ "$status" -eq 1 ]
  [ "$LEFTOVER" -eq 0 ]
}
