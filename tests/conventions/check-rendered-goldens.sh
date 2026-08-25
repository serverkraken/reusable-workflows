#!/usr/bin/env bash
# CI gate: kein eingechecktes Golden darf einen strukturell ungueltigen Wert
# festschreiben.
#
# Warum es das braucht: der Golden-Vergleich prueft BYTES gegen einen frueheren
# Lauf, und `UPDATE_GOLDEN=1` kopiert den aktuellen Output ungeprueft zurueck.
# Ein Golden ist damit kein Orakel, sondern ein Protokoll — es sagt „so hat es
# gerendert", nicht „so ist es richtig". Der Self-CI-Job lintet die gerenderten
# Workflows zusaetzlich mit actionlint, aber actionlint sieht nur Syntax:
# `oci_registry: ghcr.io//charts` ist ein einwandfreier YAML-String und eine
# Registry, die es nicht gibt. Genau der Wert lag als Golden im Repo
# (service-with-helm), weil der Bash-Renderer `target_repo` leer liess.
#
# Geprueft werden die Werte, an denen ein leeres Segment aus einer nicht
# aufgeloesten Variablen entsteht — Registries, Image-Namen, Image-Referenzen —
# und Platzhalter, die die Substitution haette ersetzen muessen.
set -euo pipefail

if [[ -n "${REPO_ROOT:-}" ]]; then
  cd "$REPO_ROOT"
else
  cd "$(git rev-parse --show-toplevel)"
fi

ROOTS=("${@}")
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  ROOTS=(tests/fixtures)
fi

FAILED=0
CHECKED=0

# Schluessel, deren Wert ein Registry-/Image-Pfad ist.
PATH_KEYS='oci_registry|image_name|image_ref|dockerfile|context|chart_path'

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  CHECKED=$((CHECKED + 1))

  # 1) Nicht aufgeloeste Platzhalter. Die Substitution laeuft nach dem
  #    Templating; bleibt einer stehen, ist ein Renderpfad uebersprungen worden.
  while IFS=: read -r lineno text; do
    [[ -n "$lineno" ]] || continue
    echo "FAIL: $file:$lineno unaufgeloester Platzhalter:${text}"
    FAILED=1
  done < <(grep -nE '\$REPO' "$file" 2>/dev/null || true)

  # 2) Leeres Pfadsegment in einem Registry-/Image-Wert. `://` ist erlaubt,
  #    alles andere Doppelte nicht.
  while IFS=: read -r lineno text; do
    [[ -n "$lineno" ]] || continue
    echo "FAIL: $file:$lineno leeres Pfadsegment:${text}"
    FAILED=1
  done < <(grep -nE "^[[:space:]]*($PATH_KEYS):[[:space:]]*[^#]*[^:]//" "$file" 2>/dev/null || true)

  # 3) Wert endet oder beginnt mit einem Schraegstrich — ebenfalls ein Zeichen
  #    dafuer, dass ein Segment leer geblieben ist.
  while IFS=: read -r lineno text; do
    [[ -n "$lineno" ]] || continue
    echo "FAIL: $file:$lineno Schraegstrich ohne Segment:${text}"
    FAILED=1
  done < <(grep -nE "^[[:space:]]*($PATH_KEYS):[[:space:]]+(/|[^[:space:]#]*/[[:space:]]*$)" "$file" 2>/dev/null || true)

done < <(
  for r in "${ROOTS[@]}"; do
    [[ -d "$r" ]] || continue
    find "$r" -path '*/expected/*' \( -name '*.yml' -o -name '*.yaml' -o -name '*.json' \) -type f
  done | sort
)

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "Ein Golden schreibt einen ungueltigen Wert fest. Den Renderer korrigieren,"
  echo "dann das Golden neu erzeugen — nicht umgekehrt."
  exit 1
fi

echo "OK: $CHECKED gerenderte Golden-Dateien, keine ungueltigen Registry-/Image-Werte."
