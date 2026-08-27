#!/usr/bin/env bats
# Tests for scripts/onboard-sweep-stale-pr-check.sh
#
# Decides whether the sweep should skip an adopter because its open bot
# onboard PR is already at the current catalog minor. Network is mocked via
# the shared gh-stub on PATH (tests/shell/lib/gh-stub.sh).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/onboard-sweep-stale-pr-check.sh"
  STUB="$REPO_ROOT/tests/shell/lib/gh-stub.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard-sweep-stale-pr"

  WORK=$(mktemp -d)
  export GH_STUB_CALL_LOG="$WORK/gh-calls.log"
  : > "$GH_STUB_CALL_LOG"

  mkdir -p "$WORK/bin"
  ln -sf "$STUB" "$WORK/bin/gh"

  # Bot identity required so the script's API filter selects.
  # Default to the real bot login. Override per-test if needed.
  export GH_TOKEN="dummy-token-for-tests"
}

teardown() {
  rm -rf "$WORK"
}

run_check() {
  local fixture_dir="$1"; shift
  export GH_STUB_FIXTURE_DIR="$FIX/$fixture_dir"
  PATH="$WORK/bin:$PATH" run "$SCRIPT" "$@"
}

@test "stale-pr-check: lock rendered_against matches current minor → skip" {
  run_check clean-current owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "skip" ]
}

@test "stale-pr-check: lock rendered_against is older minor → stale" {
  run_check stale-minor owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: lock missing rendered_against field → stale" {
  run_check missing-field owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: lock 404 → stale" {
  run_check lock-404 owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "stale-pr-check: no open bot PR → no-pr" {
  run_check no-open-pr owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "no-pr" ]
}

@test "stale-pr-check: missing args → exits 1 with usage" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "stale-pr-check: missing GH_TOKEN → exits 1 with error" {
  unset GH_TOKEN
  run "$SCRIPT" owner/repo v4.7.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN"* ]]
}

# === Sichtbarkeit bei API-Fehlern ===
#
# Das Skript ist ausdruecklich fail-open (siehe Kopf): ein Sweep, der Repos
# aktuell halten soll, darf bei einem Rate-Limit nicht stumm alles
# ueberspringen, und der Force-Push trifft nur bot-eigene Branches.
#
# Was gefehlt hat, ist nicht ein anderes Verhalten, sondern die Sichtbarkeit:
# ein API-Fehler sah im Sweep-Bericht genauso aus wie ein echtes Ergebnis. Das
# Urteil bleibt, die Vermutung wird benannt.

@test "stale-pr-check: ein 500 beim Lock meldet den Fehler und bleibt fail-open" {
  run_check lock-500 owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::lock fetch failed"* ]]
  [[ "$output" == *"HTTP 500"* ]]
  # Verhalten unveraendert: fail-open heisst weiterhin "stale".
  [[ "$output" == *"stale"* ]]
}

@test "stale-pr-check: ein 404 beim Lock meldet NICHTS" {
  # Gegenprobe: 404 ist der legitime Fall (Legacy-PR ohne Lock). Eine Warnung
  # dafuer waere Rauschen, und Rauschen liest niemand.
  run_check lock-404 owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
  [ "$output" = "stale" ]
}

# Audit H-20. `gh api` liefert ohne --paginate nur die erste Seite (30
# Eintraege). Hat ein Adopter mehr offene PRs, liegt der Bot-PR womoeglich
# dahinter — die Pruefung meldet "no-pr", und der Sweep legt einen ZWEITEN
# Onboarding-PR an, obwohl schon einer offen ist.
#
# Die Fixture stellt genau das her: 35 offene PRs, der Bot-PR an Position 33.
# Wirksam ist der Test nur, weil gh-stub.sh seit H-20 ohne --paginate die erste
# Seite abschneidet; vorher gab der Stub immer alles aus, und ein Test dagegen
# waere in beiden Fassungen gruen gewesen.
@test "stale-pr-check: Bot-PR hinter Seite 1 wird gefunden (Audit H-20)" {
  run_check bot-pr-on-page-2 owner/repo v4.7.0
  [ "$status" -eq 0 ]
  [ "$output" = "skip" ] || { echo "output: $output"; false; }
}
