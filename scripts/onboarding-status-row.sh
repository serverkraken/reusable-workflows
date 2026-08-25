#!/usr/bin/env bash
# onboarding-status-row.sh — upsert one target's row in docs/onboarding-status.md.
#
# Usage:  onboarding-status-row.sh <doc> <result.json> <pin_version>
# Env:    TODAY   override the date stamp (tests); default: UTC today.
#
# Exit 2 means the result file carries no usable target — the caller should
# warn and skip, not write a blank-target row.
#
# Extracted from onboard.yml's finalize job so the two rules below can be
# tested. As inline workflow bash neither had ever been exercised.
set -euo pipefail

DOC="${1:-}"
RESULT="${2:-}"
PIN="${3:-v4}"

if [[ -z "$DOC" || -z "$RESULT" ]]; then
  echo "usage: $0 <doc> <result.json> [pin_version]" >&2
  exit 1
fi

target=$(jq -e -r '.target' "$RESULT" 2>/dev/null) || target=""
if [[ -z "$target" || "$target" == "null" ]]; then
  exit 2
fi

pa=$(jq -r '.pr_a_url // ""' "$RESULT")
pas=$(jq -r '.pr_a_status // ""' "$RESULT")
pb=$(jq -r '.pr_b_url // ""' "$RESULT")
pbs=$(jq -r '.pr_b_status // ""' "$RESULT")
js=$(jq -r '.job_status // ""' "$RESULT")

if   [[ "$pas" == "no-changes" && "$pbs" == "no-legacy"    ]]; then status="complete"
elif [[ "$pas" == "no-changes" && "$pbs" == "cleanup-open" ]]; then status="cleanup-open"
elif [[ "$pas" == "add-open"   && "$pbs" == "no-legacy"    ]]; then status="add-open, no-legacy"
elif [[ "$pas" == "add-open"   && "$pbs" == "cleanup-open" ]]; then status="add-open, cleanup-open"
else                                                              status="$pas / $pbs"
fi

failed=0
if [[ "$js" != "success" ]]; then
  status="error ($status)"
  failed=1
fi

# The "Onboarded" date must not move on a failed run. It used to be stamped
# with today unconditionally, so a repo whose onboarding broke was recorded as
# "onboarded today" — the column then answered a question nobody had asked and
# hid the one that mattered: when did this last actually work?
existing_date=$(awk -v tgt="$target" '
  index($0, "| " tgt " |") == 1 {
    split($0, cell, "|")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell[3])
    print cell[3]
    exit
  }
' "$DOC" 2>/dev/null || true)

if (( failed )); then
  onboarded="${existing_date:-—}"
else
  onboarded="${TODAY:-$(date -u +%Y-%m-%d)}"
fi

pa_md="—"; [[ -n "$pa" ]] && pa_md="[PR]($pa)"
pb_md="—"; [[ -n "$pb" ]] && pb_md="[PR]($pb)"

consumers_cell=$(jq -r '(.gitops_consumers // []) | map(.repo) | join(", ")' "$RESULT")
[[ -z "$consumers_cell" ]] && consumers_cell="—"

new_row="| $target | $onboarded | $PIN | $pa_md | $pb_md | $status | $consumers_cell |"

awk -v tgt="$target" -v row="$new_row" '
  BEGIN { replaced = 0 }
  {
    if (index($0, "| " tgt " |") == 1) { print row; replaced = 1 }
    else { print $0 }
  }
  END { if (!replaced) print row }
' "$DOC" > "$DOC.new" && mv "$DOC.new" "$DOC"

printf '%s\n' "$new_row"
