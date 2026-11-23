#!/usr/bin/env bats
# Tests for scripts/shellcheck-run.sh (Schritt "Run shellcheck" in lint-shell.yml)
#
# Der Kern ist shellchecks Vertrag fuer fatale Laeufe, gemessen:
#
#   $ shellcheck -f json1 -S style gibtsnicht.sh
#   rc=2 · stdout {"comments":[]} · stderr "openBinaryFile: does not exist"
#
# Ein gueltiger, LEERER Bericht trotz Abbruch. Die alte Pruefung
# (`rc != 0 && ! -s shellcheck.json`) lief daran vorbei und meldete gruen,
# ohne eine Zeile geprueft zu haben. Frueher deckte das der Nightly-Job
# test-lint-shell-unreadable mit einem EINGECHECKTEN kaputten Symlink ab; der
# brach das Laden aller Composite-Actions (#458). Die fatalen Faelle entstehen
# hier deshalb zur Laufzeit.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/scripts/shellcheck-run.sh"
  command -v shellcheck >/dev/null || {
    echo "shellcheck fehlt — ohne ihn prueft diese Suite nichts" >&2
    return 1
  }
  WORK="$(mktemp -d)"
  cd "$WORK"
  export SEVERITY=style FOLLOW=false
  printf '#!/bin/sh\necho "ok"\n' > clean.sh
  # SC2086 (info): ungequotete Variable.
  printf '#!/bin/sh\necho $1\n' > finding.sh
}

teardown() {
  rm -rf "$WORK"
}

@test "sauberer Lauf: exit 0, Bericht ohne Funde, rc 0 protokolliert" {
  printf 'clean.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.comments == []' shellcheck.json
  [ "$(sort -n shellcheck.rc | tail -1)" = "0" ]
}

# Funde sind KEIN Fehler dieses Schritts: ob sie den Job rot machen, entscheidet
# fail_on_findings spaeter ueber den Count.
@test "Funde: exit 0, Bericht traegt sie, rc 1 protokolliert" {
  printf 'finding.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '[.comments[].code] | index(2086) != null' shellcheck.json
  [ "$(sort -n shellcheck.rc | tail -1)" = "1" ]
}

@test "kaputter Symlink: fatal trotz gueltigem leerem Bericht" {
  ln -s gibtsnicht.sh dangling.sh
  printf 'dangling.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rc=2"* ]]
  [[ "$output" == *"does not exist"* ]]
  # Genau die Falle: der Bericht ist NICHT leer. Eine Pruefung auf `-s` allein
  # haette diesen Lauf durchgewinkt.
  [ -s shellcheck.json ]
  jq -e '.comments == []' shellcheck.json
}

@test "Verzeichnis mit .sh-Endung: ebenfalls fatal" {
  mkdir dir.sh
  printf 'dir.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rc=2"* ]]
}

# xargs meldet fuer jeden Kindstatus 1..125 pauschal 123 (GNU) bzw. 1 (BSD).
# Ein fataler Aufruf neben einem mit Funden darf darin nicht untergehen: es
# zaehlt der hoechste ECHTE shellcheck-Status.
@test "fataler Aufruf neben Funden: der hoechste Status gewinnt" {
  ln -s gibtsnicht.sh dangling.sh
  printf 'finding.sh\ndangling.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rc=2"* ]]
}

@test "Pfade mit Leerzeichen bleiben ein Argument" {
  printf '#!/bin/sh\necho "ok"\n' > 'mit leer.sh'
  printf 'mit leer.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "SEVERITY wird durchgereicht" {
  printf 'finding.sh\n' > files.txt
  SEVERITY=error run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.comments == []' shellcheck.json
}

@test "FOLLOW=true reicht -x durch" {
  printf 'echo lib\n' > lib.sh
  printf '#!/bin/sh\n. ./lib.sh\n' > main.sh
  printf 'main.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # Ohne -x: SC1091 "Not following".
  jq -e '[.comments[].code] | index(1091) != null' shellcheck.json
  FOLLOW=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '[.comments[].code] | index(1091) == null' shellcheck.json
}

# Ein shellcheck, das mit 0 endet, aber nichts schreibt (kaputter Build,
# falscher Wrapper im PATH), hat nichts geprueft. Stub statt echtem Binary.
@test "rc 0 ohne Bericht ist ein Fehler, kein Nullbefund" {
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/shellcheck"
  chmod +x "$WORK/bin/shellcheck"
  printf 'clean.sh\n' > files.txt
  PATH="$WORK/bin:$PATH" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"without producing a report"* ]]
}

# Aufeinanderfolgende Laeufe im selben Workspace (self-hosted Pool): ein altes
# shellcheck.rc mit 0 darf einen neuen fatalen Lauf nicht verdecken — und ein
# alter fataler Status keinen neuen sauberen Lauf rot faerben.
@test "shellcheck.rc wird pro Lauf neu angelegt" {
  ln -s gibtsnicht.sh dangling.sh
  printf 'dangling.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  printf 'clean.sh\n' > files.txt
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
