#!/usr/bin/env bash
# scripts/bats-junit-counts.sh — Testzahlen aus einem bats-JUnit-Bericht.
#
# Aufruf: bats-junit-counts.sh <report.xml>
# Ausgabe (stdout, eine Zeile je Wert, direkt an $GITHUB_OUTPUT anhaengbar):
#   tests_total=<n>     alle Testfaelle
#   tests_failed=<n>    failures + errors
#   tests_skipped=<n>
#
# Summiert die <testsuite>-Elemente (eines je .bats-Datei). Das Wurzelelement
# <testsuites> traegt bei bats keine Zaehler und wird nicht mitgezaehlt.
# Exit 2 bei fehlender oder leerer Datei, Exit 3 ohne jedes <testsuite>:
# ein Bericht, der nichts zaehlt, darf nicht als "0 Fehler" durchgehen.
set -euo pipefail

report="${1:-}"
if [[ -z "$report" || ! -s "$report" ]]; then
  echo "bats-junit-counts: Bericht fehlt oder ist leer: '${report}'" >&2
  exit 2
fi

awk '
  /^[[:space:]]*<testsuite[[:space:]]/ {
    suites++
    if (match($0, /tests="[0-9]+"/))    { t = substr($0, RSTART + 7, RLENGTH - 8); total += t }
    if (match($0, /failures="[0-9]+"/)) { f = substr($0, RSTART + 10, RLENGTH - 11); failed += f }
    if (match($0, /errors="[0-9]+"/))   { e = substr($0, RSTART + 8, RLENGTH - 9); failed += e }
    if (match($0, /skipped="[0-9]+"/))  { s = substr($0, RSTART + 9, RLENGTH - 10); skipped += s }
  }
  END {
    if (suites == 0) { exit 3 }
    printf "tests_total=%d\ntests_failed=%d\ntests_skipped=%d\n", total, failed, skipped
  }
' "$report" || {
  rc=$?
  [[ $rc -eq 3 ]] && echo "bats-junit-counts: kein <testsuite> im Bericht: ${report}" >&2
  exit "$rc"
}
