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
  fi
done

if (( fail )); then
  exit 1
fi
echo "OK: $checked Fixtures, beide Engines gleich; $declined mit begruendeter Absage der Bash-Engine."
