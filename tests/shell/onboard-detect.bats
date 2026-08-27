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

@test "detect: root go.mod wins over sub-directory Dockerfiles" {
  run "$DETECT" --profile-json "$FIX/go-root-subdir-dockerfile"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.monorepo' <<< "$output")" = "false" ]
  [ "$(jq -r '.components | length' <<< "$output")" = "1" ]
  [ "$(jq -r '.components[0].path' <<< "$output")" = "." ]
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

# Audit H-24. Die OWNED-Liste kannte ci-android.yml nicht, obwohl der Renderer
# sie ausgibt. Gemessen: ein Flutter-Profil rendern, dasselbe Repo wieder
# erkennen lassen — und die EIGENE Ausgabe stand als
# "unrecognized legacy workflow; manual review needed" in legacy_ci. PR B haette
# ihre Loeschung vorgeschlagen, das naechste Onboarding sie wieder angelegt.
#
# Der Test nimmt bewusst ein Go-Repo ohne Flutter: der Name gehoert dem
# Renderer unabhaengig davon, ob DIESER Adopter die Datei gerade bekommt —
# genau wie beim ebenfalls opt-in gerenderten prerelease-on-push.yml.
@test "profile-json: legacy_ci skips ci-android.yml (Audit H-24)" {
  tmpdir=$(mktemp -d)
  printf 'module example.com/x\ngo 1.22\n' > "$tmpdir/go.mod"
  mkdir -p "$tmpdir/.github/workflows"
  cat > "$tmpdir/.github/workflows/ci-android.yml" <<'YAML'
name: ci-android
on: [push]
jobs:
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/build-flutter-android.yml@v4
YAML
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
  # Der Topics-Aufruf MUSS beantwortet werden. Frueher fiel er in den
  # Fehlerzweig, und der Detektor las das als "keine Topics" - der Mock trug
  # damit die Fehlfunktion mit, die H-10 beschreibt.
  "api /repos/owner/repo/topics") echo "[]" ;;
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
  "api /repos/owner/repo/topics") echo "[]" ;;
  "api /repos/owner/repo") echo "main" ;;
  "release list")          echo "null" ;;
  *) echo "::error::unexpected gh call: $*" >&2; exit 1 ;;
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

# === Flutter detection ===

@test "detects flutter from pubspec sdk: flutter (legacy key=value)" {
  run "$DETECT" "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=flutter"* ]]
}

@test "profile-json: flutter-app primary_language=flutter" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "flutter"'
  echo "$output" | jq -e '.components[0].languages == ["flutter"]'
}

@test "profile-json: flutter-package is still detected as flutter" {
  run "$DETECT" --profile-json "$FIX/flutter-package"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "flutter"'
}

@test "profile-json: flutter-app release_please_type=dart" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_please_type == "dart"'
}

@test "profile-json: flutter emits no no_lint_test_atom warning" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.warnings[] | select(.code == "no_lint_test_atom")] | length == 0'
}

@test "profile-json: flutter-app has flutter_android=true and role=mobile-app" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_signals.flutter_android == true'
  echo "$output" | jq -e '.components[0].role == "mobile-app"'
}

@test "profile-json: flutter-package has flutter_android=false and role=library" {
  run "$DETECT" --profile-json "$FIX/flutter-package"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_signals.flutter_android == false'
  echo "$output" | jq -e '.components[0].role == "library"'
}

@test "profile-json: go-repo release_signals gains flutter_android=false (additive)" {
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_signals.flutter_android == false'
}

@test "legacy key=value: flutter emits release_type=dart" {
  run "$DETECT" "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"release_type=dart"* ]]
}

@test "--emit-both: flutter emits release_type=dart" {
  run "$DETECT" --emit-both "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"release_type=dart"* ]]
}

@test "profile-json: flutter app with nested sub-chart stays a single root component" {
  run "$DETECT" --profile-json "$FIX/flutter-app-subchart"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components | length == 1'
  echo "$output" | jq -e '.components[0].path == "."'
  echo "$output" | jq -e '.components[0].primary_language == "flutter"'
  # the nested chart is reported as a release signal of the root component,
  # not split into a sibling component
  echo "$output" | jq -e '.components[0].release_signals.chart_yaml != null'
  # the root is still an Android Flutter app (has android/) → flutter_android stays true
  echo "$output" | jq -e '.components[0].release_signals.flutter_android == true'
}

# === Flutter: Abstand hinter `sdk:` (Audit M-1) ===
#
# Jede eingecheckte Fixture schreibt genau ein Leerzeichen. Deshalb ist nie
# aufgefallen, dass Bash und Go sich hier uneinig waren: Bash nahm
# `sdk:[[:space:]]*flutter` (Stern), Go verglich woertlich mit "sdk: flutter".
# Zwei Leerzeichen und ein Tab sind gueltiges YAML mit derselben Bedeutung —
# der Go-Pfad, und der ist der Standard, hat solche Repos als `simple`
# gerendert, also ohne einen einzigen Flutter-Job. Umgekehrt las Bash
# `sdk:flutter` als Flutter, obwohl YAML das gar nicht als Mapping liest.
#
# Die Fixtures entstehen hier statt unter tests/fixtures/, weil sie nur den
# Abstand variieren; drei fast gleiche Fixture-Baeume waeren mehr Rauschen als
# Nutzen.

_pubspec_fixture() { # $1 = Zielverzeichnis, $2 = die sdk-Zeile
  mkdir -p "$1/lib"
  printf 'name: demo\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\ndependencies:\n  flutter:\n    %s\n' "$2" > "$1/pubspec.yaml"
  echo "void main() {}" > "$1/lib/main.dart"
}

@test "flutter: zwei Leerzeichen hinter sdk: werden erkannt" {
  _pubspec_fixture "$BATS_TEST_TMPDIR/two" "sdk:  flutter"
  run "$DETECT" "$BATS_TEST_TMPDIR/two"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=flutter"* ]]
}

@test "flutter: Tab hinter sdk: wird erkannt" {
  _pubspec_fixture "$BATS_TEST_TMPDIR/tab" "$(printf 'sdk:\tflutter')"
  run "$DETECT" "$BATS_TEST_TMPDIR/tab"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=flutter"* ]]
}

@test "flutter: sdk:flutter ohne Leerzeichen ist KEIN Flutter-Repo" {
  # YAML verlangt hinter dem Doppelpunkt Whitespace; ohne ihn ist die Zeile ein
  # Skalar und erklaert keine Abhaengigkeit. Die alte Bash-Regel (Stern) hat sie
  # trotzdem als Flutter gezaehlt.
  _pubspec_fixture "$BATS_TEST_TMPDIR/none" "sdk:flutter"
  run "$DETECT" "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=simple"* ]]
  [[ "$output" != *"language=flutter"* ]]
}

