# Smarter Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `onboard.yml` to handle monorepos, multi-Dockerfile repos, libraries, CLIs, Helm-only repos, and mixed-language single components; add three new build atoms (`docker-build-multi`, `goreleaser`, `helm-publish`); add a weekly central drift-audit.

**Architecture:** Detection emits a structured `profile.json`; renderer uses gomplate to compose workflows from skeletons by conditionally including jobs; rendered files are tracked in `.github/onboard.lock.json` per adopter; a central drift-check workflow re-renders at the locked catalog version and compares hashes.

**Tech Stack:** Bash + `jq` + `yq` + `gomplate` for detection and rendering; bats for unit tests; actionlint + yamllint for static workflow checks; release-please for catalog releases.

**Spec:** `docs/superpowers/specs/2026-05-17-smarter-onboarding-design.md`

**Phasing:** Five phases, each independently mergeable. Phase 1 ships three new atoms. Phase 2 rebuilds detection. Phase 3 rebuilds rendering. Phase 4 rewires `onboard.yml` to consume them. Phase 5 adds the drift-audit.

---

## Phase 1 — New build atoms

These three atoms are independently useful and consumed by the new renderer in Phase 3. None of them depend on the onboarding pipeline.

### Task 1.1: `docker-build-multi.yml` skeleton + happy-path caller

**Files:**
- Create: `.github/workflows/docker-build-multi.yml`
- Create: `tests/callers/docker-build-multi-happy.yml`
- Create: `tests/fixtures/multi-image/Dockerfile`
- Create: `tests/fixtures/multi-image/Dockerfile.worker`

**Why:** Multi-image repos need one reusable workflow call to build N images, not N rendered jobs. The atom internally fans out a matrix over an `images` JSON input and calls `docker-build.yml` per image.

- [ ] **Step 1: Write the happy-path caller workflow**

```yaml
# tests/callers/docker-build-multi-happy.yml
name: docker-build-multi happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/docker-build-multi.yml'
      - 'tests/callers/docker-build-multi-happy.yml'
      - 'tests/fixtures/multi-image/**'
jobs:
  build:
    uses: ./.github/workflows/docker-build-multi.yml
    with:
      build_context: tests/fixtures/multi-image
      images: |
        [
          {"dockerfile": "Dockerfile",        "image_name": "fixture-api"},
          {"dockerfile": "Dockerfile.worker", "image_name": "fixture-worker"}
        ]
      push: false
    secrets: inherit
```

- [ ] **Step 2: Add minimal Dockerfiles for the fixture**

```dockerfile
# tests/fixtures/multi-image/Dockerfile
FROM scratch
COPY Dockerfile /
```

```dockerfile
# tests/fixtures/multi-image/Dockerfile.worker
FROM scratch
COPY Dockerfile.worker /
```

- [ ] **Step 3: Implement `docker-build-multi.yml`**

```yaml
# .github/workflows/docker-build-multi.yml
name: docker-build-multi
on:
  workflow_call:
    inputs:
      build_context:
        required: false
        type: string
        default: '.'
      images:
        required: true
        type: string
        # JSON array: [{"dockerfile": "...", "image_name": "..."}, ...]
      push:
        required: false
        type: boolean
        default: true
      runs_on:
        required: false
        type: string
        default: '["self-hosted", "Linux"]'
    secrets:
      ghcr_token:
        required: false

permissions:
  contents: read
  packages: write

jobs:
  parse:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.parse.outputs.matrix }}
    steps:
      - id: parse
        env:
          IMAGES: ${{ inputs.images }}
        run: |
          set -euo pipefail
          # Validate it parses and is a non-empty array
          count=$(echo "$IMAGES" | jq 'if type=="array" then length else -1 end')
          if [[ "$count" -le 0 ]]; then
            echo "::error::images input must be a non-empty JSON array"
            exit 1
          fi
          echo "matrix=$(echo "$IMAGES" | jq -c .)" >> "$GITHUB_OUTPUT"

  build:
    needs: parse
    strategy:
      fail-fast: false
      matrix:
        image: ${{ fromJSON(needs.parse.outputs.matrix) }}
    uses: ./.github/workflows/docker-build.yml
    with:
      build_context: ${{ inputs.build_context }}
      dockerfile: ${{ matrix.image.dockerfile }}
      image_name: ${{ matrix.image.image_name }}
      push: ${{ inputs.push }}
      runs_on: ${{ inputs.runs_on }}
    secrets: inherit
```

> NOTE: If the existing `docker-build.yml` does not have a `build_context` / `image_name` input today, this task assumes the renderer will pass single-image inputs the same way. If `docker-build.yml`'s actual input names differ, read it first and adjust the `with:` block to match — this is the only place the atom couples to the existing one.

- [ ] **Step 4: Static-check the new workflow locally**

```bash
actionlint .github/workflows/docker-build-multi.yml
yamllint -s .github/workflows/docker-build-multi.yml
```

Expected: both exit 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/docker-build-multi.yml \
        tests/callers/docker-build-multi-happy.yml \
        tests/fixtures/multi-image/
git commit -m "feat: add docker-build-multi.yml atom for multi-Dockerfile repos"
```

### Task 1.2: `docker-build-multi` failure-path caller

**Files:**
- Create: `tests/callers/docker-build-multi-fail.yml`

- [ ] **Step 1: Write the failure-path caller (must fail the matrix)**

```yaml
# tests/callers/docker-build-multi-fail.yml
name: docker-build-multi fail
on:
  workflow_dispatch:
jobs:
  build:
    uses: ./.github/workflows/docker-build-multi.yml
    with:
      build_context: tests/fixtures/multi-image
      images: '[]'   # empty array → parse job must fail with clear message
      push: false
    secrets: inherit
```

- [ ] **Step 2: Commit**

```bash
git add tests/callers/docker-build-multi-fail.yml
git commit -m "test: add docker-build-multi failure-path caller (empty images)"
```

### Task 1.3: `goreleaser.yml` atom

**Files:**
- Create: `.github/workflows/goreleaser.yml`
- Create: `tests/callers/goreleaser-happy.yml`
- Create: `tests/fixtures/cli-go-with-goreleaser/.goreleaser.yaml`
- Create: `tests/fixtures/cli-go-with-goreleaser/main.go`
- Create: `tests/fixtures/cli-go-with-goreleaser/go.mod`

**Why:** CLI repos release binaries, not container images. `goreleaser` is the established tool; this atom wraps it so the renderer can call it from `release.yml` without copying boilerplate to every adopter.

- [ ] **Step 1: Write the fixture project**

```
# tests/fixtures/cli-go-with-goreleaser/go.mod
module example.com/cli
go 1.22
```

```go
// tests/fixtures/cli-go-with-goreleaser/main.go
package main
func main() { println("hello") }
```

```yaml
# tests/fixtures/cli-go-with-goreleaser/.goreleaser.yaml
version: 2
builds:
  - id: cli
    main: ./main.go
    goos: [linux, darwin]
    goarch: [amd64, arm64]
archives:
  - format: tar.gz
```

- [ ] **Step 2: Write the happy-path caller**

```yaml
# tests/callers/goreleaser-happy.yml
name: goreleaser happy
on:
  workflow_dispatch:
jobs:
  release:
    uses: ./.github/workflows/goreleaser.yml
    with:
      working_directory: tests/fixtures/cli-go-with-goreleaser
      snapshot: true
    secrets: inherit
```

- [ ] **Step 3: Implement `goreleaser.yml`**

```yaml
# .github/workflows/goreleaser.yml
name: goreleaser
on:
  workflow_call:
    inputs:
      working_directory:
        required: false
        type: string
        default: '.'
      goreleaser_version:
        required: false
        type: string
        default: '~> v2'
      snapshot:
        required: false
        type: boolean
        default: false
      runs_on:
        required: false
        type: string
        default: '["self-hosted", "Linux"]'
    secrets:
      github_token:
        required: false

permissions:
  contents: write
  packages: write

