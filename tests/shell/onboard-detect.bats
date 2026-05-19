#!/usr/bin/env bats
# Tests for scripts/onboard-detect.sh
#
# Contract (from spec §5):
#   onboard-detect.sh <repo-path> [language-override]
#   stdout key=value lines: language, release_type, current_version, default_branch
#   - When TARGET_REPO env is unset (local/test mode), current_version=0.0.0
#     and default_branch=main are emitted as defaults.
#   - Exit 1 on ambiguous signals or missing repo path.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DETECT="$REPO_ROOT/scripts/onboard-detect.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
  # Ensure target-repo env isn't bleeding in from CI
  unset TARGET_REPO
  unset GH_TOKEN
}

@test "detects go from go.mod" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
  [[ "$output" == *"release_type=go"* ]]
}

@test "detects python from pyproject.toml" {
  run "$DETECT" "$FIX/python-poetry"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=python"* ]]
  [[ "$output" == *"release_type=python"* ]]
}

@test "detects rust from Cargo.toml" {
  run "$DETECT" "$FIX/rust-cargo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=rust"* ]]
  [[ "$output" == *"release_type=rust"* ]]
}

@test "detects helm from Chart.yaml" {
  run "$DETECT" "$FIX/helm-chart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=helm"* ]]
  [[ "$output" == *"release_type=helm"* ]]
}

@test "detects node from package.json" {
  run "$DETECT" "$FIX/node-package"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=node"* ]]
  [[ "$output" == *"release_type=node"* ]]
}

@test "falls back to simple when no signals" {
  run "$DETECT" "$FIX/simple"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=simple"* ]]
  [[ "$output" == *"release_type=simple"* ]]
}

@test "errors on ambiguous signals" {
  run "$DETECT" "$FIX/ambiguous"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous language signals"* ]]
  [[ "$output" == *"go"* ]]
  [[ "$output" == *"python"* ]]
}

@test "respects explicit language override" {
  run "$DETECT" "$FIX/ambiguous" go
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
}

@test "emits default current_version=0.0.0 when TARGET_REPO unset" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=0.0.0"* ]]
}

@test "emits default default_branch=main when TARGET_REPO unset" {
  run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_branch=main"* ]]
}

@test "errors on missing repo path" {
  run "$DETECT" "/nonexistent/path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo path does not exist"* ]]
}

# === Task 2.2: profile.json mode ===

@test "profile-json: single go service emits schema_version=1" {
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema_version == 1'
}

@test "profile-json: single go service has one component at path '.'" {
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components | length == 1'
  echo "$output" | jq -e '.components[0].path == "."'
  echo "$output" | jq -e '.components[0].languages == ["go"]'
  # go-repo fixture has no Dockerfile → role=library
  echo "$output" | jq -e '.components[0].role == "library"'
}

@test "profile-json: default_branch defaults to main when TARGET_REPO unset" {
  unset TARGET_REPO
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.default_branch == "main"'
}

@test "profile-json: current_version defaults to 0.0.0 when TARGET_REPO unset" {
  unset TARGET_REPO
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.current_version == "0.0.0"'
}

# === Task 2.3: monorepo detection ===

@test "profile-json: go.work monorepo enumerates components" {
  run "$DETECT" --profile-json "$FIX/monorepo-go"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.monorepo == true'
  echo "$output" | jq -e '.components | length == 2'
  echo "$output" | jq -e '[.components[].path] | sort == ["services/api","services/worker"]'
  echo "$output" | jq -e '[.components[].languages] | flatten | unique | sort == ["go"]'
}

@test "profile-json: sub-dockerfiles without sub-markers fallback to monorepo" {
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/services/api" "$tmpdir/services/worker"
  echo "FROM scratch" > "$tmpdir/services/api/Dockerfile"
  echo "FROM scratch" > "$tmpdir/services/worker/Dockerfile"

  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.monorepo == true'
  echo "$output" | jq -e '.components | length == 2'
  echo "$output" | jq -e '[.components[].release_please_type] | unique == ["generic"]'
  rm -rf "$tmpdir"
}

# === Task 2.4: Dockerfile inventory + image-name override ===

@test "profile-json: multi-Dockerfile produces dockerfiles[] of length 2" {
  run "$DETECT" --profile-json "$FIX/multi-dockerfile"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].dockerfiles | length == 2'
}

@test "profile-json: Dockerfile.worker override beats convention" {
  run "$DETECT" --profile-json "$FIX/multi-dockerfile"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[0].dockerfiles[] | select(.path=="Dockerfile.worker") | .image_name] == ["custom-worker"]'
  echo "$output" | jq -e '[.components[0].dockerfiles[] | select(.path=="Dockerfile.worker") | .image_name_source] == ["override"]'
}

@test "profile-json: plain Dockerfile gets derived image name with REPO placeholder" {
  run "$DETECT" --profile-json "$FIX/multi-dockerfile"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[0].dockerfiles[] | select(.path=="Dockerfile") | .image_name_source] == ["derived"]'
  echo "$output" | jq -e '[.components[0].dockerfiles[] | select(.path=="Dockerfile") | .image_name] == ["$REPO"]'
}

