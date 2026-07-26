# tests/shell/lib/assertions.bash
#
# Shared bats assertion helpers.
#
# refute_grep: assert that grep finds NO match.
#
# Why not plain `! grep …`? Bash exempts `!`-prefixed pipelines from
# errexit, so a mid-test `! grep` that finds a match does NOT fail the
# test — it only works by accident when it happens to be the last line.
# `! grep` also treats grep errors (exit 2, e.g. unreadable file) as
# success. This helper fails the test in both cases.
refute_grep() {
  local rc=0
  grep "$@" || rc=$?
  [ "$rc" -eq 1 ]
}
