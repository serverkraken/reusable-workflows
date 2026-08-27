#!/usr/bin/env bats
# Tests for tests/conventions/check-reusable-permissions.py
#
# The gate exists because granting a reusable-workflow job too few permissions
# does not fail the JOB — it aborts the entire RUN with `startup_failure`, no
# annotation and no log. Measured on runs 33074131069 / 33074876898.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-reusable-permissions.py"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows"
  cd "$FIXTURE_DIR"
  cat > .github/workflows/atom.yml <<'YAML'
on:
  workflow_call:
permissions:
  contents: write
  packages: write
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "accepts a caller granting exactly what the atom declares" {
  cat > .github/workflows/caller.yml <<'YAML'
on: push
jobs:
  call:
    uses: ./.github/workflows/atom.yml
    permissions:
      contents: write
      packages: write
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "accepts a caller granting more than the atom declares" {
  cat > .github/workflows/caller.yml <<'YAML'
on: push
jobs:
  call:
    uses: ./.github/workflows/atom.yml
    permissions:
      contents: write
      packages: write
      issues: write
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "flags a missing scope — the defect that aborts the whole run" {
  cat > .github/workflows/caller.yml <<'YAML'
on: push
jobs:
  call:
    uses: ./.github/workflows/atom.yml
    permissions:
      contents: write
YAML
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"packages: none"* ]]
  [[ "$output" == *"startup"* ]]
}

@test "flags a scope granted too weakly" {
  cat > .github/workflows/caller.yml <<'YAML'
on: push
jobs:
  call:
    uses: ./.github/workflows/atom.yml
    permissions:
      contents: read
      packages: write
YAML
  run python3 "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contents: read"* ]]
}

# Omitting permissions entirely is a different, legitimate choice: the job
# inherits the calling workflow's defaults. The gate must not force a grant.
@test "ignores a caller that declares no permissions at all" {
  cat > .github/workflows/caller.yml <<'YAML'
on: push
jobs:
  call:
    uses: ./.github/workflows/atom.yml
    secrets: inherit
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 caller job(s) checked"* ]]
}

@test "ignores a call to a workflow outside the catalog" {
  cat > .github/workflows/caller.yml <<'YAML'
on: push
jobs:
  call:
    uses: someorg/other/.github/workflows/thing.yml@v1
    permissions:
      contents: read
YAML
  run python3 "$SCRIPT"
  [ "$status" -eq 0 ]
}
