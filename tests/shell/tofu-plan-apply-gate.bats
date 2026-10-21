#!/usr/bin/env bats

# scripts/tofu-plan-apply-gate.sh entscheidet, ob tofu-plan-apply unter diesem
# Ereignis ueberhaupt anwenden darf. Hier haengt dran, ob ein PR-Lauf oder ein
# gewoehnlicher Branch-Push Infrastruktur veraendert — deshalb bekommt jedes
# Ereignis einen eigenen Fall, in beiden Stellungen von require_tag.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tofu-plan-apply-gate.sh"
}

# --- Ereignisse, die nie anwenden duerfen --------------------------------

@test "pull_request wird immer abgelehnt" {
  run bash "$SCRIPT" pull_request branch true
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  run bash "$SCRIPT" pull_request branch false
  [ "$status" -eq 1 ]
}

@test "pull_request_target wird immer abgelehnt" {
  run bash "$SCRIPT" pull_request_target branch false
  [ "$status" -eq 1 ]
}

@test "workflow_run wird immer abgelehnt" {
  run bash "$SCRIPT" workflow_run tag false
  [ "$status" -eq 1 ]
}

@test "schedule wird immer abgelehnt" {
  run bash "$SCRIPT" schedule branch false
  [ "$status" -eq 1 ]
}

# --- require_tag=true: nur Tag, Release oder Dispatch ----------------------

@test "push auf einen Tag ist mit require_tag erlaubt" {
  run bash "$SCRIPT" push tag true
  [ "$status" -eq 0 ]
}

@test "push auf einen Branch wird mit require_tag abgelehnt" {
  run bash "$SCRIPT" push branch true
  [ "$status" -eq 1 ]
  [[ "$output" == *"require_tag"* ]]
}

@test "release ist mit require_tag erlaubt" {
  run bash "$SCRIPT" release tag true
  [ "$status" -eq 0 ]
}

@test "workflow_dispatch von einem Branch ist mit require_tag erlaubt" {
  # Der Dispatch ist die Handlung eines Menschen — dieselbe Freigabe wie bei
  # tofu-apply.
  run bash "$SCRIPT" workflow_dispatch branch true
  [ "$status" -eq 0 ]
}

# --- require_tag=false: Merge ist die Freigabe -----------------------------

@test "push auf einen Branch ist ohne require_tag erlaubt" {
  run bash "$SCRIPT" push branch false
  [ "$status" -eq 0 ]
}

# --- Eingaben ----------------------------------------------------------------

@test "ein unbekannter require_tag-Wert wird abgelehnt statt als false gelesen" {
  run bash "$SCRIPT" push tag yes
  [ "$status" -eq 1 ]
}

@test "fehlende Argumente werden abgelehnt" {
  run bash "$SCRIPT" push
  [ "$status" -ne 0 ]
}
