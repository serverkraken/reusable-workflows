#!/usr/bin/env bats
# Tests for the "Move floating major/minor tags" step in
# .github/workflows/semantic-release.yml.
#
# Wie bei semantic-release-outputs.bats liegt die Logik inline im Atom und
# nicht unter scripts/: das Atom checkt zur Laufzeit das ADOPTER-Repo aus, ein
# Katalog-Skript waere dort nicht erreichbar. Dieser Test zieht den run-Body
# deshalb mit awk aus dem YAML und fuehrt ihn gegen ein echtes bare-Repo aus.
#
# Der entscheidende Fall: am 2026-08-25 mergten drei PRs binnen 27 Sekunden.
# Der Lauf, der v4.18.1 schnitt, hatte einen drei Commits aelteren Stand
# ausgecheckt — und `git tag -f v4` ohne Ziel setzte v4 genau dorthin. Gruener
# Lauf, falscher Tag, und Adopter pinnen auf v4.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/semantic-release.yml"
  TMP="$(mktemp -d)"
  STEP="$TMP/float.sh"
  extract_step > "$STEP"
  chmod +x "$STEP"

  ORIGIN="$TMP/origin.git"
  WORK="$TMP/work"
  git init -q --bare "$ORIGIN"
  git init -q "$WORK"
  cd "$WORK"
  git config user.name ci
  git config user.email ci@example.com
  git remote add origin "$ORIGIN"
  for n in 1 2 3 4; do
    echo "$n" > file.txt
    git add file.txt
    git commit -qm "commit $n"
  done
  git branch -M main
  git push -q origin main
  C4=$(git rev-parse HEAD)
  C1=$(git rev-parse HEAD~3)
  export GITHUB_OUTPUT="$TMP/out"
  : > "$GITHUB_OUTPUT"
}

teardown() {
  cd /
  rm -rf "$TMP"
}

# Zieht den `run: |`-Body des Float-Schritts aus dem Workflow-YAML und
# entfernt die gemeinsame Einrueckung.
extract_step() {
  awk '
    /^      - name: Move floating major\/minor tags$/ { instep = 1 }
    instep && /^        run: \|$/ { inrun = 1; next }
    inrun {
      if ($0 !~ /^          / && $0 !~ /^[[:space:]]*$/) { exit }
      sub(/^          /, "")
      print
    }
  ' "$WORKFLOW"
}

@test "the step body could be extracted at all" {
  # Schlaegt die Extraktion fehl, sind alle folgenden Tests wertlos gruen.
  run wc -l < "$STEP"
  [ "$output" -gt 20 ]
  grep -q 'git rev-list -n1 "\$NEW_TAG"' "$STEP"
}

@test "floats onto the release commit, not the checked-out HEAD" {
  git tag v1.2.3 "$C4"
  git push -q origin v1.2.3
  git tag -d v1.2.3 >/dev/null
  git checkout -q "$C1"          # Lauf steht drei Commits zurueck

  NEW_TAG=v1.2.3 run bash "$STEP"
  [ "$status" -eq 0 ]

  run git -C "$ORIGIN" rev-list -n1 v1
  [ "$output" = "$C4" ]
  run git -C "$ORIGIN" rev-list -n1 v1.2
  [ "$output" = "$C4" ]
}

@test "emits the outputs the workflow declares" {
  git tag v3.4.5 "$C4"; git push -q origin v3.4.5
  NEW_TAG=v3.4.5 run bash "$STEP"
  [ "$status" -eq 0 ]
  grep -qx "major_tag=v3" "$GITHUB_OUTPUT"
  grep -qx "minor_tag=v3.4" "$GITHUB_OUTPUT"
}

@test "moves an existing floating tag forward" {
  git tag v1.0.0 "$(git rev-parse HEAD~2)"; git push -q origin v1.0.0
  NEW_TAG=v1.0.0 bash "$STEP" >/dev/null
  first=$(git -C "$ORIGIN" rev-list -n1 v1)

  git tag v1.1.0 "$C4"; git push -q origin v1.1.0
  NEW_TAG=v1.1.0 bash "$STEP" >/dev/null
  run git -C "$ORIGIN" rev-list -n1 v1
  [ "$output" = "$C4" ]
  [ "$output" != "$first" ]
  # Der Minor-Tag der aelteren Reihe bleibt stehen.
  run git -C "$ORIGIN" rev-list -n1 v1.0
  [ "$output" = "$first" ]
}

@test "refuses when the release tag does not exist anywhere" {
  # Sonst zeigte der Float-Tag auf irgendetwas — schlimmer als gar nicht.
  NEW_TAG=v9.9.9 run bash "$STEP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  run git -C "$ORIGIN" rev-parse --verify -q v9
  [ "$status" -ne 0 ]
}
