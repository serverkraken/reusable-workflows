#!/usr/bin/env bats
# Tests for scripts/seed-onboarding-status.sh
#
# The script lists serverkraken/* repos via gh CLI and appends one Markdown
# table row per missing repo to docs/onboarding-status.md. Existing rows
# must be preserved; the regex anchor must avoid substring false-matches
# (e.g. "serverkraken/foo" must not match an existing "serverkraken/foo-extra"
# row).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/seed-onboarding-status.sh"
  WORK="$(mktemp -d)"
  cd "$WORK"
  export REPO_ROOT="$WORK"
  mkdir -p docs

  # PATH-injected gh mock: emits a fixed list of three repos when invoked
  # with `gh repo list ...`. The script reads only the nameWithOwner field
  # so we ignore --json/--limit/-q flags and just print the canned list.
  BIN="$WORK/bin"
  mkdir -p "$BIN"
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "list" ]]; then
  printf 'serverkraken/alpha\nserverkraken/beta\nserverkraken/foo\n'
  exit 0
fi
echo "::error::unexpected gh call: $*" >&2
exit 1
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
}

teardown() {
  unset REPO_ROOT
  rm -rf "$WORK"
}

@test "creates onboarding-status.md with header when missing" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ -f docs/onboarding-status.md ]]
  grep -q '# Onboarding Status' docs/onboarding-status.md
  grep -q '| Repository | Onboarded |' docs/onboarding-status.md
}

@test "appends new repos and preserves existing rows" {
  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

_Last updated by the onboarding workflow: 2026-01-01T00:00:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/alpha | ✓ | v3.0.0 | #1 | #2 | onboarded |
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Existing row preserved verbatim
  grep -qE '^\| serverkraken/alpha \| ✓ \| v3\.0\.0 \|' docs/onboarding-status.md
  # New rows appended (mock returns beta + foo as not-yet-present)
  grep -qE '^\| serverkraken/beta \|' docs/onboarding-status.md
  grep -qE '^\| serverkraken/foo \|' docs/onboarding-status.md
}

@test "regex anchor avoids substring false-match (foo vs foo-extra)" {
  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

_Last updated by the onboarding workflow: 2026-01-01T00:00:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/foo-extra | — | — | — | — | not onboarded |
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # foo (without the -extra suffix) must now appear exactly once as a fresh row.
  # If the regex anchor were broken, the existing foo-extra row would match
  # ^| serverkraken/foo and the new foo row would never be appended.
  count=$(grep -cE '^\| serverkraken/foo \|' docs/onboarding-status.md)
  [ "$count" -eq 1 ]
  # foo-extra row is still present
  grep -qE '^\| serverkraken/foo-extra \|' docs/onboarding-status.md
}
