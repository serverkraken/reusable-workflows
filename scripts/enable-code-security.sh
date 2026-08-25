#!/usr/bin/env bash
# enable-code-security.sh — turn on GitHub code scanning for a private adopter.
#
# Code scanning needs `code_security` enabled on private repos before SARIF
# upload works. Public repos get it for free and do not carry the knob at all,
# so visibility is read first and non-private targets are skipped.
#
# Extracted from onboard.yml for two reasons. It is the only outright mutation
# the onboard job performs on a target before any dry-run gate, so it needs a
# guard that can be tested; and as inline workflow bash it could not be tested
# at all — the integration dry-run targets this repo, which is public, so the
# PATCH path never ran in CI.
#
# Usage:  enable-code-security.sh <owner/repo>
# Env:    DRY_RUN   "true" reports what would change and mutates nothing.
#         GH_TOKEN  token with administration:write on the target.
#
# Stdout: one `outcome=<value>` line, plus human-readable progress.
#         outcome=skipped-public   target is not private; nothing to do
#         outcome=already-enabled  code_security was already on
#         outcome=would-enable     dry run; a real run would PATCH
#         outcome=enabled          code_security was switched on
set -euo pipefail

TARGET="${1:-}"
DRY_RUN="${DRY_RUN:-false}"

if [[ -z "$TARGET" ]]; then
  echo "::error::usage: $0 <owner/repo>" >&2
  exit 1
fi

visibility=$(gh api "/repos/$TARGET" --jq '.visibility')
if [[ "$visibility" != "private" ]]; then
  echo "Skipping code_security enable for $TARGET (visibility=$visibility)"
  echo "outcome=skipped-public"
  exit 0
fi

current=$(gh api "/repos/$TARGET" --jq '.security_and_analysis.code_security.status // "absent"')
if [[ "$current" == "enabled" ]]; then
  echo "code_security already enabled on $TARGET — no-op"
  echo "outcome=already-enabled"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  # A dry run promises to change nothing. This step used to PATCH regardless,
  # so "render + log diff; do NOT push or open PRs" quietly excluded the one
  # mutation that reached the target repo's settings rather than its files.
  echo "DRY RUN: would enable code_security on $TARGET (currently $current)"
  echo "outcome=would-enable"
  exit 0
fi

echo "Enabling code_security on $TARGET (was $current)"
echo '{"security_and_analysis":{"code_security":{"status":"enabled"}}}' \
  | gh api --method PATCH "/repos/$TARGET" --input - > /dev/null
echo "outcome=enabled"