jobs:
  release:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    defaults:
      run:
        working-directory: ${{ inputs.working_directory }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: actions/setup-go@v5
        with:
          go-version-file: ${{ inputs.working_directory }}/go.mod
          cache: true
      - uses: goreleaser/goreleaser-action@v6
        with:
          distribution: goreleaser
          version: ${{ inputs.goreleaser_version }}
          args: release --clean ${{ inputs.snapshot && '--snapshot' || '' }}
          workdir: ${{ inputs.working_directory }}
        env:
          GITHUB_TOKEN: ${{ secrets.github_token || secrets.GITHUB_TOKEN }}
```

- [ ] **Step 4: Static-check**

```bash
actionlint .github/workflows/goreleaser.yml
yamllint -s .github/workflows/goreleaser.yml
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/goreleaser.yml \
        tests/callers/goreleaser-happy.yml \
        tests/fixtures/cli-go-with-goreleaser/
git commit -m "feat: add goreleaser.yml atom for CLI binary releases"
```

### Task 1.4: `helm-publish.yml` atom

**Files:**
- Create: `.github/workflows/helm-publish.yml`
- Create: `tests/callers/helm-publish-happy.yml`
- Create: `tests/fixtures/helm-only/Chart.yaml`
- Create: `tests/fixtures/helm-only/values.yaml`

**Why:** Helm charts (standalone repos and service-with-chart repos) publish to OCI today via `helm/chart-releaser-action` or `helm push`. Atom wraps the OCI-push variant (simpler, no GitHub Pages dependency).

- [ ] **Step 1: Fixture chart**

```yaml
# tests/fixtures/helm-only/Chart.yaml
apiVersion: v2
name: fixture
version: 0.1.0
type: application
```

```yaml
# tests/fixtures/helm-only/values.yaml
{}
```

- [ ] **Step 2: Happy-path caller**

```yaml
# tests/callers/helm-publish-happy.yml
name: helm-publish happy
on:
  workflow_dispatch:
jobs:
  publish:
    uses: ./.github/workflows/helm-publish.yml
    with:
      chart_path: tests/fixtures/helm-only
      oci_registry: ghcr.io/serverkraken/test
      dry_run: true
    secrets: inherit
```

- [ ] **Step 3: Implement the atom**

```yaml
# .github/workflows/helm-publish.yml
name: helm-publish
on:
  workflow_call:
    inputs:
      chart_path:
        required: true
        type: string
      oci_registry:
        required: true
        type: string
        # e.g. ghcr.io/serverkraken/charts
      helm_version:
        required: false
        type: string
        default: 'v3.15.0'
      dry_run:
        required: false
        type: boolean
        default: false
      runs_on:
        required: false
        type: string
        default: '["self-hosted", "Linux"]'
    secrets:
      ghcr_token:
        required: false

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@v6
      - uses: azure/setup-helm@v4
        with:
          version: ${{ inputs.helm_version }}
      - name: helm lint
        run: helm lint "${{ inputs.chart_path }}"
      - name: helm package
        id: pkg
        run: |
          set -euo pipefail
          out=$(helm package "${{ inputs.chart_path }}" --destination /tmp/charts)
          file=$(echo "$out" | awk '{print $NF}')
          echo "file=$file" >> "$GITHUB_OUTPUT"
      - name: helm registry login
        if: ${{ !inputs.dry_run }}
        env:
          REG: ${{ inputs.oci_registry }}
          TOKEN: ${{ secrets.ghcr_token || secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          host="${REG%%/*}"
          echo "$TOKEN" | helm registry login "$host" -u "${{ github.actor }}" --password-stdin
      - name: helm push
        if: ${{ !inputs.dry_run }}
        env:
          FILE: ${{ steps.pkg.outputs.file }}
          REG: ${{ inputs.oci_registry }}
        run: helm push "$FILE" "oci://$REG"
      - name: Dry-run summary
        if: ${{ inputs.dry_run }}
        run: echo "DRY RUN — would push ${{ steps.pkg.outputs.file }} to oci://${{ inputs.oci_registry }}"
```

- [ ] **Step 4: Static-check**

```bash
actionlint .github/workflows/helm-publish.yml
yamllint -s .github/workflows/helm-publish.yml
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/helm-publish.yml \
        tests/callers/helm-publish-happy.yml \
        tests/fixtures/helm-only/
git commit -m "feat: add helm-publish.yml atom (OCI push)"
```

### Task 1.5: Document atoms in README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add new atoms to the "Available reusable workflows" table**

Find the existing atoms table in `README.md` and append three rows for `docker-build-multi.yml`, `goreleaser.yml`, `helm-publish.yml` with one-line descriptions matching the atom headers above.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: list new atoms (docker-build-multi, goreleaser, helm-publish)"
```

---

## Phase 2 — Detection rewrite (`profile.json`)

Replaces the four-key-value-line output with structured JSON. The old `language`/`release_type`/`current_version`/`default_branch` outputs of the action stay as derived fields for transitional compatibility, but the renderer in Phase 3 ignores them in favor of `profile.json`.

### Task 2.1: New monorepo + multi-component fixtures

**Files:**
- Create: `tests/fixtures/onboard/monorepo-go/go.work`
- Create: `tests/fixtures/onboard/monorepo-go/services/api/go.mod`
- Create: `tests/fixtures/onboard/monorepo-go/services/api/Dockerfile`
- Create: `tests/fixtures/onboard/monorepo-go/services/worker/go.mod`
- Create: `tests/fixtures/onboard/monorepo-go/services/worker/Dockerfile`
- Create: `tests/fixtures/onboard/multi-dockerfile/go.mod`
- Create: `tests/fixtures/onboard/multi-dockerfile/Dockerfile`
- Create: `tests/fixtures/onboard/multi-dockerfile/Dockerfile.worker`
- Create: `tests/fixtures/onboard/library-go/go.mod`
- Create: `tests/fixtures/onboard/cli-go-with-goreleaser/.goreleaser.yaml` (already from 1.3 — symlink or copy)
- Create: `tests/fixtures/onboard/service-with-helm/go.mod`
- Create: `tests/fixtures/onboard/service-with-helm/Dockerfile`
- Create: `tests/fixtures/onboard/service-with-helm/charts/svc/Chart.yaml`

- [ ] **Step 1: Build out fixtures (minimal content; presence is what detection reads)**

For each `go.mod`:
```
module example.com/<name>
go 1.22
```

For each `Dockerfile`:
```
FROM scratch
COPY Dockerfile /
```

For `Dockerfile.worker` in `multi-dockerfile` (test image-name override):
```
# onboard:image=custom-worker
FROM scratch
COPY Dockerfile.worker /
```

For `monorepo-go/go.work`:
```
go 1.22
use (
    ./services/api
    ./services/worker
)
```

For `service-with-helm/charts/svc/Chart.yaml`:
```
apiVersion: v2
name: svc
version: 0.1.0
type: application
```

For `library-go/go.mod`: same as others, but **no Dockerfile, no `cmd/`**.

For `cli-go-with-goreleaser`: copy or symlink from Phase 1.

- [ ] **Step 2: Commit fixtures**

```bash
git add tests/fixtures/onboard/
git commit -m "test: add monorepo / multi-image / library / service-with-helm fixtures"
```

### Task 2.2: TDD — `profile.json` skeleton for single service

**Files:**
- Modify: `tests/shell/onboard-detect.bats`
- Modify: `scripts/onboard-detect.sh`
- Create: `scripts/lib/onboard-detect-lib.sh` (extracted helpers; see below)

**Why this split:** the existing script is positional-arg + key=value output. We're switching to JSON. Doing it in one shot risks regression on the existing key=value tests. Strategy: add a `--profile-json` flag that emits the new format; once stable, flip the default and drop the old format in Phase 4.

- [ ] **Step 1: Add failing bats test**

Append to `tests/shell/onboard-detect.bats`:

```bash
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
  echo "$output" | jq -e '.components[0].role == "library"'
  # go-repo fixture has no Dockerfile → role=library
}
```

- [ ] **Step 2: Run the tests, watch them fail**

```bash
bats tests/shell/onboard-detect.bats -f "profile-json"
```

Expected: FAIL — `--profile-json` flag unknown.

- [ ] **Step 3: Implement minimal profile-json mode**

Rewrite the top of `scripts/onboard-detect.sh` to parse the flag and dispatch:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/onboard-detect-lib.sh
source "$SCRIPT_DIR/lib/onboard-detect-lib.sh"

PROFILE_JSON=0
if [[ "${1:-}" == "--profile-json" ]]; then
  PROFILE_JSON=1
  shift
fi

REPO_PATH="${1:-}"
LANG_OVERRIDE="${2:-auto}"

if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
  echo "::error::usage: $0 [--profile-json] <repo-path> [language-override]" >&2
  exit 1
fi

if [[ $PROFILE_JSON -eq 1 ]]; then
  emit_profile_json "$REPO_PATH"
  exit 0
fi

# === Legacy key=value path (unchanged from previous version) ===
# ... existing single-language detection logic untouched ...
```

And create `scripts/lib/onboard-detect-lib.sh` with the bare-minimum first cut:

```bash
#!/usr/bin/env bash
# onboard-detect-lib.sh — JSON profile builders.
# Sourced by scripts/onboard-detect.sh and tested via bats.

emit_profile_json() {
  local repo="$1"
  local target_repo="${TARGET_REPO:-}"
  local default_branch="main"
  local current_version="0.0.0"

  if [[ -n "$target_repo" ]]; then
    default_branch=$(gh api "/repos/$target_repo" -q '.default_branch' 2>/dev/null || echo "main")
    local tag
    tag=$(gh release list --repo "$target_repo" --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
    [[ -n "$tag" ]] && current_version="${tag#v}"
  fi

  local components
  components=$(detect_components "$repo")

  jq -n \
    --argjson schema_version 1 \
    --arg target_repo "$target_repo" \
    --arg default_branch "$default_branch" \
    --arg current_version "$current_version" \
    --argjson monorepo "$(echo "$components" | jq 'length > 1')" \
    --argjson components "$components" \
    --argjson legacy_ci "$(detect_legacy_ci "$repo")" \
    --argjson warnings '[]' \
    '{
      schema_version: $schema_version,
      target_repo: $target_repo,
      default_branch: $default_branch,
      current_version: $current_version,
      monorepo: $monorepo,
      components: $components,
      legacy_ci: $legacy_ci,
      warnings: $warnings
    }'
}

# Minimal first cut — single-component, ignores monorepo markers (added in 2.3).
detect_components() {
  local repo="$1"
  local langs
  langs=$(detect_languages "$repo" ".")
  local dockerfiles
  dockerfiles=$(inventory_dockerfiles "$repo" ".")
  local role
  role=$(detect_role "$repo" "." "$dockerfiles")
  local primary
  primary=$(echo "$langs" | jq -r '.[0] // "generic"')

  jq -n \
    --arg path "." \
    --argjson languages "$langs" \
    --arg primary "$primary" \
    --arg role "$role" \
    --argjson dockerfiles "$dockerfiles" \
    --argjson signals '{"goreleaser_config": null, "chart_yaml": null}' \
    '[{
      path: $path,
      languages: $languages,
      primary_language: $primary,
      release_please_type: $primary,
      role: $role,
      dockerfiles: $dockerfiles,
      release_signals: $signals
    }]'
}

detect_languages() {
  local repo="$1" path="$2"
  local p="$repo/$path"
  local out='[]'
  [[ -f "$p/go.mod" ]]         && out=$(echo "$out" | jq '. + ["go"]')
  [[ -f "$p/pyproject.toml" ]] && out=$(echo "$out" | jq '. + ["python"]')
  [[ -f "$p/Cargo.toml" ]]     && out=$(echo "$out" | jq '. + ["rust"]')
  [[ -f "$p/Chart.yaml" ]]     && out=$(echo "$out" | jq '. + ["helm"]')
  [[ -f "$p/package.json" ]]   && out=$(echo "$out" | jq '. + ["node"]')
  echo "$out"
}

inventory_dockerfiles() {
  local repo="$1" path="$2"
  local p="$repo/$path"
  local files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(find "$p" -maxdepth 1 -type f \( -name 'Dockerfile' -o -name 'Dockerfile.*' \) -printf '%f\n' 2>/dev/null | sort)
  local arr='[]'
  for f in "${files[@]}"; do
    local override
    override=$(read_image_override "$p/$f")
    local image_name image_source
    if [[ -n "$override" ]]; then
      image_name="$override"
      image_source="override"
    else
      image_name=$(derive_image_name "$f" "$path")
      image_source="derived"
    fi
    arr=$(echo "$arr" | jq \
      --arg path "$f" \
      --arg image_name "$image_name" \
      --arg image_name_source "$image_source" \
      '. + [{path: $path, image_name: $image_name, image_name_source: $image_name_source}]')
  done
  echo "$arr"
}

read_image_override() {
  local file="$1"
  # Look in first 5 lines for `# onboard:image=<name>`
  head -n 5 "$file" 2>/dev/null | grep -m1 -oE '^# onboard:image=[A-Za-z0-9._/-]+' | sed 's/^# onboard:image=//' || true
}

derive_image_name() {
  local filename="$1" path="$2"
  # path='.' → use just <repo>; sub-path → use last segment as suffix
  local suffix=""
  if [[ "$filename" == "Dockerfile" ]]; then
    suffix=""
  elif [[ "$filename" =~ ^Dockerfile\.(.+)$ ]]; then
    suffix="${BASH_REMATCH[1]}"
  fi
  if [[ "$path" == "." ]]; then
    if [[ -n "$suffix" ]]; then
      echo "\$REPO-$suffix"   # renderer substitutes \$REPO with repo name
    else
      echo "\$REPO"
    fi
  else
    local seg="${path##*/}"
    if [[ -n "$suffix" ]]; then
      echo "\$REPO-$seg-$suffix"
    else
      echo "\$REPO-$seg"
    fi
  fi
}

detect_role() {
  local repo="$1" path="$2" dockerfiles="$3"
  local p="$repo/$path"
  local has_docker
  has_docker=$(echo "$dockerfiles" | jq 'length > 0')
  if [[ "$has_docker" == "true" ]]; then
    echo "service"; return
  fi
  if [[ -f "$p/Chart.yaml" ]]; then
    echo "helm-app"; return
  fi
  # CLI heuristics
  if [[ -d "$p/cmd" ]] && find "$p/cmd" -mindepth 2 -maxdepth 2 -name 'main.go' -print -quit | grep -q .; then
    echo "cli"; return
  fi
  if [[ -f "$p/Cargo.toml" ]] && grep -q '^\[\[bin\]\]' "$p/Cargo.toml" 2>/dev/null; then
    echo "cli"; return
  fi
  if [[ -f "$p/pyproject.toml" ]] && grep -q '^\[project\.scripts\]\|^\[tool\.poetry\.scripts\]' "$p/pyproject.toml" 2>/dev/null; then
    echo "cli"; return
  fi
  echo "library"
}

detect_legacy_ci() {
  # Phase 2.6 fills this in; for now return [].
  echo '[]'
}
```

- [ ] **Step 4: Run the new tests, watch them pass**

```bash
bats tests/shell/onboard-detect.bats -f "profile-json"
```

Expected: PASS.

- [ ] **Step 5: Re-run the legacy tests, make sure they still pass**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: ALL PASS (legacy key=value path untouched).

- [ ] **Step 6: Commit**

```bash
git add scripts/onboard-detect.sh scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(detect): emit structured profile.json (single-component)"
```

### Task 2.3: Monorepo detection — `go.work` and fallback

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh`
- Modify: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write failing tests**

```bash
@test "profile-json: go.work monorepo enumerates components" {
  run "$DETECT" --profile-json "$FIX/monorepo-go"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.monorepo == true'
  echo "$output" | jq -e '.components | length == 2'
  echo "$output" | jq -e '[.components[].path] | sort == ["services/api","services/worker"]'
  echo "$output" | jq -e '.components[0].role == "service"'   # has Dockerfile
}

@test "profile-json: sub-dockerfiles without sub-markers fallback to monorepo" {
  # We don't have a dedicated fixture; build one inline:
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/services/api" "$tmpdir/services/worker"
  echo "FROM scratch" > "$tmpdir/services/api/Dockerfile"
  echo "FROM scratch" > "$tmpdir/services/worker/Dockerfile"

  run "$DETECT" --profile-json "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.monorepo == true'
  echo "$output" | jq -e '.components | length == 2'
  echo "$output" | jq -e '.components[0].release_please_type == "generic"'
  rm -rf "$tmpdir"
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/shell/onboard-detect.bats -f "monorepo"
```

- [ ] **Step 3: Replace `detect_components` with the multi-component version**

In `scripts/lib/onboard-detect-lib.sh`, replace `detect_components` with:

```bash
detect_components() {
  local repo="$1"

  # 1) Explicit monorepo markers
  local paths=()
  if [[ -f "$repo/go.work" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(awk '/^use \(/{flag=1;next}/^\)/{flag=0}flag{gsub(/[()"\t ]/,"");print}' "$repo/go.work" | sed 's|^\./||')
  elif [[ -f "$repo/Cargo.toml" ]] && grep -q '^\[workspace\]' "$repo/Cargo.toml" 2>/dev/null; then
    # Cargo workspace: members = [ "crates/a", "crates/b" ]  (single-line or multi-line)
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(awk '
      /^\[workspace\]/{flag=1; next}
      /^\[/ && !/^\[workspace\]/{flag=0}
      flag && /members[[:space:]]*=/{
        # capture everything between [ and ]
        capture=1
      }
      capture {
        line = line $0
        if (index($0, "]") > 0) {
          gsub(/.*\[|\].*/, "", line)
          n = split(line, arr, ",")
          for (i=1; i<=n; i++) {
            gsub(/[[:space:]"]/, "", arr[i])
            if (arr[i] != "") print arr[i]
          }
          capture=0; line=""
        }
      }
    ' "$repo/Cargo.toml")
  elif [[ -f "$repo/pnpm-workspace.yaml" ]]; then
    # packages: ["apps/*", "packages/foo"]  — expand globs against the repo
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      # Resolve glob relative to repo
      while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        rel="${d#$repo/}"
        paths+=("$rel")
      done < <(compgen -G "$repo/$pat" 2>/dev/null || true)
    done < <(awk '
      /^packages:/{flag=1; next}
      flag && /^[[:space:]]*-/{
        line=$0
        gsub(/.*-[[:space:]]*["'\''']?/, "", line)
        gsub(/["'\'']?[[:space:]]*$/, "", line)
        print line
      }
      flag && /^[^[:space:]-]/{flag=0}
    ' "$repo/pnpm-workspace.yaml")
  fi

  # 2) Fallback monorepo via multiple sub-markers
  if [[ ${#paths[@]} -eq 0 ]]; then
    while IFS= read -r m; do
      local d
      d=$(dirname "$m")
      # strip leading "$repo/"
      d="${d#$repo/}"
      [[ "$d" == "." ]] && continue
      paths+=("$d")
    done < <(find "$repo" -mindepth 2 -maxdepth 3 \( -name 'go.mod' -o -name 'pyproject.toml' -o -name 'Cargo.toml' -o -name 'Chart.yaml' \) 2>/dev/null | sort -u)
  fi

  # 3) Sub-Dockerfile fallback (no language markers but multiple sub-Dockerfiles)
  if [[ ${#paths[@]} -eq 0 ]]; then
    local sub_dockerfile_dirs=()
    while IFS= read -r f; do
      local d
      d=$(dirname "$f")
      d="${d#$repo/}"
      [[ "$d" == "." ]] && continue
      sub_dockerfile_dirs+=("$d")
    done < <(find "$repo" -mindepth 2 -maxdepth 3 -name 'Dockerfile' 2>/dev/null | sort -u)
    if [[ ${#sub_dockerfile_dirs[@]} -ge 2 ]]; then
      paths=("${sub_dockerfile_dirs[@]}")
    fi
  fi

  # 4) Single-component fallback
  if [[ ${#paths[@]} -eq 0 ]]; then
    paths=(".")
  fi

  # De-duplicate while preserving order
  declare -A seen=()
  local unique=()
  for p in "${paths[@]}"; do
    if [[ -z "${seen[$p]:-}" ]]; then
      seen[$p]=1
      unique+=("$p")
    fi
  done

  local arr='[]'
  for p in "${unique[@]}"; do
    local langs role dockerfiles primary signals
    langs=$(detect_languages "$repo" "$p")
    dockerfiles=$(inventory_dockerfiles "$repo" "$p")
    role=$(detect_role "$repo" "$p" "$dockerfiles")
    primary=$(echo "$langs" | jq -r '.[0] // "generic"')
    signals=$(detect_release_signals "$repo" "$p")

    arr=$(echo "$arr" | jq \
      --arg path "$p" \
      --argjson languages "$langs" \
      --arg primary "$primary" \
      --arg role "$role" \
      --argjson dockerfiles "$dockerfiles" \
      --argjson signals "$signals" \
      '. + [{
        path: $path,
        languages: $languages,
        primary_language: $primary,
        release_please_type: $primary,
        role: $role,
        dockerfiles: $dockerfiles,
        release_signals: $signals
      }]')
  done
  echo "$arr"
}

detect_release_signals() {
  local repo="$1" path="$2"
  local p="$repo/$path"
  local gorel="null"
  local chart="null"
  for f in .goreleaser.yaml .goreleaser.yml goreleaser.yaml; do
    if [[ -f "$p/$f" ]]; then
      gorel=$(printf '"%s/%s"' "$path" "$f")
      break
    fi
  done
  # Chart inside the component but not at component root (root Chart.yaml means role=helm-app)
  local found_chart
  found_chart=$(find "$p" -mindepth 2 -maxdepth 4 -name 'Chart.yaml' 2>/dev/null | head -n 1)
  if [[ -n "$found_chart" ]]; then
    local rel="${found_chart#$repo/}"
    chart=$(printf '"%s"' "$rel")
  fi
  echo "{\"goreleaser_config\": $gorel, \"chart_yaml\": $chart}"
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
bats tests/shell/onboard-detect.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(detect): monorepo enumeration (go.work, multi-marker, sub-Dockerfile fallbacks)"
```

### Task 2.4: TDD — image-name override + multi-Dockerfile

**Files:**
- Modify: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write failing tests**

```bash
@test "profile-json: multi-Dockerfile produces dockerfiles[] of length 2" {
  run "$DETECT" --profile-json "$FIX/multi-dockerfile"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].dockerfiles | length == 2'
}

@test "profile-json: Dockerfile.worker derived image gets suffix" {
  run "$DETECT" --profile-json "$FIX/multi-dockerfile"
  [ "$status" -eq 0 ]
  # Dockerfile → derived name = $REPO
  echo "$output" | jq -e '[.components[0].dockerfiles[] | select(.path=="Dockerfile") | .image_name_source] == ["derived"]'
  # Dockerfile.worker has `# onboard:image=custom-worker`
  echo "$output" | jq -e '[.components[0].dockerfiles[] | select(.path=="Dockerfile.worker") | .image_name] == ["custom-worker"]'
  echo "$output" | jq -e '[.components[0].dockerfiles[] | select(.path=="Dockerfile.worker") | .image_name_source] == ["override"]'
}
```

- [ ] **Step 2: Run; should already pass thanks to 2.2's `inventory_dockerfiles`**

```bash
bats tests/shell/onboard-detect.bats -f "Dockerfile"
```

Expected: PASS (logic is in place from Task 2.2).

If it fails, debug the `inventory_dockerfiles` function — usually a `find -printf` quirk on macOS vs Linux. (Bats CI runs on Linux; macOS dev can use `gfind` from coreutils as workaround.)

- [ ] **Step 3: Commit (tests-only)**

```bash
git add tests/shell/onboard-detect.bats
git commit -m "test(detect): cover multi-Dockerfile and image-name override"
```

### Task 2.5: TDD — role detection (`library` / `cli` / `helm-app`)

**Files:**
- Modify: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Failing tests**

```bash
@test "profile-json: library-go has role=library, no dockerfiles, no signals" {
  run "$DETECT" --profile-json "$FIX/library-go"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "library"'
  echo "$output" | jq -e '.components[0].dockerfiles | length == 0'
  echo "$output" | jq -e '.components[0].release_signals.goreleaser_config == null'
}

