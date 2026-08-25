#!/usr/bin/env bats
# Tests for scripts/catalog-current-version.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/catalog-current-version.sh"
  WORK="$(mktemp -d)"

  git init "$WORK" >/dev/null
  git -C "$WORK" config user.name "Test User"
  git -C "$WORK" config user.email "test@example.invalid"
  git -C "$WORK" commit --allow-empty -m "initial" >/dev/null
}

teardown() {
  rm -rf "$WORK"
}

@test "uses the latest reachable patch tag, not floating major or minor tags" {
  git -C "$WORK" tag v4
  git -C "$WORK" tag v4.9
  git -C "$WORK" tag v4.9.0

  CATALOG_ROOT="$WORK" run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v4"* ]]
  [[ "$output" == *"current_minor=v4.9.0"* ]]
}

@test "falls back to v0 when only floating tags exist" {
  git -C "$WORK" tag v4
  git -C "$WORK" tag v4.9

  CATALOG_ROOT="$WORK" run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v0"* ]]
  [[ "$output" == *"current_minor=v0.0.0"* ]]
}

@test "ignores a closer floating major tag and keeps the previous patch tag" {
  git -C "$WORK" tag v4.8.0
  git -C "$WORK" commit --allow-empty -m "move floating major" >/dev/null
  git -C "$WORK" tag v4

  CATALOG_ROOT="$WORK" run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v4"* ]]
  [[ "$output" == *"current_minor=v4.8.0"* ]]
}

# === Nicht-SemVer-Tags und git-Fehler (Audit I-10, I-11) ===
#
# `--match` ist ein GLOB, keine Regex. `v[0-9]*.[0-9]*.[0-9]*` trifft auch
# `v1.2.3-rc1`; der sed, der den Major herauszieht, ist dagegen verankert und
# traf dann NICHT - also blieb der ganze Tag als "Major" stehen. Gemessen gegen
# den Stand davor:
#
#   v1.2.3-rc1   ->  current_version=v1.2.3-rc1
#   v1.2.3.4     ->  current_version=v1.2.3.4
#   v1x.2y.3z    ->  current_version=v1x.2y.3z
#
# `current_version` ist der Wert, gegen den der Sweep die Pins der Adopter
# vergleicht und den er als neuen Pin vorschlaegt.

@test "ein Prerelease-Tag wird uebersprungen, nicht als Major ausgegeben" {
  git -C "$WORK" tag v1.2.2
  git -C "$WORK" commit --allow-empty -m "next" >/dev/null
  git -C "$WORK" tag v1.2.3-rc1

  # `git describe` selbst liefert hier das Prerelease - genau deshalb muss das
  # Skript nachvalidieren statt dem Muster zu vertrauen.
  [ "$(git -C "$WORK" describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0)" = "v1.2.3-rc1" ]

  run env CATALOG_ROOT="$WORK" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v1"* ]]
  [[ "$output" == *"current_minor=v1.2.2"* ]]
}

@test "vierstellige und alphanumerische Tags gelten nicht als Release" {
  git -C "$WORK" tag v1.2.3.4
  run env CATALOG_ROOT="$WORK" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v0"* ]]

  git -C "$WORK" tag -d v1.2.3.4 >/dev/null
  git -C "$WORK" tag v1x.2y.3z
  run env CATALOG_ROOT="$WORK" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v0"* ]]
}

@test "ein Verzeichnis ohne Repository ist ein Fehler, kein v0" {
  # Vorher nicht von "noch kein Release" zu unterscheiden: beides ergab
  # current_version=v0 mit rc=0. Der Sweep haette daraufhin jeden Adopter fuer
  # veraltet gehalten.
  run env CATALOG_ROOT="$WORK/kein-repo" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "ein echtes Release neben einem Prerelease bleibt massgeblich" {
  # Gegenprobe zur Ausschluss-Schleife: sie darf nicht so weit gehen, dass sie
  # gueltige Tags mit verwirft.
  git -C "$WORK" tag v2.0.0
  run env CATALOG_ROOT="$WORK" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=v2"* ]]
  [[ "$output" == *"current_minor=v2.0.0"* ]]
}
