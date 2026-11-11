#!/usr/bin/env bats
# Tests for tests/conventions/check-timeout-input.py
#
# The gate: a job whose runner is overridable (runs-on from a runs_on* input)
# must take its timeout from an inputs.timeout_minutes* input, or carry a
# `# timeout-fixed: <reason>` marker. See the gate header.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-timeout-input.py"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows"
  cd "$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

# atom <timeout-block>: a workflow_call atom with one overridable-runner job.
atom() {
  cat <<YAML
on:
  workflow_call:
jobs:
  lint:
    runs-on: \${{ fromJSON(inputs.runs_on) }}
$1
    steps:
      - name: Do the work
        run: echo hi
YAML
}

@test "accepts a timeout read from timeout_minutes" {
  atom '    timeout-minutes: ${{ inputs.timeout_minutes }}' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 job(s) checked, 1 overridable, 0 fixed"* ]]
}

@test "accepts a role-specific timeout input" {
  atom '    timeout-minutes: ${{ inputs.timeout_minutes_merge }}' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "flags a hard-coded timeout on an overridable runner" {
  atom '    timeout-minutes: 15' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"job \`lint\`: \`timeout-minutes: 15\` is fixed"* ]]
}

@test "flags a missing timeout (GitHub would allow 360 minutes)" {
  atom '' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no \`timeout-minutes\`"* ]]
}

@test "flags a timeout read from an input that is not a timeout input" {
  atom '    timeout-minutes: ${{ inputs.minutes }}' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "accepts a fixed timeout marked with a reason" {
  atom $'    # timeout-fixed: summary only\n    timeout-minutes: 5' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 fixed with a reason"* ]]
}

@test "flags a timeout-fixed marker without a reason" {
  atom $'    # timeout-fixed:\n    timeout-minutes: 5' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no reason"* ]]
}

@test "flags a marker that is not directly above the timeout" {
  atom $'    # timeout-fixed: summary only\n    if: always()\n    timeout-minutes: 5' > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "a step-level timeout-minutes does not count as the job timeout" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Do the work
        timeout-minutes: 3
        run: echo hi
YAML
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no \`timeout-minutes\`"* ]]
}

@test "ignores jobs on a fixed runner (outside the scope)" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  tool:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - run: echo hi
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 job(s) checked"* ]]
}

@test "ignores reusable-workflow calls" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  build:
    uses: ./.github/workflows/other.yml
    with:
      runs_on: ${{ inputs.runs_on }}
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 job(s) checked"* ]]
}

@test "ignores workflows that are not workflow_call" {
  cat > .github/workflows/ci.yml <<'YAML'
on:
  push:
jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 15
    steps:
      - run: echo hi
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the real catalog passes" {
  cd "$REPO_ROOT"
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
}
