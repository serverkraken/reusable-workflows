#!/usr/bin/env bash
# onboard-sweep-stale-pr-check.sh — decide whether an open bot onboard PR's
# content is already at the current catalog minor.
#
# Usage:   onboard-sweep-stale-pr-check.sh <owner/repo> <current_minor>
# Env:     GH_TOKEN — read access to the target repo's PRs + contents.
# Stdout:  one of {skip|stale|no-pr}
#
# Decision tree (fail-open):
#   no open bot PR on chore/onboard-reusable-workflows         → "no-pr"
#   PR-listing API error (rate-limit, 403, network)            → "no-pr"  (safe: sweep re-onboards)
#   open PR + lock.rendered_against == current_minor           → "skip"
#   open PR + lock missing / field absent / API error / mismatch → "stale"
#
# The sweep treats "skip" as `skipped:open-pr` and "no-pr" / "stale" as
# "fall through to drift-status / fresh-onboard".
#
# Fail-open bleibt so. Ein Sweep, dessen Aufgabe es ist, Repos aktuell zu
# halten, soll bei einem Rate-Limit nicht stumm alles ueberspringen; und der
# Force-Push trifft ausschliesslich bot-eigene Branches (push-bot-branch.sh
# prueft die Autorschaft, Audit E-8).
#
# Was gefehlt hat, ist die SICHTBARKEIT: das Skript entschied auf einer
# Vermutung und sagte es nicht. Ein API-Fehler sah im Sweep-Bericht genauso aus
# wie ein echtes "es gibt keinen PR". Jeder Fehler ausser 404 wird deshalb
# gemeldet - 404 ist der legitime Fall (Legacy-PR ohne Lock, oder gar kein
# solcher Branch).
set -euo pipefail

# Meldet einen API-Fehlschlag, der KEIN 404 ist. gh schreibt den JSON-Body nach
# stdout und eine Zeile wie `gh: Not Found (HTTP 404)` nach stderr; der Status
# ist also nur als Text erreichbar.
_note_api_failure() {
  local what="$1" errfile="$2"
  local body
  body=$(tr -d '\n' < "$errfile")
  [[ -z "$body" ]] && return 0
  # Tolerant gegenueber der Schreibweise, wie apply-repo-defaults.sh es auch
  # haelt: "Not Found" und "HTTP 404" mit oder ohne Klammern.
  if grep -qiE 'HTTP 404|Not Found' <<< "$body"; then
    return 0                        # legitim: nicht vorhanden
  fi
  echo "::warning::${what} failed for ${TARGET}: ${body} — deciding fail-open, the verdict below is a guess" >&2
}

TARGET="${1:-}"
CURRENT_MINOR="${2:-}"

if [[ -z "$TARGET" || -z "$CURRENT_MINOR" ]]; then
  echo "::error::usage: $0 <owner/repo> <current_minor>" >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "::error::GH_TOKEN env var required to call GitHub API" >&2
  exit 1
fi

BRANCH="chore/onboard-reusable-workflows"

# Step 1: does an open bot PR exist on the onboard branch?
PR_ERR=$(mktemp)
trap 'rm -f "$PR_ERR" "${LOCK_ERR:-}"' EXIT
# --paginate (Audit H-20). Ohne das liefert `gh api` NUR DIE ERSTE SEITE, per
# Vorgabe 30 Eintraege. Hat ein Adopter mehr offene PRs, liegt der Bot-PR
# womoeglich dahinter, `exists` wird 0, das Skript meldet "no-pr" — und der
# Sweep legt einen ZWEITEN Onboarding-PR an, obwohl schon einer offen ist.
#
# Statt `| length` je Seite eine Zeile pro Treffer und danach zaehlen:
# mit --paginate wendet gh den -q-Ausdruck PRO SEITE an, `length` haette also
# eine Zahl je Seite ausgegeben ("0\n1") und die Vergleiche unten zerbrochen.
#
# Das fail-open-Verhalten bleibt: ein Fehlschlag liefert eine leere Liste,
# also 0, und _note_api_failure meldet alles ausser 404.
pr_matches=$(gh api --paginate -X GET "/repos/$TARGET/pulls" -f state=open -f per_page=100 \
  -q ".[] | select(.user.login == \"serverkraken-release-bot[bot]\")
          | select(.head.ref == \"$BRANCH\")
          | .number" 2>"$PR_ERR" || true)
exists=$(printf '%s\n' "$pr_matches" | sed '/^$/d' | wc -l | tr -d ' ')
_note_api_failure "PR listing" "$PR_ERR"

if [[ "$exists" -eq 0 ]]; then
  echo "no-pr"
  exit 0
fi

# Step 2: fetch lock from the bot branch and compare rendered_against.
# gh api returns base64 content; decode and read the field.
LOCK_ERR=$(mktemp)
lock_b64=$(gh api \
  "/repos/$TARGET/contents/.github/onboard.lock.json?ref=$BRANCH" \
  -q '.content' 2>"$LOCK_ERR" || true)
# 404 heisst hier "der Branch traegt keinen Lock" - ein Legacy-PR, und der
# gehoert zu Recht neu gerendert. Alles andere ist ein Fehler und wird gemeldet.
_note_api_failure "lock fetch" "$LOCK_ERR"

lock_rendered=$(printf '%s' "$lock_b64" | base64 -d 2>/dev/null \
                | jq -r '.rendered_against // empty' 2>/dev/null || true)

if [[ "$lock_rendered" == "$CURRENT_MINOR" ]]; then
  echo "skip"
else
  echo "stale"
fi