@test "flutter: kanonische Schreibweise bleibt unveraendert erkannt" {
  _pubspec_fixture "$BATS_TEST_TMPDIR/one" "sdk: flutter"
  run "$DETECT" "$BATS_TEST_TMPDIR/one"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=flutter"* ]]
}

# === topics ===

@test "profile-json: topics defaults to [] when TARGET_REPO unset" {
  unset TARGET_REPO
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.topics == []'
}

@test "profile-json: topics populated from gh api /repos/<repo>/topics" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
# Minimal gh mock honoring the calls emit_profile_json makes with -q.
case "$*" in
  *"/topics"*)       echo '["sk-prerelease-on-push","serverkraken-onboarded"]' ;;
  *"release list"*)  echo '' ;;
  *"/repos/o/r"*)    echo 'main' ;;
  *)                 echo '' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  TARGET_REPO=o/r PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.topics | index("sk-prerelease-on-push")) != null'
}

# ---- gitops detection helpers (Task 1) ----

# Source the lib directly to unit-test the helper functions.
load_lib() { source "$REPO_ROOT/scripts/lib/onboard-detect-lib.sh"; }

@test "detect_gitops_kubernetes: true on full cluster-template fingerprint" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps" "$d/bootstrap/templates"
  touch "$d/.sops.yaml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
}

@test "detect_gitops_kubernetes: true via makejinja.toml marker" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps"
  touch "$d/.sops.yaml" "$d/makejinja.toml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
}

@test "detect_gitops_kubernetes: false when .sops.yaml missing" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps" "$d/bootstrap/templates"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ]
}

@test "detect_gitops_kubernetes: false when kubernetes/ missing" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bootstrap/templates"
  touch "$d/.sops.yaml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ]
}

@test "detect_gitops_kubernetes: false when no cluster-template marker" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps"
  touch "$d/.sops.yaml"
  load_lib
  run detect_gitops_kubernetes "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ]
}

@test "_gitops_manifests_paths: enumerates workload dirs, excludes control dirs" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/apps" "$d/kubernetes/argo" \
           "$d/kubernetes/bootstrap" "$d/kubernetes/components" "$d/kubernetes/flux-system"
  load_lib
  run _gitops_manifests_paths "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .)" = '["kubernetes/apps","kubernetes/argo"]' ]
}

@test "_gitops_manifests_paths: empty array when no workload dirs" {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/kubernetes/bootstrap"
  load_lib
  run _gitops_manifests_paths "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

# ---- gitops profile-json (Task 2) ----

@test "profile-json: gitops-cluster sets primary_language=gitops" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "gitops"'
}

@test "profile-json: gitops-cluster sets role=gitops" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.components[0].role == "gitops"'
}

@test "profile-json: gitops-cluster release_please_type is simple" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.components[0].release_please_type == "simple"'
}

@test "profile-json: gitops-cluster attaches .gitops object" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.gitops.manifests_paths == ["kubernetes/apps","kubernetes/argo"]'
  echo "$output" | jq -e '.gitops.sops == true'
  echo "$output" | jq -e '.gitops.has_kube_linter_config == true'
  echo "$output" | jq -e '.gitops.has_gitleaks_config == true'
}

@test "profile-json: gitops-cluster emits zero warnings" {
  run "$DETECT" --profile-json "$FIX/gitops-cluster"
  echo "$output" | jq -e '.warnings | length == 0'
}

@test "profile-json: non-gitops profile has no .gitops key" {
  run "$DETECT" --profile-json "$FIX/go-repo"
  echo "$output" | jq -e 'has("gitops") | not'
}

# ---- gitops legacy_ci recognition (Task 3) ----

# Build a tmp repo with a single legacy workflow file containing $2, assert the
# detected replaced_by equals $3 (a JSON array literal).
_legacy_one() {
  local fname="$1" body="$2"
  local d; d="$(mktemp -d)"
  mkdir -p "$d/.github/workflows"
  printf '%s\n' "$body" > "$d/.github/workflows/$fname"
  "$DETECT" --profile-json "$d"
  rm -rf "$d"
}

@test "legacy_ci: kubeconform.yaml → kube-validate.yml" {
  out=$(_legacy_one "kubeconform.yaml" "run: kubeconform -strict")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("kubeconform.yaml")) | .replaced_by] | flatten == ["kube-validate.yml"]'
}

@test "legacy_ci: kube-linter.yaml → kube-lint.yml" {
  out=$(_legacy_one "kube-linter.yaml" "uses: stackrox/kube-linter-action@v1")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("kube-linter.yaml")) | .replaced_by] | flatten == ["kube-lint.yml"]'
}

@test "legacy_ci: gitleaks.yaml → secret-scan.yml" {
  out=$(_legacy_one "gitleaks.yaml" "run: gitleaks detect --source .")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("gitleaks.yaml")) | .replaced_by] | flatten == ["secret-scan.yml"]'
}

@test "legacy_ci: trivy.yaml (CLI fs scan) → trivy-fs.yml" {
  out=$(_legacy_one "trivy.yaml" "run: trivy fs --scanners vuln .")
  echo "$out" | jq -e '[.legacy_ci[] | select(.path | endswith("trivy.yaml")) | .replaced_by] | flatten == ["trivy-fs.yml"]'
}

# ---- gitops legacy key=value path (Task 4) ----

@test "legacy mode: gitops-cluster reports language=gitops" {
  run "$DETECT" "$FIX/gitops-cluster"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=gitops"* ]]
  [[ "$output" == *"release_type=simple"* ]]
}

@test "emit-both: gitops-cluster reports language=gitops + valid profile_json" {
  run "$DETECT" --emit-both "$FIX/gitops-cluster"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=gitops"* ]]
  # the profile_json block carries the gitops object
  echo "$output" | sed -n '/profile_json<</,/^EOF_/p' | sed '1d;$d' | jq -e '.gitops.sops == true'
}

@test "detect: refuses a repo with an adopter manifest (Go CLI required)" {
  run "$DETECT" --profile-json "$FIX/go-root-multi-image"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adopter manifest"* ]]
  [[ "$output" == *"use_go_cli"* ]]
  run "$DETECT" "$FIX/go-root-multi-image"
  [ "$status" -eq 1 ]
  run "$DETECT" --emit-both "$FIX/go-root-multi-image"
  [ "$status" -eq 1 ]
}

