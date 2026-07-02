#!/usr/bin/env bats
# Tests for scripts/onboard-sweep-stale-pr-check.sh
#
# Decides whether the sweep should skip an adopter because its open bot
# onboard PR is already at the current catalog minor. Network is mocked via
# the shared gh-stub on PATH (tests/shell/lib/gh-stub.sh).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/onboard-sweep-stale-pr-check.sh"
  STUB="$REPO_ROOT/tests/shell/lib/gh-stub.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard-sweep-stale-pr"

  WORK=$(mktemp -d)
  export GH_STUB_CALL_LOG="$WORK/gh-calls.log"
  : > "$GH_STUB_CALL_LOG"

  mkdir -p "$WORK/bin"
  ln -sf "$STUB" "$WORK/bin/gh"

  # Bot identity required so the script's API filter selects.
  # Default to the real bot login. Override per-test if needed.
  export GH_TOKEN="dummy-token-for-tests"
}

teardown() {
  rm -rf "$WORK"
}

run_check() {
  local fixture_dir="$1"; shift
  export GH_STUB_FIXTURE_DIR="$FIX/$fixture_dir"
  PATH="$WORK/bin:$PATH" run "$SCRIPT" "$@"
}

@test "stale-pr-check: lock rendered_against matches current minor → skip" {
  run_check clean-current owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "skip" ]
}

@test "stale-pr-check: lock rendered_against is older minor → stale" {
  run_check stale-minor owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: lock missing rendered_against field → stale" {
  run_check missing-field owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: lock 404 → stale" {
  run_check lock-404 owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: no open bot PR → no-pr" {
  run_check no-open-pr owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "no-pr" ]
}

@test "stale-pr-check: missing args → exits 1 with usage" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "stale-pr-check: missing GH_TOKEN → exits 1 with error" {
  unset GH_TOKEN
  run "$SCRIPT" owner/repo v4.7.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN"* ]]
}
