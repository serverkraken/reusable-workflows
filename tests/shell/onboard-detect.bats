#!/usr/bin/env bats
# Tests for scripts/onboard-detect.sh
#
# Contract (from spec §5):
#   onboard-detect.sh <repo-path> [language-override]
#   stdout key=value lines: language, release_type, current_version, default_branch
#   - When TARGET_REPO env is unset (local/test mode), current_version=0.0.0
#     and default_branch=main are emitted as defaults.
#   - Exit 1 on ambiguous signals or missing repo path.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DETECT="$REPO_ROOT/scripts/onboard-detect.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
  # Ensure target-repo env isn't bleeding in from CI
  unset TARGET_REPO
  unset GH_TOKEN
}

@test "detects go from go.mod" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
  [[ "$output" == *"release_type=go"* ]]
}

@test "detects python from pyproject.toml" {
  run "$DETECT" "$FIX/python-poetry"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=python"* ]]
  [[ "$output" == *"release_type=python"* ]]
}

@test "detects rust from Cargo.toml" {
  run "$DETECT" "$FIX/rust-cargo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=rust"* ]]
  [[ "$output" == *"release_type=rust"* ]]
}

@test "detects helm from Chart.yaml" {
  run "$DETECT" "$FIX/helm-chart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=helm"* ]]
  [[ "$output" == *"release_type=helm"* ]]
}

@test "detects node from package.json" {
  run "$DETECT" "$FIX/node-package"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=node"* ]]
  [[ "$output" == *"release_type=node"* ]]
}

@test "falls back to simple when no signals" {
  run "$DETECT" "$FIX/simple"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=simple"* ]]
  [[ "$output" == *"release_type=simple"* ]]
}

@test "errors on ambiguous signals" {
  run "$DETECT" "$FIX/ambiguous"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous language signals"* ]]
  [[ "$output" == *"go"* ]]
  [[ "$output" == *"python"* ]]
}

@test "respects explicit language override" {
  run "$DETECT" "$FIX/ambiguous" go
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
}

@test "emits default current_version=0.0.0 when TARGET_REPO unset" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=0.0.0"* ]]
}

@test "emits default default_branch=main when TARGET_REPO unset" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_branch=main"* ]]
}

@test "errors on missing repo path" {
  run "$DETECT" "/nonexistent/path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}