@test "profile-json: cli-go-with-goreleaser has role=cli and goreleaser signal" {
  run "$DETECT" --profile-json "$FIX/cli-go-with-goreleaser"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "cli"'
  echo "$output" | jq -e '.components[0].release_signals.goreleaser_config != null'
}

@test "profile-json: helm-chart fixture has role=helm-app" {
  run "$DETECT" --profile-json "$FIX/helm-chart"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "helm-app"'
}

@test "profile-json: service-with-helm has role=service AND chart signal" {
  run "$DETECT" --profile-json "$FIX/service-with-helm"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].role == "service"'
  echo "$output" | jq -e '.components[0].release_signals.chart_yaml | endswith("Chart.yaml")'
}
```

- [ ] **Step 2: Run; CLI test will likely fail (no `cmd/<name>/main.go` in fixture yet)**

```bash
bats tests/shell/onboard-detect.bats -f "role"
```

- [ ] **Step 3: Update the CLI fixture to have a CLI structure**

```bash
mkdir -p tests/fixtures/onboard/cli-go-with-goreleaser/cmd/cli
cat > tests/fixtures/onboard/cli-go-with-goreleaser/cmd/cli/main.go <<'EOF'
package main
func main() {}
EOF
```

- [ ] **Step 4: Run again, expect pass**

```bash
bats tests/shell/onboard-detect.bats -f "role"
```

- [ ] **Step 5: Commit**

```bash
git add tests/shell/onboard-detect.bats tests/fixtures/onboard/cli-go-with-goreleaser/cmd/
git commit -m "test(detect): role heuristic (library/cli/helm-app/service)"
```

### Task 2.6: Legacy-CI scan

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh`
- Modify: `tests/shell/onboard-detect.bats`
- Create: `tests/fixtures/onboard/legacy-ci/.github/workflows/build.yml`
- Create: `tests/fixtures/onboard/legacy-ci/.github/workflows/trivy.yml`
- Create: `tests/fixtures/onboard/legacy-ci/go.mod`

