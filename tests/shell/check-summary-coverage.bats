#!/usr/bin/env bats
# Tests for tests/conventions/check-summary-coverage.sh.

setup() {
  REPO_ROOT_REAL="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT_REAL/tests/conventions/check-summary-coverage.sh"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows"
  WF="$FIXTURE_DIR/.github/workflows/demo.yml"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

run_gate() {
  # Eintraege sind jetzt <datei>:<aggregator>, weil nicht jeder Workflow
  # seinen Sammeljob "summary" nennt.
  REPO_ROOT="$FIXTURE_DIR" run bash "$SCRIPT" ".github/workflows/demo.yml:${1:-summary}"
}

@test "passes when every job is reachable from summary" {
  cat > "$WF" <<'EOF2'
name: demo
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  assert-build:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  summary:
    needs:
      - assert-build
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "3 jobs" ]]
}

@test "fails on a job that summary cannot see" {
  # Der Fall aus K-18: der Job laeuft, taucht im Log auf, und kann den
  # Required Check nicht rot faerben.
  cat > "$WF" <<'EOF2'
name: demo
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  orphan-test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  summary:
    needs:
      - build
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "'orphan-test' is not reachable" ]]
  [[ ! "$output" =~ "'build' is not reachable" ]]
}

@test "follows needs transitively and in inline-array form" {
  cat > "$WF" <<'EOF2'
name: demo
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  b:
    needs: [a]
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  c:
    needs: b
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  summary:
    needs: [c]
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate
  [ "$status" -eq 0 ]
}

@test "accepts an exempt marker with a reason" {
  cat > "$WF" <<'EOF2'
name: demo
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  # summary-exempt: cleanup only, swallows its own errors
  cleanup:
    needs: [build]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  summary:
    needs:
      - build
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1 exempt" ]]
}

@test "rejects an exempt marker without a reason" {
  cat > "$WF" <<'EOF2'
name: demo
on: [push]
jobs:
  # summary-exempt:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  summary:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no reason" ]]
}

@test "rejects a stale exempt marker on a job that IS reachable" {
  # Eine Ausnahmeliste, die niemand zurueckschneidet, behauptet Blindheit, wo
  # keine ist — und verliert damit ihren Wert als Warnsignal.
  cat > "$WF" <<'EOF2'
name: demo
on: [push]
jobs:
  # summary-exempt: stale, this job is in needs after all
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  summary:
    needs:
      - build
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "IS reachable" ]]
}

@test "fails when a required workflow has no summary job" {
  cat > "$WF" <<'EOF2'
name: demo
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no 'summary' job" ]]
}

@test "an aggregator that is not called summary is honoured" {
  # nightly-runner-parity sammelt in assert-parity, failure-paths-nightly in
  # report-regressions. Waere "summary" fest verdrahtet, waeren beide fuer das
  # Gate unsichtbar — und genau dort lag eine echte Luecke.
  cat > "$WF" <<'EOF2'
name: demo
on: [schedule]
jobs:
  work-a:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  work-b:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  assert-parity:
    needs: [work-a]
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate assert-parity
  [ "$status" -ne 0 ]
  [[ "$output" =~ "'work-b' is not reachable from 'assert-parity'" ]]

  # Mit beiden im Sammeljob ist es sauber.
  sed -i.bak 's/needs: \[work-a\]/needs: [work-a, work-b]/' "$WF"
  run_gate assert-parity
  [ "$status" -eq 0 ]
}

@test "a workflow whose named aggregator does not exist fails" {
  cat > "$WF" <<'EOF2'
name: demo
on: [schedule]
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF2
  run_gate report-regressions
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no 'report-regressions' job" ]]
}
