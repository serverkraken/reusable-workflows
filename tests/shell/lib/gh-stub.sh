#!/usr/bin/env bash
# tests/shell/lib/gh-stub.sh
#
# gh CLI mock for apply-repo-defaults bats tests.
#
# Behavior:
#   - Logs each invocation as a single line to $GH_STUB_CALL_LOG:
#       <verb>\t<endpoint>\t<flags-csv>\t<input-payload>
#   - Resolves response from $GH_STUB_FIXTURE_DIR keyed by sanitized endpoint
#     (slashes -> __, leading slash dropped, no trailing).
#       /repos/owner/repo/branches/main/protection
#         -> "$GH_STUB_FIXTURE_DIR/repos__owner__repo__branches__main__protection.json"
#   - If the fixture file is named *.404.json, exit 1 + stderr error simulating
#     a missing-resource response.
#   - If the fixture is *.403.json, exit 1 + 403 stderr.
#   - Otherwise: print the fixture file content to stdout, exit 0.
#   - For 'gh api -X PUT/PATCH/POST/DELETE' (mutating verbs): also accept JSON
#     payload via -f or --input; record it in the call-log line.
set -euo pipefail

CALL_LOG="${GH_STUB_CALL_LOG:-/dev/null}"
FIX_DIR="${GH_STUB_FIXTURE_DIR:-/dev/null}"

# Parse: gh api [-X METHOD] [-f key=val|--input file|--jq expr] ENDPOINT
verb="GET"
endpoint=""
flags=()
input_payload=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    api) shift ;;
    -X) verb="$2"; shift 2 ;;
    --method) verb="$2"; shift 2 ;;
    -f) flags+=("$2"); shift 2 ;;
    --input) input_payload="$(cat "$2")"; shift 2 ;;
    --jq) flags+=("--jq=$2"); shift 2 ;;
    -q) flags+=("--jq=$2"); shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done

# Sanitize endpoint for filename
key="${endpoint#/}"
key="${key//\//__}"
verb_lc=$(echo "$verb" | tr '[:upper:]' '[:lower:]')
fixture=""
for try_key in "${verb_lc}.${key}" "${key}"; do
  for ext in json 404.json 403.json 500.json; do
    if [[ -f "$FIX_DIR/${try_key}.${ext}" ]]; then
      fixture="$FIX_DIR/${try_key}.${ext}"
      break 2
    fi
  done
done

# Log the call
flags_csv=$(IFS=,; echo "${flags[*]:-}")
printf "%s\t%s\t%s\t%s\n" "$verb" "$endpoint" "$flags_csv" "${input_payload//$'\n'/ }" >> "$CALL_LOG"

if [[ -z "$fixture" ]]; then
  echo "gh-stub: no fixture for $endpoint (looked in $FIX_DIR)" >&2
  exit 1
fi

# Real `gh api` prints the HTTP error body to STDOUT (and a short diagnostic to
# stderr) before exiting non-zero. Mirror that here so callers using the
# `$(gh api ... 2>/dev/null || echo fallback)` idiom are exercised against real
# behavior — the error body leaks into the capture unless the caller discards
# stdout on failure.
case "$fixture" in
  *.404.json) cat "$fixture"; echo "gh: HTTP 404" >&2; exit 1 ;;
  *.403.json) cat "$fixture"; echo "gh: HTTP 403 forbidden" >&2; exit 1 ;;
  *.500.json) cat "$fixture"; echo "gh: HTTP 500" >&2; exit 1 ;;
  *) cat "$fixture"; exit 0 ;;
esac
