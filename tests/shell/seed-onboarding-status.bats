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


# ---- Audit H-23: Repo-Name als Regex ----
#
# Der Name wurde per sed nur an `/` maskiert und dann als ERE benutzt. Ein
# Punkt blieb damit ein Metazeichen, das JEDES Zeichen trifft. Die Org hat vier
# solche Repos (juke.gallery, juke.gallery-admin, juke.gallery-rest,
# juke.gallery-user), ein Fehltreffer braucht aber ein Repo, das sich nur an
# dieser Stelle unterscheidet — deshalb war der Fehler bisher latent.
#
# Der Test stellt genau dieses Paar her: `juke.gallery` gegen eine bereits
# vorhandene Zeile `jukeXgallery`. Als Regex trifft der Punkt das X, das Repo
# gilt faelschlich als vorhanden und faellt aus der Tabelle.
@test "ein Punkt im Repo-Namen ist kein Regex-Metazeichen (Audit H-23)" {
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "list" ]]; then
  printf 'serverkraken/juke.gallery\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$BIN/gh"

  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

_Last updated by the onboarding workflow: 2026-01-01T00:00:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status | Consumers |
|---|---|---|---|---|---|---|
| serverkraken/jukeXgallery | yes | v4 | — | — | onboarded | — |
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Das echte Repo muss angehaengt worden sein ...
  grep -q '^| serverkraken/juke\.gallery |' docs/onboarding-status.md || {
    cat docs/onboarding-status.md; false
  }
  # ... und die fremde Zeile unberuehrt bleiben.
  grep -q '^| serverkraken/jukeXgallery |' docs/onboarding-status.md
}

# Gegenprobe: ein Repo, das WIRKLICH schon in der Tabelle steht, darf nicht
# doppelt angehaengt werden. Ohne diese Zusicherung koennte der Fix den
# Duplikat-Schutz stillschweigend aushebeln.
@test "ein bereits vorhandenes Repo wird nicht doppelt angehaengt" {
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "list" ]]; then
  printf 'serverkraken/juke.gallery\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$BIN/gh"

  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

_Last updated by the onboarding workflow: 2026-01-01T00:00:00Z_

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status | Consumers |
|---|---|---|---|---|---|---|
| serverkraken/juke.gallery | yes | v4 | — | — | onboarded | — |
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  local n
  n=$(grep -c '^| serverkraken/juke\.gallery |' docs/onboarding-status.md)
  [ "$n" -eq 1 ] || { cat docs/onboarding-status.md; false; }
}

# ---- Audit H-22: stille Kappung durch --limit ----
#
# `gh repo list --limit N` schneidet ohne Hinweis ab. Die Org hat derzeit 41
# Repos gegen ein Limit von 200, die alte Grenze griff also NICHT — sie war
# eine latente Kappung. Jede feste Grenze ist aber irgendwann zu klein, und
# genau dann soll es auffallen statt still Repos zu verlieren.
@test "eine womoeglich abgeschnittene Repo-Liste wird gemeldet (Audit H-22)" {
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "list" ]]; then
  printf 'serverkraken/a\nserverkraken/b\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$BIN/gh"

  REPO_LIMIT=2 run "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"probably truncated"* ]] || { echo "$output"; false; }
}

# Gegenprobe: unterhalb der Grenze bleibt es still. Sonst waere die Warnung
# Rauschen bei jedem Lauf.
@test "eine vollstaendige Repo-Liste meldet keine Kappung" {
  REPO_LIMIT=50 run "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"probably truncated"* ]] || { echo "$output"; false; }
}
