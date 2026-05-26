#!/usr/bin/env bash
# apply-defaults-lib.sh — pure functions for repo-defaults computation.
#
# No API side effects in this file. apply-repo-defaults.sh is the only
# consumer; tests source this file directly.

# classify_tier <field-name> → echoes "tier_1" | "tier_2" | "unknown"
#
# Tier 1 (always-overwrite every sweep): security-relevant fields.
# Tier 2 (first-onboard-only): comfort fields, gated by the lock marker.
classify_tier() {
  case "$1" in
    branch_protection|delete_branch_on_merge|topics_additive)
      echo "tier_1"
      ;;
    allow_squash_merge|allow_merge_commit|allow_rebase_merge|allow_auto_merge|\
    squash_merge_commit_title|squash_merge_commit_message|\
    has_wiki|has_projects|has_issues|has_discussions)
      echo "tier_2"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# compute_topics_union <current-json-array> <additive-json-array>
#   → echoes JSON array: current ∪ additive, preserving current order,
#     appending missing additives in their input order.
compute_topics_union() {
  local current="$1"
  local additive="$2"
  jq -nc \
    --argjson current "$current" \
    --argjson additive "$additive" \
    '$current + ($additive - $current)'
}

# diff_branch_protection <current-json> <target-json>
#   → echoes diff summary line, or empty if equivalent.
#
# Current is the GitHub API's branch-protection response shape:
#   { enforce_admins: {enabled: bool}, required_linear_history: {enabled: bool},
#     required_pull_request_reviews: {required_approving_review_count, ...} ... }
# Or the literal string "missing" when no protection exists.
#
# Target is the catalog config shape (flat booleans / nested objects).
#
# We normalize both to a canonical comparison shape, then jq-diff.
diff_branch_protection() {
  local current="$1"
  local target="$2"

  if [[ "$current" == "missing" ]]; then
    echo "reason=missing"
    return 0
  fi

  # Normalize current API shape → flat keys matching target.
  local normalized_current
  normalized_current=$(jq -nc --argjson c "$current" '
    {
      enforce_admins: ($c.enforce_admins.enabled // false),
      required_linear_history: ($c.required_linear_history.enabled // false),
      allow_force_pushes: ($c.allow_force_pushes.enabled // false),
      allow_deletions: ($c.allow_deletions.enabled // false),
      required_conversation_resolution: ($c.required_conversation_resolution.enabled // false),
      lock_branch: ($c.lock_branch.enabled // false),
      block_creations: ($c.block_creations.enabled // false),
      required_status_checks: ($c.required_status_checks // null),
      required_pull_request_reviews: (
        if $c.required_pull_request_reviews == null then null
        else {
          required_approving_review_count: ($c.required_pull_request_reviews.required_approving_review_count // 0),
          dismiss_stale_reviews: ($c.required_pull_request_reviews.dismiss_stale_reviews // false),
          require_code_owner_reviews: ($c.required_pull_request_reviews.require_code_owner_reviews // false),
          require_last_push_approval: ($c.required_pull_request_reviews.require_last_push_approval // false)
        }
        end
      ),
      restrictions: ($c.restrictions // null)
    }
  ')

  # Normalize target to canonical shape: only keys present in target get compared.
  local normalized_target
  normalized_target=$(jq -nc --argjson t "$target" '
    ($t | del(._target)) as $clean |
    {
      enforce_admins: ($clean.enforce_admins // false),
      required_linear_history: ($clean.required_linear_history // false),
      allow_force_pushes: ($clean.allow_force_pushes // false),
      allow_deletions: ($clean.allow_deletions // false),
      required_conversation_resolution: ($clean.required_conversation_resolution // false),
      lock_branch: ($clean.lock_branch // false),
      block_creations: ($clean.block_creations // false),
      required_status_checks: ($clean.required_status_checks // null),
      required_pull_request_reviews: (
        if $clean.required_pull_request_reviews == null then null
        else {
          required_approving_review_count: ($clean.required_pull_request_reviews.required_approving_review_count // 0),
          dismiss_stale_reviews: ($clean.required_pull_request_reviews.dismiss_stale_reviews // false),
          require_code_owner_reviews: ($clean.required_pull_request_reviews.require_code_owner_reviews // false),
          require_last_push_approval: ($clean.required_pull_request_reviews.require_last_push_approval // false)
        }
        end
      ),
      restrictions: ($clean.restrictions // null)
    }
  ')

  # Build keys-where-they-differ list (only on keys in target).
  local diff_keys
  diff_keys=$(jq -nc \
    --argjson c "$normalized_current" \
    --argjson t "$normalized_target" \
    '[($t | keys_unsorted)[] | select(($c[.]) != ($t[.]))] | join(",")')

  if [[ "$diff_keys" == "" || "$diff_keys" == '""' ]]; then
    echo ""
  else
    echo "reason=drift fields=$(echo "$diff_keys" | tr -d '"')"
  fi
}