- [ ] **Step 1: Build legacy-ci fixture**

```yaml
# tests/fixtures/onboard/legacy-ci/.github/workflows/build.yml
name: build
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/build-push-action@v6
```

```yaml
# tests/fixtures/onboard/legacy-ci/.github/workflows/trivy.yml
name: trivy
on: [push]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: aquasecurity/trivy-action@master
```

```
module example.com/legacy
go 1.22
```

- [ ] **Step 2: Failing tests**

```bash
@test "profile-json: legacy_ci detects trivy-action and recommends trivy-fs replacement" {
  run "$DETECT" --profile-json "$FIX/legacy-ci"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.legacy_ci | length == 2'
  echo "$output" | jq -e '
    [.legacy_ci[] | select(.path == ".github/workflows/trivy.yml") | .replaced_by] | flatten | index("trivy-fs.yml") != null
  '
}

@test "profile-json: legacy_ci detects docker/build-push-action and recommends docker-build" {
  run "$DETECT" --profile-json "$FIX/legacy-ci"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    [.legacy_ci[] | select(.path == ".github/workflows/build.yml") | .replaced_by] | flatten | index("docker-build.yml") != null
  '
}
```

- [ ] **Step 3: Implement `detect_legacy_ci`**

Replace the placeholder in `scripts/lib/onboard-detect-lib.sh`:

```bash
detect_legacy_ci() {
  local repo="$1"
  local dir="$repo/.github/workflows"
  if [[ ! -d "$dir" ]]; then
    echo '[]'; return
  fi

  # Workflow files our renderer owns — skip these from legacy classification.
  # Synced with onboard-render.sh RENDERED file list.
  local OWNED=(ci.yml release.yml prerelease.yml cleanup.yml)

  local arr='[]'
  while IFS= read -r f; do
    local base
    base=$(basename "$f")
    local owned=0
    for o in "${OWNED[@]}"; do [[ "$base" == "$o" ]] && owned=1; done
    [[ $owned -eq 1 ]] && continue

    local summary="" replacements='[]'
    if grep -q 'aquasecurity/trivy-action' "$f" 2>/dev/null; then
      summary="trivy-action (deprecated); replace with trivy-fs.yml or trivy-image.yml"
      replacements='["trivy-fs.yml","trivy-image.yml"]'
    elif grep -q 'docker/build-push-action' "$f" 2>/dev/null; then
      summary="docker/build-push-action; replaced by docker-build.yml"
      replacements='["docker-build.yml"]'
    elif grep -qE 'docker (build|buildx).*--push|docker push ' "$f" 2>/dev/null; then
      summary="ad-hoc docker buildx + push; replaced by docker-build.yml"
      replacements='["docker-build.yml"]'
    elif grep -q 'semantic-release' "$f" 2>/dev/null; then
      summary="hand-rolled semantic-release; replaced by release-please.yml"
      replacements='["release-please.yml"]'
    else
      summary="unrecognized legacy workflow; manual review needed"
    fi

    local rel="${f#$repo/}"
    arr=$(echo "$arr" | jq \
      --arg path "$rel" \
      --arg summary "$summary" \
      --argjson replaced_by "$replacements" \
      '. + [{path: $path, summary: $summary, replaced_by: $replaced_by}]')
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
  echo "$arr"
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
bats tests/shell/onboard-detect.bats -f "legacy_ci"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats tests/fixtures/onboard/legacy-ci/
git commit -m "feat(detect): legacy-CI scan emits replacement suggestions"
```

### Task 2.7: Update `actions/onboard-detect/action.yml` to surface profile.json

**Files:**
- Modify: `actions/onboard-detect/action.yml`

- [ ] **Step 1: Add `profile_json` output to the action**

```yaml
# actions/onboard-detect/action.yml — add to outputs:
outputs:
  language:
    description: 'Detected language (legacy)'
    value: ${{ steps.detect.outputs.language }}
  release_type:
    description: 'release-please release-type (legacy)'
    value: ${{ steps.detect.outputs.release_type }}
  current_version:
    description: 'Current version without leading v'
    value: ${{ steps.detect.outputs.current_version }}
  default_branch:
    description: 'Default branch of target_repo'
    value: ${{ steps.detect.outputs.default_branch }}
  profile_json:
    description: 'Full structured detection profile (JSON-encoded)'
    value: ${{ steps.detect.outputs.profile_json }}
```

