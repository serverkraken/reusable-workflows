#!/usr/bin/env bats
# Tests for scripts/onboard-sweep-drift-status.sh
#
# The script clones an adopter and runs onboard-drift.sh against the clone.
# Bats uses the ONBOARD_SWEEP_TARGET_PATH env var to skip the clone and point
# the script at a pre-prepared local target — this avoids network access and
# keeps tests deterministic.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/onboard-sweep-drift-status.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
}

@test "drift-status: drift-clean fixture reports clean in test mode" {
  ONBOARD_SWEEP_TARGET_PATH="$FIX/drift-clean" \
    run "$SCRIPT" serverkraken/dummy v3
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "drift-status: hand-edited adopter reports modified" {
  # Copy the drift-clean fixture so we can tamper with it.
  tmp=$(mktemp -d)
  cp -R "$FIX/drift-clean/." "$tmp/"
  echo "# tampered" >> "$tmp/.github/workflows/ci.yml"
  ONBOARD_SWEEP_TARGET_PATH="$tmp" \
    run "$SCRIPT" serverkraken/dummy v3
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "modified" ]
}

@test "drift-status: adopter on old major reports behind" {
  tmp=$(mktemp -d)
  cp -R "$FIX/drift-clean/." "$tmp/"
  jq '.catalog_version = "v1"' "$tmp/.github/onboard.lock.json" \
    > "$tmp/.github/onboard.lock.json.new"
  mv "$tmp/.github/onboard.lock.json.new" "$tmp/.github/onboard.lock.json"
  ONBOARD_SWEEP_TARGET_PATH="$tmp" \
    run "$SCRIPT" serverkraken/dummy v3
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "behind" ]
}

@test "drift-status: missing args exits 1 with usage message" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "drift-status: missing GH_TOKEN in clone mode exits 1" {
  # No ONBOARD_SWEEP_TARGET_PATH set → script tries clone mode.
  # No GH_TOKEN → script errors out before attempting any network call.
  unset GH_TOKEN
  run "$SCRIPT" serverkraken/dummy v3
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN"* ]]
}
