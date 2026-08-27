#!/usr/bin/env bats
# Tests for tests/conventions/check-runs-on-guard.py
#
# The gate exists because `runs_on: '[]'` does not fail a job — measured on run
# 33050121217, where cleanup-images landed on a real self-hosted runner with an
# empty label list while holding `packages: write`. See the gate header.
#
# Two halves are tested here, and the second is the one that is easy to forget:
#
#   1. the gate catches a missing / misplaced / mis-bound guard
#   2. the guard TEXT the atoms actually ship still rejects what it must
#
# Without (2), someone could break the bash condition and every structural
# check would stay green.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-runs-on-guard.py"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows"
  cd "$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

guarded_job() {
  cat <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Reject an empty runs_on
        working-directory: ${{ github.workspace }}
        env:
          RUNS_ON: ${{ inputs.runs_on }}
        run: |
          set -euo pipefail
          trimmed="${RUNS_ON//[[:space:]]/}"
          if [[ "$trimmed" != "["*"]" || ! "$trimmed" =~ [A-Za-z0-9] ]]; then
            echo "::error::runs_on must be a non-empty JSON array of runner labels, got: ${RUNS_ON}" >&2
            exit 1
          fi
      - name: Do the work
        run: echo hi
YAML
}

# --- 1. the gate ------------------------------------------------------------

@test "accepts a job whose first step guards the value it runs on" {
  guarded_job > .github/workflows/atom.yml
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 job(s) checked"* ]]
}

@test "flags a runner-selecting job with no guard at all" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Do the work
        run: echo hi
YAML
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not \`Reject an empty runs_on\`"* ]]
}

@test "flags a guard that is present but not the first step" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Do the work
        run: echo hi
      - name: Reject an empty runs_on
        env:
          RUNS_ON: ${{ inputs.runs_on }}
        run: exit 1
YAML
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"first step is \`Do the work\`"* ]]
}

# This is the defect that would otherwise pass silently: a guard that validates
# a DIFFERENT input than the one the job resolves its runner from.
@test "flags a guard bound to an expression the job does not run on" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  build:
    runs-on: ${{ fromJSON(matrix.runs_on_input == 'runs_on_amd64' && inputs.runs_on_amd64 || inputs.runs_on_arm64) }}
    steps:
      - name: Reject an empty runs_on
        working-directory: ${{ github.workspace }}
        env:
          RUNS_ON: ${{ inputs.runs_on_amd64 }}
        run: exit 1
YAML
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"would pass while the real value is empty"* ]]
}

# The guard runs before the checkout, so a job-level working-directory default
# points at a directory that does not exist yet. Measured on run 33062297620,
# where goreleaser died with "No such file or directory" instead of checking.
@test "flags a guard that does not pin the workspace as its working directory" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  release:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    defaults:
      run:
        working-directory: ${{ inputs.working_directory }}
    steps:
      - name: Reject an empty runs_on
        env:
          RUNS_ON: ${{ inputs.runs_on }}
        run: exit 1
YAML
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"before the checkout"* ]]
}

@test "ignores a forwarder job that has no runs-on of its own" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  release:
    uses: ./.github/workflows/semantic-release.yml
    with:
      runs_on: ${{ inputs.runs_on }}
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 job(s) checked"* ]]
}

@test "ignores a job pinned to a literal runner" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Do the work
        run: echo hi
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- 2. the guard body the atoms actually ship ------------------------------

# Extracted from a real atom rather than retyped, so an edit to the shipped
# text is what gets exercised here.
run_shipped_guard() {
  local value="$1" body
  body="$(python3 - "$REPO_ROOT/.github/workflows/lint-python.yml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
block = text.split("- name: Reject an empty runs_on", 1)[1]
block = block.split("run: |", 1)[1]
out = []
for line in block.split("\n")[1:]:
    if line.strip() and not line.startswith("          "):
        break
    out.append(line[10:])
print("\n".join(out).rstrip())
PY
)"
  RUNS_ON="$value" bash -c "$body"
}

@test "shipped guard accepts real runner label arrays" {
  run run_shipped_guard '["self-hosted","Linux"]'
  [ "$status" -eq 0 ]
  run run_shipped_guard '["self-hosted", "Linux", "X64", "performance"]'
  [ "$status" -eq 0 ]
  run run_shipped_guard '["ubuntu-latest"]'
  [ "$status" -eq 0 ]
}

@test "shipped guard rejects an empty array" {
  run run_shipped_guard '[]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-empty JSON array"* ]]
  run run_shipped_guard '[ ]'
  [ "$status" -ne 0 ]
}

@test "shipped guard rejects an array that names nothing" {
  run run_shipped_guard '[""]'
  [ "$status" -ne 0 ]
  run run_shipped_guard '[" ", ""]'
  [ "$status" -ne 0 ]
}

@test "shipped guard rejects non-array JSON that fromJSON would accept" {
  # `"ubuntu-latest"`, `null` and `{}` all survive fromJSON; only the guard
  # turns them into a red job.
  run run_shipped_guard '"ubuntu-latest"'
  [ "$status" -ne 0 ]
  run run_shipped_guard 'null'
  [ "$status" -ne 0 ]
  run run_shipped_guard '{}'
  [ "$status" -ne 0 ]
}

@test "shipped guard rejects an empty value" {
  run run_shipped_guard ''
  [ "$status" -ne 0 ]
}