And replace the `run:` block with one that produces both:

```yaml
runs:
  using: composite
  steps:
    - id: detect
      shell: bash
      env:
        TARGET_REPO: ${{ inputs.target_repo }}
        GH_TOKEN: ${{ inputs.github_token }}
      run: |
        set -euo pipefail
        # Legacy outputs (existing behavior)
        "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" \
          "${{ inputs.repo_path }}" \
          "${{ inputs.language_override }}" \
          >> "$GITHUB_OUTPUT"
        # Structured profile (new)
        profile=$("$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --profile-json "${{ inputs.repo_path }}")
        # GH action multi-line output
        {
          echo "profile_json<<EOF"
          echo "$profile"
          echo "EOF"
        } >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Run actionlint on the action**

```bash
actionlint actions/onboard-detect/action.yml
```

- [ ] **Step 3: Commit**

```bash
git add actions/onboard-detect/action.yml
git commit -m "feat(detect-action): surface profile_json output alongside legacy fields"
```

---

## Phase 3 — Renderer rewrite (gomplate + lock file)

Replaces `sed`-based templating with gomplate. Same six rendered files for now; structure-driven differences (multi-image, library, etc.) come in 3.4–3.6.

### Task 3.1: Install `gomplate` in CI

**Files:**
- Modify: `.github/workflows/validate.yml` (or wherever bats runs)
- Create: `scripts/install-gomplate.sh`

- [ ] **Step 1: Pin a gomplate version**

```bash
# scripts/install-gomplate.sh
#!/usr/bin/env bash
set -euo pipefail
VERSION="${GOMPLATE_VERSION:-v3.11.7}"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
esac
URL="https://github.com/hairyhenderson/gomplate/releases/download/${VERSION}/gomplate_${OS}-${ARCH}"
DEST="${DEST:-/usr/local/bin/gomplate}"
curl -fsSL "$URL" -o "$DEST"
chmod +x "$DEST"
"$DEST" --version
```

- [ ] **Step 2: Wire it into `validate.yml` before bats runs**

In `.github/workflows/validate.yml` add a step before bats:
```yaml
- name: Install gomplate
  run: sudo ./scripts/install-gomplate.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/install-gomplate.sh .github/workflows/validate.yml
git commit -m "build: install gomplate in CI for renderer tests"
```

### Task 3.2: Skeleton templates (single-component service first)

**Files:**
- Create: `docs/adopter-templates/skeletons/ci.yml.tmpl`
- Create: `docs/adopter-templates/skeletons/release.yml.tmpl`
- Create: `docs/adopter-templates/skeletons/prerelease.yml.tmpl`
- Create: `docs/adopter-templates/skeletons/cleanup.yml.tmpl`
- Create: `docs/adopter-templates/configs/release-please-config.json.tmpl` (rewrite)
- Create: `docs/adopter-templates/configs/release-please-config.monorepo.json.tmpl`
- Create: `docs/adopter-templates/configs/release-please-manifest.json.tmpl` (rewrite)

- [ ] **Step 1: Port today's `release.yml` to a gomplate template**

```yaml
# docs/adopter-templates/skeletons/release.yml.tmpl
{{- $pin := .pin -}}
{{- $c := index .profile.components 0 -}}
name: release
on:
  push:
    branches: [{{ .profile.default_branch }}]

permissions:
  contents: write
  packages: write
  pull-requests: write

jobs:
  release-please:
    uses: serverkraken/reusable-workflows/.github/workflows/release-please.yml@{{ $pin }}
    secrets: inherit

  {{- if eq (len $c.dockerfiles) 1 }}
  docker-build:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@{{ $pin }}
    with:
      dockerfile: {{ (index $c.dockerfiles 0).path }}
      image_name: {{ (index $c.dockerfiles 0).image_name }}
    secrets: inherit
  {{- else if gt (len $c.dockerfiles) 1 }}
  docker-build:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build-multi.yml@{{ $pin }}
    with:
      images: |
        {{ $c.dockerfiles | toJSON }}
    secrets: inherit
  {{- end }}

  {{- if $c.release_signals.goreleaser_config }}
  goreleaser:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: serverkraken/reusable-workflows/.github/workflows/goreleaser.yml@{{ $pin }}
    secrets: inherit
  {{- end }}

  {{- if $c.release_signals.chart_yaml }}
  helm-publish:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: serverkraken/reusable-workflows/.github/workflows/helm-publish.yml@{{ $pin }}
    with:
      chart_path: {{ dir $c.release_signals.chart_yaml }}
      oci_registry: ghcr.io/{{ .profile.target_repo }}/charts
    secrets: inherit
  {{- end }}
```

> Implementer note: gomplate's `dir` filter is available on `path` package; if it isn't auto-imported, gomplate exposes it as `{{ path.Dir x }}`. Check gomplate docs and adjust.

- [ ] **Step 2: Port `ci.yml.tmpl`** (PR-time scans + lint)

Start from `docs/adopter-templates/ci.yml`. Replace static parts with template substitution where needed (mostly `@{{ $pin }}` swaps). For monorepo support in 3.5, this gets wrapped in a `range`.

- [ ] **Step 3: Port `prerelease.yml.tmpl` and `cleanup.yml.tmpl` similarly** (mostly `@v1 → @{{ $pin }}` substitutions, no conditional jobs yet).

- [ ] **Step 4: Port config templates**

```json
// docs/adopter-templates/configs/release-please-config.json.tmpl
{
  "release-type": "{{ (index .profile.components 0).release_please_type }}",
  "packages": {
    ".": {
      "release-type": "{{ (index .profile.components 0).release_please_type }}"
    }
  }
}
```

```json
// docs/adopter-templates/configs/release-please-config.monorepo.json.tmpl
{
  "packages": {
    {{- $first := true }}
    {{- range .profile.components }}
    {{- if not $first }},{{ end }}
    {{- $first = false }}
    "{{ .path }}": {
      "release-type": "{{ .release_please_type }}",
      "package-name": "{{ .path }}"
    }
    {{- end }}
  }
}
```

```json
// docs/adopter-templates/configs/release-please-manifest.json.tmpl
{
  {{- $first := true }}
  {{- range .profile.components }}
  {{- if not $first }},{{ end }}
  {{- $first = false }}
  "{{ .path }}": "{{ $.profile.current_version }}"
  {{- end }}
}
```

- [ ] **Step 5: Commit**

```bash
git add docs/adopter-templates/skeletons/ docs/adopter-templates/configs/
git commit -m "feat(templates): gomplate skeletons for service / multi-image / monorepo"
```

### Task 3.3: Renderer script using gomplate + lock file

**Files:**
- Modify: `scripts/onboard-render.sh`
- Modify: `actions/onboard-render/action.yml`
- Modify: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Failing bats test for the new signature**

```bash
# tests/shell/onboard-render.bats — replace existing test driver
setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  DETECT="$REPO_ROOT/scripts/onboard-detect.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"
}

@test "render: single-service produces 6 expected files + lock" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/go-repo")
  echo "$profile" > "$tmp/profile.json"
  run "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ -f "$tmp/.github/workflows/ci.yml" ]
  [ -f "$tmp/.github/workflows/release.yml" ]
  [ -f "$tmp/.github/workflows/prerelease.yml" ]
  [ -f "$tmp/.github/workflows/cleanup.yml" ]
  [ -f "$tmp/release-please-config.json" ]
  [ -f "$tmp/.release-please-manifest.json" ]
  [ -f "$tmp/.github/onboard.lock.json" ]
  rm -rf "$tmp"
}

@test "render: lock file enumerates all rendered paths" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/go-repo")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  files=$(jq -r '.files | keys[]' "$tmp/.github/onboard.lock.json" | sort)
  expected=".github/workflows/ci.yml
.github/workflows/cleanup.yml
.github/workflows/prerelease.yml
.github/workflows/release.yml
.release-please-manifest.json
release-please-config.json"
  [ "$files" = "$expected" ]
  rm -rf "$tmp"
}

@test "render: lock file catalog_version matches pin argument" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/go-repo")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v3.1.4"
  v=$(jq -r '.catalog_version' "$tmp/.github/onboard.lock.json")
  [ "$v" = "v3.1.4" ]
  rm -rf "$tmp"
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/shell/onboard-render.bats -f "render:"
```

- [ ] **Step 3: Rewrite `onboard-render.sh`**

```bash
#!/usr/bin/env bash
# onboard-render.sh — render adopter templates via gomplate, write lock file.
#
# Usage: onboard-render.sh <catalog> <target> <profile-json> <pin-version>
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "::error::usage: $0 <catalog> <target> <profile-json-path> <pin-version>" >&2
  exit 2
fi

CATALOG="$1"
TARGET="$2"
PROFILE="$3"
PIN="$4"

if ! command -v gomplate >/dev/null 2>&1; then
  echo "::error::gomplate not installed; see scripts/install-gomplate.sh" >&2
  exit 1
fi

[[ -f "$PROFILE" ]] || { echo "::error::profile not found: $PROFILE" >&2; exit 1; }

# Determine if monorepo for config template selection.
MONOREPO=$(jq -r '.monorepo' "$PROFILE")

SKELETONS="$CATALOG/docs/adopter-templates/skeletons"
CONFIGS="$CATALOG/docs/adopter-templates/configs"

mkdir -p "$TARGET/.github/workflows"

render() {
  local src="$1" dst="$2"
  gomplate \
    -d "profile=$PROFILE" \
    -c "pin=$PIN" \
    -f "$src" \
    -o "$dst"
}