# === API-Fehler duerfen nicht wie Antworten aussehen (Audit H-5, H-10) ===
#
# Vier Aufrufe fielen frueher auf plausible Vorgaben zurueck:
#
#   gh api /repos/<r>          -> "main"     (Default-Branch frei erfunden)
#   gh release list            -> ""         -> current_version bleibt 0.0.0
#   gh api /repos/<r>/topics   -> []         -> Opt-ins still verloren
#
# Gemessen an der echten API trennt der Exit-Status die Faelle sauber:
#
#   Repo mit Releases     rc=0, Tag
#   Repo OHNE Releases    rc=0, leer     <- gueltig
#   Repo existiert nicht  rc=1, leer
#   Token ungueltig       rc=1, leer
#
# Aus current_version wird `.release-please-manifest.json` geseedet. Ein Repo
# auf 1.10.0, dessen Release-Abfrage scheitert, haette dort 0.0.0 bekommen und
# beim naechsten Release rueckwaerts versioniert.

# Schreibt einen gh-Mock, der $1 beantwortet und bei $2 fehlschlaegt.
# $1 = "ok"|"fail" je Aufrufart, in der Reihenfolge branch,releases,topics
_gh_mock() {
  local branch="$1" releases="$2" topics="$3"
  GH_MOCK=$(mktemp -d)
  cat > "$GH_MOCK/gh" <<GHEOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "api /repos/owner/repo/topics") [[ "$topics"  == ok ]] && { echo '[]'; exit 0; }; exit 1 ;;
  "api /repos/owner/repo")        [[ "$branch"  == ok ]] && { echo main; exit 0; }; exit 1 ;;
  "release list")                 [[ "$releases" == ok ]] && { echo null; exit 0; }; exit 1 ;;
esac
echo "::error::unexpected gh call: \$*" >&2
exit 1
GHEOF
  chmod +x "$GH_MOCK/gh"
}

@test "gescheiterte Release-Abfrage seedet NICHT 0.0.0, sondern bricht ab" {
  _gh_mock ok fail ok
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" --profile-json "$FIX/go-repo"
  rm -rf "$GH_MOCK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list releases"* ]]
}

@test "gescheiterte Topics-Abfrage gilt nicht als 'keine Topics'" {
  # Topics steuern Opt-ins wie `sk-prerelease-on-push`; ein verschluckter
  # Fehler haette das Opt-in still fallen lassen.
  _gh_mock ok ok fail
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" --profile-json "$FIX/go-repo"
  rm -rf "$GH_MOCK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read topics"* ]]
}

@test "gescheiterte Branch-Abfrage bricht ab, statt 'main' zu erfinden" {
  _gh_mock fail ok ok
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" --profile-json "$FIX/go-repo"
  rm -rf "$GH_MOCK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not accessible"* ]]
}

@test "ein Repo ohne Releases bleibt gueltig und ergibt 0.0.0" {
  # Gegenprobe: die drei Abbrueche oben duerfen den legitimen Fall nicht
  # mitreissen. Ein Repo vor seinem ersten Release antwortet mit rc=0.
  _gh_mock ok ok ok
  PATH="$GH_MOCK:$PATH" TARGET_REPO=owner/repo GH_TOKEN=stub run "$DETECT" --profile-json "$FIX/go-repo"
  rm -rf "$GH_MOCK"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.current_version')" = "0.0.0" ]
}

# === Kollidierende Image-Namen (Audit H-4) ===
#
# Der abgeleitete Name nimmt nur das LETZTE Pfadsegment: `apps/api` und
# `services/api` ergeben beide `$REPO-api`. Beide Komponenten wuerden in
# dasselbe GHCR-Image pushen; derselbe Versionstag zeigt danach auf den Build,
# der zufaellig zuletzt lief, und cleanup-images sieht ein Paket statt zweier.
#
# Der Go-Detektor prueft dasselbe (checkImageNameCollisions) und meldet
# denselben Wortlaut — die Engines duerfen sich hier nicht unterscheiden.

_two_components() {
  local repo="$1" a="$2" b="$3"
  for c in "$a" "$b"; do
    mkdir -p "$repo/$c"
    printf 'module x\ngo 1.22\n' > "$repo/$c/go.mod"
    printf 'FROM scratch\n' > "$repo/$c/Dockerfile"
  done
}

@test "kollidierende Image-Namen werden abgewiesen" {
  local repo="$BATS_TEST_TMPDIR/kollision"
  _two_components "$repo" "apps/api" "services/api"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *'duplicate image name'* ]]
  # Beide Pfade muessen im Text stehen, sonst ist nicht zu sehen, welche zwei
  # sich in die Quere kommen.
  [[ "$output" == *"apps/api/Dockerfile"* ]]
  [[ "$output" == *"services/api/Dockerfile"* ]]
  # Der genannte Ausweg muss der sein, der auch funktioniert: das Manifest
  # verbietet kollidierende Basisnamen mit einer eigenen Regel, ein `image:`
  # hilft dort also nicht.
  [[ "$output" == *"rename"* ]]
}

@test "verschiedene Image-Namen gehen weiterhin durch" {
  # Gegenprobe: ein gewoehnliches Monorepo darf die Pruefung nicht treffen.
  local repo="$BATS_TEST_TMPDIR/ok"
  _two_components "$repo" "services/api" "services/worker"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].dockerfiles[].image_name] | length == 2'
  echo "$output" | jq -e '[.components[].dockerfiles[].image_name] | unique | length == 2'
}

# === Workspace-Muster (Audit H-8/B-8, H-7/B-11) ===
#
# Cargo-Member wurden woertlich uebernommen: `members = ["crates/*"]` ergab eine
# Komponente mit dem Pfad `crates/*` — ein Verzeichnis, das es nicht gibt. Die
# echten Crates bekamen dadurch KEINE Jobs. `crates/*` ist das uebliche
# Cargo-Layout, und der pnpm-Zweig direkt daneben expandierte laengst.
#
# Der Go-Detektor verhaelt sich identisch (expandWorkspacePatterns).

_crate() {
  mkdir -p "$1/src"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$(basename "$1")" > "$1/Cargo.toml"
  echo 'fn main(){}' > "$1/src/main.rs"
}

@test "Cargo-Workspace: ein Glob wird expandiert" {
  local repo="$BATS_TEST_TMPDIR/cargo-glob"
  _crate "$repo/crates/alpha"; _crate "$repo/crates/beta"
  printf '[workspace]\nmembers = ["crates/*"]\n' > "$repo/Cargo.toml"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].path] == ["crates/alpha","crates/beta"]'
}

@test "Cargo-Workspace: ein Member ausserhalb des Checkouts faellt weg" {
  local base="$BATS_TEST_TMPDIR/cargo-esc"
  mkdir -p "$base/repo"
  _crate "$base/nachbar"
  printf '[workspace]\nmembers = ["../nachbar"]\n' > "$base/repo/Cargo.toml"
  run "$DETECT" --profile-json "$base/repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].path] | all(. == ".")'
}

