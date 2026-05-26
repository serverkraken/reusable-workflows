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

@test "tier_1 bp: no protection (404) → PUT full config" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-no-bp --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  # The stub call-log should contain a PUT to branches/main/protection
  grep -q $'^PUT\t/repos/o/r/branches/main/protection' "$GH_STUB_CALL_LOG"
}

@test "tier_1 bp: clean state → no PUT" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  ! grep -q $'^PUT\t/repos/o/r/branches/main/protection' "$GH_STUB_CALL_LOG"
}

@test "tier_1 bp: drift (enforce_admins flipped) → PUT" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-drifted --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  grep -q $'^PUT\t/repos/o/r/branches/main/protection' "$GH_STUB_CALL_LOG"
}

@test "tier_1 delete_branch_on_merge: clean (already true) → no PATCH" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  ! grep -qE $'^PATCH\t/repos/o/r\t' "$GH_STUB_CALL_LOG"
}

@test "tier_1 topics: target absent → PUT with union" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-no-topics --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  grep -q $'^PUT\t/repos/o/r/topics' "$GH_STUB_CALL_LOG"
  grep -q "serverkraken-onboarded" "$GH_STUB_CALL_LOG"
}

@test "tier_1 topics: target already present → no PUT" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  ! grep -q $'^PUT\t/repos/o/r/topics' "$GH_STUB_CALL_LOG"
}

@test "tier_2: marker present → no merge_hygiene/repo_settings PATCH" {
  tgt=$(prepare_target "lock-v2-with-marker.json")
  run_with_stub api-drifted-tier2 --repo o/r --target-path "$tgt" --prev-marker 2026-05-26T18:00:00Z
  [ "$status" -eq 0 ]
  ! grep -q "has_wiki" "$GH_STUB_CALL_LOG"
}

@test "tier_2: marker empty + drift → PATCH" {
  tgt=$(prepare_target "lock-v2-empty-marker.json")
  run_with_stub api-drifted-tier2 --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  grep -q "has_wiki" "$GH_STUB_CALL_LOG"
}

@test "tier_2: no prev lock → both tiers apply" {
  tgt=$(prepare_target "")
  run_with_stub api-drifted-tier2 --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  grep -q "has_wiki" "$GH_STUB_CALL_LOG"
}

@test "lock mutation: prev empty → writes now() to defaults_applied_at, bumps schema to 2" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  sv=$(jq -r '.schema_version' "$tgt/.github/onboard.lock.json")
  [ "$sv" = "2" ]
  marker=$(jq -r '.defaults_applied_at' "$tgt/.github/onboard.lock.json")
  [[ "$marker" =~ ^2[0-9]{3}- ]]
}

@test "lock mutation: prev non-empty → preserves prev marker" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker "2026-04-01T00:00:00Z"
  [ "$status" -eq 0 ]
  marker=$(jq -r '.defaults_applied_at' "$tgt/.github/onboard.lock.json")
  [ "$marker" = "2026-04-01T00:00:00Z" ]
}

@test "lock mutation: no prior lock → script still runs, writes nothing if no lock" {
  tgt=$(prepare_target "")
  run_with_stub api-clean --repo o/r --target-path "$tgt" --prev-marker ""
  [ "$status" -eq 0 ]
  [ ! -f "$tgt/.github/onboard.lock.json" ]
}

@test "dry-run: drifted state produces no mutating API calls, no lock write" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  before_sha=$(jq -S . "$tgt/.github/onboard.lock.json" | sha256sum | awk '{print $1}')
  run_with_stub api-drifted --repo o/r --target-path "$tgt" --prev-marker "" --dry-run
  [ "$status" -eq 0 ]
  ! grep -qE $'^(PUT|PATCH|POST|DELETE)\t' "$GH_STUB_CALL_LOG"
  after_sha=$(jq -S . "$tgt/.github/onboard.lock.json" | sha256sum | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

@test "dry-run: still emits defaults_applied=true output" {
  tgt=$(prepare_target "lock-v1-no-marker.json")
  run_with_stub api-drifted --repo o/r --target-path "$tgt" --prev-marker "" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *defaults_applied=true* ]]
}
