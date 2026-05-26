#!/usr/bin/env bats
# Pure-function tests for scripts/lib/apply-defaults-lib.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  source "$REPO_ROOT/scripts/lib/apply-defaults-lib.sh"
}

@test "classify_tier: branch_protection is tier_1" {
  run classify_tier "branch_protection"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_1" ]
}

@test "classify_tier: delete_branch_on_merge is tier_1" {
  run classify_tier "delete_branch_on_merge"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_1" ]
}

@test "classify_tier: topics_additive is tier_1" {
  run classify_tier "topics_additive"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_1" ]
}

@test "classify_tier: allow_squash_merge is tier_2" {
  run classify_tier "allow_squash_merge"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_2" ]
}

@test "classify_tier: has_wiki is tier_2" {
  run classify_tier "has_wiki"
  [ "$status" -eq 0 ]
  [ "$output" = "tier_2" ]
}

@test "classify_tier: unknown field returns unknown" {
  run classify_tier "totally_made_up_field"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}
