#!/usr/bin/env bats
# Fixture fuer test-bats (Fehlerpfad): ein gruener und ein roter Test.
# failure-paths-nightly.yml prueft, dass das Atom daran scheitert UND
# tests_total=2, tests_failed=1 meldet — also am Test-Gate, nicht frueher.

@test "gruener Test" {
  true
}

@test "gezielt roter Test" {
  false
}