@test "Cargo-Workspace: ausgeschriebene Member bleiben erhalten" {
  # Gegenprobe: die Expansion darf gewoehnliche Member nicht verlieren.
  local repo="$BATS_TEST_TMPDIR/cargo-literal"
  _crate "$repo/pkg-a"; _crate "$repo/pkg-b"
  printf '[workspace]\nmembers = ["pkg-a", "pkg-b"]\n' > "$repo/Cargo.toml"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].path] == ["pkg-a","pkg-b"]'
}

@test "go.work: ein use-Pfad ausserhalb des Checkouts faellt weg" {
  # B-11. Beim Cargo-Fix (#308) als miterledigt bezeichnet — war es nicht:
  # `parseGoWork` blieb unangetastet, beide Engines lieferten `["../nachbar"]`.
  local base="$BATS_TEST_TMPDIR/gowork-esc"
  mkdir -p "$base/repo" "$base/nachbar"
  printf 'module nachbar\ngo 1.22\n' > "$base/nachbar/go.mod"
  printf 'go 1.22\n\nuse ../nachbar\n' > "$base/repo/go.work"
  run "$DETECT" --profile-json "$base/repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].path] | all(. == ".")'
}

@test "go.work: ein gewoehnliches use ./svc bleibt erhalten" {
  # Gegenprobe: der fuehrende ./ muss weiterhin aufgeloest werden.
  local repo="$BATS_TEST_TMPDIR/gowork-ok"
  mkdir -p "$repo/svc"
  printf 'module svc\ngo 1.22\n' > "$repo/svc/go.mod"
  printf 'go 1.22\n\nuse ./svc\n' > "$repo/go.work"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].path] == ["svc"]'
}

@test "gleicher Basename ohne Dockerfiles wird abgewiesen" {
  # Suchmuster "nicht-injektive Abbildung": die Image-Namen-Pruefung fing das
  # nur MIT Dockerfiles. Ohne sie gaben beide Komponenten `package-name: api`,
  # und release-please erzeugte fuer beide Tags `api-vX.Y.Z`.
  local repo="$BATS_TEST_TMPDIR/pkgcollision"
  mkdir -p "$repo/apps/api" "$repo/services/api"
  printf 'module x\ngo 1.22\n' > "$repo/apps/api/go.mod"
  printf 'module x\ngo 1.22\n' > "$repo/services/api/go.mod"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate release-please package name"* ]]
  [[ "$output" == *"apps/api"* ]]
  [[ "$output" == *"services/api"* ]]
}

@test "verschiedene Basenamen ohne Dockerfiles gehen durch" {
  # Gegenprobe: ein gewoehnliches Monorepo darf die Pruefung nicht treffen.
  local repo="$BATS_TEST_TMPDIR/pkgok"
  mkdir -p "$repo/services/api" "$repo/services/worker"
  printf 'module x\ngo 1.22\n' > "$repo/services/api/go.mod"
  printf 'module x\ngo 1.22\n' > "$repo/services/worker/go.mod"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].path] == ["services/api","services/worker"]'
}

@test "abgeleitete Image-Namen sind kleingeschrieben" {
  # OCI-Namen sind kleingeschrieben (Audit H-17). `services/MyService` ergab
  # `$REPO-MyService`, und das landete unveraendert im gerenderten image_name
  # UND im GHCR-package_name. Der Go-Detektor macht dasselbe.
  local repo="$BATS_TEST_TMPDIR/upper"
  mkdir -p "$repo/services/MyService"
  printf 'module x\ngo 1.22\n' > "$repo/services/MyService/go.mod"
  printf 'FROM scratch\n' > "$repo/services/MyService/Dockerfile"
  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.components[].dockerfiles[].image_name] == ["$REPO-myservice"]'
  # Der Komponentenpfad bleibt, wie er auf der Platte heisst.
  echo "$output" | jq -e '[.components[].path] == ["services/MyService"]'
}

# --- `# onboard:image=` folgt derselben Regel wie das Manifest ---------------
#
# Die Annotation wurde mit `[A-Za-z0-9._/-]+` gelesen — nur am ZEILENANFANG
# verankert. Zwei Defekte in einem Ausdruck:
#
#   `# onboard:image=acme/svc UND MEHR`  ->  image_name "acme/svc UND MEHR"
#   `# onboard:image=Acme/UPPER`         ->  image_name "Acme/UPPER"
#
# Der erste ist der schwerere: ein Image-Name mit Leerzeichen waere ins
# gerenderte image_name gelaufen. Der Go-Detektor wies ihn ab (beidseitig
# verankert) — die Bash-Fassung nicht. Beide Engines lesen jetzt dieselbe
# Regel, beidseitig verankert und kleingeschrieben.

_image_names() {
  bash "$REPO_ROOT/scripts/onboard-detect.sh" --profile-json "$1" \
    | jq -c '[.components[].dockerfiles[].image_name]'
}

_repo_with_annotation() {
  local dir="$BATS_TEST_TMPDIR/annot" header="$1"
  rm -rf "$dir"; mkdir -p "$dir/svc"
  printf 'module x\ngo 1.22\n' > "$dir/svc/go.mod"
  printf '%sFROM scratch\n' "$header" > "$dir/svc/Dockerfile"
  echo "$dir"
}

@test "onboard:image mit gueltigem Kleinbuchstaben-Namen wird uebernommen" {
  run _image_names "$(_repo_with_annotation '# onboard:image=acme/svc
')"
  [ "$status" -eq 0 ]
  [ "$output" = '["acme/svc"]' ]
}

@test "onboard:image mit Grossbuchstaben wird abgewiesen" {
  run _image_names "$(_repo_with_annotation '# onboard:image=Acme/UPPER
')"
  [ "$status" -eq 0 ]
  [ "$output" = '["$REPO-svc"]' ]
}

@test "onboard:image mit Text hinter dem Namen wird abgewiesen" {
  run _image_names "$(_repo_with_annotation '# onboard:image=acme/svc UND MEHR
')"
  [ "$status" -eq 0 ]
  [ "$output" = '["$REPO-svc"]' ]
}

# --- unsichtbare Zeichen am Zeilenende --------------------------------------
#
# `read_release_override` matchte mit `grep -oE '^# onboard:release=(true|false)'`
# nur den Zeilenanfang; die Go-Fassung vergleicht die Zeile exakt. Beide Engines
# entschieden damit gegensaetzlich ueber die Auslieferung eines Images, und zwar
# in beide Richtungen:
#
#   # onboard:release=true<CR>            Go verwarf sie,  Bash nahm sie
#   # onboard:release=false-aber-doch-ja  Go verwarf sie,  Bash nahm sie
#
# Ein CRLF-Dockerfile ist nichts Exotisches - auf Windows geschrieben ist es der
# Normalfall. Beide Engines schneiden das Zeilenende jetzt ab und verankern
# beidseitig.

