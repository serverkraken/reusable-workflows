#!/usr/bin/env bats
# Tests for scripts/enable-code-security.sh.
#
# `gh` is stubbed: the stub answers the two GET calls from files the test
# writes, and records any PATCH into $CALLS. The whole point of the extraction
# is that the mutating path becomes observable — the integration dry-run
# targets a PUBLIC repo, so in CI the PATCH branch never runs at all.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/enable-code-security.sh"
  TMP="$(mktemp -d)"
  export CALLS="$TMP/calls.log"
  : > "$CALLS"
  cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "--method" && "$3" == "PATCH" ]]; then
  echo "PATCH $4" >> "$CALLS"
  echo '{}'
  exit 0
fi
case "$4" in
  .visibility) cat "$STUB_VISIBILITY" ;;
  *)           cat "$STUB_STATUS" ;;
esac
STUB
  chmod +x "$TMP/gh"
  PATH="$TMP:$PATH"
  export PATH
  export STUB_VISIBILITY="$TMP/vis" STUB_STATUS="$TMP/status"
  echo private > "$STUB_VISIBILITY"
  echo absent  > "$STUB_STATUS"
}

teardown() {
  rm -rf "$TMP"
}

@test "dry run reports the change but never PATCHes" {
  DRY_RUN=true run "$SCRIPT" acme/private-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=would-enable"* ]]
  [[ "$output" == *"acme/private-app"* ]]
  [ ! -s "$CALLS" ]
}

@test "live run enables it" {
  DRY_RUN=false run "$SCRIPT" acme/private-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=enabled"* ]]
  grep -q "PATCH /repos/acme/private-app" "$CALLS"
}

@test "unset DRY_RUN behaves as a live run" {
  run "$SCRIPT" acme/private-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=enabled"* ]]
  grep -q "PATCH /repos/acme/private-app" "$CALLS"
}

@test "public target is skipped before anything is read or written" {
  echo public > "$STUB_VISIBILITY"
  run "$SCRIPT" acme/public-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=skipped-public"* ]]
  [ ! -s "$CALLS" ]
}

@test "already-enabled target is a no-op even in a live run" {
  echo enabled > "$STUB_STATUS"
  DRY_RUN=false run "$SCRIPT" acme/private-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"outcome=already-enabled"* ]]
  [ ! -s "$CALLS" ]
}

@test "missing target argument fails" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}
