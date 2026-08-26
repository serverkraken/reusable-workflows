#!/usr/bin/env bash
# check-repo-badges.sh — die eingecheckten Fakten-Badges gegen die Quelle pruefen.
#
# `docs/badges/go.svg` und `docs/badges/license.svg` sind erzeugte Dateien. Sie
# liegen im Repo, damit die README ohne externen Request rendert — aber genau
# deshalb koennen sie veralten: ein `go`-Bump in go.mod aendert das Badge nicht
# mit, und niemand merkt es. Ein Badge, das eine falsche Go-Version behauptet,
# ist schlechter als keines.
#
# Dieses Gate rendert neu und vergleicht. Es faellt durch, wenn der Stand
# abweicht, und sagt, mit welchem Befehl man ihn nachzieht.
#
# BEWUSST NICHT geprueft wird `docs/badges/<paket>.svg` aus version-badges.sh:
# das haengt am release-please-Manifest, und dessen Versionsbump kommt im
# Release-PR. Das Gate wuerde damit jeden Release-PR blockieren. Diese Badges
# zieht stattdessen der version-badges-Job in catalog-release.yml nach dem
# Release nach — derselbe Workflow, den auch die Adopter bekommen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash scripts/repo-badges.sh --repo-path . --badges-dir "$tmp" >/dev/null

fail=0
checked=0
for f in "$tmp"/*.svg; do
  [[ -e "$f" ]] || continue
  name="$(basename "$f")"
  checked=$((checked + 1))
  if [[ ! -f "docs/badges/$name" ]]; then
    echo "FEHLER: docs/badges/$name fehlt" >&2
    fail=1
    continue
  fi
  if ! cmp -s "$f" "docs/badges/$name"; then
    echo "FEHLER: docs/badges/$name ist nicht mehr aktuell:" >&2
    # grep, nicht rg: laeuft auch auf einem Runner ohne ripgrep.
    diff <(grep -o 'aria-label="[^"]*"' "docs/badges/$name" || true) \
         <(grep -o 'aria-label="[^"]*"' "$f" || true) >&2 || true
    fail=1
  fi
done

if (( checked == 0 )); then
  echo "FEHLER: repo-badges.sh hat nichts erzeugt — das Gate wuerde nichts pruefen" >&2
  exit 1
fi

if (( fail != 0 )); then
  echo >&2
  echo "Nachziehen mit:" >&2
  echo "  bash scripts/repo-badges.sh --repo-path . --badges-dir docs/badges" >&2
  exit 1
fi

echo "OK: $checked Fakten-Badges stimmen mit go.mod und LICENSE ueberein."
