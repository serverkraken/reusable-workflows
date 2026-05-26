#!/usr/bin/env bats
# Tests for tests/conventions/check-step-summary.sh
# Verifies the CI-gate that enforces docs/conventions/step-summary.md.

setup() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  SCRIPT="$REPO_ROOT/tests/conventions/check-step-summary.sh"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/.github/workflows"
  cd "$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "passes when atom has H2-heading + STEP_SUMMARY write" {
  cat > .github/workflows/lint-go.yml <<'EOF'
name: lint-go
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Summary
        run: |
          {
            echo "## lint-go"
            echo "**Result:** ✓ passed"
          } >> "$GITHUB_STEP_SUMMARY"
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "fails when atom has no STEP_SUMMARY write" {
  cat > .github/workflows/lint-go.yml <<'EOF'
name: lint-go
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo "nothing"
EOF
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "writes no \$GITHUB_STEP_SUMMARY" ]]
}

@test "fails when atom writes summary but no '## <atom>' heading" {
  cat > .github/workflows/lint-go.yml <<'EOF'
name: lint-go
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Summary
        run: |
          {
            echo "## something-else"
            echo "**Result:** ✓ passed"
          } >> "$GITHUB_STEP_SUMMARY"
EOF
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no '## lint-go' heading found" ]]
}

@test "skips Self-CI atoms (validate.yml)" {
  cat > .github/workflows/validate.yml <<'EOF'
name: validate
on: [push]
jobs:
  v:
    runs-on: ubuntu-latest
    steps:
      - run: echo "no summary needed for self-CI"
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