_release_flags() {
  bash "$REPO_ROOT/scripts/onboard-detect.sh" --profile-json "$1" \
    | jq -c '[.components[].dockerfiles[].release_eligible]'
}

_repo_with_dockerfile() {  # <dateiname> <kopfzeile-roh>
  local dir="$BATS_TEST_TMPDIR/rel" 
  rm -rf "$dir"; mkdir -p "$dir/svc"
  printf 'module x\ngo 1.22\n' > "$dir/svc/go.mod"
  printf '%bFROM scratch\n' "$2" > "$dir/svc/$1"
  echo "$dir"
}

@test "release=true mit CR aus Windows wird gelesen" {
  run _release_flags "$(_repo_with_dockerfile Dockerfile.dev '# onboard:release=true\r\n')"
  [ "$output" = '[true]' ]
}

@test "release=true mit Leerzeichen dahinter wird gelesen" {
  run _release_flags "$(_repo_with_dockerfile Dockerfile.dev '# onboard:release=true \n')"
  [ "$output" = '[true]' ]
}

@test "release=false mit Text dahinter ist ungueltig, Default gilt" {
  run _release_flags "$(_repo_with_dockerfile Dockerfile '# onboard:release=false-aber-doch-ja\n')"
  [ "$output" = '[true]' ]
}

@test "echtes release=false unterdrueckt die Auslieferung weiter" {
  run _release_flags "$(_repo_with_dockerfile Dockerfile '# onboard:release=false\n')"
  [ "$output" = '[false]' ]
}

@test "onboard:image mit CR aus Windows wird gelesen" {
  local d; d="$(_repo_with_dockerfile Dockerfile '# onboard:image=acme/svc\r\n')"
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$d' | jq -c '[.components[].dockerfiles[].image_name]'"
  [ "$output" = '["acme/svc"]' ]
}

# --- mehrdeutige Sprachsignale ----------------------------------------------
#
# Der Legacy-Modus brach dabei seit je ab; der --profile-json-Modus nahm still
# `.[0]` der erkannten Sprachen. Gemessen an go.mod + pyproject.toml im
# Wurzelverzeichnis: primary_language=go, warnings=[], und die gerenderte ci.yml
# trug lint-go-root und test-go-root — die Python-Haelfte fiel ersatzlos weg,
# ohne ein Wort. Der Go-Detektor bricht an derselben Stelle ab; damit entschied
# der Schalter `use_go_cli` darueber, ob so ein Repo ueberhaupt onboardbar ist.

@test "mehrdeutige Sprachsignale brechen auch im JSON-Modus ab" {
  run bash "$REPO_ROOT/scripts/onboard-detect.sh" --profile-json "$FIX/ambiguous"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous language signals: go python"* ]]
}

@test "eindeutige Signale bleiben im JSON-Modus unberuehrt" {
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$FIX/go-repo' | jq -r '.components[0].primary_language'"
  [ "$status" -eq 0 ]
  [ "$output" = "go" ]
}

# --- verwaiste Dockerfiles in Unterverzeichnissen ---------------------------
#
# Der Go-Detektor meldet sie seit je, diese Engine nicht. Der Adopter erfuhr
# also je nach onboardender Engine, dass zwei seiner Images stillschweigend
# nicht gebaut werden — oder eben nicht.

@test "nicht zugeordnete Dockerfiles in Unterverzeichnissen werden gemeldet" {
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$FIX/go-root-subdir-dockerfile' | jq -r '.warnings[].code'"
  [ "$status" -eq 0 ]
  [ "$output" = "subdir_dockerfiles_unassigned" ]
}

@test "ein Dockerfile im Wurzelverzeichnis loest die Warnung nicht aus" {
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$FIX/multi-dockerfile' | jq -c '[.warnings[].code]'"
  [ "$output" = '[]' ]
}

# Der Aufrufer darf den Pfad mit Schraegstrich am Ende uebergeben. Ohne
# Normalisierung schlug der Praefix-Schnitt fehl und JEDES Dockerfile galt als
# "in einem Unterverzeichnis" — auch das im Wurzelverzeichnis.
@test "ein Schraegstrich am Ende des Repo-Pfads aendert nichts" {
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$FIX/multi-dockerfile/' | jq -c '[.warnings[].code]'"
  [ "$output" = '[]' ]
}

# --- language_override muss das Profil erreichen ----------------------------
#
# Der Eingang ist beschrieben als "auto = detect, otherwise force release-type".
# Er setzte aber nur die Legacy-Zeilen; das Profil, aus dem gerendert wird,
# blieb unberuehrt (Audit H-6, Bash-Zwilling zu B-4). Gemessen an einem go-Repo
# mit Override `python` trug release-please-config.json weiter
# `"release-type": "go"` — fuer alles, was der Adopter hinterher sieht, war der
# Schalter ein stiller Leerlauf.

_profile_of() {  # <repo> <override>
  bash "$REPO_ROOT/scripts/onboard-detect.sh" --emit-both "$1" "$2" \
    | sed -n '/^profile_json<</,$p' | sed '1d;$d'
}

@test "erzwungener Release-Typ landet im Profil" {
  run bash -c "$(declare -f _profile_of); REPO_ROOT='$REPO_ROOT'; _profile_of '$FIX/go-repo' python | jq -r '.components[0].release_please_type'"
  [ "$output" = "python" ]
}

@test "erzwungener Typ laesst primary_language in Ruhe" {
  # Wuerde der Schalter auch die Sprachwahl erzwingen, rendere ein erzwungenes
  # `python` auf einem reinen Go-Repo Python-Jobs gegen ein Repo ohne
  # pyproject.toml.
  run bash -c "$(declare -f _profile_of); REPO_ROOT='$REPO_ROOT'; _profile_of '$FIX/go-repo' python | jq -r '.components[0].primary_language'"
  [ "$output" = "go" ]
}

@test "auto laesst den erkannten Typ unveraendert" {
  run bash -c "$(declare -f _profile_of); REPO_ROOT='$REPO_ROOT'; _profile_of '$FIX/go-repo' auto | jq -r '.components[0].release_please_type'"
  [ "$output" = "go" ]
}

