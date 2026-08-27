#!/usr/bin/env bats

# scripts/tofu-plan-render.sh kuerzt die Plan-Ausgabe auf ein Zeichenlimit.
# GitHub nimmt maximal 65536 Zeichen pro Kommentar; ein zu langer Plan wuerde
# den Kommentar-Aufruf scheitern lassen, statt gekuerzt anzukommen.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tofu-plan-render.sh"
  cd "$BATS_TEST_TMPDIR" || exit 1
}

@test "kurzer Plan geht unveraendert durch" {
  printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n' > plan.txt
  run bash "$SCRIPT" plan.txt 1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 to add"* ]]
  [[ "$output" != *"gekuerzt"* ]]
}

@test "langer Plan wird gekuerzt und sagt es" {
  for i in $(seq 1 500); do echo "  # resource.line_${i} will be created"; done > plan.txt
  run bash "$SCRIPT" plan.txt 500
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 900 ]
  [[ "$output" == *"gekuerzt"* ]]
}

# Kopf UND Fuss muessen erhalten bleiben: oben steht, was geaendert wird,
# unten die Zusammenfassungszeile. Nur den Kopf zu behalten verwuerfe genau
# die Zeile, auf die im Review geschaut wird.
@test "Kuerzung behaelt Anfang und Ende" {
  { echo "ERSTE-ZEILE"; for i in $(seq 1 500); do echo "fuellung_${i}"; done; echo "Plan: 3 to add, 0 to change, 0 to destroy."; } > plan.txt
  run bash "$SCRIPT" plan.txt 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERSTE-ZEILE"* ]]
  [[ "$output" == *"3 to add"* ]]
}

@test "fehlende Datei bricht ab" {
  run bash "$SCRIPT" gibtsnicht.txt 500
  [ "$status" -ne 0 ]
}
