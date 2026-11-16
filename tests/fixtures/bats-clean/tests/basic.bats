#!/usr/bin/env bats
# Fixture fuer test-bats (Happy-Path): drei Tests, einer davon uebersprungen.
# Die Zahlen (3 gesamt, 0 Fehler, 1 uebersprungen; mit recursive 5/0/1) werden
# in self-ci.yml (assert-test-bats-happy) gegen die Atom-Outputs geprueft.
# Aendert sich die Anzahl hier, muss die Assertion dort mitgezogen werden.

@test "LC_ALL kommt vom Atom-Input locale" {
  [ "$LC_ALL" = "C.UTF-8" ]
}

@test "env-Input wird exportiert" {
  [ "${BATS_FIXTURE_FLAG:-}" = "gesetzt" ]
}

@test "uebersprungener Test zaehlt als skipped" {
  skip "Fixture: belegt tests_skipped"
}
