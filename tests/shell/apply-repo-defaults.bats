#!/usr/bin/env bats
# Script-level tests for apply-repo-defaults.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/apply-repo-defaults.sh"
  STUB="$REPO_ROOT/tests/shell/lib/gh-stub.sh"
  FIX="$REPO_ROOT/tests/fixtures/repo-defaults"

  # Working dir for one test invocation
  WORK=$(mktemp -d)
  export GH_STUB_CALL_LOG="$WORK/gh-calls.log"
  : > "$GH_STUB_CALL_LOG"
}

teardown() {
  rm -rf "$WORK"
}

# Helper: prepare a target tree with a given lock fixture.
prepare_target() {
  local lock_fixture="$1"
  local tgt="$WORK/target"
  mkdir -p "$tgt/.github"
  [[ -n "$lock_fixture" ]] && cp "$FIX/locks/$lock_fixture" "$tgt/.github/onboard.lock.json"
  echo "$tgt"
}

# Helper: run the script with the stub on PATH.
run_with_stub() {
  local fixture_dir="$1"; shift
  export GH_STUB_FIXTURE_DIR="$FIX/$fixture_dir"
  # PATH-prepend a directory containing a 'gh' shim that delegates to the stub.
  mkdir -p "$WORK/bin"
  ln -sf "$STUB" "$WORK/bin/gh"
  PATH="$WORK/bin:$PATH" run "$SCRIPT" "$@"
}

@test "script: no args → usage error" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
}

@test "script: --help → exits 0 with usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *usage* ]]
}

@test "script: missing target_path arg → exits non-zero" {
  run "$SCRIPT" --repo o/r
  [ "$status" -ne 0 ]
}
