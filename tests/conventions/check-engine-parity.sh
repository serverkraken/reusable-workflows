#!/usr/bin/env bash
# Gate: die beiden Detektor-Engines muessen auf jeder Fixture dasselbe Profil
# liefern.
#
# Warum es das gibt: dieses Repo traegt zwei Implementierungen derselben
# Erkennung - die Go-CLI (`sk-workflows detect`) und scripts/onboard-detect.sh.
# Welche laeuft, haengt am Schalter `use_go_cli`. Laufen sie auseinander,
# entscheidet dieser Schalter ueber das Ergebnis eines Onboardings, und im Diff
# sieht man davon nichts.
#
# Das ist keine Theorie. Vier Abweichungen wurden einzeln von Hand gefunden:
#
#   M-1    Flutter-Erkennung: `sdk:  flutter` (zwei Leerzeichen) verlor Go
#   #317   `# onboard:image=acme/svc UND MEHR` nahm nur Bash an
#   #318   `# onboard:release=true` mit CRLF nahm nur Bash an
#   hier   mehrdeutige Sprachsignale wies nur Go ab
#
# Jede einzeln, jede erst nachdem sie schon im Katalog stand. Dieser Vergleich
# haette alle vier beim Schreiben gemeldet.
#
# Die Ausnahme wird GEPRUEFT, nicht uebersprungen: wo die Bash-Engine bewusst
# absagt (Adopter-Manifest), muss sie das laut und mit Hinweis tun. Eine stumme
# Ausschlussliste wuerde genau die Faelle verstecken, um die es geht.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/onboard"
BIN="${SK_WORKFLOWS_BIN:-}"

if [[ -z "$BIN" ]]; then
  BIN="$(mktemp -d)/sk-workflows"
  (cd "$ROOT" && go build -o "$BIN" ./cmd/...)
fi

fail=0
checked=0
declined=0

for dir in "$FIXTURES"/*/; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"

  go_out=$("$BIN" detect --repo-path "$dir" --profile-json 2>/dev/null || true)
  bash_err=$(mktemp)
  bash_out=$(bash "$ROOT/scripts/onboard-detect.sh" --profile-json "$dir" 2>"$bash_err" || true)

  # Beabsichtigte Absage: die Bash-Engine unterstuetzt keine Adopter-Manifeste
  # und verweist auf die Go-CLI. Erlaubt ist sie nur, wenn sie auch wirklich so
  # ausfaellt - mit leerer Ausgabe und dem Hinweis auf stderr.
  if grep -q 'does not support manifests' "$bash_err"; then
    if [[ -n "$bash_out" ]]; then
      echo "FEHLER: $name — Bash meldet 'does not support manifests', gibt aber trotzdem ein Profil aus" >&2
      fail=1
    elif [[ -z "$go_out" ]]; then
      echo "FEHLER: $name — Bash lehnt wegen Manifest ab, aber die Go-CLI liefert auch nichts" >&2
      fail=1
    else
      declined=$((declined + 1))
    fi
    rm -f "$bash_err"
    continue
  fi
  rm -f "$bash_err"

  checked=$((checked + 1))
  if [[ "$(printf '%s' "$go_out" | jq -S . 2>/dev/null)" != "$(printf '%s' "$bash_out" | jq -S . 2>/dev/null)" ]]; then
    echo "FEHLER: $name — die Engines liefern verschiedene Profile:" >&2
    diff -u <(printf '%s' "$go_out" | jq -S . 2>/dev/null) \
            <(printf '%s' "$bash_out" | jq -S . 2>/dev/null) >&2 || true
    fail=1
    continue
  fi

  # Weisen BEIDE Engines die Erkennung ab (mehrdeutige Signale), gibt es kein
  # Profil zu rendern. Der Fall ist oben schon als "gleich" bestaetigt.
  if [[ -z "$go_out" ]]; then
    continue
  fi

  # --- und dasselbe fuer den Renderer -----------------------------------
  #
  # Erkennung UND Rendern liegen doppelt vor. Ein Vergleich nur der Profile
  # haette `oci_registry: ghcr.io//charts` nicht gesehen: die Profile waren
  # identisch, erst die Templates machten aus dem leeren target_repo eine
  # Registry, die es nicht gibt.
  #
  # Beide Ziele heissen gleich ("demo") und liegen bloss in verschiedenen
  # Elternverzeichnissen: aus dem Zielbasisnamen leiten beide Engines $REPO ab,
  # verschiedene Namen ergaeben also eine Abweichung, die keine ist.
  prof=$(mktemp); printf '%s' "$go_out" > "$prof"
  a=$(mktemp -d)/demo; b=$(mktemp -d)/demo
  mkdir -p "$a" "$b"
  go_render_err=$(mktemp); bash_render_err=$(mktemp)
  "$BIN" render --catalog "$ROOT" --target "$a" --profile "$prof" --pin v4 >/dev/null 2>"$go_render_err"; go_rc=$?
  bash "$ROOT/scripts/onboard-render.sh" "$ROOT" "$b" "$prof" v4 >/dev/null 2>"$bash_render_err"; bash_rc=$?

  # Die Rueckgabewerte pruefen, NICHT bloss die Ergebnisverzeichnisse.
  #
  # Die erste Fassung haengte `|| true` an beide Aufrufe und verglich dann die
  # Baeume. Damit haette ein Lauf, in dem BEIDE Renderer scheitern, zwei leere
  # Verzeichnisse verglichen und "gleich" gemeldet - ein Gate, das nichts
  # prueft und gruen ist.
  #
  # Nachgestellt mit einem gomplate, das mit 127 endet: Go hinterlaesst dabei
  # ein halbes .github/ und faellt durch, die Bash-Engine bricht schon an ihrer
  # `command -v gomplate`-Pruefung ab und schreibt nichts. Auch eine
  # Leerheitspruefung haette das also nur halb gesehen.
  if (( go_rc != 0 || bash_rc != 0 )); then
    echo "FEHLER: $name — Rendern fehlgeschlagen (go rc=$go_rc, bash rc=$bash_rc):" >&2
    head -c 300 "$go_render_err" >&2; echo >&2
    head -c 300 "$bash_render_err" >&2; echo >&2
    fail=1
    rm -f "$go_render_err" "$bash_render_err" "$prof"
    rm -rf "$(dirname "$a")" "$(dirname "$b")"
    continue
  fi
  rm -f "$go_render_err" "$bash_render_err"

  # `rendered_at` ist sekundengenau. Faellt der eine Lauf in die naechste
  # Sekunde, unterscheiden sich die Locks - das ist ein Wettlauf, keine
  # Abweichung der Engines. Also normalisieren, statt den Vergleich flaky zu
  # machen oder die Lock-Datei ganz auszunehmen.
  for lock in "$a/.github/onboard.lock.json" "$b/.github/onboard.lock.json"; do
    [[ -f "$lock" ]] || continue
    tmp=$(mktemp)
    jq -S '.rendered_at = "NORMALISIERT"' "$lock" > "$tmp" && mv "$tmp" "$lock"
  done

  if ! diff -r "$a" "$b" >/dev/null 2>&1; then
    echo "FEHLER: $name — die Engines rendern verschiedene Dateien:" >&2
    diff -r "$a" "$b" >&2 || true
    fail=1
  fi
  rm -f "$prof"
  rm -rf "$(dirname "$a")" "$(dirname "$b")"
done

if (( fail )); then
  exit 1
fi
echo "OK: $checked Fixtures, beide Engines liefern gleiches Profil UND gleiche gerenderte Dateien; $declined mit begruendeter Absage der Bash-Engine."
