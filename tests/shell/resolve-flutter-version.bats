#!/usr/bin/env bats
# Tests for scripts/resolve-flutter-version.sh — the version-resolution logic
# of release-flutter-android.yml's "Resolve version + sync pubspec.yaml" step.
#
# Regression anchor: adopter strassenfuchs carries rolling major/minor tags
# (v0, v0.40) and archive/* tags next to exact version tags. The auto-derive
# path must only consider exact vX.Y.Z tags and must fall back instead of
# hard-failing when no usable tag exists (run 30762809021: "resolved version
# does not look like semver: 0-rc.1").

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/resolve-flutter-version.sh"
  REPO_DIR="$(mktemp -d)"
  cd "$REPO_DIR"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git commit --allow-empty -q -m "c1"
}

teardown() {
  cd /
  rm -rf "$REPO_DIR"
}

# --- explicit version input -------------------------------------------------

@test "explicit version with leading v is stripped" {
  run bash "$SCRIPT" "v1.2.3" "false" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3$"
  echo "$output" | grep -q "^tag=v1.2.3$"
}

@test "explicit version without leading v passes through" {
  run bash "$SCRIPT" "1.2.3" "false" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3$"
}

@test "explicit prerelease version is kept as-is" {
  run bash "$SCRIPT" "v0.41.0-rc.1" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.41.0-rc.1$"
  echo "$output" | grep -q "^tag=v0.41.0-rc.1$"
}

@test "explicit non-semver version fails" {
  run bash "$SCRIPT" "banana" "true" "7"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "does not look like semver"
}

@test "empty version without create_release fails" {
  run bash "$SCRIPT" "" "false" "7"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "version is required"
}

# --- auto-derive path (empty version + create_release=true) ------------------

@test "auto-derive picks latest exact version tag" {
  git tag v0.40.1
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.40.1-rc.7$"
  echo "$output" | grep -q "^tag=v0.40.1-rc.7$"
}

@test "auto-derive ignores rolling major/minor and archive tags (strassenfuchs repro)" {
  # v0.40.1 on an older commit; rolling + archive tags on a NEWER commit so
  # plain `git describe --tags --abbrev=0` would pick v0 → "0-rc.7".
  git tag v0.40.1
  git commit --allow-empty -q -m "c2"
  git tag v0
  git tag v0.40
  git tag archive/feature-maplibre-migration
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.40.1-rc.7$"
}

@test "auto-derive strips prerelease suffix from latest tag" {
  git tag v1.2.3-rc.9
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3-rc.7$"
}

@test "auto-derive accepts exact version tags without v prefix" {
  git tag 1.2.3
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=1.2.3-rc.7$"
}

@test "auto-derive falls back to 0.0.0 when no tags exist" {
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.0.0-rc.7$"
}

@test "auto-derive falls back to 0.0.0 when only non-semver tags exist" {
  git tag v0
  git tag archive/feature-foo
  run bash "$SCRIPT" "" "true" "7"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bare=0.0.0-rc.7$"
}

@test "auto-derive never hard-fails on weird tag zoo" {
  git tag v0
  git tag v0.40
  git tag some-random-tag
  run bash "$SCRIPT" "" "true" "42"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq "^bare=[0-9]+\.[0-9]+\.[0-9]+-rc\.42$"
}

# --- Verankerung der SemVer-Pruefung (Audit I-17, I-12) ---------------------
#
# `SEMVER_CORE` war nur am ANFANG verankert. Alles, was mit X.Y.Z beginnt,
# bestand damit. Gegen den Stand davor gemessen:
#
#   1.2.3.4                  -> tag=v1.2.3.4
#   1.2.3abc                 -> tag=v1.2.3abc
#   "1.2.3 && echo PWNED"    -> tag=v1.2.3 && echo PWNED
#   "1.2.3\nEXTRA=injected"  -> ZWEI Zeilen in GITHUB_OUTPUT
#
# Der letzte Fall ist der schwerwiegende: der Aufrufer schreibt die Ausgabe mit
# `echo "$OUT" >> "$GITHUB_OUTPUT"` weiter (release-flutter-android.yml:190).
# Ein Zeilenumbruch im `version`-Input schiebt damit beliebige Step-Outputs
# unter, und die werden weiter unten als `${{ steps.ver.outputs.tag }}` gelesen.

@test "eine vierstellige Version wird abgewiesen" {
  run bash "$SCRIPT" "1.2.3.4" "false" "7"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not look like semver"* ]]
}

@test "Ziffern mit angehaengtem Text werden abgewiesen" {
  run bash "$SCRIPT" "1.2.3abc" "false" "7"
  [ "$status" -eq 1 ]
}

@test "Shell-Metazeichen hinter der Version werden abgewiesen" {
  run bash "$SCRIPT" "1.2.3 && echo PWNED" "false" "7"
  [ "$status" -eq 1 ]
  [[ "$output" != *"PWNED"* ]] || [[ "$output" == *"does not look like semver"* ]]
}

@test "ein Zeilenumbruch kann keine zusaetzlichen Outputs unterschieben" {
  run bash "$SCRIPT" "$(printf '1.2.3\nEXTRA=injected')" "false" "7"
  [ "$status" -eq 1 ]
  [[ "$output" != *"EXTRA=injected"$'\n'* ]]
  # Entscheidend: keine Zeile der Ausgabe darf ein fremdes key=value sein.
  ! echo "$output" | grep -qE '^EXTRA='
}

@test "gueltige SemVer-Formen bleiben erlaubt" {
  # Gegenprobe: die Verankerung darf Prerelease und Build-Metadaten nicht
  # mitverbieten — der Auto-Pfad erzeugt selbst X.Y.Z-rc.<n>.
  for v in "1.2.3" "1.2.3-rc.1" "1.2.3+build.5" "1.2.3-rc.1+build.5"; do
    run bash "$SCRIPT" "$v" "false" "7"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bare=$v"* ]]
  done
}

@test "auto-derive verwirft einen vierstelligen Tag statt ihn zu uebernehmen" {
  # Die "belt-and-braces"-Pruefung im Auto-Pfad nutzte dasselbe unverankerte
  # Muster und liess `1.2.3.4-rc.42` durch.
  git tag "1.2.3.4"
  run bash "$SCRIPT" "" "true" "42"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bare=0.0.0-rc.42"* ]]
}

@test "auto-derive meldet einen kaputten Checkout, faellt aber nicht hart aus" {
  # I-12: der Fallback bleibt — ein manueller Build soll an der Tag-Landschaft
  # des Adopters nicht sterben. Aber "kein Repository" wird benannt, sonst
  # sieht ein kaputter Checkout aus wie ein Repo vor seinem ersten Tag.
  local outside="$BATS_TEST_TMPDIR/kein-repo"
  mkdir -p "$outside"
  run bash -c "cd '$outside' && bash '$SCRIPT' '' true 42"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a git repository"* ]]
  [[ "$output" == *"bare=0.0.0-rc.42"* ]]
}
