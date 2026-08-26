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
# Argumente protokollieren, damit Tests pruefen koennen, WAS angefordert wurde
# und nicht nur, was zurueckkam (Audit L-9).
printf '%s\n' "\$*" >> "\${CURL_ARGV_LOG:-/dev/null}"
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
  export CURL_ARGV_LOG="$WORK/curl-argv"
  : > "$CURL_ARGV_LOG"
  run env PATH="$WORK/bin:$PATH" DEST="$DEST" CURL_ARGV_LOG="$CURL_ARGV_LOG" \
    ${GOMPLATE_VERSION:+GOMPLATE_VERSION="$GOMPLATE_VERSION"} bash "$SCRIPT"
}

# Die Plattform hier unabhaengig herleiten, nicht aus dem Skript lesen: sonst
# pruefte der Test seine eigene Kopie der Abbildung und nicht die des Skripts.
expected_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
  esac
  printf '%s-%s' "$os" "$arch"
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

# ---------------------------------------------------------------------------
# Audit L-9: der curl-Stub hat die URL bisher vollstaendig ignoriert — er schrieb
# nur die Nutzlast ans -o-Ziel. Geprueft wurde damit ausschliesslich, was
# ZURUECKKAM, nie, WAS ANGEFORDERT wurde.
#
# Ein Tippfehler im Repo-Pfad, eine nicht interpolierte Version oder eine
# falsche Plattform waeren in keinem Test aufgefallen: der Stub haette brav
# dasselbe gueltige Asset abgelegt, die Pruefsumme haette gestimmt, und die
# Installation waere gruen gewesen — waehrend im echten Lauf ein 404 kaeme.

@test "die angeforderte URL nennt Repo, Version und Plattform" {
  local platform; platform="$(expected_platform)"
  # Die Version wird GESETZT, nicht aus dem Skript gekratzt: so prueft der Test
  # die Interpolation und nicht seine eigene Lesart der Skriptzeile. Es muss
  # eine Version mit gepinnter Pruefsumme sein, sonst bricht das Skript ab,
  # bevor es ueberhaupt eine URL bildet.
  local version="v3.11.7"

  stub_curl "egal — hier zaehlt nur die Anfrage"
  export GOMPLATE_VERSION="$version"
  run_install
  # Der Lauf scheitert an der Pruefsumme; das ist in Ordnung — die Anfrage ist
  # zu diesem Zeitpunkt laengst gestellt, und genau um sie geht es hier.

  local argv; argv="$(cat "$CURL_ARGV_LOG")"
  [[ "$argv" == *"https://github.com/hairyhenderson/gomplate/releases/download/${version}/gomplate_${platform}"* ]] \
    || { echo "angefordert wurde: $argv"; false; }
}

@test "der Download laeuft mit -f, damit eine Fehlerseite nicht zum Binary wird" {
  stub_curl "egal"
  run_install
  # Ohne -f liefert curl bei 404 die Fehlerseite MIT Exit 0. Die Pruefsumme
  # faengt das zwar auch, aber erst eine Stufe spaeter und mit einer Meldung,
  # die nach Manipulation klingt statt nach "Asset gibt es nicht".
  local argv; argv="$(cat "$CURL_ARGV_LOG")"
  [[ "$argv" == *"-fsSL"* ]] || { echo "argv: $argv"; false; }
}

# Sichert die Eigenschaft aus Audit I-18 an der ANFRAGE ab, nicht erst am
# Ergebnis: geladen wird in eine temporaere Datei NEBEN $DEST, nie nach $DEST.
@test "geladen wird neben das Ziel, nicht darauf" {
  stub_curl "egal"
  run_install

  local argv; argv="$(cat "$CURL_ARGV_LOG")"
  [[ "$argv" != *" -o $DEST"* ]] || { echo "direkt nach DEST geladen: $argv"; false; }
  # ... und zwar im selben Verzeichnis, sonst waere das spaetere mv kein
  # Rename im selben Dateisystem und damit nicht atomar.
  [[ "$argv" == *" -o $(dirname "$DEST")/.gomplate."* ]] || { echo "argv: $argv"; false; }
}
