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

@test "detects rust cargo-workspace" {
  run "$DETECT" "$FIX/cargo-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=rust"* ]]
  [[ "$output" == *"release_type=rust"* ]]
}

@test "cargo-workspace --profile-json emits both member paths" {
  run "$DETECT" --profile-json "$FIX/cargo-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pkg-a"* ]]
  [[ "$output" == *"pkg-b"* ]]
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

@test "detects node pnpm-workspace" {
  run "$DETECT" "$FIX/pnpm-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=node"* ]]
  [[ "$output" == *"release_type=node"* ]]
}

@test "pnpm-workspace --profile-json includes all glob-expanded members" {
  run "$DETECT" --profile-json "$FIX/pnpm-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps/web"* ]]
  [[ "$output" == *"apps/api"* ]]
  [[ "$output" == *"packages/shared"* ]]
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
  # go-repo has no `import "C"` → cgo:false
  echo "$output" | jq -e '.components[0].cgo == false'
}

@test "profile-json: go-cgo fixture has cgo:true (direct import C)" {
  run "$DETECT" --profile-json "$FIX/go-cgo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "go"'
  echo "$output" | jq -e '.components[0].cgo == true'
}

@test "profile-json: go-cgo-transitive fixture has cgo:true (go.mod dep)" {
  # No `import "C"` in adopter source — cgo:true must still come through
  # because go.mod references a known cgo-via-dep package (go-sqlite3).
  run "$DETECT" --profile-json "$FIX/go-cgo-transitive"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].cgo == true'
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
  # primary_language is "generic" for no-signal components, but release_please_type
  # maps that to "simple" (release-please's catch-all type) since "generic" is
  # not a valid release-please release-type enum value.
  echo "$output" | jq -e '[.components[].primary_language] | unique == ["generic"]'
  echo "$output" | jq -e '[.components[].release_please_type] | unique == ["simple"]'
  rm -rf "$tmpdir"
}

@test "profile-json: empty-signals component maps release_please_type to simple" {
  # Direct test of the generic→simple mapping for fully-empty repos.
  run "$DETECT" --profile-json "$FIX/simple"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "generic"'
  echo "$output" | jq -e '.components[0].release_please_type == "simple"'
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

@test "profile-json: legacy_ci detects cargo-llvm-cov and recommends test-rust" {
  tmpdir=$(mktemp -d)
  echo '[package]' > "$tmpdir/Cargo.toml"
  echo 'name = "x"' >> "$tmpdir/Cargo.toml"
  echo 'version = "0.1.0"' >> "$tmpdir/Cargo.toml"
  mkdir -p "$tmpdir/.github/workflows"
  cat > "$tmpdir/.github/workflows/test.yml" <<'EOF'
name: test
on: [push]
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: taiki-e/install-action@v2
        with:
          tool: cargo-llvm-cov
      - run: cargo llvm-cov --fail-under-lines 90
EOF
  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci | length == 1'
  echo "$output" | jq -e '.legacy_ci[0].replaced_by == ["test-rust.yml"]'
  rm -rf "$tmpdir"
}

@test "profile-json: legacy_ci detects pytest and recommends test-python" {
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/pyproject.toml" <<'EOF'
[tool.poetry]
name = "x"
version = "0.1.0"
EOF
  mkdir -p "$tmpdir/.github/workflows"
  cat > "$tmpdir/.github/workflows/test-coverage.yml" <<'EOF'
name: test
on: [push]
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: poetry run pytest --cov
EOF
  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci | length == 1'
  echo "$output" | jq -e '.legacy_ci[0].replaced_by == ["test-python.yml"]'
  rm -rf "$tmpdir"
}

@test "profile-json: legacy_ci detects go test -cover and recommends test-go" {
  tmpdir=$(mktemp -d)
  echo "module example.com/x" > "$tmpdir/go.mod"
  echo "go 1.22" >> "$tmpdir/go.mod"
  mkdir -p "$tmpdir/.github/workflows"
  cat > "$tmpdir/.github/workflows/test.yml" <<'EOF'
name: test
on: [push]
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: go test -race -coverprofile=cover.out ./...
EOF
  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci | length == 1'
  echo "$output" | jq -e '.legacy_ci[0].replaced_by == ["test-go.yml"]'
  rm -rf "$tmpdir"
}

@test "profile-json: legacy_ci docker push pattern wins over cargo signal in same file" {
  # Regression guard: a release workflow that does `docker push` plus a
  # transient `cargo test` step is a docker-build replacement, NOT test-rust.
  tmpdir=$(mktemp -d)
  echo '[package]' > "$tmpdir/Cargo.toml"
  echo 'name = "x"' >> "$tmpdir/Cargo.toml"
  echo 'version = "0.1.0"' >> "$tmpdir/Cargo.toml"
  mkdir -p "$tmpdir/.github/workflows"
  cat > "$tmpdir/.github/workflows/release.yml" <<'EOF'
name: release
on: [push]
jobs:
  r:
    runs-on: ubuntu-latest
    steps:
      - run: cargo test
      - run: docker buildx build --push -t ghcr.io/x/y:latest .
EOF
  # 'release.yml' is OWNED — pick a non-OWNED filename to exercise classification.
  mv "$tmpdir/.github/workflows/release.yml" "$tmpdir/.github/workflows/publish.yml"
  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci[0].replaced_by == ["docker-build.yml"]'
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

@test "read_release_override reads true from header" {
  tmpfile=$(mktemp)
  printf '%s\n' '# Dockerfile' '# onboard:release=true' 'FROM alpine' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ "$result" = "true" ]
}

@test "read_release_override reads false from header" {
  tmpfile=$(mktemp)
  printf '%s\n' '# Dockerfile' '# onboard:release=false' 'FROM alpine' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ "$result" = "false" ]
}

