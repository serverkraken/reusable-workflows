#!/usr/bin/env bats
# Tests for scripts/onboarding-status-row.sh.
#
# Dieser Pfad laeuft in CI nie: die Statusdoku-Schritte haengen an
# `if: !inputs.dry_run`, und der einzige Integrationstest ist ein Dry-Run.
# Als Inline-Bash im Workflow war er damit vollstaendig ungeprueft.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/onboarding-status-row.sh"
  TMP="$(mktemp -d)"
  DOC="$TMP/onboarding-status.md"
  cat > "$DOC" <<'EOF2'
# Onboarding Status

_Last updated by the onboarding workflow: 2026-01-01T00:00:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status | Consumers |
|---|---|---|---|---|---|---|
| acme/existing | 2025-03-04 | v3 | — | — | complete | — |
EOF2
}

teardown() {
  rm -rf "$TMP"
}

result() {
  printf '%s' "$1" > "$TMP/r.json"
  printf '%s' "$TMP/r.json"
}

row_for() {
  grep -F "| $1 |" "$DOC"
}

@test "a successful run stamps today and appends a new row" {
  f=$(result '{"target":"acme/new","pr_a_status":"add-open","pr_b_status":"no-legacy","pr_a_url":"https://x/1","pr_b_url":"","job_status":"success"}')
  TODAY=2026-08-25 run "$SCRIPT" "$DOC" "$f" v4
  [ "$status" -eq 0 ]
  run row_for acme/new
  [[ "$output" == *"| 2026-08-25 |"* ]]
  [[ "$output" == *"add-open, no-legacy"* ]]
  [[ "$output" == *"[PR](https://x/1)"* ]]
}

@test "a failed run does NOT restamp the date of an existing row" {
  # Der Kern von E-13: bis hierher bekam auch die Fehlerzeile das heutige
  # Datum, und die Spalte behauptete ein Onboarding, das fehlgeschlagen ist.
  f=$(result '{"target":"acme/existing","pr_a_status":"add-open","pr_b_status":"no-legacy","pr_a_url":"","pr_b_url":"","job_status":"failure"}')
  TODAY=2026-08-25 run "$SCRIPT" "$DOC" "$f" v4
  [ "$status" -eq 0 ]
  run row_for acme/existing
  [[ "$output" == *"| 2025-03-04 |"* ]]
  [[ "$output" != *"2026-08-25"* ]]
  [[ "$output" == *"error (add-open, no-legacy)"* ]]
}

@test "a failed run on a brand-new target records no date at all" {
  f=$(result '{"target":"acme/brandnew","pr_a_status":"","pr_b_status":"","pr_a_url":"","pr_b_url":"","job_status":"failure"}')
  TODAY=2026-08-25 run "$SCRIPT" "$DOC" "$f" v4
  [ "$status" -eq 0 ]
  run row_for acme/brandnew
  [[ "$output" == *"| — |"* ]]
  [[ "$output" != *"2026-08-25"* ]]
  [[ "$output" == *"error"* ]]
}

@test "a successful re-run of an existing target moves its date forward" {
  f=$(result '{"target":"acme/existing","pr_a_status":"no-changes","pr_b_status":"no-legacy","pr_a_url":"","pr_b_url":"","job_status":"success"}')
  TODAY=2026-08-25 run "$SCRIPT" "$DOC" "$f" v4
  [ "$status" -eq 0 ]
  run row_for acme/existing
  [[ "$output" == *"| 2026-08-25 |"* ]]
  [[ "$output" == *"complete"* ]]
}

@test "an existing target is replaced, not duplicated" {
  f=$(result '{"target":"acme/existing","pr_a_status":"no-changes","pr_b_status":"no-legacy","pr_a_url":"","pr_b_url":"","job_status":"success"}')
  TODAY=2026-08-25 run "$SCRIPT" "$DOC" "$f" v4
  [ "$(grep -cF '| acme/existing |' "$DOC")" -eq 1 ]
}

@test "a result without a target exits 2 and leaves the doc untouched" {
  before=$(cat "$DOC")
  f=$(result '{"job_status":"failure"}')
  run "$SCRIPT" "$DOC" "$f" v4
  [ "$status" -eq 2 ]
  [ "$(cat "$DOC")" = "$before" ]
}

@test "gitops consumers are joined into the last column" {
  f=$(result '{"target":"acme/chart","pr_a_status":"no-changes","pr_b_status":"no-legacy","pr_a_url":"","pr_b_url":"","job_status":"success","gitops_consumers":[{"repo":"acme/cluster"},{"repo":"acme/edge"}]}')
  TODAY=2026-08-25 run "$SCRIPT" "$DOC" "$f" v4
  run row_for acme/chart
  [[ "$output" == *"acme/cluster, acme/edge"* ]]
}
