#!/usr/bin/env bats
# Tests for scripts/push-bot-branch.sh.
#
# Aufbau: ein bare-Repo als "origin", ein Arbeitsklon. Damit ist der
# entscheidende Fall echt nachstellbar — ein Mensch pusht einen Fixup auf den
# Bot-Branch, und der naechste Lauf darf ihn nicht wegwerfen.

BOT='serverkraken-release-bot[bot]'

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/push-bot-branch.sh"
  TMP="$(mktemp -d)"
  ORIGIN="$TMP/origin.git"
  WORK="$TMP/work"

  git init -q --bare "$ORIGIN"
  git init -q "$WORK"
  cd "$WORK"
  git config user.name "$BOT"
  git config user.email bot@example.com
  git remote add origin "$ORIGIN"
  echo base > base.txt
  git add base.txt
  git commit -qm "base"
  git branch -M main
  git push -q origin main
  git fetch -q origin
}

teardown() {
  cd /
  rm -rf "$TMP"
}

# Legt einen Bot-Commit auf den Bot-Branch und pusht ihn ueber das Skript.
bot_push() {
  cd "$WORK"
  git checkout -q -B bot-branch origin/main
  echo "$1" > rendered.txt
  git add rendered.txt
  git commit -qm "chore: onboard"
  run "$SCRIPT" bot-branch origin/main "$BOT"
}

@test "a branch that does not exist yet is pushed" {
  bot_push v1
  [ "$status" -eq 0 ]
  run git -C "$ORIGIN" rev-parse --verify bot-branch
  [ "$status" -eq 0 ]
}

@test "the bot may replace its own previous commit" {
  bot_push v1
  [ "$status" -eq 0 ]
  bot_push v2
  [ "$status" -eq 0 ]
  run git -C "$ORIGIN" show bot-branch:rendered.txt
  [ "$output" = "v2" ]
}

@test "a human commit on the bot branch aborts the push and names the author" {
  bot_push v1
  [ "$status" -eq 0 ]

  # Ein Mensch pusht einen Fixup auf den Bot-Branch.
  human="$TMP/human"
  git clone -q "$ORIGIN" "$human"
  cd "$human"
  git config user.name "Some Reviewer"
  git config user.email reviewer@example.com
  git checkout -q bot-branch
  echo "hand-tuned" > rendered.txt
  git commit -qam "fix: correct the rendered workflow"
  git push -q origin bot-branch

  bot_push v3
  [ "$status" -ne 0 ]
  [[ "$output" == *"Some Reviewer"* ]]
  [[ "$output" == *"Refusing to force-push"* ]]

  # Und der Fixup steht noch da.
  run git -C "$ORIGIN" show bot-branch:rendered.txt
  [ "$output" = "hand-tuned" ]
}

@test "a branch moved by another BOT run is still overwritten — only human work is protected" {
  bot_push v1
  [ "$status" -eq 0 ]

  # Ein paralleler Lauf bewegt den Branch, ohne dass dieser Klon es sieht.
  other="$TMP/other"
  git clone -q "$ORIGIN" "$other"
  cd "$other"
  git config user.name "$BOT"
  git config user.email bot@example.com
  git checkout -q bot-branch
  echo "concurrent" > rendered.txt
  git commit -qam "chore: onboard"
  git push -q origin bot-branch

  # Der erste Klon kennt den neuen Stand nicht — aber das Skript holt ihn,
  # sieht nur Bot-Commits und darf deshalb ueberschreiben. Das ist gewollt:
  # geschuetzt wird menschliche Arbeit, nicht die Reihenfolge zweier Botlaeufe.
  bot_push v4
  [ "$status" -eq 0 ]
  run git -C "$ORIGIN" show bot-branch:rendered.txt
  [ "$output" = "v4" ]
}

@test "missing arguments fail" {
  cd "$WORK"
  run "$SCRIPT" bot-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}
