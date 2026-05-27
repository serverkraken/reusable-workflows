#!/usr/bin/env bash
# tests/conventions/check-step-summary.sh
#
# CI gate enforcing docs/conventions/step-summary.md.
#
# For every workflow in .github/workflows/ (except the Self-CI allowlist),
# assert:
#   1. The file writes to $GITHUB_STEP_SUMMARY at least once.
#   2. The file contains an H2 heading matching its own basename
#      (e.g., lint-go.yml must contain a line writing "## lint-go").
#
# Bats fixtures invoke this from a temp dir; CI invokes from repo root.
# Both cases work because we glob .github/workflows/*.{yml,yaml} relative
# to CWD; nullglob keeps the loop empty when one extension is unused.

set -euo pipefail

SELF_CI_ALLOWLIST=(
  "validate.yml"
  "integration.yml"
  "self-ci.yml"
  "release.yml"
  "catalog-release.yml"
)

CONVENTION_DOC="docs/conventions/step-summary.md"
FAILED=0
CHECKED=0

shopt -s nullglob
for file in .github/workflows/*.yml .github/workflows/*.yaml; do
  basename=$(basename "$file")
  atom_name="${basename%.yml}"

  # Skip Self-CI atoms.
  skip=0
  for entry in "${SELF_CI_ALLOWLIST[@]}"; do
    if [[ "$basename" == "$entry" ]]; then
      skip=1
      break
    fi
  done
  # Skip caller-*.yml test wrappers — they call atoms via `uses:` and the
  # called atom writes the step summary. Wrapping it again would be noise.
  if [[ "$basename" == caller-*.yml ]]; then
    skip=1
  fi
  if [[ $skip -eq 1 ]]; then
    continue
  fi

  CHECKED=$((CHECKED + 1))

  # Check 1: GITHUB_STEP_SUMMARY write present.
  if ! grep -q 'GITHUB_STEP_SUMMARY' "$file"; then
    echo "FAIL: $basename writes no \$GITHUB_STEP_SUMMARY."
    echo "      Required by $CONVENTION_DOC."
    FAILED=1
    continue
  fi

  # Check 2: H2 heading matches atom name.
  # Two accepted patterns:
  #   (a) echo "## <atom>"      (single-line echo, most common)
  #   (b) a bare line of "## <atom>"  (heredocs or block-quoted)
  pattern_echo="echo[[:space:]]+[\"']## ${atom_name}[\"' ]"
  pattern_bare="^[[:space:]]*## ${atom_name}([[:space:]]|$)"
  if ! grep -qE "$pattern_echo" "$file" && ! grep -qE "$pattern_bare" "$file"; then
    echo "FAIL: $basename writes summary but no '## ${atom_name}' heading found."
    echo "      Heading must match atom filename per $CONVENTION_DOC."
    FAILED=1
  fi
done

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "Convention violations found. See $CONVENTION_DOC."
  exit 1
fi

echo "OK: $CHECKED atoms checked, all conformant."
