#!/usr/bin/env bash
# Prueft, ob ein gespeicherter Plan auf diesen Apply-Lauf passt.
#
# Aufruf:
#   tofu-apply-preflight.sh <meta.json> <dir> <key> <catalog_ref> <max_age_min> [now_epoch]
#
#   stdout — `age_minutes=<n>` und `plan_tofu_version=<v>`, gedacht fuer
#            `>> "$GITHUB_OUTPUT"` beim Aufrufer
#   Exit 0 — alle vier Pruefungen bestanden
#   Exit 1 — eine Pruefung schlug fehl, mit ::error:: auf stderr
#
# WARUM ALS SKRIPT UND NICHT INLINE: hier haengt dran, ob ein fremder Plan
# angewandt wird. Inline waere die Logik nur ueber einen echten Workflow-Lauf
# pruefbar, und die Altersgrenze gar nicht — ein frisch erzeugter Plan ist
# null Minuten alt, eine Nightly-Fixture kann ihn nicht altern lassen. Mit
# `now_epoch` als optionalem letztem Argument wird genau das testbar.
#
# DIE VIERTE PRUEFUNG IST NICHT REDUNDANT. `tofu apply <saved plan>` verweigert
# von selbst, wenn sich der STATE seit dem Plan bewegt hat ("Saved plan is
# stale"). Es sieht aber NICHT, dass jemand eine Ressource ausserhalb des
# States veraendert hat — etwa von Hand in der Cloud-Konsole. Dagegen hilft nur
# eine Frist.
set -euo pipefail

META="${1:?meta.json fehlt}"
WANT_DIR="${2?working_directory fehlt}"
WANT_KEY="${3?concurrency_key fehlt}"
WANT_REF="${4?catalog_ref fehlt}"
MAX_AGE="${5:?max_plan_age_minutes fehlt}"
NOW="${6:-$(date -u +%s)}"

if [[ ! -f "$META" ]]; then
  echo "::error::plan-meta.json nicht gefunden: ${META}" >&2
  exit 1
fi

field() {
  local value
  value=$(jq -r --arg k "$1" '.[$k] // empty' "$META")
  if [[ -z "$value" ]]; then
    echo "::error::plan-meta.json: Feld '$1' fehlt oder ist leer" >&2
    exit 1
  fi
  printf '%s' "$value"
}

got_dir=$(field working_directory)
got_key=$(field concurrency_key)
got_ref=$(field catalog_ref)
got_ver=$(field tofu_version)
created=$(field created_at)

fail=0

# 1. Stack.
if [[ "$got_dir" != "$WANT_DIR" ]]; then
  echo "::error::der Plan gehoert zu Stack '${got_dir}', angewandt werden soll '${WANT_DIR}'" >&2
  fail=1
fi

# 2. State-Identitaet.
if [[ "$got_key" != "$WANT_KEY" ]]; then
  echo "::error::der Plan gehoert zu State '${got_key}', angewandt werden soll '${WANT_KEY}'" >&2
  fail=1
fi

# 3. Katalog-Revision. Adopter pinnen den beweglichen `v4`; laeuft der Apply
#    Stunden nach dem Plan, kann `v4` weitergerueckt sein. Bewusst VERGLEICHEN
#    und abbrechen, statt den Katalog auf den alten Stand zurueckzuchecken:
#    einen Plan mit veralteter Katalogversion anzuwenden hiesse, einen
#    womoeglich bereits behobenen Fehler noch einmal auszufuehren.
if [[ "$got_ref" != "$WANT_REF" ]]; then
  echo "::error::der Plan entstand mit Katalog-Ref '${got_ref}', dieser Lauf nutzt '${WANT_REF}'" >&2
  echo "::error::neu planen, statt einen Plan fremder Katalogversion anzuwenden" >&2
  fail=1
fi

# 4. Alter.
if ! created_epoch=$(date -u -d "$created" +%s 2>/dev/null); then
  # BSD date (macOS) kennt kein -d. Python ist auf jedem Runner da.
  created_epoch=$(python3 -c '
import datetime, sys
stamp = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
print(int(stamp.replace(tzinfo=datetime.timezone.utc).timestamp()))
' "$created") || {
    echo "::error::created_at laesst sich nicht lesen: '${created}'" >&2
    exit 1
  }
fi

age=$(( (NOW - created_epoch) / 60 ))
if (( age < 0 )); then
  # Uhren laufen auseinander. Ein Plan aus der Zukunft ist kein Grund
  # weiterzumachen -- er koennte auch manipuliert sein.
  echo "::error::der Plan traegt einen Zeitstempel in der Zukunft (${created}) — Uhren pruefen" >&2
  fail=1
elif (( age > MAX_AGE )); then
  echo "::error::der Plan ist ${age} Minuten alt, erlaubt sind ${MAX_AGE} — neu planen" >&2
  fail=1
fi

if (( fail != 0 )); then
  exit 1
fi

echo "age_minutes=${age}"
echo "plan_tofu_version=${got_ver}"
