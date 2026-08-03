#!/usr/bin/env bats
# Tests for scripts/resolve-flutter-version.sh — the version-resolution logic
# of release-flutter-android.yml's "Resolve version + sync pubspec.yaml" step.
#
# Regression anchor: adopter strassenfuchs carries rolling major/minor tags
# (v0, v0.40) and archive/* tags next to exact version tags. The auto-derive
# path must only consider exact vX.Y.Z tags and must fall back instead of
# hard-failing when no usable tag exists (run 30762809021: "resolved version
# does not look like semver: 0-rc.1").

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/resolve-flutter-version.sh"
  REPO_DIR="$(mktemp -d)"
  cd "$REPO_DIR"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git commit --allow-empty -q -m "c1"
}

teardown() {
  cd /
  rm -rf "$REPO_DIR"
}

# --- explicit version input -------------------------------------------------

@test "explicit version with leading v is stripped" {
  run bash "$SCRIPT" "v1.2.3" "false" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3$"
  echo "$output" | grep -q "^tag=v1.2.3$"
}

@test "explicit version without leading v passes through" {
  run bash "$SCRIPT" "1.2.3" "false" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3$"
}

@test "explicit prerelease version is kept as-is" {
  run bash "$SCRIPT" "v0.41.0-rc.1" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.41.0-rc.1$"
  echo "$output" | grep -q "^tag=v0.41.0-rc.1$"
}

@test "explicit non-semver version fails" {
  run bash "$SCRIPT" "banana" "true" "7"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "does not look like semver"
}

@test "empty version without create_release fails" {
  run bash "$SCRIPT" "" "false" "7"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "version is required"
}

# --- auto-derive path (empty version + create_release=true) ------------------

@test "auto-derive picks latest exact version tag" {
  git tag v0.40.1
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.40.1-rc.7$"
  echo "$output" | grep -q "^tag=v0.40.1-rc.7$"
}

@test "auto-derive ignores rolling major/minor and archive tags (strassenfuchs repro)" {
  # v0.40.1 on an older commit; rolling + archive tags on a NEWER commit so
  # plain `git describe --tags --abbrev=0` would pick v0 → "0-rc.7".
  git tag v0.40.1
  git commit --allow-empty -q -m "c2"
  git tag v0
  git tag v0.40
  git tag archive/feature-maplibre-migration
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.40.1-rc.7$"
}

@test "auto-derive strips prerelease suffix from latest tag" {
  git tag v1.2.3-rc.9
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3-rc.7$"
}

@test "auto-derive accepts exact version tags without v prefix" {
  git tag 1.2.3
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3-rc.7$"
}

@test "auto-derive falls back to 0.0.0 when no tags exist" {
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.0.0-rc.7$"
}

@test "auto-derive falls back to 0.0.0 when only non-semver tags exist" {
  git tag v0
  git tag archive/feature-foo
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.0.0-rc.7$"
}

@test "auto-derive never hard-fails on weird tag zoo" {
  git tag v0
  git tag v0.40
  git tag some-random-tag
  run bash "$SCRIPT" "" "true" "42"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq "^bare=[0-9]+\.[0-9]+\.[0-9]+-rc\.42$"
}
