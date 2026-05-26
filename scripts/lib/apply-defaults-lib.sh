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
