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

@test "compute_topics_union: empty current + one new → just the new" {
  run compute_topics_union "[]" '["serverkraken-onboarded"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["serverkraken-onboarded"]' ]
}

@test "compute_topics_union: existing without target → appended at end" {
  run compute_topics_union '["go","backend"]' '["serverkraken-onboarded"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["go","backend","serverkraken-onboarded"]' ]
}

@test "compute_topics_union: existing already contains target → unchanged" {
  run compute_topics_union '["serverkraken-onboarded","go"]' '["serverkraken-onboarded"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["serverkraken-onboarded","go"]' ]
}

@test "compute_topics_union: multiple new, some already present → only missing appended" {
  run compute_topics_union '["a","b"]' '["b","c"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["a","b","c"]' ]
}

@test "diff_branch_protection: missing target → diff with reason=missing" {
  target='{"enforce_admins":false,"required_linear_history":true}'
  run diff_branch_protection "missing" "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == reason=missing* ]]
}

@test "diff_branch_protection: identical state → empty" {
  current='{"enforce_admins":{"enabled":false},"required_linear_history":{"enabled":true}}'
  target='{"enforce_admins":false,"required_linear_history":true}'
  run diff_branch_protection "$current" "$target"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "diff_branch_protection: enforce_admins flipped → drift" {
  current='{"enforce_admins":{"enabled":true},"required_linear_history":{"enabled":true}}'
  target='{"enforce_admins":false,"required_linear_history":true}'
  run diff_branch_protection "$current" "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == *enforce_admins* ]]
}