@test "flutter wird auf dart abgebildet, wie im Legacy-Pfad" {
  run bash -c "$(declare -f _profile_of); REPO_ROOT='$REPO_ROOT'; _profile_of '$FIX/go-repo' flutter | jq -r '.components[0].release_please_type'"
  [ "$output" = "dart" ]
}

@test "ohne Wurzelkomponente warnt der Schalter, statt stumm zu bleiben" {
  run bash -c "$(declare -f _profile_of); REPO_ROOT='$REPO_ROOT'; _profile_of '$FIX/monorepo-go' python | jq -c '{w:[.warnings[].code],t:[.components[].release_please_type]}'"
  [[ "$output" == *"language_override_not_applied"* ]]
  [[ "$output" != *'"python"'* ]]
}

# --- pnpm-workspace.yaml in Flow-Schreibweise (Audit H-9) -------------------
#
# `packages: ["apps/*"]` ist gueltiges YAML und bedeutet dasselbe wie die
# Block-Form. Gelesen wurde nur die Block-Form — der Kommentar im Code nannte
# die Flow-Form sogar als Beispiel und beschrieb damit, was er NICHT tat.
# Gemessen: das Monorepo fiel lautlos zu einer einzigen Wurzelkomponente
# zusammen, ohne Jobs je Paket.

_pnpm_repo() {  # <workspace-inhalt>
  local dir="$BATS_TEST_TMPDIR/pnpm"
  rm -rf "$dir"; mkdir -p "$dir/apps/web" "$dir/apps/api"
  printf '{"name":"root"}\n' > "$dir/package.json"
  printf '{"name":"web"}\n' > "$dir/apps/web/package.json"
  printf '{"name":"api"}\n' > "$dir/apps/api/package.json"
  printf '%b' "$1" > "$dir/pnpm-workspace.yaml"
  echo "$dir"
}

_paths_of() {
  bash "$REPO_ROOT/scripts/onboard-detect.sh" --profile-json "$1" \
    | jq -c '[.components[].path] | sort'
}

@test "pnpm Block-Schreibweise ergibt zwei Komponenten" {
  run _paths_of "$(_pnpm_repo 'packages:\n  - apps/*\n')"
  [ "$output" = '["apps/api","apps/web"]' ]
}