@test "read_release_override emits empty when annotation absent" {
  tmpfile=$(mktemp)
  printf '%s\n' 'FROM alpine' 'RUN echo hi' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ -z "$result" ]
}

@test "read_release_override ignores annotation beyond line 5" {
  tmpfile=$(mktemp)
  printf '%s\n' '1' '2' '3' '4' '5' '# onboard:release=true' 'FROM alpine' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ -z "$result" ]
}

@test "inventory_dockerfiles detects Containerfile alongside Dockerfile" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Containerfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].path == "Containerfile"'
}

@test "inventory_dockerfiles classifies Dockerfile release_eligible=true by default" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == true'
}

@test "inventory_dockerfiles classifies Dockerfile.dev release_eligible=false by default" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile.dev"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == false'
}

@test "inventory_dockerfiles honors release=true override on Dockerfile.*" {
  tmpdir=$(mktemp -d)
  printf '%s\n' '# onboard:release=true' 'FROM alpine' > "$tmpdir/Dockerfile.worker"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == true'
}

@test "inventory_dockerfiles honors release=false override on Dockerfile" {
  tmpdir=$(mktemp -d)
  printf '%s\n' '# onboard:release=false' 'FROM alpine' > "$tmpdir/Dockerfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == false'
}

@test "inventory_dockerfiles classifies Containerfile.dev release_eligible=false" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Containerfile.dev"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == false'
}

@test "derive_image_name handles Containerfile root case" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(derive_image_name "Containerfile" ".")
  [ "$result" = "\$REPO" ]
}

@test "derive_image_name handles Containerfile.suffix" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(derive_image_name "Containerfile.worker" ".")
  [ "$result" = "\$REPO-worker" ]
}

@test "derive_image_name handles Containerfile in subpath" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(derive_image_name "Containerfile.worker" "services/api")
  [ "$result" = "\$REPO-api-worker" ]
}

# === Task 4: no_release_eligible warning ===

@test "profile-json warns when component has Dockerfiles but none release-eligible" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile.dev"
  : > "$tmpdir/Dockerfile.debug"
  run "$DETECT" --profile-json "$tmpdir"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.warnings[] | select(.code == "no_release_eligible")' >/dev/null
}

@test "profile-json no_release_eligible warning includes component path" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile.dev"
  run "$DETECT" --profile-json "$tmpdir"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.warnings[] | select(.code == "no_release_eligible") | .path == "."' >/dev/null
}

@test "profile-json does NOT warn no_release_eligible when at least one Dockerfile is eligible" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile"
  : > "$tmpdir/Dockerfile.dev"
  run "$DETECT" --profile-json "$tmpdir"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.warnings[] | select(.code == "no_release_eligible")] | length == 0' >/dev/null
}

