#!/usr/bin/env bats
# Tests for scripts/onboard-render.sh
#
# Contract (from spec §6):
#   onboard-render.sh <catalog-path> <target-path> <release-type> <current-version> <pin-version>
#   Writes 6 files into <target>:
#     .github/workflows/{ci,release,prerelease,cleanup}.yml
#     release-please-config.json
#     .release-please-manifest.json

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  TARGET="$(mktemp -d)"
}

teardown() {
  rm -rf "$TARGET"
}

@test "renders all six files for go release-type" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" go 2.4.0 v1
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
  [ -f "$TARGET/.github/workflows/release.yml" ]
  [ -f "$TARGET/.github/workflows/prerelease.yml" ]
  [ -f "$TARGET/.github/workflows/cleanup.yml" ]
  [ -f "$TARGET/release-please-config.json" ]
  [ -f "$TARGET/.release-please-manifest.json" ]
}

@test "substitutes release-type into config" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" python 1.0.0 v1
  [ "$status" -eq 0 ]
  grep -q '"release-type": "python"' "$TARGET/release-please-config.json"
  ! grep -q '{{RELEASE_TYPE}}' "$TARGET/release-please-config.json"
}

@test "substitutes version into manifest" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" go 2.4.0 v1
  [ "$status" -eq 0 ]
  grep -q '"\.": "2\.4\.0"' "$TARGET/.release-please-manifest.json"
  ! grep -q '{{VERSION}}' "$TARGET/.release-please-manifest.json"
}

@test "pin_version=v1 is a no-op (templates already pin @v1)" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" simple 0.0.0 v1
  [ "$status" -eq 0 ]
  grep -q '@v1' "$TARGET/.github/workflows/release.yml"
  ! grep -q '@v11' "$TARGET/.github/workflows/release.yml"
}

@test "pin_version=v1.1.0 substitutes @v1 → @v1.1.0" {
  run "$RENDER" "$REPO_ROOT" "$TARGET" simple 0.0.0 v1.1.0
  [ "$status" -eq 0 ]
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/release.yml"
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/ci.yml"
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/prerelease.yml"
  grep -q '@v1\.1\.0' "$TARGET/.github/workflows/cleanup.yml"
}

@test "errors when a template file is missing" {
  # Point catalog at a path that has no templates
  EMPTY_CATALOG="$(mktemp -d)"
  mkdir -p "$EMPTY_CATALOG/docs/adopter-templates"
  run "$RENDER" "$EMPTY_CATALOG" "$TARGET" go 1.0.0 v1
  [ "$status" -eq 1 ]
  [[ "$output" == *"template missing"* ]]
  rm -rf "$EMPTY_CATALOG"
}

@test "errors on missing positional args" {
  run "$RENDER"
  [ "$status" -ne 0 ]
}
