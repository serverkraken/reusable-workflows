#!/usr/bin/env bash
# Prueft die getippte Bestaetigung eines zerstoerenden Vorgangs.
#
# Aufruf:
#   tofu-confirm.sh DESTROY <owner/repo> <concurrency_key> -- <eingabe>
#   tofu-confirm.sh UNLOCK  <owner/repo> <concurrency_key> <lock_id> -- <eingabe>
#
#   Exit 0 — die Eingabe stimmt woertlich
#   Exit 1 — sie stimmt nicht; die Fehlermeldung nennt den erwarteten Text
#
# WARUM ALS SKRIPT: `tofu-destroy` und `tofu-unlock` laufen ausschliesslich
# unter `workflow_dispatch`. Die Self-CI laeuft auf `pull_request`, das
# Nightly auf `schedule` — der Event-Riegel schlaegt dort ZUERST zu, und die
# Bestaetigungslogik wird nie erreicht. Ueber einen Workflow ist sie damit
# nicht pruefbar. Als Skript ist sie es, und zwar genau an der Stelle, an der
# ein Fehler am teuersten waere.
#
# WARUM `--` ALS TRENNER: die Eingabe kommt aus einem Workflow-Input und ist
# beliebiger Text. Ohne festen Trenner koennte eine Eingabe wie
# `DESTROY x y` als weiteres Argument gelesen werden und die Stelligkeit
# verschieben.
#
# WARUM DER VERGLEICH SO STRIKT IST: `working_directory` allein waere zu
# schwach — das hiesse in fast jedem Repo "tippe tofu". Repo UND
# State-Identitaet zusammen (beim Unlock zusaetzlich die Lock-ID) sind eine
# Huerde, die man nicht versehentlich nimmt.
set -euo pipefail

usage() {
  echo "::error::Aufruf: tofu-confirm.sh DESTROY <repo> <key> -- <eingabe>" >&2
  echo "::error::   oder: tofu-confirm.sh UNLOCK <repo> <key> <lock_id> -- <eingabe>" >&2
  exit 2
}

ACTION="${1:-}"
case "$ACTION" in
  DESTROY)
    [[ $# -eq 5 && "$4" == "--" ]] || usage
    REPO="$2"; KEY="$3"; ACTUAL="$5"
    EXPECTED="DESTROY ${REPO} ${KEY}"
    ;;
  UNLOCK)
    [[ $# -eq 6 && "$5" == "--" ]] || usage
    REPO="$2"; KEY="$3"; LOCK_ID="$4"; ACTUAL="$6"
    EXPECTED="UNLOCK ${REPO} ${KEY} ${LOCK_ID}"
    ;;
  *)
    usage
    ;;
esac

for part in "$REPO" "$KEY"; do
  if [[ -z "$part" ]]; then
    # Ohne diese Pruefung entstuende ein erwarteter Text mit einer Luecke
    # ("DESTROY repo "), und wer sie zufaellig trifft, kaeme durch.
    echo "::error::Repo und State-Identitaet duerfen nicht leer sein — die Bestaetigung waere sonst raetselhaft und leichter zu treffen" >&2
    exit 1
  fi
done

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "::error::confirm stimmt nicht. Erwartet wird woertlich:" >&2
  echo "::error::  ${EXPECTED}" >&2
  # Die Eingabe wird NICHT ausgegeben: sie kommt vom Aufrufer und koennte
  # versehentlich etwas Schuetzenswertes enthalten.
  exit 1
fi

echo "Bestaetigung akzeptiert: ${EXPECTED}"
