#!/usr/bin/env bash
# Wandelt `KEY=VALUE`-Zeilen (aus dem `tf_vars`-Secret) in eine sourcebare
# Datei mit TF_VAR_*-Zuweisungen und maskiert jeden Wert im Log.
#
# Aufruf:  printf '%s\n' "$TF_VARS" | tf-vars-env.sh <ausgabedatei>
#
#   stdin  — die KEY=VALUE-Zeilen
#   stdout — je Wert ein `::add-mask::`, damit der Runner ihn maskiert
#   <ausgabedatei> — je Zeile `TF_VAR_key='value'`, gedacht fuer
#                    `set -a; . <ausgabedatei>; set +a` im Plan-Schritt
#
# WARUM NICHT MEHR $GITHUB_ENV: was dort landet, gilt fuer den GANZEN Job —
# also auch fuer den Artefakt-Upload und beide Kommentar-Schritte, die mit den
# Werten nichts zu tun haben. Eine sourcebare Datei laesst den Aufrufer
# entscheiden, in welchem Schritt die Variablen existieren; gebraucht werden
# sie nur im `tofu plan`. Die Datei gehoert nach $RUNNER_TEMP (nicht in den
# Workspace) und wird am Jobende geloescht.
#
# Der Inhalt kommt von der Aufruferseite und wird als feindlich behandelt:
#
#   - Jeder Schluessel muss ein gueltiger Shell-Variablenname sein. Ohne diese
#     Pruefung koennte eine konstruierte Zeile beliebige Zuweisungen in die
#     Ausgabedatei schreiben — die wird gesourct, das waere Code-Ausfuehrung.
#   - Das feste Praefix TF_VAR_ macht es unmoeglich, eine bestehende Variable
#     der Runner-Umgebung (PATH, HOME, GITHUB_TOKEN) zu ueberschreiben.
#   - Der Wert wird einfach gequotet ausgegeben, eingebettete `'` werden
#     escaped. Ohne das fuehrte ein Wert wie `x'; rm -rf /; :'` beim Sourcen
#     genau das aus.
#   - Eine kaputte Zeile bricht ab, statt uebersprungen zu werden: eine
#     stillschweigend verworfene Variable faellt erst als unverstaendlicher
#     tofu-Fehler auf.
#
# Limitation: Werte koennen keinen Zeilenumbruch enthalten, da der Input
# zeilenweise gelesen wird. Ein mehrzeiliger Secret wird daher in separate
# KEY=VALUE-Kandidaten zerlegt und bricht auf der ersten Zeile ohne `=` ab.
# Genuinely mehrzeilige Werte gehoeren in eine Datei oder sollten base64-kodiert
# als einzelne Zeile uebergeben werden.
set -euo pipefail

OUT="${1:?Ausgabedatei fehlt: tf-vars-env.sh <datei>}"

# 077, BEVOR die Datei entsteht: sie traegt Klartext-Secrets, und auf dem
# self-hosted Pool ist der Runner-Benutzer nicht allein auf der Maschine.
umask 077
: > "$OUT"

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  # CR am Zeilenende abschneiden. Ohne das wird bei einem mit CRLF
  # geschriebenen Secret `wert\r` maskiert — GitHub maskiert nur EXAKTE
  # Treffer, und tofu gibt spaeter `wert` ohne CR aus. Der Wert stuende dann
  # im Klartext im Log und im PR-Kommentar. Die Maske haette es sogar
  # verschleiert: sie sah aus, als griffe sie.
  line="${line%$'\r'}"
  [[ -z "${line// /}" ]] && continue
  [[ "$line" == \#* ]] && continue

  if [[ "$line" != *"="* ]]; then
    echo "::error::tf_vars Zeile ${lineno}: keine KEY=VALUE-Zuweisung" >&2
    exit 1
  fi

  key="${line%%=*}"
  value="${line#*=}"

  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    # Der Schluessel wird bewusst NICHT mit ausgegeben: er stammt aus einem
    # Secret und koennte selbst schuetzenswert sein.
    echo "::error::tf_vars Zeile ${lineno}: ungueltiger Variablenname" >&2
    exit 1
  fi

  # Maskieren, BEVOR der Wert irgendwo sonst auftauchen kann.
  echo "::add-mask::${value}"
  escaped="${value//\'/\'\\\'\'}"
  printf "TF_VAR_%s='%s'\n" "$key" "$escaped" >> "$OUT"
done
