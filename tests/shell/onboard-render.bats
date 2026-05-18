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
