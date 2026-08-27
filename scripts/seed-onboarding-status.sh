#!/usr/bin/env bash
# seed-onboarding-status.sh — populate docs/onboarding-status.md with one row
# per serverkraken/* repo. Existing rows are preserved; only new repos are appended.
#
# Usage: scripts/seed-onboarding-status.sh
# Requires: gh, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DOC="$REPO_ROOT/docs/onboarding-status.md"

if ! command -v gh >/dev/null; then
  echo "gh CLI required" >&2
  exit 1
fi

stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ ! -f "$DOC" ]]; then
  cat > "$DOC" <<EOF
# Onboarding Status

_Last updated by the onboarding workflow: ${stamp}_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status | Consumers |
|---|---|---|---|---|---|---|
EOF
fi

# --limit 1000 statt 200 (Audit H-22). `gh repo list` kappt still bei --limit;
# eine Org jenseits der Grenze verliert Repos aus dem Statusdokument, ohne dass
# irgendwo etwas davon steht. Gemessen: serverkraken hat derzeit 41 Repos, die
# alte Grenze griff also NICHT — sie war eine latente Kappung, kein aktiver
# Fehler.
#
# Die Zahl allein reicht aber nicht: jede feste Grenze ist irgendwann zu klein.
# Deshalb wird gemeldet, wenn genau so viele Repos zurueckkommen, wie erlaubt
# waren — dann ist die Liste vermutlich abgeschnitten.
REPO_LIMIT="${REPO_LIMIT:-1000}"
repos=$(gh repo list serverkraken --limit "$REPO_LIMIT" --json nameWithOwner -q '.[].nameWithOwner' | sort)
repo_count=$(printf '%s\n' "$repos" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "$repo_count" -ge "$REPO_LIMIT" ]]; then
  echo "::warning::gh repo list returned $repo_count repos, which is the limit ($REPO_LIMIT) — the list is probably truncated; raise REPO_LIMIT" >&2
fi

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  # Exakter Spaltenvergleich statt Regex (Audit H-23).
  #
  # Vorher wurde der Repo-Name per sed nur an `/` maskiert und dann als ERE
  # benutzt. Ein Punkt im Namen blieb damit ein Metazeichen, das JEDES Zeichen
  # trifft — die Org hat vier solche Repos (juke.gallery, juke.gallery-admin,
  # juke.gallery-rest, juke.gallery-user). Ein Fehltreffer braucht ein Repo,
  # das sich nur an dieser Stelle unterscheidet; das gibt es derzeit nicht, der
  # Fehler ist also latent. Dazu ist `\/` in einer ERE nicht definiert und
  # funktioniert nur, weil GNU grep es als literales `/` durchgehen laesst.
  #
  # Statt besser zu maskieren faellt die Regex ganz weg: die Tabelle hat feste
  # Spalten, also wird Spalte 2 exakt verglichen. Damit ist jeder Repo-Name
  # sicher, unabhaengig von seinen Zeichen.
  if awk -F'|' -v want=" $repo " '$2 == want { found = 1 } END { exit !found }' "$DOC"; then
    continue
  fi
  echo "| ${repo} | — | — | — | — | not onboarded | — |" >> "$DOC"
done <<< "$repos"

echo "Seeded $DOC. Review with git diff before committing."
