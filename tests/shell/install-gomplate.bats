#!/usr/bin/env bats

# Tests fuer scripts/install-gomplate.sh.
#
# Der Fund (I-1): der Download lief ohne jede Pruefung —
# `curl -fsSL "$URL" -o "$DEST"` gefolgt von `chmod +x`. Das Skript laeuft
# unter anderem in onboard.yml, also in einem Job mit einem App-Token, das in
# Adopter-Repos schreiben darf. Ein ausgetauschtes Release-Asset haette dort
# beliebigen Code ausgefuehrt.
#
# Und (I-18): der Download ging DIREKT nach $DEST. Ein Abbruch mittendrin
# hinterliess dort ein halbes Binary.
#
# `curl` ist gestubbt: geprueft wird die Pruef- und Ersetzungslogik, nicht das
# Netz. Ein Test gegen das echte Release liefe sonst bei jedem CI-Lauf gegen
# GitHub und waere ausserdem nicht in der Lage, einen manipulierten Download
# herzustellen.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/install-gomplate.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin"
  DEST="$WORK/target/gomplate"
  mkdir -p "$WORK/target"
}

teardown() {
  rm -rf "$WORK"
}

# Schreibt einen curl-Stub, der $1 als "heruntergeladene" Datei ablegt.
stub_curl() {
  local payload="$1"
  cat > "$WORK/bin/curl" <<STUB
#!/usr/bin/env bash
out=""
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-o" ]]; then out="\$a"; fi
  prev="\$a"
done
printf '%s' $(printf '%q' "$payload") > "\$out"
STUB
  chmod +x "$WORK/bin/curl"
}

run_install() {
  run env PATH="$WORK/bin:$PATH" DEST="$DEST" bash "$SCRIPT"
}

@test "ein manipuliertes Asset wird abgewiesen" {
  stub_curl "ich bin nicht gomplate"
  run_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  # Beide Summen im Log: ohne sie ist die Meldung nicht nachvollziehbar.
  [[ "$output" == *"expected"* ]]
  [[ "$output" == *"actual"* ]]
}

@test "nach einem abgewiesenen Download liegt am Zielort NICHTS" {
  # Das ist der Kern von I-18: vorher ging der Download direkt nach $DEST,
  # ein halbes oder falsches Binary blieb also liegen und war ausfuehrbar.
  stub_curl "ich bin nicht gomplate"
  run_install
  [ "$status" -eq 1 ]
  [ ! -e "$DEST" ]
}

@test "auch temporaere Dateien bleiben nicht liegen" {
  stub_curl "ich bin nicht gomplate"
  run_install
  [ "$status" -eq 1 ]
  # Kein .gomplate.XXXXXX-Rest neben dem Ziel.
  run bash -c "ls -A '$(dirname "$DEST")'"
  [ -z "$output" ]
}

@test "eine Version ohne gepinnte Pruefsumme wird nicht installiert" {
  # Renovate hebt VERSION an, ohne die Tabelle zu pflegen. Ein rotes Setup ist
  # die richtige Antwort — nicht ein ungeprueft installiertes Binary.
  stub_curl "egal"
  run env PATH="$WORK/bin:$PATH" DEST="$DEST" GOMPLATE_VERSION=v9.9.9 bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pinned SHA-256"* ]]
  # Der Hinweis muss sagen, WO die Pruefsumme herkommt.
  [[ "$output" == *"checksums-v9.9.9_sha256.txt"* ]]
  [ ! -e "$DEST" ]
}

@test "ein passendes Asset wird installiert und ausfuehrbar gemacht" {
  # Gegenprobe: die Pruefung darf nicht alles abweisen. Der Stub liefert genau
  # den Inhalt, dessen SHA-256 in der Tabelle steht — hier ueber eine eigene
  # Version, damit der echte Hash nicht im Test dupliziert werden muss.
  local payload="#!/usr/bin/env bash"$'\n'"echo 'gomplate version 3.11.7'"
  stub_curl "$payload"
  local sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)
  else
    sum=$(printf '%s' "$payload" | shasum -a 256 | cut -d' ' -f1)
  fi

  # Eine Kopie des Skripts mit Tabellenzeilen fuer eine Testversion. Alle vier
  # Plattformen, damit der Test nicht davon abhaengt, worauf er laeuft.
  local script="$WORK/install.sh"
  cp "$SCRIPT" "$script"
  python3 - "$script" "$sum" <<'PY'
import sys
path, sum_ = sys.argv[1], sys.argv[2]
src = open(path).read()
rows = "".join(
    f'  ["v0.0.0 {os_}-{arch}"]="{sum_}"\n'
    for os_ in ("linux", "darwin") for arch in ("amd64", "arm64")
)
src = src.replace("declare -A GOMPLATE_SHA256=(\n", "declare -A GOMPLATE_SHA256=(\n" + rows, 1)
open(path, "w").write(src)
PY

  run env PATH="$WORK/bin:$PATH" DEST="$DEST" GOMPLATE_VERSION=v0.0.0 bash "$script"
  [ "$status" -eq 0 ]
  [ -x "$DEST" ]
}
