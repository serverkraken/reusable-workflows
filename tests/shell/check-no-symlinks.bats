#!/usr/bin/env bats
# Tests for tests/conventions/check-no-symlinks.sh
#
# Das Gate gibt es seit #458: drei absichtlich kaputte Symlinks in
# tests/fixtures liessen den Runner beim Entpacken JEDER Composite-Action des
# Katalogs abbrechen ("Could not find file"). Getestet wird gegen ein frisches
# Wegwerf-Repo, damit kein Fall vom Zustand dieses Repos abhaengt.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-no-symlinks.sh"
  FIXTURE_DIR="$(mktemp -d)"
  cd "$FIXTURE_DIR"
  git init -q .
  printf 'echo hi\n' > real.sh
  git add real.sh
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "akzeptiert ein Repo ohne Symlinks" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "meldet einen getrackten kaputten Symlink mit Pfad" {
  mkdir -p fixtures/x
  ln -s gibtsnicht.sh fixtures/x/dangling.sh
  git add fixtures/x/dangling.sh
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fixtures/x/dangling.sh"* ]]
}

# Auch ein gueltiger Link ist verboten: ob der Runner ihn beim Entpacken
# aufloesen kann, haengt an Ziel und Reihenfolge im Archiv. Die Regel "kein
# Symlink" ist pruefbar, "kein kaputter Symlink" haengt am Checkout.
@test "meldet auch einen getrackten gueltigen Symlink" {
  ln -s real.sh linked.sh
  git add linked.sh
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"linked.sh"* ]]
}

# Massgeblich ist der Git-Index, denn der Runner laedt das Archiv des Commits.
# Ein ungetrackter Link im Arbeitsverzeichnis (z. B. aus einem Testlauf)
# landet nie dort.
@test "ignoriert einen ungetrackten Symlink" {
  ln -s gibtsnicht.sh untracked.sh
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "meldet alle Links, nicht nur den ersten" {
  ln -s a.sh one.sh
  ln -s b.sh two.sh
  git add one.sh two.sh
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"one.sh"* ]]
  [[ "$output" == *"two.sh"* ]]
}