@test "profile-json: monorepo-go sub-Dockerfiles have derived names with sub-path suffix" {
  run "$DETECT" --profile-json "$FIX/monorepo-go"
  [ "$status" -eq 0 ]
  # Each component has one Dockerfile, derived to "$REPO-api" or "$REPO-worker"
  echo "$output" | jq -e '
    [.components[] | select(.path=="services/api") | .dockerfiles[] | .image_name] == ["$REPO-api"]
  '
  echo "$output" | jq -e '
    [.components[] | select(.path=="services/worker") | .dockerfiles[] | .image_name] == ["$REPO-worker"]
  '
}

# === Task 2.5: role + release signals ===

@test "profile-json: library-go has role=library, no dockerfiles, no signals" {
  run "$DETECT" --profile-json "$FIX/library-go"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "library"'
  echo "$output" | jq -e '.components[0].dockerfiles | length == 0'
  echo "$output" | jq -e '.components[0].release_signals.goreleaser_config == null'
  echo "$output" | jq -e '.components[0].release_signals.chart_yaml == null'
}

@test "profile-json: cli-go-with-goreleaser has role=cli and goreleaser signal" {
  run "$DETECT" --profile-json "$FIX/cli-go-with-goreleaser"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "cli"'
  signal=$(echo "$output" | jq -r '.components[0].release_signals.goreleaser_config')
  [ -n "$signal" ]
  [ "$signal" != "null" ]
  [[ "$signal" == *".goreleaser.yaml" ]]
}

@test "profile-json: helm-chart fixture has role=helm-app" {
  run "$DETECT" --profile-json "$FIX/helm-chart"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "helm-app"'
}

@test "profile-json: service-with-helm has role=service AND chart_yaml signal" {
  run "$DETECT" --profile-json "$FIX/service-with-helm"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "service"'
  signal=$(echo "$output" | jq -r '.components[0].release_signals.chart_yaml')
  [[ "$signal" == *"Chart.yaml" ]]
}

# === Task 2.6: legacy CI scan ===

@test "profile-json: legacy_ci detects aquasecurity/trivy-action and recommends trivy replacements" {
  run "$DETECT" --profile-json "$FIX/legacy-ci"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci | length == 2'
  echo "$output" | jq -e '
    [.legacy_ci[] | select(.path == ".github/workflows/trivy.yml") | .replaced_by] | flatten | contains(["trivy-fs.yml"])
  '
}

@test "profile-json: legacy_ci detects docker/build-push-action and recommends docker-build" {
  run "$DETECT" --profile-json "$FIX/legacy-ci"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    [.legacy_ci[] | select(.path == ".github/workflows/build.yml") | .replaced_by] == [["docker-build.yml"]]
  '
}

@test "profile-json: legacy_ci skips OWNED workflow filenames" {
  # build a fixture that has ONLY an owned file — should produce empty legacy_ci
  tmpdir=$(mktemp -d)
  echo "module example.com/x" > "$tmpdir/go.mod"
  echo "go 1.22" >> "$tmpdir/go.mod"
  mkdir -p "$tmpdir/.github/workflows"
  cat > "$tmpdir/.github/workflows/release.yml" <<'EOF'
name: release
on: [push]
jobs:
  r:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci | length == 0'
  rm -rf "$tmpdir"
}

@test "profile-json: legacy_ci default-classifies unrecognized workflows" {
  tmpdir=$(mktemp -d)
  echo "module example.com/x" > "$tmpdir/go.mod"
  echo "go 1.22" >> "$tmpdir/go.mod"
  mkdir -p "$tmpdir/.github/workflows"
  cat > "$tmpdir/.github/workflows/random.yml" <<'EOF'
name: random
on: [push]
jobs:
  r:
    runs-on: ubuntu-latest
    steps:
      - run: echo just an unrecognized workflow
EOF
  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci | length == 1'
  echo "$output" | jq -e '.legacy_ci[0].replaced_by == []'
  echo "$output" | jq -e '.legacy_ci[0].summary | startswith("unrecognized")'
  rm -rf "$tmpdir"
}

# === Task 10: warn on unsupported primary_language ===

@test "profile.json warns when primary_language has no lint/test atom" {
  fixture="$BATS_TEST_TMPDIR/node-svc"
  mkdir -p "$fixture"
  cat > "$fixture/package.json" <<'JSON'
{
  "name": "node-svc",
  "version": "0.1.0"
}
JSON
  cat > "$fixture/Dockerfile" <<'DOCKER'
FROM node:22-alpine
COPY package.json .
CMD ["node"]
DOCKER

  run "$BATS_TEST_DIRNAME/../../scripts/onboard-detect.sh" --profile-json "$fixture"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.warnings | map(select(.code == "no_lint_test_atom")) | length > 0' >/dev/null
  echo "$output" | jq -e '.warnings[] | select(.code == "no_lint_test_atom") | .primary_language == "node"' >/dev/null
}
