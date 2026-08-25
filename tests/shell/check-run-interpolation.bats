#!/usr/bin/env bats
# Tests for tests/conventions/check-run-interpolation.sh
#
# The gate exists because the 2026-08-25 audit found five caller-controlled
# expressions interpolated straight into `run:` bodies — one of which let a
# caller turn a failing lint into a green job.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-run-interpolation.sh"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows"
  cd "$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "flags a caller input interpolated into a run block" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: |
          cargo clippy -- ${{ inputs.clippy_args }}
YAML
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"inputs.clippy_args"* ]]
}

@test "accepts the same value passed through env" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - env:
          CLIPPY_ARGS: ${{ inputs.clippy_args }}
        run: |
          cargo clippy -- $CLIPPY_ARGS
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "flags a single-line run, not just block scalars" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: cargo clippy -- ${{ inputs.clippy_args }}
YAML
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "flags matrix and github.event, not just inputs" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "${{ matrix.platform }}"
          echo "${{ github.event.pull_request.title }}"
YAML
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"matrix.platform"* ]]
  [[ "$output" == *"github.event.pull_request.title"* ]]
}

# Values produced inside the workflow are out of scope on purpose — blanket
# flagging them would bury the gate in false positives and get it ignored.
@test "does not flag steps, needs or plain github context" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "${{ steps.build.outputs.digest }}"
          echo "${{ needs.version.outputs.tag }}"
          echo "${{ github.run_id }}"
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "an expression outside a run body is not flagged" {
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - working-directory: ${{ inputs.working_directory }}
        env:
          TAG: ${{ inputs.tag }}
        run: |
          echo "$TAG"
YAML
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "composite actions are scanned too" {
  mkdir -p actions/thing
  cat > actions/thing/action.yml <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        echo "${{ inputs.name }}"
YAML
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"inputs.name"* ]]
}
