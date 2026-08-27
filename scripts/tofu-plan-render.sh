#!/usr/bin/env bash
# Kuerzt eine tofu-plan-Ausgabe auf ein Zeichenlimit.
#
# GitHub nimmt hoechstens 65536 Zeichen pro Kommentar. Ein ungekuerzter Plan
# laesst den Kommentar-Aufruf scheitern — der Plan kaeme dann gar nicht an.
#
# Kopf UND Fuss bleiben erhalten: oben steht, was sich aendert, unten die
# Zusammenfassungszeile ("Plan: 2 to add, ..."). Nur den Kopf zu behalten
# verwuerfe genau die Zeile, auf die im Review zuerst geschaut wird.
set -euo pipefail

FILE="${1:?Plan-Datei fehlt}"
LIMIT="${2:-60000}"

if [[ ! -f "$FILE" ]]; then
  echo "::error::Plan-Datei nicht gefunden: $FILE" >&2
  exit 1
fi

SIZE=$(wc -c < "$FILE" | tr -d ' ')
if [[ "$SIZE" -le "$LIMIT" ]]; then
  cat "$FILE"
  exit 0
fi

HALF=$(( LIMIT / 2 ))
head -c "$HALF" "$FILE"
printf '\n\n... [gekuerzt: %s von %s Zeichen entfernt — Volltext in der Step-Summary] ...\n\n' \
  "$(( SIZE - LIMIT ))" "$SIZE"
tail -c "$HALF" "$FILE"
