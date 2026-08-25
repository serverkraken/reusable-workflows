#!/usr/bin/env bats

# Der Package-Probe-Schritt aus cleanup-images.yml, gegen einen gestubbten `gh`.
#
# Getestet wird der AUSGELIEFERTE run-Rumpf: er wird aus der YAML gezogen und
# ausgefuehrt. Eine Kopie im Test wuerde nur beweisen, dass die Kopie stimmt —
# und genau diese Sorte Test hat in diesem Audit mehrfach das Fehlverhalten
# festgeschrieben statt es zu fangen.
#
# Der Fund (D-12): die Probe unterschied "die API sagt nein" nicht von "die API
# hat nicht geantwortet". `2>&1` verwarf den Grund, und jeder Fehler las sich
# als "nicht publiziert — nichts aufzuraeumen". Gegen den Stand davor gemessen,
# mit demselben Harness:
#
#   404 Paket fehlt      rc=0  exists=false      (richtig)
#   401 Token ungueltig  rc=0  exists=false      <- falsch, und gruen
#   500 Serverfehler     rc=0  exists=false      <- falsch, und gruen
#
# Ein woechentlicher Cron mit abgelaufenem Token meldete damit dauerhaft Erfolg
# und raeumte nichts auf — die eine Fehlerart, die ein Retention-Job nicht
# haben darf.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin"

  # run-Rumpf des Schritts `id: stale` aus der YAML ziehen. Bewusst ohne
  # YAML-Bibliothek und ohne yq — beides ist in CI nicht vorhanden; die
  # Blockskalar-Regel (einruecken bis zur ersten flacheren Zeile) reicht.
  python3 - "$REPO_ROOT/.github/workflows/cleanup-images.yml" > "$WORK/body.sh" <<'PY'
import sys

lines = open(sys.argv[1]).read().splitlines()
start = None
for i, line in enumerate(lines):
    if line.strip() == "id: stale":
        start = i
        break
if start is None:
    sys.exit("step with `id: stale` not found")

for i in range(start, len(lines)):
    if lines[i].strip() in ("run: |", "run: |-"):
        indent = len(lines[i]) - len(lines[i].lstrip()) + 2
        body = []
        for raw in lines[i + 1:]:
            if raw.strip() and len(raw) - len(raw.lstrip()) < indent:
                break
            body.append(raw[indent:] if len(raw) >= indent else "")
        print("\n".join(body))
        sys.exit(0)
sys.exit("no run block under `id: stale`")
PY
  [ -s "$WORK/body.sh" ]
}

teardown() {
  rm -rf "$WORK"
}

# $1 = Modus für den gh-Stub
stub_gh() {
  cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
# Gematcht wird die GANZE Argumentliste, nicht \$2: bei
# `gh api --paginate <pfad>` steht dort das Flag, nicht der Pfad — daran ist
# eine erste Fassung dieses Stubs vorbeigelaufen.
#
# Die Owner-Abfrage (/orgs/<owner>) muss von der Paket-Abfrage
# (/orgs/<owner>/packages/...) getrennt bleiben, sonst misst der Test den
# falschen Aufruf.
ARGS="\$*"
case "$1" in
  absent)
    [[ "\$ARGS" != *"/packages/"* ]] && exit 0
    echo 'gh: Package not found. (HTTP 404)' >&2; exit 1 ;;
  present)
    [[ "\$ARGS" == *"/versions"* ]] && { echo '[]'; exit 0; }
    exit 0 ;;
  unauthorized)
    echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1 ;;
  server_error)
    [[ "\$ARGS" != *"/packages/"* ]] && exit 0
    echo 'gh: Internal Server Error (HTTP 500)' >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$WORK/bin/gh"
}

run_body() {
  PATH="$WORK/bin:$PATH" \
  PKG=demo DAYS=14 KEEP=10 OWNER=serverkraken GH_TOKEN=x \
  GITHUB_OUTPUT="$WORK/out" \
    bash "$WORK/body.sh"
}

@test "404 auf das Paket bleibt 'nicht publiziert' — der Cron darf deswegen nicht rot werden" {
  stub_gh absent
  : > "$WORK/out"
  run run_body
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/out")" == *"exists=false"* ]]
}

@test "401 meldet NICHT 'nichts aufzuraeumen', sondern faellt durch" {
  stub_gh unauthorized
  : > "$WORK/out"
  run run_body
  [ "$status" -eq 1 ]
  # Kein exists=false: ein abgelaufener Token darf nicht wie ein leeres
  # Registry aussehen.
  [[ "$(cat "$WORK/out")" != *"exists=false"* ]]
  # Der Grund muss im Log stehen — rc=1 allein liesse offen, woran es lag.
  [[ "$output" == *"401"* ]]
}

@test "500 faellt ebenfalls durch" {
  stub_gh server_error
  : > "$WORK/out"
  run run_body
  [ "$status" -eq 1 ]
  [[ "$(cat "$WORK/out")" != *"exists=false"* ]]
  [[ "$output" == *"500"* ]]
}

@test "existierendes Paket wird weiterhin als vorhanden erkannt" {
  # Gegenprobe zu den beiden Fehlerfaellen: waere der Guard zu scharf, koennte
  # er alles abweisen und die Tests oben blieben trotzdem gruen.
  stub_gh present
  : > "$WORK/out"
  run run_body
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/out")" == *"exists=true"* ]]
}