@test "profile-json does NOT warn no_release_eligible for library component with no Dockerfile" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/go.mod"
  run "$DETECT" --profile-json "$tmpdir"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.warnings[] | select(.code == "no_release_eligible")] | length == 0' >/dev/null
}

@test "detect_components treats root Containerfile as a root-marker component" {
  # Regression: root Containerfile must qualify the repo root as a single component,
  # equivalent to Dockerfile. Previously detect_components only checked Dockerfile,
  # which would skip the root-marker branch and (wrongly) fall through to find()
  # for sub-components.
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Containerfile"
  run "$DETECT" --profile-json "$tmpdir"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components | length == 1' >/dev/null
  echo "$output" | jq -e '.components[0].path == "."' >/dev/null
}

@test "GITHUB_OUTPUT multiline block survives payload containing literal EOF" {
  # Mirrors the random-delimiter pattern from actions/onboard-detect/action.yml.
  # If the action used a fixed "EOF" delimiter, a payload line equal to "EOF"
  # would terminate the multi-line block early and the rest would be parsed
  # as a new key=value assignment. This test guards against that regression
  # by running the delimiter generation + extraction in isolation.
  payload=$'{"a":"line1"\nEOF\n"b":"line3"}'
  out=$(mktemp)
  delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
  { echo "profile_json<<${delim}"; echo "$payload"; echo "${delim}"; } > "$out"
  extracted=$(awk -v d="$delim" '$0==("profile_json<<"d){f=1;next} $0==d{f=0;next} f' "$out")
  rm -f "$out"
  [ "$extracted" = "$payload" ]
}

@test "current_version=0.0.0 when target_repo has no releases (gh returns \"null\")" {
  # gh release list --json tagName -q '.[0].tagName' on an empty list returns
  # the literal string "null" (exit 0). The script must treat that as no
  # release found and keep the 0.0.0 default.
  GH_MOCK=$(mktemp -d)
  cat > "$GH_MOCK/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api /repos/owner/repo") echo "main" ;;
  "release list")          echo "null" ;;
  *) echo "::error::unexpected gh call: $*" >&2; exit 1 ;;
esac
GHEOF
  chmod +x "$GH_MOCK/gh"
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current_version=0.0.0"* ]]
  [[ "$output" != *"current_version=null"* ]]
  rm -rf "$GH_MOCK"
}

@test "profile-json: current_version=0.0.0 for repo with no releases" {
  GH_MOCK=$(mktemp -d)
  cat > "$GH_MOCK/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api /repos/owner/repo") echo "main" ;;
  "release list")          echo "null" ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$GH_MOCK/gh"
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.current_version')" = "0.0.0" ]
  rm -rf "$GH_MOCK"
}

@test "--emit-both emits legacy key=value lines AND profile_json block" {
  run "$DETECT" --emit-both "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
  [[ "$output" == *"release_type=go"* ]]
  [[ "$output" == *"current_version=0.0.0"* ]]
  [[ "$output" == *"default_branch=main"* ]]
  [[ "$output" == *"profile_json<<EOF_"* ]]
}

@test "--emit-both profile_json block contains valid JSON" {
  run "$DETECT" --emit-both "$FIX/go-repo"
  [ "$status" -eq 0 ]
  # Extract the profile_json block content between the delimiter markers.
  # The first line of the block is "profile_json<<EOF_<hash>"; the closing
  # marker is "EOF_<hash>" on its own line. We use awk to find both.
  block=$(echo "$output" | awk '
    /^profile_json<<EOF_/ {
      delim = $0
      sub(/^profile_json<</, "", delim)
      flag = 1
      next
    }
    flag && $0 == delim { flag = 0; next }
    flag { print }
  ')
  # Validate that the extracted block is valid JSON with the expected schema.
  echo "$block" | jq -e '.schema_version == 1 and (.components | type == "array")'
}

@test "detects go workspace single-entry form" {
  run "$DETECT" "$FIX/go-work-single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
}

@test "go-work-single --profile-json emits the single member path" {
  run "$DETECT" --profile-json "$FIX/go-work-single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"svc\""* ]]
}
