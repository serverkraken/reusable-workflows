#!/usr/bin/env bash
# tests/shell/lib/materialize-symlinks.sh <fixture-dir> <ziel-dir>
#
# Kopiert eine Fixture nach <ziel-dir> und legt dort die Symlinks aus ihrer
# symlinks.txt an. Das Manifest selbst wird in der Kopie entfernt, damit sie
# genau so aussieht wie die Fixture mit eingecheckten Links.
#
# Warum: getrackte Symlinks lassen den Runner beim Entpacken jeder
# Composite-Action des Katalogs abbrechen (#458, Gate check-no-symlinks.sh).
# Tests, die Symlink-Semantik pruefen, bauen sie deshalb zur Laufzeit.
#
# Jeder Link wird nach dem Anlegen geprueft: ein Test, dessen Links still
# fehlen, prueft die Fixture ohne Symlinks und bliebe gruen.
set -euo pipefail

src="${1:?Aufruf: materialize-symlinks.sh <fixture-dir> <ziel-dir>}"
dest="${2:?Aufruf: materialize-symlinks.sh <fixture-dir> <ziel-dir>}"
manifest="$src/symlinks.txt"

if [[ ! -f "$manifest" ]]; then
  echo "materialize-symlinks: $manifest fehlt" >&2
  exit 1
fi

mkdir -p "$dest"
cp -R "$src/." "$dest/"
rm -f "$dest/symlinks.txt"

count=0
while read -r link target rest; do
  [[ -z "$link" || "$link" == \#* ]] && continue
  if [[ -z "$target" || -n "$rest" ]]; then
    echo "materialize-symlinks: ungueltige Zeile in $manifest: $link $target $rest" >&2
    exit 1
  fi
  mkdir -p "$dest/$(dirname "$link")"
  ln -s "$target" "$dest/$link"
  if [[ ! -L "$dest/$link" ]]; then
    echo "materialize-symlinks: $dest/$link wurde nicht als Symlink angelegt" >&2
    exit 1
  fi
  count=$((count + 1))
done < "$manifest"

if (( count == 0 )); then
  echo "materialize-symlinks: $manifest enthaelt keinen Link" >&2
  exit 1
fi
