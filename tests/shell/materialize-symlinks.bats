#!/usr/bin/env bats
# Tests for tests/shell/lib/materialize-symlinks.sh
#
# Der Helfer baut Fixtures mit Symlinks zur Laufzeit (#458). Fehlt ein Link
# still, prueft der aufrufende Test die nackte Fixture und bleibt gruen —
# deshalb muss jeder Fehler hier laut sein.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/shell/lib/materialize-symlinks.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/src/scripts"
  printf 'echo hi\n' > "$WORK/src/scripts/real.sh"
}

teardown() {
  rm -rf "$WORK"
}

@test "legt gueltige und kaputte Links an und entfernt das Manifest" {
  printf '# Kommentar\n\nscripts/linked.sh real.sh\nsub/dangling.sh fehlt.sh\n' > "$WORK/src/symlinks.txt"
  run bash "$SCRIPT" "$WORK/src" "$WORK/out"
  [ "$status" -eq 0 ]
  [ -L "$WORK/out/scripts/linked.sh" ] && [ -e "$WORK/out/scripts/linked.sh" ]
  [ -L "$WORK/out/sub/dangling.sh" ] && [ ! -e "$WORK/out/sub/dangling.sh" ]
  [ ! -e "$WORK/out/symlinks.txt" ]
  [ -f "$WORK/out/scripts/real.sh" ]
}

# Gos bufio.Scanner liest die letzte Zeile auch ohne Newline; `read` allein
# nicht. Ohne Gleichstand saehen Go- und Bash-Tests verschiedene Fixtures.
@test "liest auch eine letzte Zeile ohne Newline" {
  printf 'scripts/a.sh real.sh\nscripts/b.sh real.sh' > "$WORK/src/symlinks.txt"
  run bash "$SCRIPT" "$WORK/src" "$WORK/out"
  [ "$status" -eq 0 ]
  [ -L "$WORK/out/scripts/a.sh" ]
  [ -L "$WORK/out/scripts/b.sh" ]
}

@test "scheitert ohne Manifest" {
  run bash "$SCRIPT" "$WORK/src" "$WORK/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlinks.txt fehlt"* ]]
}

@test "scheitert bei einem Manifest ohne Link" {
  printf '# nur Kommentar\n' > "$WORK/src/symlinks.txt"
  run bash "$SCRIPT" "$WORK/src" "$WORK/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"keinen Link"* ]]
}

@test "scheitert bei einer Zeile mit drei Feldern" {
  printf 'a.sh b.sh c.sh\n' > "$WORK/src/symlinks.txt"
  run bash "$SCRIPT" "$WORK/src" "$WORK/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ungueltige Zeile"* ]]
}
