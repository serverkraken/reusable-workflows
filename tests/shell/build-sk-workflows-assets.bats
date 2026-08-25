#!/usr/bin/env bats

# Tests fuer scripts/build-sk-workflows-assets.sh.
#
# Der Fund (I-9): das Ausgabeverzeichnis wurde nie geleert, und die
# Pruefsummendatei entstand aus einem Glob DARUEBER statt aus dem, was der Lauf
# gebaut hat. Der Aufrufer laedt pauschal hoch:
#
#   gh release upload "$TAG_NAME" dist/sk-workflows/* --clobber
#
# Gegen den Stand davor gemessen, mit einer Datei `sk-workflows_v9.9.9_
# darwin_arm64.tar.gz`, die nur das Wort "stale" enthielt:
#
#   Verzeichnis danach:  ... + darwin_arm64.tar.gz   (blieb liegen)
#   Pruefsummen:         3 Zeilen, darunter das Fremdarchiv
#
# Es waere also als offizielles Release-Asset dieser Version veroeffentlicht
# worden, mit gueltiger Pruefsumme.
#
# Der ausgelieferte Aufrufer ist nicht betroffen - catalog-release.yml laeuft
# auf `ubuntu-latest`, also ephemer. Das ist eine Eigenschaft des Aufrufers,
# nicht des Skripts; lokal und auf self-hosted Runnern ueberlebt das
# Verzeichnis.
#
# `go` wird gestubbt: geprueft wird die Verzeichnishygiene, nicht der Compiler.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/build-sk-workflows-assets.sh"
  WORK="$(mktemp -d)"
  OUT="$WORK/dist"
  mkdir -p "$WORK/bin" "$OUT"

  cat > "$WORK/bin/go" <<'STUB'
#!/usr/bin/env bash
# Nur `go build -o <pfad> ...` wird gebraucht.
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    mkdir -p "$(dirname "$a")"
    printf 'fake binary\n' > "$a"
    chmod +x "$a"
    exit 0
  fi
  prev="$a"
done
exit 0
STUB
  chmod +x "$WORK/bin/go"
  export PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

run_build() {
  run bash "$SCRIPT" v9.9.9 "$OUT"
}

@test "baut beide Linux-Archive und eine Pruefsummendatei" {
  run_build
  [ "$status" -eq 0 ]
  [ -f "$OUT/sk-workflows_v9.9.9_linux_amd64.tar.gz" ]
  [ -f "$OUT/sk-workflows_v9.9.9_linux_arm64.tar.gz" ]
  [ -f "$OUT/sk-workflows_v9.9.9_checksums.txt" ]
}

@test "ein Archiv aus einem frueheren Lauf wird entfernt, nicht mitveroeffentlicht" {
  printf 'stale\n' > "$OUT/sk-workflows_v9.9.9_darwin_arm64.tar.gz"
  run_build
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/sk-workflows_v9.9.9_darwin_arm64.tar.gz" ]
}

@test "die Pruefsummen nennen genau das Gebaute, nicht den Verzeichnisinhalt" {
  printf 'stale\n' > "$OUT/sk-workflows_v9.9.9_darwin_arm64.tar.gz"
  run_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$OUT/sk-workflows_v9.9.9_checksums.txt")" -eq 2 ]
  ! grep -q "darwin" "$OUT/sk-workflows_v9.9.9_checksums.txt"
}

@test "eine fremde Datei im Verzeichnis wird gemeldet, weil der Upload sie mitnimmt" {
  # Entfernen waere anmassend - die Datei gehoert dem Skript nicht. Aber
  # stillschweigend mit hochladen zu lassen ist die schlechtere Antwort.
  printf 'x\n' > "$OUT/fremd.txt"
  run_build
  [ "$status" -eq 0 ]
  [[ "$output" == *"fremd.txt"* ]]
  [ -f "$OUT/fremd.txt" ]
}

@test "ohne Fremddateien gibt es keine Warnung" {
  # Gegenprobe: eine Warnung, die immer erscheint, liest niemand mehr.
  run_build
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not build"* ]]
}
