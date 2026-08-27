#!/usr/bin/env bats
# Tests for scripts/trivy-findings-report.sh.
#
# The script turns a Trivy JSON report into (a) a Markdown findings table
# for $GITHUB_STEP_SUMMARY and (b) GitHub workflow-command annotations,
# so failing trivy-* jobs show WHAT was found instead of only a count.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/trivy-findings-report.sh"
  FIX="$REPO_ROOT/tests/fixtures/trivy-report"
  load lib/assertions
}

# ---------- table ----------

@test "table: header row is present and rows are sorted CRITICAL > HIGH > MEDIUM" {
  run bash "$SCRIPT" table "$FIX/mixed.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^| Severity | Type | ID | Location | Installed → Fixed | Title |$'
  # Order: line numbers of severities must ascend
  crit_first=$(echo "$output" | grep -n '^| CRITICAL' | head -1 | cut -d: -f1)
  crit_last=$(echo "$output"  | grep -n '^| CRITICAL' | tail -1 | cut -d: -f1)
  high_first=$(echo "$output" | grep -n '^| HIGH' | head -1 | cut -d: -f1)
  high_last=$(echo "$output"  | grep -n '^| HIGH' | tail -1 | cut -d: -f1)
  med_first=$(echo "$output"  | grep -n '^| MEDIUM' | head -1 | cut -d: -f1)
  [ "$crit_last" -lt "$high_first" ]
  [ "$high_last" -lt "$med_first" ]
  [ "$crit_first" -lt "$crit_last" ]
}

@test "table: vulnerability row carries id, package, versions and title" {
  run bash "$SCRIPT" table "$FIX/mixed.json"
  echo "$output" | grep -q '^| HIGH | vuln | CVE-2023-0002 | `libcrypto1.1` | `1.1.1q-r0` → `1.1.1t-r0` | openssl: X.400 address type confusion in X.509 GeneralName |$'
}

@test "table: vulnerability without fix shows dash for fixed version" {
  run bash "$SCRIPT" table "$FIX/mixed.json"
  echo "$output" | grep -q '^| MEDIUM | vuln | CVE-2021-0003 | `busybox` | `1.34.1-r3` → – |'
}

@test "table: secret row points at file:line" {
  run bash "$SCRIPT" table "$FIX/mixed.json"
  echo "$output" | grep -q '^| CRITICAL | secret | aws-access-key-id | `app/config.env:12` | – | AWS Access Key ID |$'
}

@test "table: misconfiguration row points at file:line and uses AVD id" {
  run bash "$SCRIPT" table "$FIX/mixed.json"
  echo "$output" | grep -q '^| HIGH | misconfig | AVD-DS-0002 | `Dockerfile:3` | – | Image user should not be '"'"'root'"'"' |$'
}

@test "table: pipes and newlines in titles are neutralised" {
  run bash "$SCRIPT" table "$FIX/mixed.json"
  echo "$output" | grep -q 'zlib: a heap-based buffer over-read \\| with pipes |$'
  echo "$output" | grep -q 'busybox: something multi-line title'
}

@test "table: secret Match values are never printed" {
  run bash "$SCRIPT" table "$FIX/mixed.json"
  refute_grep -q 'AKIA' <<<"$output"
}

@test "table: respects MAX_ROWS and reports the remainder" {
  MAX_ROWS=2 run bash "$SCRIPT" table "$FIX/mixed.json"
  [ "$status" -eq 0 ]
  rows=$(echo "$output" | grep -c '^| \(CRITICAL\|HIGH\|MEDIUM\|LOW\|UNKNOWN\) |')
  [ "$rows" -eq 2 ]
  echo "$output" | grep -q '^_… and 3 more findings'
}

@test "table: empty report prints nothing and exits 0" {
  run bash "$SCRIPT" table "$FIX/empty.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" table "$FIX/no-results.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- annotations ----------

@test "annotations: one ::error:: line per finding, sorted by severity" {
  run bash "$SCRIPT" annotations "$FIX/mixed.json"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | grep -c '^::error')
  [ "$count" -eq 5 ]
  first=$(echo "$output" | head -1)
  [[ "$first" == "::error"*"[CRITICAL]"* ]]
  echo "$output" | grep -q '^::error::\[HIGH\] CVE-2023-0002 in libcrypto1.1 1.1.1q-r0 (fixed: 1.1.1t-r0) — openssl'
  echo "$output" | grep -q '^::error::\[MEDIUM\] CVE-2021-0003 in busybox 1.34.1-r3 (no fix) — busybox'
}

