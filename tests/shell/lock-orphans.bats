#!/usr/bin/env bats
# Tests for scripts/lock-orphans.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/lock-orphans.sh"
  source "$REPO_ROOT/scripts/lib/hash-lib.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/.github/workflows"
}

teardown() {
  rm -rf "$WORK"
}

# write_file <relpath> <content> -> echoes "sha256:<hash>"
write_file() {
  printf '%s\n' "$2" > "$WORK/$1"
  printf 'sha256:%s' "$(cd "$WORK" && sha256_of "$1")"
}

lock() {  # lock <outfile> <path=hash> ...
  local out="$WORK/$1"; shift
  local json='{"files":{}}'
  for pair in "$@"; do
    json=$(printf '%s' "$json" | jq --arg k "${pair%%=*}" --arg v "${pair#*=}" '.files[$k] = $v')
  done
  printf '%s' "$json" > "$out"
}

@test "a template the catalog stopped rendering is reported as SAFE" {
  h=$(write_file ".github/workflows/old.yml" "rendered by the catalog")
  n=$(write_file ".github/workflows/new.yml" "the replacement")
  lock old.json ".github/workflows/old.yml=$h" ".github/workflows/new.yml=$n"
  lock new.json ".github/workflows/new.yml=$n"

  run "$SCRIPT" "$WORK/old.json" "$WORK/new.json" "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == "SAFE	.github/workflows/old.yml" ]]
}

@test "an orphan the adopter edited is MODIFIED, not SAFE" {
  h=$(write_file ".github/workflows/old.yml" "rendered by the catalog")
  lock old.json ".github/workflows/old.yml=$h"
  lock new.json
  printf 'the adopter changed this\n' > "$WORK/.github/workflows/old.yml"

  run "$SCRIPT" "$WORK/old.json" "$WORK/new.json" "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == "MODIFIED	.github/workflows/old.yml" ]]
}

@test "an orphan already deleted is GONE" {
  lock old.json ".github/workflows/vanished.yml=sha256:deadbeef"
  lock new.json
  run "$SCRIPT" "$WORK/old.json" "$WORK/new.json" "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == "GONE	.github/workflows/vanished.yml" ]]
}

@test "a file present in both locks is not an orphan" {
  h=$(write_file ".github/workflows/ci.yml" "same")
  lock old.json ".github/workflows/ci.yml=$h"
  lock new.json ".github/workflows/ci.yml=$h"
  run "$SCRIPT" "$WORK/old.json" "$WORK/new.json" "$WORK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the lock itself and the release-please manifest are never orphans" {
  lock old.json ".github/onboard.lock.json=sha256:a" ".release-please-manifest.json=sha256:b"
  lock new.json
  run "$SCRIPT" "$WORK/old.json" "$WORK/new.json" "$WORK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a first onboard (no previous lock) reports nothing" {
  lock new.json
  run "$SCRIPT" "$WORK/does-not-exist.json" "$WORK/new.json" "$WORK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing new lock is an error, not an empty result" {
  # Sonst saehe ein kaputter Render wie "nichts verwaist" aus — und ein
  # Aufraeumschritt, der bei Fehlern schweigt, ist schlimmer als keiner.
  lock old.json ".github/workflows/old.yml=sha256:a"
  run "$SCRIPT" "$WORK/old.json" "$WORK/nope.json" "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"new lock not found"* ]]
}
