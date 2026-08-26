#!/usr/bin/env bats
# Tests fuer scripts/repo-badges.sh — die feststehenden Repo-Angaben (Go-Version,
# Lizenz) als Badge im Katalog-Design, vorher shields.io.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/repo-badges.sh"
  TMPDIR="$(mktemp -d)"
  REPO="$TMPDIR/repo"
  OUT="$TMPDIR/badges"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMPDIR"; }

# grep, nicht rg: der CI-Runner hat kein ripgrep, und kein anderer Test in
# diesem Verzeichnis setzt es voraus. (Beim ersten Anlauf stand hier `rg`, und
# die self-CI fiel mit `rg: command not found` durch — waehrend es lokal grün
# war.)
label_of() { grep -o 'aria-label="[^"]*"' "$1" | sed 's/aria-label="//; s/"$//'; }

@test "go.mod and LICENSE become two badges" {
  printf 'module example.com/x\n\ngo 1.24\n' > "$REPO/go.mod"
  printf 'MIT License\n\nCopyright (c) 2026\n' > "$REPO/LICENSE"

  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"badges=2"* ]]

  [ "$(label_of "$OUT/go.svg")" = "go: 1.24" ]
  [ "$(label_of "$OUT/license.svg")" = "license: MIT" ]
}

@test "badges carry the kraken glyph and no external reference" {
  printf 'module example.com/x\n\ngo 1.24\n' > "$REPO/go.mod"
  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$status" -eq 0 ]

  # Dieselbe Zusicherung wie fuer die Versions-Badges: der Sinn der lokalen
  # Erzeugung ist, dass NICHTS nachgeladen wird. Ein <image href="https://…>
  # oder ein @font-face waere ein stiller Rueckfall auf einen Fremdanbieter.
  ! grep -qE 'https?://[^"]*\.(svg|png|css|woff)' "$OUT/go.svg"
  ! grep -q '@font-face' "$OUT/go.svg"
  # Die Tinte des Labels und die Glyphenfarbe belegen das gemeinsame Design.
  grep -q '#0E1A26' "$OUT/go.svg"
  grep -q '#E4ECF2' "$OUT/go.svg"
}

# Gesucht ist die `go`-DIREKTIVE, nicht irgendeine Zeile, die mit "go" anfaengt.
# `godebug` tut das auch (seit Go 1.23), und `godebug default=go1.24` hat sogar
# ebenfalls zwei Felder — nur `$1 == "go"` trennt die beiden sauber.
#
# Die Reihenfolge im Fixture ist Absicht: steht `godebug` VOR `go`, liefert ein
# naives `/^go/ {print $2; exit}` den Debug-Wert, und das Badge behauptet eine
# Version, die nicht die Sprachanforderung ist. Mit `go` zuerst waere der Test
# wertlos — er bestuende auch mit der kaputten Fassung. (Genau das ist mir beim
# ersten Anlauf passiert.)
#
# `toolchain go1.25.1` liegt zusaetzlich drin, weil es die naheliegendste
# Verwechslung ist — es faengt allerdings mit "t" an und war nie die Gefahr.
@test "godebug and toolchain do not win over the go directive" {
  printf 'module example.com/x\n\ngodebug default=go1.21\n\ngo 1.24\n\ntoolchain go1.25.1\n' > "$REPO/go.mod"
  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$status" -eq 0 ]
  [ "$(label_of "$OUT/go.svg")" = "go: 1.24" ] || { echo "gelesen: $(label_of "$OUT/go.svg")"; false; }
}

@test "a repo without go.mod simply gets no go badge" {
  printf 'MIT License\n' > "$REPO/LICENSE"
  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"badges=1"* ]]
  [ ! -e "$OUT/go.svg" ]
  [ -f "$OUT/license.svg" ]
}

# Lieber kein Badge als ein falscher Lizenzname: eine unbekannte Lizenzform
# darf nicht als "MIT" durchgehen, nur weil MIT der haeufigste Fall ist.
@test "an unrecognised LICENSE yields no badge instead of a guess" {
  printf 'Voellig eigene Lizenzbedingungen\n' > "$REPO/LICENSE"
  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"badges=0"* ]]
  [ ! -e "$OUT/license.svg" ]
}

@test "Apache and GPL are recognised, not just MIT" {
  printf '                                 Apache License\n                           Version 2.0, January 2004\n' > "$REPO/LICENSE"
  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$status" -eq 0 ]
  [ "$(label_of "$OUT/license.svg")" = "license: Apache-2.0" ]

  rm -f "$OUT/license.svg"
  printf 'GNU GENERAL PUBLIC LICENSE\n' > "$REPO/LICENSE"
  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$(label_of "$OUT/license.svg")" = "license: GPL" ]
}

# Ohne diese Eigenschaft meldete jeder Lauf changed=true, und ein Drift-Gate
# haette nie einen leeren Diff gesehen.
@test "a second run changes nothing and reports changed=false" {
  printf 'module example.com/x\n\ngo 1.24\n' > "$REPO/go.mod"
  printf 'MIT License\n' > "$REPO/LICENSE"

  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [[ "$output" == *"changed=true"* ]]
  local before; before="$(cat "$OUT/go.svg")"

  run bash "$SCRIPT" --repo-path "$REPO" --badges-dir "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=false"* ]] || { echo "$output"; false; }
  [ "$(cat "$OUT/go.svg")" = "$before" ]
}

@test "missing arguments fail loudly" {
  run bash "$SCRIPT" --badges-dir "$OUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--repo-path is required"* ]]

  run bash "$SCRIPT" --repo-path "$REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--badges-dir is required"* ]]

  run bash "$SCRIPT" --repo-path "$TMPDIR/gibtsnicht" --badges-dir "$OUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo path not found"* ]]
}
