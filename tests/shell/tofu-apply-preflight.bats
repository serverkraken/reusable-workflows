#!/usr/bin/env bats

# scripts/tofu-apply-preflight.sh entscheidet, ob ein gespeicherter Plan auf
# diesen Apply-Lauf passt. Hier haengt dran, ob ein fremder oder veralteter
# Plan angewandt wird — deshalb bekommt jede der vier Pruefungen einen eigenen
# Fall, und der Happy Path einen, der beweist, dass nicht einfach alles
# durchfaellt.
#
# Das letzte Argument (now_epoch) macht die Altersgrenze ueberhaupt pruefbar:
# ein frisch erzeugter Plan ist null Minuten alt, eine Workflow-Fixture kann
# ihn nicht altern lassen.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tofu-apply-preflight.sh"
  cd "$BATS_TEST_TMPDIR" || exit 1
  # 2026-08-28T10:00:00Z
  CREATED='2026-08-28T10:00:00Z'
  NOW_SAME=1787911200      # exakt derselbe Zeitpunkt (2026-08-28T10:00:00Z)
  cat > meta.json <<EOF
{
  "working_directory": "tofu",
  "concurrency_key": "prod",
  "catalog_ref": "v4",
  "tofu_version": "1.12.6",
  "adopter_sha": "deadbeef",
  "created_at": "${CREATED}",
  "run_id": "12345"
}
EOF
}

@test "passender Plan wird akzeptiert und meldet Alter und Version" {
  run bash "$SCRIPT" meta.json tofu prod v4 120 "$NOW_SAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"age_minutes=0"* ]]
  [[ "$output" == *"plan_tofu_version=1.12.6"* ]]
}

@test "Plan fuer einen anderen Stack wird abgelehnt" {
  run bash "$SCRIPT" meta.json infra prod v4 120 "$NOW_SAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gehoert zu Stack 'tofu'"* ]]
}

@test "Plan fuer eine andere State-Identitaet wird abgelehnt" {
  run bash "$SCRIPT" meta.json tofu staging v4 120 "$NOW_SAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gehoert zu State 'prod'"* ]]
}

# Der Fall, der ohne diese Pruefung still danebengeht: der Adopter pinnt den
# beweglichen v4, und zwischen Plan und Apply ist v4 weitergerueckt.
@test "Plan aus einer anderen Katalogversion wird abgelehnt" {
  run bash "$SCRIPT" meta.json tofu prod v5 120 "$NOW_SAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Katalog-Ref 'v4'"* ]]
  [[ "$output" == *"neu planen"* ]]
}

@test "zu alter Plan wird abgelehnt" {
  # 121 Minuten spaeter, Grenze steht auf 120.
  run bash "$SCRIPT" meta.json tofu prod v4 120 "$((NOW_SAME + 121 * 60))"
  [ "$status" -eq 1 ]
  [[ "$output" == *"121 Minuten alt"* ]]
  [[ "$output" == *"erlaubt sind 120"* ]]
}

@test "Plan genau an der Altersgrenze wird noch akzeptiert" {
  run bash "$SCRIPT" meta.json tofu prod v4 120 "$((NOW_SAME + 120 * 60))"
  [ "$status" -eq 0 ]
  [[ "$output" == *"age_minutes=120"* ]]
}

# Auseinanderlaufende Uhren sind der harmlose Fall; ein manipulierter
# Zeitstempel der andere. Beide sollen nicht durchrutschen, indem die
# Subtraktion negativ wird und die Altersgrenze damit trivial haelt.
@test "Zeitstempel aus der Zukunft wird abgelehnt" {
  run bash "$SCRIPT" meta.json tofu prod v4 120 "$((NOW_SAME - 60 * 60))"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Zukunft"* ]]
}

@test "mehrere Abweichungen werden alle gemeldet, nicht nur die erste" {
  run bash "$SCRIPT" meta.json infra staging v5 120 "$NOW_SAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Stack 'tofu'"* ]]
  [[ "$output" == *"State 'prod'"* ]]
  [[ "$output" == *"Katalog-Ref 'v4'"* ]]
}

@test "fehlende meta.json bricht ab" {
  run bash "$SCRIPT" gibtsnicht.json tofu prod v4 120 "$NOW_SAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nicht gefunden"* ]]
}

# Ein leeres Feld ist gefaehrlicher als ein fehlendes: ohne diese Pruefung
# verglichen zwei leere Strings erfolgreich, und die Pruefung waere ein No-op.
@test "leeres Feld in meta.json bricht ab" {
  cat > leer.json <<'EOF'
{
  "working_directory": "",
  "concurrency_key": "prod",
  "catalog_ref": "v4",
  "tofu_version": "1.12.6",
  "created_at": "2026-08-28T10:00:00Z"
}
EOF
  run bash "$SCRIPT" leer.json "" prod v4 120 "$NOW_SAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"working_directory"* ]]
}