# Workflow skeletons (same set for all variants for now)
render "$SKELETONS/ci.yml.tmpl"         "$TARGET/.github/workflows/ci.yml"
render "$SKELETONS/release.yml.tmpl"    "$TARGET/.github/workflows/release.yml"
render "$SKELETONS/prerelease.yml.tmpl" "$TARGET/.github/workflows/prerelease.yml"
render "$SKELETONS/cleanup.yml.tmpl"    "$TARGET/.github/workflows/cleanup.yml"

# release-please config: single vs monorepo
if [[ "$MONOREPO" == "true" ]]; then
  render "$CONFIGS/release-please-config.monorepo.json.tmpl" "$TARGET/release-please-config.json"
else
  render "$CONFIGS/release-please-config.json.tmpl"          "$TARGET/release-please-config.json"
fi
render "$CONFIGS/release-please-manifest.json.tmpl" "$TARGET/.release-please-manifest.json"

# Substitute $REPO placeholder in image names (used by derive_image_name).
REPO_SHORT="${TARGET##*/}"
# release.yml might have literal $REPO from the lib; do a careful in-place swap.
for f in "$TARGET/.github/workflows/release.yml"; do
  if grep -q '\$REPO' "$f" 2>/dev/null; then
    sed -i.bak "s/\$REPO/${REPO_SHORT}/g" "$f" && rm -f "$f.bak"
  fi
done

# Write the lock file.
LOCK="$TARGET/.github/onboard.lock.json"
RENDERED=(
  ".github/workflows/ci.yml"
  ".github/workflows/release.yml"
  ".github/workflows/prerelease.yml"
  ".github/workflows/cleanup.yml"
  "release-please-config.json"
  ".release-please-manifest.json"
)

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
files_json='{}'
for f in "${RENDERED[@]}"; do
  [[ -f "$TARGET/$f" ]] || { echo "::error::expected rendered file missing: $f" >&2; exit 1; }
  sha=$(sha256sum "$TARGET/$f" | cut -d' ' -f1)
  files_json=$(echo "$files_json" | jq --arg k "$f" --arg v "sha256:$sha" '. + {($k): $v}')
done

jq -n \
  --argjson schema_version 1 \
  --arg catalog_version "$PIN" \
  --arg rendered_at "$now" \
  --argjson files "$files_json" \
  '{schema_version: $schema_version, catalog_version: $catalog_version, rendered_at: $rendered_at, files: $files}' \
  > "$LOCK"
```

- [ ] **Step 4: Update `actions/onboard-render/action.yml` to the new signature**

```yaml
# actions/onboard-render/action.yml
inputs:
  catalog_path:
    required: true
  target_path:
    required: true
  profile_json:
    description: 'profile_json output from onboard-detect'
    required: true
  pin_version:
    required: false
    default: 'v1'
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        set -euo pipefail
        tmp=$(mktemp)
        printf '%s' '${{ inputs.profile_json }}' > "$tmp"
        "${{ inputs.catalog_path }}/scripts/onboard-render.sh" \
          "${{ inputs.catalog_path }}" \
          "${{ inputs.target_path }}" \
          "$tmp" \
          "${{ inputs.pin_version }}"
```

- [ ] **Step 5: Run tests, expect pass**

```bash
bats tests/shell/onboard-render.bats -f "render:"
```

- [ ] **Step 6: Commit**

```bash
git add scripts/onboard-render.sh actions/onboard-render/action.yml tests/shell/onboard-render.bats
git commit -m "feat(render): gomplate-based renderer with lock file"
```

### Task 3.4: TDD — variant-aware rendering (multi-image / library / cli / service-with-helm)

**Files:**
- Modify: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Failing tests**

```bash
@test "render: multi-image service produces docker-build-multi reference" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/multi-dockerfile")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  grep -q "docker-build-multi.yml@v2" "$tmp/.github/workflows/release.yml"
  ! grep -q "docker-build.yml@v2" "$tmp/.github/workflows/release.yml"
  rm -rf "$tmp"
}

@test "render: library-go has no docker job" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/library-go")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  ! grep -q "docker-build" "$tmp/.github/workflows/release.yml"
  ! grep -q "trivy-image" "$tmp/.github/workflows/release.yml"
  rm -rf "$tmp"
}

@test "render: cli-go-with-goreleaser includes goreleaser job" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/cli-go-with-goreleaser")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  grep -q "goreleaser.yml@v2" "$tmp/.github/workflows/release.yml"
  rm -rf "$tmp"
}

@test "render: service-with-helm includes helm-publish job" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/service-with-helm")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  grep -q "helm-publish.yml@v2" "$tmp/.github/workflows/release.yml"
  grep -q "chart_path: charts/svc" "$tmp/.github/workflows/release.yml"
  rm -rf "$tmp"
}
```

- [ ] **Step 2: Run; depending on `release.yml.tmpl` conditional correctness, some may pass and some fail**

```bash
bats tests/shell/onboard-render.bats -f "render:"
```

If any fails, **fix `release.yml.tmpl`**, not the test. The template conditionals in Task 3.2 should already cover these; this task validates them on real fixture data.

- [ ] **Step 3: Commit**

```bash
git add tests/shell/onboard-render.bats docs/adopter-templates/skeletons/release.yml.tmpl
git commit -m "test(render): variant-aware rendering (multi-image/library/cli/helm)"
```

### Task 3.5: TDD — monorepo rendering

**Files:**
- Modify: `tests/shell/onboard-render.bats`
- Modify: `docs/adopter-templates/skeletons/release.yml.tmpl`
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl`

- [ ] **Step 1: Failing tests**

```bash
@test "render: monorepo-go produces release-please-config.json with packages map" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/monorepo-go")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  pkgs=$(jq -r '.packages | keys | sort | join(",")' "$tmp/release-please-config.json")
  [ "$pkgs" = "services/api,services/worker" ]
  rm -rf "$tmp"
}

@test "render: monorepo-go release.yml has per-component docker-build jobs" {
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/monorepo-go")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  grep -q "docker-build-services-api:" "$tmp/.github/workflows/release.yml"
  grep -q "docker-build-services-worker:" "$tmp/.github/workflows/release.yml"
  rm -rf "$tmp"
}
```

- [ ] **Step 2: Wrap the single-component logic in a `range`**

Update `docs/adopter-templates/skeletons/release.yml.tmpl` so that for `.profile.monorepo` it iterates over `.profile.components`:

```yaml
{{- $pin := .pin }}
{{- $monorepo := .profile.monorepo }}
name: release
on:
  push:
    branches: [{{ .profile.default_branch }}]
permissions:
  contents: write
  packages: write
  pull-requests: write
jobs:
  release-please:
    uses: serverkraken/reusable-workflows/.github/workflows/release-please.yml@{{ $pin }}
    secrets: inherit

{{ range $i, $c := .profile.components }}
{{- $slug := replaceAll "/" "-" $c.path -}}
{{- if eq $slug "." }}{{ $slug = "" }}{{ end }}
{{- $suffix := "" }}{{ if $slug }}{{ $suffix = printf "-%s" $slug }}{{ end }}

  {{- if eq (len $c.dockerfiles) 1 }}
  docker-build{{ $suffix }}:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@{{ $pin }}
    with:
      build_context: {{ $c.path }}
      dockerfile: {{ $c.path }}/{{ (index $c.dockerfiles 0).path }}
      image_name: {{ (index $c.dockerfiles 0).image_name }}
    secrets: inherit
  {{- else if gt (len $c.dockerfiles) 1 }}
  docker-build{{ $suffix }}:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build-multi.yml@{{ $pin }}
    with:
      build_context: {{ $c.path }}
      images: {{ $c.dockerfiles | toJSON }}
    secrets: inherit
  {{- end }}
{{ end }}
```

> Note: gomplate's stdlib has `replaceAll`; if not, swap to `strings.ReplaceAll`. Verify when running.

- [ ] **Step 3: Run, expect pass**

```bash
bats tests/shell/onboard-render.bats -f "monorepo"
```

- [ ] **Step 4: Commit**

```bash
git add docs/adopter-templates/skeletons/ tests/shell/onboard-render.bats
git commit -m "feat(render): monorepo support (per-component jobs + packages map)"
```

### Task 3.6: Golden-file fixtures + `UPDATE_GOLDEN` driver

**Files:**
- Modify: `tests/shell/onboard-render.bats`
- Create: `tests/fixtures/onboard/<scenario>/expected/...` for each scenario

- [ ] **Step 1: Add a driver helper**

```bash
# tests/shell/onboard-render.bats — append:
golden_check() {
  local fixture="$1"
  tmp=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/$fixture")
  echo "$profile" > "$tmp/profile.json"
  "$RENDER" "$REPO_ROOT" "$tmp" "$tmp/profile.json" "v2"
  rm "$tmp/profile.json"

  # Strip non-deterministic rendered_at from lock file before comparison.
  # The hashes (the actual reproducibility contract) stay in place.
  local lock="$tmp/.github/onboard.lock.json"
  if [[ -f "$lock" ]]; then
    jq 'del(.rendered_at)' "$lock" > "$lock.det" && mv "$lock.det" "$lock"
  fi

  if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
    rm -rf "$FIX/$fixture/expected"
    mkdir -p "$FIX/$fixture/expected"
    cp -R "$tmp/." "$FIX/$fixture/expected/"
    skip "UPDATE_GOLDEN — rewrote $fixture/expected"
  fi

  diff -r "$FIX/$fixture/expected" "$tmp"
  rm -rf "$tmp"
}

@test "golden: go-repo"              { golden_check "go-repo"; }
@test "golden: multi-dockerfile"     { golden_check "multi-dockerfile"; }
@test "golden: library-go"           { golden_check "library-go"; }
@test "golden: cli-go-with-goreleaser" { golden_check "cli-go-with-goreleaser"; }
@test "golden: service-with-helm"    { golden_check "service-with-helm"; }
@test "golden: monorepo-go"          { golden_check "monorepo-go"; }
```

