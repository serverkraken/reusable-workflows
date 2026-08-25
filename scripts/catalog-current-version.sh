#!/usr/bin/env bash
# Emit GitHub-output-compatible current catalog version fields.
#
# current_version is the floating major (for example v4).
# current_minor is the latest reachable patch tag (for example v4.9.0).

set -euo pipefail

if [[ -n "${CATALOG_ROOT:-}" ]]; then
  repo_root="$CATALOG_ROOT"
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# "Keine Release-Tags" und "git konnte nicht antworten" sind zwei verschiedene
# Dinge, und frueher fielen beide auf v0.0.0 (Audit I-11). Gemessen lieferten
# ein Verzeichnis ohne Repository und ein unlesbares Verzeichnis jeweils
# `current_version=v0` mit rc=0 - ununterscheidbar vom Katalog vor seinem
# ersten Release. Der Sweep leitet daraus ab, auf welchem Major die Adopter
# stehen sollten; mit v0 gilt jedes Repo als veraltet.
if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error::not a git repository: $repo_root" >&2
  exit 1
fi

# `--match` ist ein GLOB, keine Regex: `v[0-9]*.[0-9]*.[0-9]*` trifft auch
# `v1.2.3-rc1`, `v1.2.3.4` und `v1x.2y.3z` (Audit I-10). Der sed unten ist
# dagegen verankert - trifft er nicht, blieb der GANZE Tag als "Major" stehen,
# und `current_version` wurde zu `v1.2.3-rc1`. Das ist der Wert, gegen den der
# Sweep die Pins der Adopter vergleicht.
#
# Deshalb wird das Ergebnis nachvalidiert und ein nicht konformer Tag gezielt
# ausgeschlossen, statt das Muster zu verschaerfen: `describe` waehlt den
# NAECHSTGELEGENEN erreichbaren Tag, und diese Eigenschaft haengen bestehende
# Tests fest (ein naeherer Floating-Tag darf den vorherigen Patch-Tag nicht
# verdraengen). Ein Glob kann SemVer nicht ausdruecken, eine Schleife schon.
semver_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
excludes=()
tag="v0.0.0"

for _ in $(seq 1 32); do
  candidate=$(git -C "$repo_root" describe \
    --tags \
    --match 'v[0-9]*.[0-9]*.[0-9]*' \
    "${excludes[@]}" \
    --abbrev=0 2>/dev/null) || break

  [[ -z "$candidate" ]] && break
  if [[ "$candidate" =~ $semver_re ]]; then
    tag="$candidate"
    break
  fi
  # Nicht konform: diesen Tag ausschliessen und den naechsten ansehen.
  excludes+=(--exclude "$candidate")
done

major=$(printf '%s\n' "$tag" | sed -E 's/^v([0-9]+)\.[0-9]+\.[0-9]+$/v\1/')

printf 'current_version=%s\n' "$major"
printf 'current_minor=%s\n' "$tag"
