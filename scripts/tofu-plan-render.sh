#!/usr/bin/env bash
# Kuerzt eine tofu-plan-Ausgabe auf ein Zeichenlimit und legt sie in einen
# Code-Block, aus dem ihr Inhalt nicht ausbrechen kann.
#
# Ausgabe ist der FERTIGE Block inklusive oeffnender und schliessender Zaeune —
# der Aufrufer setzt keine eigenen mehr.
#
# GitHub nimmt hoechstens 65536 Zeichen pro Kommentar. Ein ungekuerzter Plan
# laesst den Kommentar-Aufruf scheitern — der Plan kaeme dann gar nicht an.
#
# Kopf UND Fuss bleiben erhalten: oben steht, was sich aendert, unten die
# Zusammenfassungszeile ("Plan: 2 to add, ..."). Nur den Kopf zu behalten
# verwuerfe genau die Zeile, auf die im Review zuerst geschaut wird.
#
# WARUM DIE ZAUNLAENGE BERECHNET WIRD: der Planinhalt ist Adopter-Text. Eine
# feste ```-Zaun schliesst sich, sobald im Plan selbst eine Zeile aus drei
# Backticks steht — ab da rendert der Rest als echtes Markdown IM Kommentar
# des Bots. Ein Ausgabewert wie
#
#     ```
#     </details>
#     [Klicken Sie hier, um sich anzumelden](https://phish.example)
#
# stuende dann als anklickbarer Link unter dem Bot-Namen. Die Zaunlaenge ist
# deshalb ein Zeichen laenger als die laengste Backtick-Folge im Inhalt: dann
# gibt es im Inhalt keine Zeile, die den Block schliessen KANN. Innerhalb des
# Blocks ist `</details>` wieder nur Text.
set -euo pipefail

FILE="${1:?Plan-Datei fehlt}"
LIMIT="${2:-60000}"

if [[ ! -f "$FILE" ]]; then
  echo "::error::Plan-Datei nicht gefunden: $FILE" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# `tr -d '\0'` beim Befuellen, nicht erst beim Zaehlen: `grep` behandelt eine
# Eingabe mit NUL-Byte als BINAER, meldet nur "binary file matches", gibt KEINE
# Treffer aus und beendet mit 0. `longest` waere damit 0, der Zaun fiele auf
# drei Backticks zurueck — und ein Plantext mit NUL UND einer Backtick-Folge
# braeche wieder aus dem Block aus, also genau das, was die Zaunberechnung
# verhindern soll. Ein NUL ist in einem Markdown-Kommentar ohnehin nicht
# darstellbar; er wird entfernt, statt die Zaehlung zu verfaelschen.
SIZE=$(wc -c < "$FILE" | tr -d ' ')
if [[ "$SIZE" -le "$LIMIT" ]]; then
  tr -d '\0' < "$FILE" > "$TMP"
else
  HALF=$(( LIMIT / 2 ))
  {
    head -c "$HALF" "$FILE"
    printf '\n\n... [gekuerzt: %s von %s Zeichen entfernt — Volltext in der Step-Summary] ...\n\n' \
      "$(( SIZE - LIMIT ))" "$SIZE"
    tail -c "$HALF" "$FILE"
  } | tr -d '\0' > "$TMP"
fi

# Laengste Backtick-Folge im (bereits gekuerzten) Inhalt. `|| true`: grep
# meldet 1, wenn gar kein Backtick vorkommt — der Normalfall.
longest=$(LC_ALL=C grep -o '`\{1,\}' "$TMP" 2>/dev/null \
  | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' || true)
fence_len=$(( ${longest:-0} + 1 ))
(( fence_len < 3 )) && fence_len=3

fence=''
for (( i = 0; i < fence_len; i++ )); do
  fence+='`'
done

printf '%s\n' "$fence"
cat "$TMP"
# Die schliessende Zaun muss auf einer EIGENEN Zeile beginnen. Nach einem
# `tail -c` endet der Inhalt nicht zwingend mit einem Zeilenumbruch.
if [[ -s "$TMP" ]] && [[ "$(tail -c 1 "$TMP" | od -An -c | tr -d ' \n')" != '\n' ]]; then
  printf '\n'
fi
printf '%s\n' "$fence"