@test "pnpm Flow-Schreibweise ergibt dieselben zwei Komponenten" {
  run _paths_of "$(_pnpm_repo 'packages: ["apps/*"]\n')"
  [ "$output" = '["apps/api","apps/web"]' ]
}

@test "pnpm Flow mit einfachen Anfuehrungszeichen" {
  run _paths_of "$(_pnpm_repo "packages: ['apps/*']\n")"
  [ "$output" = '["apps/api","apps/web"]' ]
}

@test "pnpm Flow ueber mehrere Zeilen" {
  run _paths_of "$(_pnpm_repo 'packages: [\n  "apps/web",\n  "apps/api"\n]\n')"
  [ "$output" = '["apps/api","apps/web"]' ]
}

# --- Komponenten drei Ebenen tief (Audit B-12) ------------------------------
#
# Der Go-Detektor begrenzt das Komponenten-VERZEICHNIS auf drei Ebenen
# (fallbackMarkerPaths: depth <= 3); `find` hier begrenzte die gefundene DATEI
# auf drei — also das Verzeichnis auf zwei. Gemessen an
# services/team-a/api/go.mod: Go fand beide Komponenten, diese Engine
# kollabierte das Repo auf ["."].

_nested_repo() {  # <tiefe: 3|4>
  local dir="$BATS_TEST_TMPDIR/nested"
  rm -rf "$dir"
  if [[ "$1" == "3" ]]; then
    mkdir -p "$dir/services/team-a/api" "$dir/services/team-b/worker"
    printf 'module a\ngo 1.22\n' > "$dir/services/team-a/api/go.mod"
    printf 'module b\ngo 1.22\n' > "$dir/services/team-b/worker/go.mod"
  else
    mkdir -p "$dir/a/b/c/d" "$dir/a/b/c/e"
    printf 'module d\ngo 1.22\n' > "$dir/a/b/c/d/go.mod"
    printf 'module e\ngo 1.22\n' > "$dir/a/b/c/e/go.mod"
  fi
  echo "$dir"
}

@test "Komponenten drei Ebenen tief werden gefunden" {
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$(_nested_repo 3)' | jq -c '[.components[].path]|sort'"
  [ "$output" = '["services/team-a/api","services/team-b/worker"]' ]
}

@test "vier Ebenen bleiben ausserhalb der Grenze, wie im Go-Detektor" {
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$(_nested_repo 4)' | jq -c '[.components[].path]'"
  [ "$output" = '["."]' ]
}

# Ein Schraegstrich am Ende des Repo-Pfads darf nichts aendern. `${p#"$repo"/}`
# stand an vier Stellen woertlich; endet $repo auf `/`, wird das Muster zu `//`
# und passt nicht mehr — die Komponenten trugen dann ihren vollen Pfad. Dieser
# Zweig ist der einzige, den keine bestehende Fixture durchlief.
@test "Schraegstrich am Ende aendert die Komponentenpfade nicht" {
  local d; d="$(_nested_repo 3)"
  run bash -c "bash '$REPO_ROOT/scripts/onboard-detect.sh' --profile-json '$d/' | jq -c '[.components[].path]|sort'"
  [ "$output" = '["services/team-a/api","services/team-b/worker"]' ]
}

# Audit I-14: `find … 2>/dev/null | sort` in einer Prozesssubstitution verschluckte
# die Fehlermeldung UND den Exit-Status. `find` bricht bei einem unlesbaren
# Verzeichnis nicht ab — es meldet non-zero und gibt trotzdem aus, was es fand.
# Aus einem TEILergebnis wurde ein vollstaendiges: Komponenten fehlten im Profil,
# ohne dass irgendwo etwas davon stand.
#
# Die Go-Engine macht es ueber fsErrors.note laengst richtig; das hier zieht nach.
@test "unreadable directory becomes a path_unreadable warning, not silence" {
  # root: das Verzeichnis waere lesbar und der Test wuerde nichts pruefen.
  [ "$(id -u)" -ne 0 ] || skip "als root ist kein Verzeichnis unlesbar"

  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/services/api" "$repo/services/geheim"
  printf 'module example.com/api\n' > "$repo/services/api/go.mod"
  printf 'module example.com/worker\n' > "$repo/services/geheim/go.mod"
  printf 'FROM scratch\n' > "$repo/services/api/Dockerfile"
  chmod 000 "$repo/services/geheim"

  run "$DETECT" --profile-json "$repo"
  local rc="$status" out="$output"
  chmod 755 "$repo/services/geheim"   # sonst scheitert das Aufraeumen
  [ "$rc" -eq 0 ] || { echo "$out"; false; }

  # 1. Die Warnung existiert und nennt den KONKRETEN Pfad — so wie Go
  #    (fsErrors.note), nicht bloss die Suchwurzel.
  local codes paths
  codes="$(jq -r '[.warnings[].code] | join(",")' <<<"$out")"
  [[ "$codes" == *"path_unreadable"* ]] || { echo "warnings: $out"; false; }
  paths="$(jq -r '[.warnings[] | select(.code=="path_unreadable") | .path] | join(",")' <<<"$out")"
  [ "$paths" = "services/geheim" ]

  # 2. Kein absoluter Runner-Pfad in der Meldung: sie landet im Profil und
  #    damit im Onboarding-PR-Text.
  jq -e '[.warnings[] | select(.message | test("^/|/Users/|/home/|/tmp/"))] | length == 0' <<<"$out" >/dev/null

  # 3. Das Teilergebnis bleibt erhalten — die lesbare Komponente ist da.
  #    Der Fund ist nicht "find schlaegt fehl", sondern "der Fehlschlag war
  #    unsichtbar".
  jq -e '[.components[].path] | index("services/api") != null' <<<"$out" >/dev/null
}

# Der erste Anlauf zu I-14 war lokal gruen und fiel in der self-CI um: GNU find
# (Linux) zitiert den Pfad in seiner Fehlerzeile, BSD find (macOS) nicht. Die
# Anfuehrungszeichen wanderten in den Pfad, und aus `services/geheim` wurde
# `'/…/services/geheim'`.
#
# Deshalb hier beide Formen gegen die ausgelagerte Funktion — ohne dass die
# Plattform des Testlaufs mitentscheidet, welcher Fall geprueft wird.
@test "find error paths are unquoted the same way on GNU and BSD" {
  source "$REPO_ROOT/scripts/lib/onboard-detect-lib.sh"

  # BSD find: unzitiert
  [ "$(_find_err_unquote "/repo/services/geheim")" = "/repo/services/geheim" ]
  # GNU find unter LC_ALL=C: ASCII-Apostrophe
  [ "$(_find_err_unquote "'/repo/services/geheim'")" = "/repo/services/geheim" ]
  # GNU find ohne LC_ALL=C: typografische Anfuehrungszeichen
  [ "$(_find_err_unquote "$(printf '‘/repo/services/geheim’')")" = "/repo/services/geheim" ]
  # Ein Pfad, der selbst ein Apostroph enthaelt, darf nicht verstuemmelt werden.
  [ "$(_find_err_unquote "/repo/it's/da")" = "/repo/it's/da" ]
}


# Audit H-21 — GEMESSEN WIDERLEGT, und diese beiden Tests halten fest, warum.
#
# Der Fund sagt, zwei Aufrufe verschluckten den find-Fehler weiter roh mit
# `2>/dev/null`, waehrend I-14 nur die AUFZAEHL-Pfade auf _find_sorted
# umgestellt hat:
#
#   role()            -> Rolle cli/library
#   release_signals() -> chart_yaml (steuert den helm-publish-Job)
#
# Der Aufruf ist tatsaechlich roh. Die Wirkung ist es nicht: die
# Aufzaehlung laeuft dieselben Verzeichnisse ab und meldet sie mit dem
# KONKRETEN Pfad. Gemessen an einem Verzeichnis mit Modus 000:
#
#   cmd/ unlesbar      -> warnings[].path == ["cmd"]
#   charts/ unlesbar   -> warnings[].path == ["charts"]
#
# Ein Versuch, beide Stellen zusaetzlich ueber _find_sorted zu fuehren, wurde
# wieder zurueckgenommen: er aenderte am charts-Fall nichts und machte den
# cmd-Fall SCHLECHTER — [".","cmd"] statt ["cmd"], also eine zweite Warnung,
# die faelschlich die Repo-Wurzel als unlesbar ausweist.
#
# Was hier fehlte, war kein Fix, sondern der Test. Beide Faelle waren von
# keiner Zusicherung gedeckt; die Werte degradieren still (role faellt auf
# `library`, chart_yaml auf null), und nur die Warnung verraet den Grund.
# Genau das pinnen diese beiden Tests.
@test "unlesbares cmd/ kippt die Rolle, aber die Warnung nennt cmd" {
  [ "$(id -u)" -ne 0 ] || skip "als root ist kein Verzeichnis unlesbar"

  local repo="$BATS_TEST_TMPDIR/h21cmd"
  mkdir -p "$repo/cmd/tool"
  printf 'module example.com/x\n' > "$repo/go.mod"
  printf 'package main\nfunc main(){}\n' > "$repo/cmd/tool/main.go"
  chmod 000 "$repo/cmd"

  run "$DETECT" --profile-json "$repo"
  local rc="$status" out="$output"
  chmod 755 "$repo/cmd"
  [ "$rc" -eq 0 ] || { echo "$out"; false; }

  local paths
  paths="$(jq -r '[.warnings[] | select(.code=="path_unreadable") | .path] | join(",")' <<<"$out")"
  [[ "$paths" == *"cmd"* ]] || { echo "warnings nannten: $paths"; false; }
}

# Der schwerere der beiden: chart_yaml steuert den helm-publish-Job. Wurde das
# Unterverzeichnis unlesbar, entfiel der Job — das Chart wurde nie
# veroeffentlicht.
@test "unlesbares charts/ kostet chart_yaml, aber die Warnung nennt charts" {
  [ "$(id -u)" -ne 0 ] || skip "als root ist kein Verzeichnis unlesbar"

  local repo="$BATS_TEST_TMPDIR/h21chart"
  mkdir -p "$repo/charts/svc"
  printf 'module example.com/x\n' > "$repo/go.mod"
  printf 'apiVersion: v2\nname: svc\nversion: 0.1.0\n' > "$repo/charts/svc/Chart.yaml"
  chmod 000 "$repo/charts"

  run "$DETECT" --profile-json "$repo"
  local rc="$status" out="$output"
  chmod 755 "$repo/charts"
  [ "$rc" -eq 0 ] || { echo "$out"; false; }

  local paths
  paths="$(jq -r '[.warnings[] | select(.code=="path_unreadable") | .path] | join(",")' <<<"$out")"
  [[ "$paths" == *"charts"* ]] || { echo "warnings nannten: $paths"; false; }

  # Kein absoluter Runner-Pfad — die Meldung landet im Onboarding-PR-Text.
  jq -e '[.warnings[] | select(.message | test("^/|/Users/|/home/|/tmp/"))] | length == 0' <<<"$out" >/dev/null
}

# ---- iac/shell signal detection (Task 12) ----
#
# Bash-Zwilling zu TestIaCAndShellSignals / TestNoIaCOrShellSignalWhenAbsent
# in internal/app/detect/iac_shell_test.go. Beide Signale sind repo-weit und
# additiv - anders als gitops oben, das primary_language ueberschreibt. Ein
# Go-Service mit tofu/ bleibt ein Go-Service und bekommt trotzdem beide
# Schluessel. check-engine-parity.sh prueft, dass beide Engines hier exakt
# dasselbe Profil liefern.

@test "profile-json: iac-shell-repo attaches .iac.directories" {
  run "$DETECT" --profile-json "$FIX/iac-shell-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.iac.directories == ["tofu"]'
}

@test "profile-json: iac-shell-repo attaches .shell.paths as globs, not file lists" {
  run "$DETECT" --profile-json "$FIX/iac-shell-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.shell.paths == [".taskfiles/**/*.sh","scripts/**/*.sh"]'
}

