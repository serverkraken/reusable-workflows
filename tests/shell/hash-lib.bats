#!/usr/bin/env bats
# Tests for scripts/lib/hash-lib.sh — portable sha256 helper.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/hash-lib.sh"
}

@test "hash-lib.sh exists" {
  [ -f "$LIB" ]
}

@test "sha256_of computes correct hex for known input" {
  src="$(mktemp)"
  printf 'hello\n' > "$src"
  source "$LIB"
  got=$(sha256_of "$src")
  # printf 'hello\n' | sha256sum  -> 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  [ "$got" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
  rm -f "$src"
}

@test "sha256_of handles paths with spaces" {
  dir="$(mktemp -d)"
  src="$dir/file with spaces.txt"
  printf 'hello\n' > "$src"
  source "$LIB"
  got=$(sha256_of "$src")
  [ "$got" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
  rm -rf "$dir"
}
