#!/usr/bin/env bash
# tests/shell/lib/gh-stub.sh
#
# gh CLI mock for apply-repo-defaults bats tests.
#
# Behavior:
#   - Logs each invocation as a single line to $GH_STUB_CALL_LOG:
#       <verb>\t<endpoint>\t<flags-csv>\t<input-payload>
#   - Resolves response from $GH_STUB_FIXTURE_DIR keyed by sanitized endpoint
#     (slashes -> __, leading slash dropped, no trailing).
#       /repos/owner/repo/branches/main/protection
#         -> "$GH_STUB_FIXTURE_DIR/repos__owner__repo__branches__main__protection.json"
#   - If the fixture file is named *.404.json, exit 1 + stderr error simulating
#     a missing-resource response.
#   - If the fixture is *.403.json, exit 1 + 403 stderr.
#   - Otherwise: print the fixture file content to stdout, exit 0.
#   - For 'gh api -X PUT/PATCH/POST/DELETE' (mutating verbs): also accept JSON
#     payload via -f or --input; record it in the call-log line.
set -euo pipefail

CALL_LOG="${GH_STUB_CALL_LOG:-/dev/null}"
FIX_DIR="${GH_STUB_FIXTURE_DIR:-/dev/null}"

# Parse: gh api [-X METHOD] [-f key=val|--input file|--jq expr] ENDPOINT
verb="GET"
endpoint=""
flags=()
input_payload=""
jq_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    api) shift ;;
    -X) verb="$2"; shift 2 ;;
    --method) verb="$2"; shift 2 ;;
    -f) flags+=("$2"); shift 2 ;;
    --input) input_payload="$(cat "$2")"; shift 2 ;;
    --jq) jq_filter="$2"; flags+=("--jq=$2"); shift 2 ;;
    -q)   jq_filter="$2"; flags+=("--jq=$2"); shift 2 ;;
    --paginate) paginate=1; flags+=("--paginate"); shift ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done

# Sanitize endpoint for filename
key="${endpoint#/}"
key="${key//\//__}"
verb_lc=$(echo "$verb" | tr '[:upper:]' '[:lower:]')
fixture=""
paginate="${paginate:-0}"
for try_key in "${verb_lc}.${key}" "${key}"; do
  for ext in json 404.json 403.json 500.json; do
    if [[ -f "$FIX_DIR/${try_key}.${ext}" ]]; then
      fixture="$FIX_DIR/${try_key}.${ext}"
      break 2
    fi
  done
done

# Log the call
flags_csv=$(IFS=,; echo "${flags[*]:-}")
printf "%s\t%s\t%s\t%s\n" "$verb" "$endpoint" "$flags_csv" "${input_payload//$'\n'/ }" >> "$CALL_LOG"

if [[ -z "$fixture" ]]; then
  echo "gh-stub: no fixture for $endpoint (looked in $FIX_DIR)" >&2
  exit 1
fi

# Real `gh api` prints the HTTP error body to STDOUT (and a short diagnostic to
# stderr) before exiting non-zero. Mirror that here so callers using the
# `$(gh api ... 2>/dev/null || echo fallback)` idiom are exercised against real
# behavior — the error body leaks into the capture unless the caller discards
# stdout on failure.
# `-q`/`--jq` WIRKLICH anwenden (Audit L-10).
#
# Der Stub hat den Ausdruck bisher nur ins Aufrufprotokoll geschrieben und die
# Fixture unveraendert ausgegeben. Damit lief der produktive jq-Ausdruck NIE:
# die Fixture fuer `/pulls` enthielt bereits die Zahl `1`, die der Filter erst
# haette errechnen sollen, und die Lock-Fixture bereits das entpackte
# `.content`. Ein Tippfehler in
#
#     select(.user.login == "serverkraken-release-bot[bot]")
#     select(.head.ref == "$BRANCH")
#
# waere in keinem Test aufgefallen — der Mock hat die Antwort vorweggenommen.
#
# `gh api -q` ist ein jq-Ausdruck ueber der Antwort; genau das passiert jetzt
# auch hier. Fehlerfaelle (404/403/500) bleiben ungefiltert: das echte gh
# schreibt dort den Fehlerkoerper nach stdout, ohne ihn durch den Filter zu
# schicken.
# Ohne --paginate liefert echtes `gh api` NUR DIE ERSTE SEITE (30 Eintraege
# per Vorgabe). Der Stub gab bisher immer die vollstaendige Fixture aus und
# konnte eine Kappung damit gar nicht nachstellen — ein Test gegen
# "vergessenes --paginate" waere in BEIDEN Fassungen gruen gewesen und damit
# wertlos (Audit H-20; dieselbe Klasse wie L-10, wo der Mock den jq-Ausdruck
# vorweggenommen hat).
#
# Greift nur bei JSON-ARRAYS: die contents-API antwortet mit einem Objekt, und
# das darf nicht angeschnitten werden.
GH_STUB_PAGE_SIZE="${GH_STUB_PAGE_SIZE:-30}"

emit() {
  local src="$1"
  if [[ "$paginate" -eq 0 ]] && jq -e 'type == "array"' < "$src" >/dev/null 2>&1; then
    local page
    page="$(mktemp)"
    jq -c ".[:${GH_STUB_PAGE_SIZE}]" < "$src" > "$page"
    src="$page"
  fi
  if [[ -n "$jq_filter" ]]; then
    jq -r "$jq_filter" < "$src"
  else
    cat "$src"
  fi
}

case "$fixture" in
  # Wortlaut wie beim echten gh - gemessen an gh 2.x:
  #   gh: Not Found (HTTP 404)
  #   gh: Bad credentials (HTTP 401)
  # Der Stub schrieb frueher `gh: HTTP 404`, also OHNE die Klammerform. Ein
  # Aufrufer, der auf "(HTTP 404)" prueft - so wie das echte Format aussieht -
  # lief damit ins Leere, und der Test war gruen aus dem falschen Grund.
  *.404.json) cat "$fixture"; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *.403.json) cat "$fixture"; echo "gh: Forbidden (HTTP 403)" >&2; exit 1 ;;
  *.500.json) cat "$fixture"; echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
  *) emit "$fixture"; exit 0 ;;
esac
