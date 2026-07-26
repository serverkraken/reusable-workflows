#!/usr/bin/env bats
# Tests for tests/conventions/check-contracts.sh.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-contracts.sh"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows" "$FIXTURE_DIR/actions/demo" "$FIXTURE_DIR/docs"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "passes when documented workflow and action contracts match source" {
  cat > "$FIXTURE_DIR/docs/contracts.md" <<'EOF'
# Workflow Contracts

### `demo.yml`

| Kind | Name | Type | Required | Default | Description |
|------|------|------|----------|---------|-------------|
| input | `branch` | string | yes | - | Branch |
| output | `tag` | string | - | - | Tag |
| secret | `token` | - | yes | - | Token |

### `actions/demo`

| Kind | Name | Type | Required | Default | Description |
|------|------|------|----------|---------|-------------|
| input | `config` | string | no | `''` | Config |
| output | `result` | string | - | - | Result |
EOF

  cat > "$FIXTURE_DIR/.github/workflows/demo.yml" <<'EOF'
name: demo
on:
  workflow_call:
    inputs:
      branch:
        required: true
        type: string
    outputs:
      tag:
        value: ${{ jobs.demo.outputs.tag }}
    secrets:
      token:
        required: true
jobs:
  demo:
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.tag.outputs.tag }}
    steps:
      - run: echo ok
EOF

  cat > "$FIXTURE_DIR/actions/demo/action.yml" <<'EOF'
name: demo
inputs:
  config:
    required: false
    default: ''
outputs:
  result:
    value: ${{ steps.run.outputs.result }}
runs:
  using: composite
  steps:
    - id: run
      shell: bash
      run: echo "result=ok" >> "$GITHUB_OUTPUT"
EOF

  REPO_ROOT="$FIXTURE_DIR" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "contract sections checked" ]]
}

@test "fails when docs list a stale contract name" {
  cat > "$FIXTURE_DIR/docs/contracts.md" <<'EOF'
# Workflow Contracts

### `demo.yml`

| Kind | Name | Type | Required | Default | Description |
|------|------|------|----------|---------|-------------|
| input | `missing` | string | yes | - | Missing |
EOF

  cat > "$FIXTURE_DIR/.github/workflows/demo.yml" <<'EOF'
name: demo
on:
  workflow_call:
    inputs:
      present:
        required: true
        type: string
jobs:
  demo:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF

  REPO_ROOT="$FIXTURE_DIR" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "documents input 'missing'" ]]
  [[ "$output" =~ "exposes input 'present'" ]]
}

@test "fails when a documented section omits action inputs" {
  cat > "$FIXTURE_DIR/docs/contracts.md" <<'EOF'
# Workflow Contracts

### `actions/demo`

No inputs.
EOF

  cat > "$FIXTURE_DIR/actions/demo/action.yml" <<'EOF'
name: demo
inputs:
  token:
    required: false
runs:
  using: composite
  steps:
    - shell: bash
      run: echo ok
EOF

  REPO_ROOT="$FIXTURE_DIR" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "exposes input 'token'" ]]
}

@test "fails when a documented source file is missing" {
  cat > "$FIXTURE_DIR/docs/contracts.md" <<'EOF'
# Workflow Contracts

### `missing.yml`

| Kind | Name | Type | Required | Default | Description |
|------|------|------|----------|---------|-------------|
| input | `branch` | string | yes | - | Branch |
EOF

  REPO_ROOT="$FIXTURE_DIR" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing.yml does not exist" ]]
}
