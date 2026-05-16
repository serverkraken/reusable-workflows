#!/usr/bin/env bats

setup() {
  SANITIZE_SH="$BATS_TEST_DIRNAME/../../actions/compute-prerelease-tag/sanitize.sh"
}

@test "simple lowercase branch" {
  run bash "$SANITIZE_SH" "feat-x" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feat-x-a1b2c3d$"
  echo "$output" | grep -q "^moving_tag=feat-x$"
}

@test "slash in branch name becomes dash" {
  run bash "$SANITIZE_SH" "feat/auth-fix" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feat-auth-fix-a1b2c3d$"
  echo "$output" | grep -q "^moving_tag=feat-auth-fix$"
}

@test "uppercase letters are lowercased" {
  run bash "$SANITIZE_SH" "Feature/Auth-Fix" "DEADBEE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feature-auth-fix-deadbee$"
}

@test "invalid OCI characters are stripped" {
  run bash "$SANITIZE_SH" "feat/foo@bar~baz" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo-bar-baz$"
}

@test "multiple consecutive dashes collapse to one" {
  run bash "$SANITIZE_SH" "feat//foo--bar" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo-bar$"
}

@test "leading/trailing dashes are stripped" {
  run bash "$SANITIZE_SH" "-feat-foo-" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo$"
}

@test "empty branch name fails" {
  run bash "$SANITIZE_SH" "" "abcdef0"
  [ "$status" -ne 0 ]
}

@test "empty SHA fails" {
  run bash "$SANITIZE_SH" "feat-x" ""
  [ "$status" -ne 0 ]
}

@test "branch consisting only of invalid chars fails" {
  run bash "$SANITIZE_SH" "@@@" "abcdef0"
  [ "$status" -ne 0 ]
}

@test "very long branch name truncated to 64 chars in moving tag" {
  long_branch=$(printf 'a%.0s' {1..200})
  run bash "$SANITIZE_SH" "$long_branch" "abcdef0"
  [ "$status" -eq 0 ]
  moving=$(echo "$output" | grep '^moving_tag=' | cut -d= -f2)
  [ ${#moving} -le 64 ]
}