@test "annotations: file-backed findings get file= and line= so they show inline in PRs" {
  run bash "$SCRIPT" annotations "$FIX/mixed.json"
  echo "$output" | grep -q '^::error file=app/config.env,line=12::\[CRITICAL\] aws-access-key-id — AWS Access Key ID'
  echo "$output" | grep -q '^::error file=Dockerfile,line=3::\[HIGH\] AVD-DS-0002 — Image user should not be'
}

@test "annotations: respects MAX_ANNOTATIONS" {
  MAX_ANNOTATIONS=1 run bash "$SCRIPT" annotations "$FIX/mixed.json"
  count=$(echo "$output" | grep -c '^::error')
  [ "$count" -eq 1 ]
}

@test "annotations: newlines in titles are collapsed to a single line" {
  run bash "$SCRIPT" annotations "$FIX/mixed.json"
  echo "$output" | grep -q 'busybox: something multi-line title$'
}

@test "annotations: empty report prints nothing" {
  run bash "$SCRIPT" annotations "$FIX/empty.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- errors ----------

@test "unknown mode fails" {
  run bash "$SCRIPT" bogus "$FIX/mixed.json"
  [ "$status" -ne 0 ]
}

@test "missing report file fails" {
  run bash "$SCRIPT" table /nonexistent.json
  [ "$status" -ne 0 ]
}

# ---------- Audit I-20 / I-21 ----------

# I-20. Der Tabellen-Modus maskiert laengst (`def md`), der Annotations-Modus
# tat es nicht — dieselbe Datei, zwei Ausgaben, nur eine abgesichert.
#
# GitHub trennt die Eigenschaften eines Workflow-Kommandos mit `,` und beendet
# den Kopf mit `::`. Vorher entstand woertlich:
#
#   ::error file=usr/share/doc/foo,bar/README:notes,line=3::…
#
# GitHub liest daraus `file=usr/share/doc/foo` und dahinter eine unbekannte
# Eigenschaft — die Annotation landet an der falschen Datei oder gar nicht.
@test "annotations: Komma und Doppelpunkt im Pfad werden maskiert (Audit I-20)" {
  run bash "$SCRIPT" annotations "$FIX/annotation-escaping.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"file=usr/share/doc/foo%2Cbar/README%3Anotes,line=3::"* ]] || {
    echo "$output"; false
  }
  # Die rohen Zeichen duerfen im Kopf nicht mehr stehen.
  refute_grep -q 'file=[^:]*,bar' <<<"$output"
}

# Prozentzeichen zuerst, sonst maskiert der naechste Schritt das eben
# eingefuegte `%` ein zweites Mal.
@test "annotations: Prozentzeichen in der Nachricht wird maskiert (Audit I-20)" {
  run bash "$SCRIPT" annotations "$FIX/annotation-escaping.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"100%25 Prozent"* ]] || { echo "$output"; false; }
  [[ "$output" != *"100%2525"* ]] || { echo "doppelt maskiert: $output"; false; }
}

# I-21. Die Modus-Pruefung sass nur im `case` — also NACH dem Null-Funde-
# Ausstieg. Ein Aufrufer mit einem Tippfehler lief gruen durch, solange der
# Report leer war, und scheiterte erst beim ersten echten Fund: genau in dem
# Moment, in dem der Bericht gebraucht wird.
#
# Der bestehende Test "unknown mode fails" nutzt mixed.json, also einen NICHT
# leeren Report — der Fall war damit nie abgedeckt.
@test "unbekannter Modus scheitert auch bei LEEREM Report (Audit I-21)" {
  run bash "$SCRIPT" bogus "$FIX/empty.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown mode"* ]] || { echo "$output"; false; }
}

# Gegenprobe: ein GUELTIGER Modus bleibt bei leerem Report still und gruen.
# Ohne diese Zusicherung koennte die vorgezogene Pruefung den Null-Funde-Pfad
# stillschweigend kaputtmachen.
@test "gueltiger Modus bleibt bei leerem Report still und gruen" {
  run bash "$SCRIPT" annotations "$FIX/empty.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPT" table "$FIX/empty.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
