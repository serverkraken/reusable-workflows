#!/usr/bin/env bash
# Wandelt `KEY=VALUE`-Zeilen (aus dem `tf_vars`-Secret) in TF_VAR_*-Eintraege
# in $GITHUB_ENV und maskiert jeden Wert im Log.
#
# Der Inhalt kommt von der Aufruferseite und wird als feindlich behandelt:
#
#   - Jeder Schluessel muss ein gueltiger Shell-Variablenname sein. Ohne diese
#     Pruefung koennte eine konstruierte Zeile beliebige Env-Zuweisungen in
#     GITHUB_ENV schreiben.
#   - Das feste Praefix TF_VAR_ macht es unmoeglich, eine bestehende Variable
#     der Runner-Umgebung (PATH, HOME, GITHUB_TOKEN) zu ueberschreiben.
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

: "${GITHUB_ENV:?GITHUB_ENV muss gesetzt sein}"

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
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
  printf 'TF_VAR_%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
done
