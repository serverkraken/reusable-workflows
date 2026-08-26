#!/usr/bin/env bash
# repo-badges.sh — feststehende Repo-Angaben als Badge im Katalog-Design.
#
# Das sind die Badges, die vorher von shields.io kamen: Go-Version und Lizenz.
# Anders als ein Workflow-Status sind das keine Live-Zustaende, sondern Fakten,
# die im Repo stehen — sie lassen sich also lokal erzeugen. Gewonnen wird:
#
#   - kein externer Request beim Betrachten der README
#   - rendert auch in PRIVATEN Repos (GitHubs Bild-Proxy braucht keine
#     Fremdquelle) und verraet dort die Repo-Kennung nicht an Dritte
#   - deterministisch und versioniert: der Stand ist im Diff sichtbar
#   - dasselbe Design wie die Versions-Badges, inklusive Kraken-Glyphe
#
# BEWUSST NICHT erzeugt werden Workflow-Status-Badges. Die liefert GitHub live
# aus; statisch nachgebaut wuerden sie nach einem roten Build weiter gruen
# zeigen. Ein Badge, das luegen kann, ist schlechter als ein fremd gestaltetes.
#
# Die Versions-Badges kommen weiterhin aus version-badges.sh (eines pro
# release-please-Paket) — dieses Skript ergaenzt es, es ersetzt es nicht.
#
# Usage:
#   repo-badges.sh --repo-path <dir> --badges-dir <dir>
#
# stdout (GITHUB_OUTPUT-kompatibel):
#   badges=<n>            Anzahl geschriebener Badges
#   changed=<true|false>  ob sich eine Datei geaendert hat
set -euo pipefail

REPO_PATH="" BADGES_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-path) REPO_PATH="$2"; shift 2 ;;
    --badges-dir) BADGES_DIR="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$REPO_PATH" ]] || { echo "::error::--repo-path is required" >&2; exit 1; }
[[ -n "$BADGES_DIR" ]] || { echo "::error::--badges-dir is required" >&2; exit 1; }
[[ -d "$REPO_PATH" ]] || { echo "::error::repo path not found: $REPO_PATH" >&2; exit 1; }

# shellcheck source=lib/badge-svg.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/badge-svg.sh"

# ---- Fakten einsammeln ------------------------------------------------------

# go.mod: die `go`-Direktive, nicht der Toolchain-Eintrag. Beide beginnen mit
# "go", deshalb wird auf die Zeile am Zeilenanfang mit genau einem Feld
# dahinter geprueft.
go_version() {
  local f="$REPO_PATH/go.mod" v
  [[ -f "$f" ]] || return 1
  v="$(awk '$1 == "go" && NF == 2 { print $2; exit }' "$f")"
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# Die Lizenz wird aus der ERSTEN Zeile der LICENSE-Datei gelesen, nicht geraten.
# Erkannt werden die im Haus vorkommenden Formen; alles andere ergibt kein
# Badge, statt einen falschen Namen zu behaupten.
license_name() {
  local f first
  for f in "$REPO_PATH/LICENSE" "$REPO_PATH/LICENSE.md" "$REPO_PATH/LICENSE.txt"; do
    [[ -f "$f" ]] || continue
    first="$(head -n 1 "$f" | tr -d '\r')"
    case "$first" in
      "MIT License"*)                                printf 'MIT'; return 0 ;;
      *"Apache License"*)                            printf 'Apache-2.0'; return 0 ;;
      *"GNU GENERAL PUBLIC LICENSE"*|*"GNU General Public License"*)
                                                     printf 'GPL'; return 0 ;;
      "BSD "*)                                       printf 'BSD'; return 0 ;;
      *"Mozilla Public License"*)                    printf 'MPL-2.0'; return 0 ;;
    esac
    # Datei da, Form unbekannt: lieber nichts behaupten.
    return 1
  done
  return 1
}

# ---- schreiben --------------------------------------------------------------

mkdir -p "$BADGES_DIR"
count=0
changed=false

# write_badge <dateiname-ohne-endung> <label> <wert> <kind>
write_badge() {
  local name="$1" label="$2" value="$3" kind="$4"
  local target="$BADGES_DIR/$name.svg"
  local tmp; tmp="$(mktemp)"
  badge_svg "$label" "$value" "$kind" > "$tmp"
  # Nur bei echter Aenderung schreiben: sonst meldet jeder Lauf changed=true
  # und der Drift-Gate-Diff waere nie leer.
  if [[ ! -f "$target" ]] || ! cmp -s "$tmp" "$target"; then
    mv "$tmp" "$target"
    changed=true
  else
    rm -f "$tmp"
  fi
  count=$((count + 1))
}

if v="$(go_version)"; then
  write_badge go "go" "$v" other
fi
if l="$(license_name)"; then
  write_badge license "license" "$l" other
fi

echo "badges=$count"
echo "changed=$changed"