@test "profile-json: iac-shell-repo stays a go component (signals are additive)" {
  run "$DETECT" --profile-json "$FIX/iac-shell-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "go"'
}

@test "profile-json: repo without .tf/.sh has neither .iac nor .shell key" {
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("iac") | not'
  echo "$output" | jq -e 'has("shell") | not'
}

@test "profile-json: iac/shell walk skips vendor/, node_modules/, .terraform/, .catalog/, .venv/, .task/" {
  local repo="$BATS_TEST_TMPDIR/signal-skip-dirs"
  mkdir -p "$repo/vendor" "$repo/node_modules" "$repo/.terraform" \
           "$repo/.catalog" "$repo/.venv" "$repo/.task"
  printf 'module example.com/x\n' > "$repo/go.mod"
  printf 'resource "null_resource" "x" {}\n' > "$repo/vendor/skip.tf"
  printf '#!/usr/bin/env bash\n' > "$repo/node_modules/skip.sh"
  printf 'resource "null_resource" "x" {}\n' > "$repo/.terraform/skip.tf"
  printf '#!/usr/bin/env bash\n' > "$repo/.catalog/skip.sh"
  printf '#!/usr/bin/env bash\n' > "$repo/.venv/skip.sh"
  printf '#!/usr/bin/env bash\n' > "$repo/.task/skip.sh"

  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("iac") | not'
  echo "$output" | jq -e 'has("shell") | not'
}

# Go sortiert bytewise (sort.Strings): "Infra" kommt vor "bootstrap". Ein
# lokalisiertes `sort -u` ohne LC_ALL=C stuft Grossbuchstaben anders ein und
# haette hier eine andere Reihenfolge geliefert als die Go-Engine — ein
# Paritaetsbruch, den check-engine-parity.sh nicht sieht, weil keine der 29
# Fixtures ein gemischt gross-/kleingeschriebenes oberstes Pfadsegment hat.
# Verifiziert auf dieser Maschine unter LC_ALL=en_US.UTF-8 (siehe Report):
#   LC_ALL=en_US.UTF-8 sort  -> bootstrap, Infra
#   LC_ALL=C           sort  -> Infra, bootstrap  (== Go)
@test "profile-json: iac.directories and shell.paths sort bytewise, not locale-aware" {
  local repo="$BATS_TEST_TMPDIR/locale-sort"
  mkdir -p "$repo/Infra" "$repo/bootstrap"
  printf 'module example.com/x\n' > "$repo/go.mod"
  printf 'resource "null_resource" "a" {}\n' > "$repo/Infra/main.tf"
  printf 'resource "null_resource" "b" {}\n' > "$repo/bootstrap/main.tf"
  printf '#!/usr/bin/env bash\necho a\n' > "$repo/Infra/a.sh"
  printf '#!/usr/bin/env bash\necho b\n' > "$repo/bootstrap/b.sh"

  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.iac.directories == ["Infra","bootstrap"]'
  echo "$output" | jq -e '.shell.paths == ["Infra/**/*.sh","bootstrap/**/*.sh"]'
}

# Zwilling von TestIaCSkipsChildModules in internal/app/detect/iac_shell_test.go.
# Ein Kindmodul ist kein Stack: `working_directories` ist als "ein Stack pro
# Zeile" dokumentiert, und im Modulordner liegt keine .terraform.lock.hcl —
# `init -lockfile=readonly` koennte dort gar nicht durchlaufen. Ohne den Filter
# meldeten beide Engines ["tofu","tofu/modules/server"].
@test "profile-json: iac.directories laesst Kindmodule (modules/) weg" {
  run "$DETECT" --profile-json "$FIX/iac-nested-module"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.iac.directories == ["tofu"]'
}

# Segmentgenau: `mymodules` und `modules-old` sind normale Verzeichnisnamen.
# Zwilling von TestIsChildModulePath.
@test "profile-json: der modules/-Filter greift segmentgenau" {
  local repo="$BATS_TEST_TMPDIR/module-segments"
  mkdir -p "$repo/tofu/modules/server" "$repo/tofu/mymodules" "$repo/tofu/modules-old"
  printf 'module example.com/x\n' > "$repo/go.mod"
  printf 'resource "null_resource" "a" {}\n' > "$repo/tofu/main.tf"
  printf 'resource "null_resource" "b" {}\n' > "$repo/tofu/modules/server/main.tf"
  printf 'resource "null_resource" "c" {}\n' > "$repo/tofu/mymodules/main.tf"
  printf 'resource "null_resource" "d" {}\n' > "$repo/tofu/modules-old/main.tf"

  run "$DETECT" --profile-json "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.iac.directories == ["tofu","tofu/modules-old","tofu/mymodules"]'
}

# Zwilling von TestSignalsIgnoreSymlinks. linked-only/ enthaelt AUSSCHLIESSLICH
# Symlinks — einen gueltigen und einen kaputten je Endung. Zaehlte eine Engine
# Symlinks mit, erschiene das Verzeichnis als Stack bzw. als Glob. Genau hier
# liefen die Engines auseinander: Gos WalkDir meldet einen Symlink-auf-Datei
# als Nicht-Verzeichnis, `find -type f` schliesst ihn aus.
@test "profile-json: Symlinks zaehlen weder fuer iac noch fuer shell" {
  run "$DETECT" --profile-json "$FIX/symlinked-signals"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.iac.directories == ["tofu"]'
  echo "$output" | jq -e '.shell.paths == ["scripts/**/*.sh"]'
  # Ein kaputter Symlink ist kein unlesbarer Pfad — geprueft wird der Typ des
  # Eintrags, nicht sein Ziel. Also auch keine Warnung.
  echo "$output" | jq -e '[.warnings[] | select(.code == "path_unreadable")] | length == 0'
}
