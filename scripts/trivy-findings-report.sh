#!/usr/bin/env bash
# Render Trivy JSON findings for humans.
#
# Usage:
#   trivy-findings-report.sh table       <report.json>   # Markdown table for $GITHUB_STEP_SUMMARY
#   trivy-findings-report.sh annotations <report.json>   # ::error:: workflow commands for the job log / PR
#
# Env:
#   MAX_ROWS         cap for table rows (default 50); remainder is reported as a footer line
#   MAX_ANNOTATIONS  cap for annotations (default 10 — GitHub shows at most 10 error
#                    annotations per step anyway)
#
# Covers Vulnerabilities, Secrets and Misconfigurations. Findings are sorted
# CRITICAL > HIGH > MEDIUM > LOW > UNKNOWN, stable within a severity.
# Secret `Match` values are deliberately never emitted.

set -euo pipefail

mode="${1:-}"
report="${2:-}"

if [[ -z "$mode" || -z "$report" ]]; then
  echo "usage: $0 <table|annotations> <report.json>" >&2
  exit 2
fi
if [[ ! -f "$report" ]]; then
  echo "trivy-findings-report: report not found: $report" >&2
  exit 2
fi

MAX_ROWS="${MAX_ROWS:-50}"
MAX_ANNOTATIONS="${MAX_ANNOTATIONS:-10}"

# Normalise all three finding kinds into one flat, sorted list of objects:
#   {sev, kind, id, target, line, pkg, installed, fixed, title, file}
# `file` is the Target when it looks like a path Trivy can attribute to a
# file (secrets and misconfigs always are; vulns from `trivy fs` are too,
# vulns from `trivy image` are "<image> (<os>)" and get null).
# shellcheck disable=SC2016
NORMALISE='
  def rank: {"CRITICAL":0,"HIGH":1,"MEDIUM":2,"LOW":3}[.] // 4;
  def clean: (. // "") | gsub("[\r\n]+"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
  def is_file: (. // "") | test("^[^ ()]+$") and (test(":") | not);
  [ .Results[]? as $r
    | (
        ($r.Vulnerabilities // [])[] | {
          sev: (.Severity // "UNKNOWN"),
          kind: "vuln",
          id: .VulnerabilityID,
          target: $r.Target,
          line: null,
          pkg: .PkgName,
          installed: .InstalledVersion,
          fixed: (.FixedVersion // ""),
          title: (.Title | clean),
          file: (if ($r.Target | is_file) then $r.Target else null end)
        }
      ),
      (
        ($r.Secrets // [])[] | {
          sev: (.Severity // "UNKNOWN"),
          kind: "secret",
          id: .RuleID,
          target: $r.Target,
          line: .StartLine,
          pkg: null, installed: null, fixed: null,
          title: (.Title | clean),
          file: $r.Target
        }
      ),
      (
        ($r.Misconfigurations // [])[] | {
          sev: (.Severity // "UNKNOWN"),
          kind: "misconfig",
          id: (.AVDID // .ID),
          target: $r.Target,
          line: (.CauseMetadata.StartLine // null),
          pkg: null, installed: null, fixed: null,
          title: (.Title | clean),
          file: $r.Target
        }
      )
  ]
  | sort_by(.sev | rank)
'

findings=$(jq -c "$NORMALISE" "$report")
total=$(jq 'length' <<<"$findings")

if [[ "$total" -eq 0 ]]; then
  exit 0
fi

case "$mode" in
  table)
    {
      echo "| Severity | Type | ID | Location | Installed → Fixed | Title |"
      echo "|---|---|---|---|---|---|"
      # shellcheck disable=SC2016
      jq -r --argjson max "$MAX_ROWS" '
        def md: gsub("\\|"; "\\|");
        .[:$max][]
        | (if .kind == "vuln"
             then "`" + (.pkg // "?") + "`"
           elif .line != null
             then "`" + .target + ":" + (.line|tostring) + "`"
           else "`" + .target + "`" end) as $loc
        | (if .kind == "vuln"
             then "`" + (.installed // "?") + "` → " + (if .fixed != "" then "`" + .fixed + "`" else "–" end)
           else "–" end) as $ver
        | "| \(.sev) | \(.kind) | \(.id | md) | \($loc | md) | \($ver | md) | \(.title | md) |"
      ' <<<"$findings"
      if [[ "$total" -gt "$MAX_ROWS" ]]; then
        echo ""
        echo "_… and $((total - MAX_ROWS)) more findings — see the SARIF artifact / code-scanning for the full list._"
      fi
    }
    ;;
  annotations)
    # shellcheck disable=SC2016
    jq -r --argjson max "$MAX_ANNOTATIONS" '
      .[:$max][]
      | (if .file != null
           then "::error file=" + .file + (if .line != null then ",line=" + (.line|tostring) else "" end) + "::"
         else "::error::" end) as $prefix
      | (if .kind == "vuln"
           then "[\(.sev)] \(.id) in \(.pkg // "?") \(.installed // "?") " + (if .fixed != "" then "(fixed: \(.fixed))" else "(no fix)" end) + " — \(.title)"
         else "[\(.sev)] \(.id) — \(.title)" end) as $msg
      | $prefix + $msg
    ' <<<"$findings"
    ;;
  *)
    echo "trivy-findings-report: unknown mode '$mode' (expected table|annotations)" >&2
    exit 2
    ;;
esac