- [ ] **Step 2: Bootstrap the expected files**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats -f "golden"
```

- [ ] **Step 3: Run again without UPDATE_GOLDEN, expect pass**

```bash
bats tests/shell/onboard-render.bats -f "golden"
```

- [ ] **Step 4: Visually sanity-check one or two expected outputs**

Open `tests/fixtures/onboard/monorepo-go/expected/.github/workflows/release.yml` and confirm the jobs look right (two `docker-build-...` jobs, `release-please` first, conditional on `release_created`).

- [ ] **Step 5: Commit**

```bash
git add tests/shell/onboard-render.bats tests/fixtures/onboard/*/expected/
git commit -m "test(render): golden-file fixtures with UPDATE_GOLDEN driver"
```

---

## Phase 4 — Wire `onboard.yml` to consume `profile.json`

### Task 4.1: Pass profile_json from detect to render

**Files:**
- Modify: `.github/workflows/onboard.yml`

- [ ] **Step 1: Replace the Render step with the new action contract**

In `.github/workflows/onboard.yml` find the `Render templates into target` step and change it to:

```yaml
- name: Render templates into target
  uses: ./.catalog/actions/onboard-render
  with:
    catalog_path: .catalog
    target_path: target
    profile_json: ${{ steps.detect.outputs.profile_json }}
    pin_version: ${{ inputs.pin_version }}
```

- [ ] **Step 2: Drop the now-unused detect outputs from later steps that only need `default_branch` / `language` / `current_version`**

The PR-A and result-artifact steps still use `steps.detect.outputs.default_branch` / `language` / `current_version`. Keep them — the detect action emits them in parallel with `profile_json` (Task 2.7).

- [ ] **Step 3: Actionlint**

```bash
actionlint .github/workflows/onboard.yml
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "refactor(onboard): pass profile_json from detect into render"
```

### Task 4.2: Richer PR body with detection report

**Files:**
- Modify: `.github/workflows/onboard.yml`

- [ ] **Step 1: Replace the `body=$(cat <<EOF…)` block in PR A with a profile-driven version**

Inside the `Branch A — ensure add-workflows PR` step, after staging, before composing `body`:

```bash
profile='${{ steps.detect.outputs.profile_json }}'
components_md=$(echo "$profile" | jq -r '
  .components[] |
  "- `\(.path)` — role=`\(.role)`, languages=\(.languages|join(",")), dockerfiles=\(.dockerfiles|length)"
')
warnings_md=$(echo "$profile" | jq -r '.warnings // [] | map("- " + .) | join("\n")')
legacy_md=$(echo "$profile" | jq -r '
  .legacy_ci // [] |
  map("- `\(.path)` — \(.summary) → replaced by \(.replaced_by|join(", "))") |
  join("\n")
')
```

And include those blocks in the heredoc PR body:

```bash
body=$(cat <<EOF
## Onboard to serverkraken/reusable-workflows@${PIN}

Renders the standard reusable-workflow consumer files plus a tracking
\`.github/onboard.lock.json\` so future drift can be detected centrally.

### Detected shape
${components_md}

${warnings_md:+#### Warnings
${warnings_md}
}

${legacy_md:+#### Legacy CI to retire (companion PR B)
${legacy_md}
}

After merging:
1. Push a \`feat:\` / \`fix:\` commit to \`${DEFAULT_BRANCH}\` — \`release.yml\` should open a release-please PR.
2. Merge that release-please PR. A release + image build + Trivy scan should run end-to-end.
3. Once one full release has run green, merge the companion cleanup PR (if open) to retire legacy workflow files.

_Opened by the \`onboard.yml\` workflow in \`serverkraken/reusable-workflows\`._
EOF
)
```

- [ ] **Step 2: Step summary upgrade — include the components table**

In the existing `Stage rendered files and log diff` step, after the existing diff summary, append:

```bash
echo "### Detected components" >> "$GITHUB_STEP_SUMMARY"
echo "$profile" | jq -r '.components[] |
  "| \(.path) | \(.role) | \(.languages|join(",")) | \(.dockerfiles|length) |"
' | sed '1i\
| Path | Role | Languages | Dockerfiles |
| --- | --- | --- | --- |
' >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 3: Actionlint**

```bash
actionlint .github/workflows/onboard.yml
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): richer PR body and step summary from profile_json"
```

### Task 4.3: Add `.github/onboard.lock.json` to PR A's RENDERED list

**Files:**
- Modify: `.github/workflows/onboard.yml`

- [ ] **Step 1: Update the RENDERED array**

```bash
RENDERED=(
  ".github/workflows/ci.yml"
  ".github/workflows/release.yml"
  ".github/workflows/prerelease.yml"
  ".github/workflows/cleanup.yml"
  ".github/onboard.lock.json"
  "release-please-config.json"
  ".release-please-manifest.json"
)
```

(One new entry.)

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/onboard.yml
git commit -m "feat(onboard): commit onboard.lock.json in PR A"
```

---

## Phase 5 — Drift-check

### Task 5.1: `onboard-drift.sh` + bats

**Files:**
- Create: `scripts/onboard-drift.sh`
- Create: `tests/shell/onboard-drift.bats`

- [ ] **Step 1: Failing bats tests**

```bash
#!/usr/bin/env bats
# tests/shell/onboard-drift.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  DRIFT="$REPO_ROOT/scripts/onboard-drift.sh"
  DETECT="$REPO_ROOT/scripts/onboard-detect.sh"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"

  # Build a "fake-onboarded" target into a tmpdir
  TARGET=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/go-repo")
  echo "$profile" > "$TARGET/profile.json"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  rm "$TARGET/profile.json"
  # Also copy fixture source into target so detect can re-run there
  cp -R "$FIX/go-repo/." "$TARGET/" 2>/dev/null || true
}

teardown() { rm -rf "$TARGET"; }

@test "drift: clean state reports clean" {
  CATALOG_CURRENT_VERSION=v2 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
}

@test "drift: hand-edit on ci.yml reports modified" {
  echo "# tampered" >> "$TARGET/.github/workflows/ci.yml"
  CATALOG_CURRENT_VERSION=v2 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=modified"* ]]
  [[ "$output" == *"ci.yml"* ]]
}

@test "drift: lock.catalog_version < current reports behind" {
  # Force lock to v1 to simulate adopter on older version
  jq '.catalog_version = "v1"' "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"
  CATALOG_CURRENT_VERSION=v2 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [[ "$output" == *"status=behind"* ]]
}

@test "drift: missing lock file reports no-lock" {
  rm "$TARGET/.github/onboard.lock.json"
  CATALOG_CURRENT_VERSION=v2 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [[ "$output" == *"status=no-lock"* ]]
}

@test "drift: re-render at locked catalog_version is byte-reproducible" {
  # Capture current rendered files' hashes
  before=$(jq -r '.files' "$TARGET/.github/onboard.lock.json")
  # Re-render into a fresh tmp using the same profile and pin
  re=$(mktemp -d)
  echo "$("$DETECT" --profile-json "$FIX/go-repo")" > "$re/profile.json"
  "$RENDER" "$REPO_ROOT" "$re" "$re/profile.json" "v2"
  for f in $(jq -r 'keys[]' <<< "$before"); do
    expected=$(jq -r --arg k "$f" '.[$k]' <<< "$before")
    actual="sha256:$(sha256sum "$re/$f" | cut -d' ' -f1)"
    [ "$expected" = "$actual" ]
  done
  rm -rf "$re"
}
```

- [ ] **Step 2: Implement the script**

```bash
#!/usr/bin/env bash
# onboard-drift.sh — compute drift status for a single adopter checkout.
#
# Usage: onboard-drift.sh <target-path> <catalog-path>
# Env:   CATALOG_CURRENT_VERSION  (string, e.g. "v2.0.4")
#
# Output (stdout key=value):
#   status=<clean|behind|modified|behind+modified|no-lock>
#   modified=<comma-separated paths>
#   lock_version=<...>
#   current_version=<...>
set -euo pipefail

TARGET="${1:-}"
CATALOG="${2:-}"
CURRENT="${CATALOG_CURRENT_VERSION:-}"

[[ -d "$TARGET" && -d "$CATALOG" ]] || { echo "::error::usage: $0 <target> <catalog>"; exit 1; }

LOCK="$TARGET/.github/onboard.lock.json"
if [[ ! -f "$LOCK" ]]; then
  echo "status=no-lock"
  exit 0
fi

lock_version=$(jq -r '.catalog_version' "$LOCK")
echo "lock_version=$lock_version"
[[ -n "$CURRENT" ]] && echo "current_version=$CURRENT"

behind=0
[[ -n "$CURRENT" && "$lock_version" != "$CURRENT" ]] && behind=1

modified_files=()
while IFS= read -r f; do
  expected=$(jq -r --arg k "$f" '.files[$k]' "$LOCK")
  if [[ ! -f "$TARGET/$f" ]]; then
    modified_files+=("$f(missing)")
    continue
  fi
  actual="sha256:$(sha256sum "$TARGET/$f" | cut -d' ' -f1)"
  [[ "$expected" != "$actual" ]] && modified_files+=("$f")
done < <(jq -r '.files | keys[]' "$LOCK")

is_mod=0
[[ ${#modified_files[@]} -gt 0 ]] && is_mod=1

if (( behind && is_mod ));    then status="behind+modified"
elif (( behind ));            then status="behind"
elif (( is_mod ));             then status="modified"
else                                status="clean"
fi
echo "status=$status"
echo "modified=$(IFS=,; echo "${modified_files[*]:-}")"
```

- [ ] **Step 3: Run, expect pass**

```bash
bats tests/shell/onboard-drift.bats
```

- [ ] **Step 4: Commit**

```bash
git add scripts/onboard-drift.sh tests/shell/onboard-drift.bats
git commit -m "feat(drift): onboard-drift.sh + bats coverage"
```

### Task 5.2: `actions/onboard-drift/action.yml`

**Files:**
- Create: `actions/onboard-drift/action.yml`

- [ ] **Step 1: Compose the action**

```yaml
name: 'Onboard: drift'
description: 'Compute drift status for a single adopter checkout.'
inputs:
  target_path:
    required: true
  catalog_path:
    required: true
  current_version:
    required: true
outputs:
  status:
    value: ${{ steps.drift.outputs.status }}
  modified:
    value: ${{ steps.drift.outputs.modified }}
  lock_version:
    value: ${{ steps.drift.outputs.lock_version }}
runs:
  using: composite
  steps:
    - id: drift
      shell: bash
      env:
        CATALOG_CURRENT_VERSION: ${{ inputs.current_version }}
      run: |
        "${{ inputs.catalog_path }}/scripts/onboard-drift.sh" \
          "${{ inputs.target_path }}" \
          "${{ inputs.catalog_path }}" \
          >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Commit**

```bash
git add actions/onboard-drift/
git commit -m "feat(drift): action wrapper for onboard-drift script"
```

### Task 5.3: `drift-check.yml` workflow

**Files:**
- Create: `.github/workflows/drift-check.yml`

- [ ] **Step 1: Compose the workflow**

```yaml
# .github/workflows/drift-check.yml
# Weekly central audit: for each onboarded adopter (from docs/onboarding-status.md),
# compute drift status and publish a single rolling GitHub Issue in the catalog repo.
name: drift-check
on:
  schedule:
    - cron: '0 6 * * 1'
  workflow_dispatch:
    inputs:
      target_repos:
        description: 'Comma-separated owner/repo list (default: all onboarded from status doc)'
        required: false
        type: string

permissions:
  contents: read

jobs:
  enumerate:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.enum.outputs.matrix }}
      current_version: ${{ steps.ver.outputs.current_version }}
    steps:
      - uses: actions/checkout@v6
      - id: ver
        run: |
          v=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
          echo "current_version=$v" >> "$GITHUB_OUTPUT"
      - id: enum
        env:
          INPUT: ${{ inputs.target_repos }}
        run: |
          set -euo pipefail
          if [[ -n "${INPUT:-}" ]]; then
            list="$INPUT"
          else
            # Extract onboarded repos from the status doc
            list=$(awk -F'|' '
              /^\| serverkraken\// {
                gsub(/[[:space:]]/, "", $2);
                # Drop "not onboarded" rows
                if (index($0, "not onboarded") == 0) print $2;
              }' docs/onboarding-status.md | paste -sd, -)
          fi
          out='['
          first=1
          IFS=',' read -ra entries <<< "$list"
          for e in "${entries[@]}"; do
            [[ -z "$e" ]] && continue
            owner="${e%/*}"; name="${e#*/}"
            [[ $first -eq 0 ]] && out+=','
            out+="{\"target\":\"$e\",\"owner\":\"$owner\",\"name\":\"$name\"}"
            first=0
          done
          out+=']'
          echo "matrix=$out" >> "$GITHUB_OUTPUT"

  check:
    needs: enumerate
    if: ${{ needs.enumerate.outputs.matrix != '[]' }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        target: ${{ fromJSON(needs.enumerate.outputs.matrix) }}
    steps:
      - name: Mint App token scoped to target
        id: target-token
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.RELEASE_PLEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
          owner: ${{ matrix.target.owner }}
          repositories: ${{ matrix.target.name }}

      - uses: actions/checkout@v6
        with:
          repository: ${{ matrix.target.target }}
          token: ${{ steps.target-token.outputs.token }}
          path: target

      - uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.sha }}
          path: catalog

      - name: Drift check
        id: drift
        uses: ./catalog/actions/onboard-drift
        with:
          target_path: target
          catalog_path: catalog
          current_version: ${{ needs.enumerate.outputs.current_version }}

      - name: Emit per-target result
        if: always()
        env:
          TARGET: ${{ matrix.target.target }}
          STATUS: ${{ steps.drift.outputs.status }}
          MODIFIED: ${{ steps.drift.outputs.modified }}
          LOCK_VERSION: ${{ steps.drift.outputs.lock_version }}
          CURRENT: ${{ needs.enumerate.outputs.current_version }}
        run: |
          set -euo pipefail
          mkdir -p result
          safe="${TARGET//\//-}"
          jq -n \
            --arg target "$TARGET" --arg status "$STATUS" \
            --arg modified "$MODIFIED" --arg lock_version "$LOCK_VERSION" \
            --arg current "$CURRENT" \
            '{target:$target, status:$status, modified:$modified, lock_version:$lock_version, current:$current}' \
            > "result/$safe.json"

      - uses: actions/upload-artifact@v4
        with:
          name: drift-${{ matrix.target.owner }}-${{ matrix.target.name }}
          path: result/

  publish:
    needs: [enumerate, check]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Mint App token for catalog
        id: cat-token
        uses: actions/create-github-app-token@v2
        with:
          app-id: ${{ secrets.RELEASE_PLEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
          owner: serverkraken
          repositories: reusable-workflows

      - uses: actions/checkout@v6
        with:
          token: ${{ steps.cat-token.outputs.token }}

      - uses: actions/download-artifact@v4
        with:
          path: results
          pattern: drift-*
          merge-multiple: true

      - name: Build markdown body
        id: build
        run: |
          set -euo pipefail
          today=$(date -u +%Y-%m-%d)
          {
            echo "# Onboarding Drift Report — $today"
            echo
            echo "| Repo | Status | Catalog (lock → current) | Modified files |"
            echo "|---|---|---|---|"
            for f in results/*.json; do
              [[ -f "$f" ]] || continue
              t=$(jq -r '.target' "$f")
              s=$(jq -r '.status' "$f")
              lv=$(jq -r '.lock_version' "$f")
              cv=$(jq -r '.current' "$f")
              mods=$(jq -r '.modified' "$f")
              [[ -z "$mods" || "$mods" == "null" ]] && mods="—"
              if [[ "$lv" == "$cv" ]]; then
                ver="$cv"
              else
                ver="$lv → $cv"
              fi
              echo "| $t | $s | $ver | $mods |"
            done
          } > body.md
          echo "body_path=body.md" >> "$GITHUB_OUTPUT"

      - name: Upsert rolling drift issue
        env:
          GH_TOKEN: ${{ steps.cat-token.outputs.token }}
          BODY_PATH: ${{ steps.build.outputs.body_path }}
        run: |
          set -euo pipefail
          existing=$(gh issue list --state open --search 'in:title "Onboarding Drift Report"' --json number -q '.[0].number' || echo "")
          if [[ -n "$existing" ]]; then
            gh issue edit "$existing" --body-file "$BODY_PATH"
          else
            gh issue create --title "Onboarding Drift Report" --body-file "$BODY_PATH"
          fi
```

- [ ] **Step 2: Actionlint**

```bash
actionlint .github/workflows/drift-check.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/drift-check.yml
git commit -m "feat(drift): weekly drift-check workflow with rolling issue"
```

### Task 5.4: README / docs for drift

**Files:**
- Modify: `docs/operations.md` (add a "Drift Audit" section)
- Modify: `README.md` (briefly mention the audit)

- [ ] **Step 1: Add a "Drift audit" section to `docs/operations.md`**

Explain: schedule, where the rolling issue lives, what each status means, and how to remediate (`workflow_dispatch onboard.yml` with the affected target).

- [ ] **Step 2: One-liner in README**

Append a "Drift audit" bullet to the "Operational tools" list (or equivalent section).

- [ ] **Step 3: Commit**

```bash
git add docs/operations.md README.md
git commit -m "docs: drift audit usage and statuses"
```

---

## Wrap-up

### Task 6.1: End-to-end dry-run sanity

- [ ] **Step 1: Pick one real adopter (e.g. `serverkraken/blupod-ui`) and dispatch `onboard.yml` with `dry_run=true`**

```bash
gh workflow run onboard.yml -f target_repos=serverkraken/blupod-ui -f dry_run=true
gh run watch
```

Expected: step summary contains the new "Detected components" table and warnings/legacy_ci sections (when present); rendered diff includes `.github/onboard.lock.json`.

- [ ] **Step 2: If anything looks wrong, file follow-ups; do not edit code mid-merge**

### Task 6.2: Release

- [ ] **Step 1: Confirm conventional-commit log is clean**

```bash
git log --oneline main..HEAD
```

- [ ] **Step 2: Push to a PR branch and let release-please handle the bump**

```bash
git push -u origin feature/smarter-onboarding
gh pr create --fill
```

The merge of the release-please PR will publish `v2.1.0` (minor — feat-only additions, no breaking changes to existing public atom contracts).

---

## Notes for the implementer

- gomplate features used: `index`, `len`, `gt`/`eq`, `range`, `toJSON`, `dir`, `replaceAll`. All of these are in gomplate v3.x. If your pinned version is older, upgrade.
- The `$REPO` placeholder substitution in `onboard-render.sh` (Task 3.3) is a deliberate ugly: image names in `profile.json` carry a literal `$REPO` token because Detection doesn't know the adopter's repo short-name (the target path on the runner is `target`, not the org/name). The renderer substitutes it post-gomplate. A cleaner alternative is to inject `repo_short_name` into the profile.json itself; if you prefer that, do it in Task 4.1 and remove the sed step.
- macOS dev: bats tests use `find -printf` and `sed -i` (GNU forms). On macOS, run them inside Docker or use `gfind` / `gsed` from coreutils.
