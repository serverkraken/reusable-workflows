#!/usr/bin/env bats
# Tests for scripts/legacy-ci-fingerprint.sh.
#
# The script's job is to make PR B's deletion list content-addressed instead of
# name-addressed. The decisive test is "content changed between the two runs":
# with the old existence check that file was deleted, and nothing in the run
# said so.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/legacy-ci-fingerprint.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/.github/workflows"
  PROFILE='{"legacy_ci":[
    {"path":".github/workflows/ci.yml","replaced_by":"ci.yml"},
    {"path":".github/workflows/release.yml","replaced_by":"release.yml"},
    {"path":".github/workflows/mystery.yml","replaced_by":""}
  ]}'
  echo "old ci"      > "$WORK/.github/workflows/ci.yml"
  echo "old release" > "$WORK/.github/workflows/release.yml"
  echo "hand rolled" > "$WORK/.github/workflows/mystery.yml"
}

teardown() {
  rm -rf "$WORK"
}

fingerprint() {
  printf '%s' "$PROFILE" | "$SCRIPT" "$WORK"
}

@test "emits only entries with a replacement that exist" {
  run fingerprint
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/ci.yml"* ]]
  [[ "$output" == *".github/workflows/release.yml"* ]]
  # Unrecognised legacy (empty replaced_by) is never a deletion candidate.
  [[ "$output" != *"mystery.yml"* ]]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a path the profile names but the tree lacks is skipped" {
  rm "$WORK/.github/workflows/release.yml"
  run fingerprint
  [ "$status" -eq 0 ]
  [[ "$output" != *"release.yml"* ]]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "identical trees intersect completely" {
  before=$(fingerprint)
  after=$(fingerprint)
  run comm -12 <(echo "$before") <(echo "$after")
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a file rewritten between the two runs drops out of the intersection" {
  # Genau der TOCTOU-Fall: der Pfad existiert weiterhin, der Inhalt ist ein
  # anderer. Die alte Existenzpruefung haette ihn geloescht.
  before=$(fingerprint)
  echo "a human replaced this with something real" > "$WORK/.github/workflows/ci.yml"
  after=$(fingerprint)

  run comm -12 <(echo "$before") <(echo "$after")
  [[ "$output" != *"ci.yml"* ]]
  [[ "$output" == *"release.yml"* ]]

  run comm -23 <(echo "$before") <(echo "$after")
  [[ "$output" == *"ci.yml"* ]]
}

@test "output is sorted so comm can consume it directly" {
  run fingerprint
  sorted=$(echo "$output" | LC_ALL=C sort)
  [ "$output" = "$sorted" ]
}

@test "an empty legacy_ci yields no output and still succeeds" {
  PROFILE='{"legacy_ci":[]}'
  run fingerprint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a profile without a legacy_ci key at all is not an error" {
  PROFILE='{"target_repo":"acme/app"}'
  run fingerprint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
