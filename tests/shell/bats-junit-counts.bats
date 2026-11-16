#!/usr/bin/env bats
# Tests fuer scripts/bats-junit-counts.sh: Testzahlen aus dem bats-JUnit-Bericht.
# Die Berichte hier sind ECHTE bats-Ausgabe (bats --report-formatter junit),
# keine handgeschriebenen: das Format ist das Eingabe-Interface des Skripts.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/scripts/bats-junit-counts.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/t" "$WORK/rep"
}

teardown() {
  rm -rf "$WORK"
}

# run_bats: bats-Suite in $WORK/t laufen lassen; der Exit-Status ist egal,
# nur der Bericht zaehlt.
run_bats() {
  bats --formatter tap --report-formatter junit --output "$WORK/rep" "$WORK/t" >/dev/null 2>&1 || true
}

@test "zaehlt Tests ueber mehrere Dateien: gesamt, fehlgeschlagen, uebersprungen" {
  printf '@test "a" { true; }\n@test "b" { false; }\n@test "c" { skip; }\n' > "$WORK/t/a.bats"
  printf '@test "d" { true; }\n' > "$WORK/t/b.bats"
  run_bats
  run bash "$SCRIPT" "$WORK/rep/report.xml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests_total=4"* ]]
  [[ "$output" == *"tests_failed=1"* ]]
  [[ "$output" == *"tests_skipped=1"* ]]
}

@test "meldet 0 Fehler bei gruener Suite" {
  printf '@test "a" { true; }\n@test "b" { true; }\n' > "$WORK/t/a.bats"
  run_bats
  run bash "$SCRIPT" "$WORK/rep/report.xml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests_total=2"* ]]
  [[ "$output" == *"tests_failed=0"* ]]
}

@test "lehnt eine fehlende Datei ab (Exit 2)" {
  run bash "$SCRIPT" "$WORK/gibtsnicht.xml"
  [ "$status" -eq 2 ]
}

@test "lehnt einen Bericht ohne testsuite ab (Exit 3), statt 0 Tests zu melden" {
  printf '<?xml version="1.0"?>\n<testsuites time="0">\n</testsuites>\n' > "$WORK/leer.xml"
  run bash "$SCRIPT" "$WORK/leer.xml"
  [ "$status" -eq 3 ]
  [[ "$output" != *"tests_total="* ]]
}

@test "rechnet errors zu failed" {
  printf '<testsuites>\n<testsuite name="x.bats" tests="5" failures="1" errors="2" skipped="0" time="0">\n</testsuite>\n</testsuites>\n' > "$WORK/e.xml"
  run bash "$SCRIPT" "$WORK/e.xml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests_failed=3"* ]]
}
