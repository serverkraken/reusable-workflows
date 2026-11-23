#!/usr/bin/env bash
# scripts/shellcheck-run.sh — Schritt "Run shellcheck (json1)" in lint-shell.yml
#
# Eingabe:  files.txt im Arbeitsverzeichnis (ein Pfad pro Zeile)
#           SEVERITY (error|warning|info|style), FOLLOW (true → -x)
# Ausgabe:  shellcheck.json (json1-Bericht), shellcheck.rc (echter Status pro
#           Aufruf), shellcheck.err (stderr); exit 1 bei fatalem Lauf.
# Tests:    tests/shell/shellcheck-run.bats
#
# DER VERTRAG von shellcheck, gemessen, nicht vermutet:
#
#   rc=0  keine Funde,          stderr leer,      stdout = Bericht
#   rc=1  Funde,                stderr leer,      stdout = Bericht
#   rc>=2 FATAL (Datei nicht lesbar, kaputte Option) — und stdout
#         traegt trotzdem einen gueltigen, LEEREN Bericht:
#
#     $ shellcheck -f json1 -S style gibtsnicht.sh
#     rc=2 · stdout {"comments":[]} · stderr "openBinaryFile: does not exist"
#
# Genau daran ist die alte Pruefung (`rc != 0 && ! -s shellcheck.json`)
# vorbeigelaufen: der Bericht ist nicht leer, die Bedingung greift nicht, der
# Konverter erzeugt gueltiges SARIF, der Count ist 0 und der Job wird gruen.
#
# WARUM DER WRAPPER: `rc` war nie shellchecks Code, sondern xargs'. xargs
# meldet fuer JEDEN Kindstatus zwischen 1 und 125 pauschal 123 (GNU; BSD 1)
# und macht "Funde" von "fatal" ununterscheidbar. Der `sh -c`-Wrapper schreibt
# den ECHTEN Status jedes Aufrufs in shellcheck.rc; ausgewertet wird der
# hoechste. Ohne ihn waere jede rc-basierte Pruefung hier eine auf xargs.
#
# Kein FILE_COUNT==0-Zweig: der Collect-Schritt bricht in dem Fall bereits ab,
# dieser Schritt laeuft dann gar nicht. Ein Ersatzbericht {"comments":[]} waere
# genau die stille Gruenfaerbung, die der Abbruch verhindert.
set -uo pipefail

: "${SEVERITY:?SEVERITY fehlt}"
: "${FOLLOW:=false}"

ARGS=(-f json1 -S "$SEVERITY")
[[ "$FOLLOW" == "true" ]] && ARGS+=(-x)
: > shellcheck.rc

set +e
# NUL-getrennt: die Liste ist zeilenbasiert und NUL-sicher erzeugt; ohne das
# zerlegt xargs Pfade mit Leerzeichen. `-0` statt GNU-`-d '\n'`, damit das
# Skript auch lokal (BSD-xargs) unter bats laeuft.
tr '\n' '\0' < files.txt |
  xargs -0 sh -c 'shellcheck "$@"; echo "$?" >> shellcheck.rc' shellcheck-batch "${ARGS[@]}" \
    > shellcheck.json 2> shellcheck.err
xargs_rc=$?
set -e

cat shellcheck.err >&2 || true
rc="$(sort -n shellcheck.rc | tail -1)"
if [[ -z "$rc" ]]; then
  echo "::error::shellcheck wurde gar nicht aufgerufen (xargs rc=${xargs_rc}) — es wurde nichts geprueft: $(tr -d '\n' < shellcheck.err)" >&2
  exit 1
fi
if [[ "$rc" -ge 2 ]]; then
  echo "::error::shellcheck brach mit rc=${rc} ab — der Bericht ist unvollstaendig, nicht leer: $(tr -d '\n' < shellcheck.err)" >&2
  exit 1
fi
if [[ ! -s shellcheck.json ]]; then
  echo "::error::shellcheck exited ${rc} without producing a report — it did not check anything: $(tr -d '\n' < shellcheck.err)" >&2
  exit 1
fi
