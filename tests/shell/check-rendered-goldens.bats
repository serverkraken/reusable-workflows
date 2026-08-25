#!/usr/bin/env bats
# Tests fuer tests/conventions/check-rendered-goldens.sh.
#
# Der Anlass ist L-3: `oci_registry: ghcr.io//charts` lag als Golden im Repo.
# Der Golden-Vergleich prueft Bytes gegen einen frueheren Lauf, actionlint
# prueft Syntax — ein gueltiger String mit leerem Pfadsegment faellt durch
# beide Netze.

setup() {
  REPO_ROOT_REAL="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT_REAL/tests/conventions/check-rendered-goldens.sh"
  FIXTURE_DIR="$(mktemp -d)"
  WF="$FIXTURE_DIR/fx/demo/expected/.github/workflows"
  mkdir -p "$WF"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

run_gate() {
  REPO_ROOT="$FIXTURE_DIR" run bash "$SCRIPT" fx
}

@test "ein sauberes Golden besteht" {
  cat > "$WF/release.yml" <<'EOF2'
jobs:
  build:
    with:
      image_name: serverkraken/app
      oci_registry: ghcr.io/serverkraken/app/charts
      dockerfile: images/api/Dockerfile
EOF2
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "keine ungueltigen" ]]
}

@test "leeres Pfadsegment in oci_registry faellt durch" {
  # Der Originalfund: entsteht aus leerem target_repo.
  cat > "$WF/release.yml" <<'EOF2'
jobs:
  helm:
    with:
      oci_registry: ghcr.io//charts
EOF2
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "leeres Pfadsegment" ]]
}

@test "unaufgeloester \$REPO-Platzhalter faellt durch" {
  cat > "$WF/release.yml" <<'EOF2'
jobs:
  build:
    with:
      image_name: $REPO-worker
EOF2
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unaufgeloester Platzhalter" ]]
}

@test "ein Wert, der auf einen Schraegstrich endet, faellt durch" {
  cat > "$WF/release.yml" <<'EOF2'
jobs:
  build:
    with:
      chart_path: charts/
EOF2
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Schraegstrich ohne Segment" ]]
}

@test "https:// in einem anderen Feld ist kein Treffer" {
  # `://` ist legitim; nur Registry-/Image-Schluessel werden geprueft, und dort
  # zaehlt ein Doppelslash NACH dem Schema.
  cat > "$WF/release.yml" <<'EOF2'
jobs:
  build:
    with:
      homepage: https://example.com/x
      image_name: serverkraken/app
EOF2
  run_gate
  [ "$status" -eq 0 ]
}

@test "Dateien ausserhalb von expected/ werden nicht geprueft" {
  # Die Templates selbst tragen absichtlich Platzhalter.
  mkdir -p "$FIXTURE_DIR/fx/demo/src"
  cat > "$FIXTURE_DIR/fx/demo/src/tmpl.yml" <<'EOF2'
      image_name: $REPO-api
EOF2
  cat > "$WF/release.yml" <<'EOF2'
jobs:
  build:
    with:
      image_name: serverkraken/app
EOF2
  run_gate
  [ "$status" -eq 0 ]
}
