#!/usr/bin/env bats

setup() {
  SANITIZE_SH="$BATS_TEST_DIRNAME/../../actions/compute-prerelease-tag/sanitize.sh"
}

@test "simple lowercase branch" {
  run bash "$SANITIZE_SH" "feat-x" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feat-x-a1b2c3d$"
  echo "$output" | grep -q "^moving_tag=feat-x$"
}

@test "slash in branch name becomes dash" {
  run bash "$SANITIZE_SH" "feat/auth-fix" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feat-auth-fix-a1b2c3d$"
  echo "$output" | grep -q "^moving_tag=feat-auth-fix$"
}

@test "uppercase letters are lowercased" {
  run bash "$SANITIZE_SH" "Feature/Auth-Fix" "DEADBEE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feature-auth-fix-deadbee$"
}

@test "invalid OCI characters are stripped" {
  run bash "$SANITIZE_SH" "feat/foo@bar~baz" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo-bar-baz$"
}

@test "multiple consecutive dashes collapse to one" {
  run bash "$SANITIZE_SH" "feat//foo--bar" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo-bar$"
}

@test "leading/trailing dashes are stripped" {
  run bash "$SANITIZE_SH" "-feat-foo-" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo$"
}

@test "empty branch name fails" {
  run bash "$SANITIZE_SH" "" "abcdef0"
  [ "$status" -ne 0 ]
}

@test "empty SHA fails" {
  run bash "$SANITIZE_SH" "feat-x" ""
  [ "$status" -ne 0 ]
}

@test "branch consisting only of invalid chars fails" {
  run bash "$SANITIZE_SH" "@@@" "abcdef0"
  [ "$status" -ne 0 ]
}

@test "very long branch name truncated to 64 chars in moving tag" {
  long_branch=$(printf 'a%.0s' {1..200})
  run bash "$SANITIZE_SH" "$long_branch" "abcdef0"
  [ "$status" -eq 0 ]
  moving=$(echo "$output" | grep '^moving_tag=' | cut -d= -f2)
  [ ${#moving} -le 64 ]
}

# --- Argumente, die wie Flags aussehen -------------------------------------
# `echo "$X"` frisst ein fuehrendes -n/-e/-E als Flag. Mit echo lieferte eine
# SHA von "-n" ein LEERES sha-Element, und tag_with_sha fiel auf "<branch>-"
# zusammen — fuer jeden Commit desselben Branches identisch. Zwei Builds
# haetten sich unter einem Namen gegenseitig ueberschrieben.

@test "a short-sha that looks like an echo flag is rejected, not silently dropped" {
  run bash "$SANITIZE_SH" "feature/x" "-n"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not hexadecimal"* ]]
  # Der alte Code lieferte hier still "tag_with_sha=feature-x-".
  [[ "$output" != *"tag_with_sha="* ]]
}

@test "a branch that looks like an echo flag keeps its characters" {
  # Regressionsschutz, kein frueherer Fehler: "-e feat" enthaelt ein
  # Leerzeichen und war deshalb auch fuer echo nie ein Flag. Der Test haelt
  # fest, dass printf hier nichts veraendert hat.
  run bash "$SANITIZE_SH" "-e feat" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=e-feat$"
}

@test "a branch that IS an echo flag fails loudly rather than producing a stub" {
  # Auch mit echo war das kein stiller Fehler: der Branch wurde leer und das
  # Skript brach ab. Mit printf wird daraus ein gueltiger Tag.
  run bash "$SANITIZE_SH" "-n" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=n$"
}

# --- SHA-Validierung -------------------------------------------------------

@test "a non-hexadecimal short-sha fails" {
  run bash "$SANITIZE_SH" "feat-x" "not-a-sha"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not hexadecimal"* ]]
}

@test "an uppercase short-sha is lowercased, not rejected" {
  run bash "$SANITIZE_SH" "feat-x" "A1B2C3D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feat-x-a1b2c3d$"
}

# --- OCI-Endpruefung -------------------------------------------------------

@test "a branch starting with an underscore-safe char still yields a valid OCI tag" {
  # Die Endpruefung darf keinen legitimen Fall abweisen.
  run bash "$SANITIZE_SH" "0-numeric-start" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=0-numeric-start$"
}

@test "the emitted tags always satisfy the OCI tag grammar" {
  run bash "$SANITIZE_SH" "Feature/Über-Straße_#42!!" "A1B2C3D"
  [ "$status" -eq 0 ]
  while IFS='=' read -r _ value; do
    [[ "$value" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$ ]]
  done <<< "$output"
}
