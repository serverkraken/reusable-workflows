#!/usr/bin/env bats
# Tests for scripts/onboard-sweep-drift-status.sh
#
# The script clones an adopter and runs onboard-drift.sh against the clone.
# Bats uses the ONBOARD_SWEEP_TARGET_PATH env var to skip the clone and point
# the script at a pre-prepared local target — this avoids network access and
# keeps tests deterministic.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/onboard-sweep-drift-status.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
}

@test "drift-status: drift-clean fixture reports clean in test mode" {
  ONBOARD_SWEEP_TARGET_PATH="$FIX/drift-clean" \
    run "$SCRIPT" serverkraken/dummy v3
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "drift-status: hand-edited adopter reports modified" {
  # Copy the drift-clean fixture so we can tamper with it.
  tmp=$(mktemp -d)
  cp -R "$FIX/drift-clean/." "$tmp/"
  echo "# tampered" >> "$tmp/.github/workflows/ci.yml"
  ONBOARD_SWEEP_TARGET_PATH="$tmp" \
    run "$SCRIPT" serverkraken/dummy v3
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "modified" ]
}

@test "drift-status: adopter on old major reports behind" {
  tmp=$(mktemp -d)
  cp -R "$FIX/drift-clean/." "$tmp/"
  jq '.catalog_version = "v1"' "$tmp/.github/onboard.lock.json" \
    > "$tmp/.github/onboard.lock.json.new"
  mv "$tmp/.github/onboard.lock.json.new" "$tmp/.github/onboard.lock.json"
  ONBOARD_SWEEP_TARGET_PATH="$tmp" \
    run "$SCRIPT" serverkraken/dummy v3
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "behind" ]
}

@test "drift-status: missing args exits 1 with usage message" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "drift-status: missing GH_TOKEN in clone mode exits 1" {
  # No ONBOARD_SWEEP_TARGET_PATH set → script tries clone mode.
  # No GH_TOKEN → script errors out before attempting any network call.
  unset GH_TOKEN
  run "$SCRIPT" serverkraken/dummy v3
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN"* ]]
}

# --- der Token darf nicht in argv stehen (Audit H-16) -----------------------
#
# Bisher lautete die Klon-URL
# `https://x-access-token:${GH_TOKEN}@github.com/<repo>.git`. Damit stand der
# Token im ARGV von git — auf einem self-hosted Runner ueber `ps` fuer jeden
# Prozess auf demselben Host lesbar — und zusaetzlich in der .git/config des
# Klons, also auf Platte.
#
# Der Klon-Pfad war ungetestet: alle bisherigen Faelle setzen
# ONBOARD_SWEEP_TARGET_PATH und ueberspringen ihn. Genau deshalb ist es nicht
# aufgefallen. Hier steht ein git-Stub im PATH, der argv und die relevanten
# Umgebungsvariablen protokolliert.

_git_stub() {
  STUBDIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUBDIR"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.txt"
  ENV_LOG="$BATS_TEST_TMPDIR/env.txt"
  cat > "$STUBDIR/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
printf 'COUNT=%s KEY=%s VALUE=%s\n' "\${GIT_CONFIG_COUNT:-}" "\${GIT_CONFIG_KEY_0:-}" "\${GIT_CONFIG_VALUE_0:-}" >> "$ENV_LOG"
# Klon vortaeuschen: Zielverzeichnis anlegen, damit das Skript weiterlaeuft.
for a in "\$@"; do :; done
mkdir -p "\${@: -1}"
exit 0
EOF
  chmod +x "$STUBDIR/git"
}

@test "der Token steht nicht in den git-Argumenten" {
  _git_stub
  PATH="$STUBDIR:$PATH" GH_TOKEN="s3cr3t-token-wert" \
    run "$SCRIPT" serverkraken/dummy v4
  [ -f "$ARGV_LOG" ]
  run cat "$ARGV_LOG"
  [[ "$output" != *"s3cr3t-token-wert"* ]]
  [[ "$output" != *"x-access-token:"* ]]
  # Die URL selbst muss token-frei sein.
  [[ "$output" == *"https://github.com/serverkraken/dummy.git"* ]]
}

@test "der Token wird stattdessen ueber die Umgebung gereicht" {
  _git_stub
  PATH="$STUBDIR:$PATH" GH_TOKEN="s3cr3t-token-wert" \
    run "$SCRIPT" serverkraken/dummy v4
  run cat "$ENV_LOG"
  [[ "$output" == *"COUNT=1"* ]]
  [[ "$output" == *"KEY=http.https://github.com/.extraheader"* ]]
  # base64 von "x-access-token:s3cr3t-token-wert"
  [[ "$output" == *"AUTHORIZATION: basic "* ]]
}
