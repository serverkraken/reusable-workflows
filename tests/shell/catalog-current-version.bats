#!/usr/bin/env bats
# Tests for scripts/catalog-current-version.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/catalog-current-version.sh"
  WORK="$(mktemp -d)"

  git init "$WORK" >/dev/null
  git -C "$WORK" config user.name "Test User"
  git -C "$WORK" config user.email "test@example.invalid"
  git -C "$WORK" commit --allow-empty -m "initial" >/dev/null
}

teardown() {
  rm -rf "$WORK"
}

@test "uses the latest reachable patch tag, not floating major or minor tags" {
  git -C "$WORK" tag v4
  git -C "$WORK" tag v4.9
  git -C "$WORK" tag v4.9.0

  CATALOG_ROOT="$WORK" run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v4"* ]]
  [[ "$output" == *"current_minor=v4.9.0"* ]]
}

@test "falls back to v0 when only floating tags exist" {
  git -C "$WORK" tag v4
  git -C "$WORK" tag v4.9

  CATALOG_ROOT="$WORK" run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v0"* ]]
  [[ "$output" == *"current_minor=v0.0.0"* ]]
}

@test "ignores a closer floating major tag and keeps the previous patch tag" {
  git -C "$WORK" tag v4.8.0
  git -C "$WORK" commit --allow-empty -m "move floating major" >/dev/null
  git -C "$WORK" tag v4

  CATALOG_ROOT="$WORK" run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v4"* ]]
  [[ "$output" == *"current_minor=v4.8.0"* ]]
}
