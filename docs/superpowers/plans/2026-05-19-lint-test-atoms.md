# Lint & Test Atoms Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship seven reusable lint/test workflow atoms (`lint-{go,python,rust,helm}.yml`, `test-{go,python,rust}.yml`), wire them into the smarter-onboarding `ci.yml` template, and migrate the two reference adopters (`blupod-ui`, `flow`) onto the new pipeline.

**Architecture:** Each atom is a `workflow_call` workflow that auto-detects its language toolchain version from the adopter's source files (empty-string input → file-based detect; non-empty → explicit override). Test atoms enforce a configurable coverage gate (default 90 %). The Python atoms share a small composite action `actions/setup-python-deps` that probes for `poetry.lock` / `uv.lock` / `pyproject.toml` / `requirements.txt` and installs accordingly. The adopter `ci.yml.tmpl` loops over `profile.json.components[]` and emits per-component `lint-<lang>-<suffix>` and `test-<lang>-<suffix>` jobs.

**Tech Stack:** GitHub Actions reusable workflows (YAML), composite actions, `actions/setup-go@v5`, `actions/setup-python@v5`, `astral-sh/setup-uv@v6`, `dtolnay/rust-toolchain@stable`, `Swatinem/rust-cache@v2`, `azure/setup-helm@v4`, `helm/chart-testing-action@v3`, golangci-lint v2, ruff, mypy, pytest + pytest-cov, clippy, cargo-llvm-cov, helm 3 + ct. Tests: bats for shell + golden files, `actionlint` + `yamllint` for static.

**Spec reference:** `docs/superpowers/specs/2026-05-19-lint-test-atoms-design.md`. Read it once before starting Task 1.

**Pattern deviation from spec § 7.4:** the existing newer atoms (`docker-build-multi`, `goreleaser`, `helm-publish`) use **standalone caller workflows in `tests/callers/`** triggered by `workflow_dispatch` + `pull_request` with a `paths:` filter — not job entries inside `integration.yml`. This plan follows the existing pattern. The spec is mildly wrong on this point; do not extend `integration.yml`.

---

## File structure

### PR1 — Atoms + callers + fixtures

**Created:**
- `.github/workflows/lint-go.yml`
- `.github/workflows/test-go.yml`
- `.github/workflows/lint-python.yml`
- `.github/workflows/test-python.yml`
- `.github/workflows/lint-rust.yml`
- `.github/workflows/test-rust.yml`
- `.github/workflows/lint-helm.yml`
- `actions/setup-python-deps/action.yml`
- `tests/callers/lint-go-happy.yml`, `lint-go-fail.yml`
- `tests/callers/test-go-happy.yml`, `test-go-cov-fail.yml`
- `tests/callers/lint-python-happy.yml`, `lint-python-fail.yml`
- `tests/callers/test-python-happy.yml`, `test-python-cov-fail.yml`
- `tests/callers/lint-rust-happy.yml`, `lint-rust-fail.yml`
- `tests/callers/test-rust-happy.yml`, `test-rust-cov-fail.yml`
- `tests/callers/lint-helm-happy.yml`, `lint-helm-fail.yml`
- `tests/fixtures/lint-test/go-happy/` (`go.mod`, `add.go`, `add_test.go`)
- `tests/fixtures/lint-test/go-lint-fail/` (`go.mod`, `bad.go`)
- `tests/fixtures/lint-test/go-cov-fail/` (`go.mod`, `nocov.go`)
- `tests/fixtures/lint-test/python-poetry-happy/` (`pyproject.toml`, `poetry.lock`, `lib/__init__.py`, `lib/add.py`, `tests/test_add.py`)
- `tests/fixtures/lint-test/python-uv-happy/` (`pyproject.toml`, `uv.lock`, `lib/__init__.py`, `lib/add.py`, `tests/test_add.py`)
- `tests/fixtures/lint-test/python-pip-happy/` (`pyproject.toml`, `lib/__init__.py`, `lib/add.py`, `tests/test_add.py`)
- `tests/fixtures/lint-test/python-lint-fail/` (`pyproject.toml`, `poetry.lock`, `lib/bad.py`)
- `tests/fixtures/lint-test/python-cov-fail/` (`pyproject.toml`, `poetry.lock`, `lib/__init__.py`, `lib/add.py`)
- `tests/fixtures/lint-test/rust-happy/` (`Cargo.toml`, `src/lib.rs`)
- `tests/fixtures/lint-test/rust-lint-fail/` (`Cargo.toml`, `src/lib.rs`)
- `tests/fixtures/lint-test/rust-cov-fail/` (`Cargo.toml`, `src/lib.rs`)
- `tests/fixtures/lint-test/helm-lint-fail/Chart.yaml`

**Modified:**
- `README.md` (atoms table extended)
- `docs/operations.md` (atom listing extended)

### PR2 — Detection warnings + template rewrite + golden tests

**Created:**
- `tests/shell/golden/ci/single-go.yml`
- `tests/shell/golden/ci/single-python.yml`
- `tests/shell/golden/ci/single-rust.yml`
- `tests/shell/golden/ci/single-helm.yml`
- `tests/shell/golden/ci/monorepo-mixed.yml`
- `tests/shell/golden/ci/unsupported-node.yml`

**Modified:**
- `scripts/lib/onboard-detect-lib.sh` (add unsupported-language warning emitter)
- `scripts/onboard-detect.sh` (invoke the emitter for unsupported languages)
- `tests/shell/onboard-detect.bats` (test for the new warning)
- `docs/adopter-templates/skeletons/ci.yml.tmpl` (full rewrite)
- `tests/shell/onboard-render.bats` (golden-file assertions)

### PR3 — Reference-adopter migration (post-release)

No catalog file changes. Operational dispatch only.

---

## PR1 tasks

Branch off `main` as `feat/lint-test-atoms-pr1`. Each task is one commit. Conventional-commit subjects shown verbatim.

### Task 1: `lint-go.yml` + go-happy + go-lint-fail fixtures + callers

**Files:**
- Create: `tests/fixtures/lint-test/go-happy/go.mod`
- Create: `tests/fixtures/lint-test/go-happy/add.go`
- Create: `tests/fixtures/lint-test/go-happy/add_test.go`
- Create: `tests/fixtures/lint-test/go-lint-fail/go.mod`
- Create: `tests/fixtures/lint-test/go-lint-fail/bad.go`
- Create: `tests/callers/lint-go-happy.yml`
- Create: `tests/callers/lint-go-fail.yml`
- Create: `.github/workflows/lint-go.yml`

- [ ] **Step 1: Write `tests/fixtures/lint-test/go-happy/go.mod`**

```
module example.com/lint-test/go-happy

go 1.22
```

- [ ] **Step 2: Write `tests/fixtures/lint-test/go-happy/add.go`**

```go
package gohappy

// Add returns the sum of two integers.
func Add(a, b int) int {
	return a + b
}
```

- [ ] **Step 3: Write `tests/fixtures/lint-test/go-happy/add_test.go`**

```go
package gohappy

import "testing"

func TestAdd(t *testing.T) {
	if got := Add(2, 3); got != 5 {
		t.Fatalf("Add(2,3) = %d, want 5", got)
	}
	if got := Add(-1, 1); got != 0 {
		t.Fatalf("Add(-1,1) = %d, want 0", got)
	}
}
```

- [ ] **Step 4: Sanity-check the happy fixture locally**

```bash
cd tests/fixtures/lint-test/go-happy
go vet ./...
go test -cover ./...
cd -
```

Expected: `go vet` exits 0; `go test` reports `ok ... coverage: 100.0% of statements`.

- [ ] **Step 5: Write `tests/fixtures/lint-test/go-lint-fail/go.mod`**

```
module example.com/lint-test/go-lint-fail

go 1.22
```

- [ ] **Step 6: Write `tests/fixtures/lint-test/go-lint-fail/bad.go`**

```go
package golintfail

// unusedVar will trip golangci-lint's unused linter.
var unusedVar = 42

func ShoutyName( ){return}
```

The misformatted spacing fails `gofmt` / `golangci-lint`'s default `gofmt` linter, and `unusedVar` fails the `unused` linter.

- [ ] **Step 7: Sanity-check the lint-fail fixture locally**

```bash
cd tests/fixtures/lint-test/go-lint-fail
gofmt -l .          # expect: bad.go printed to stdout
cd -
```

Expected: `gofmt -l .` prints `bad.go` (exit 0, but file listed → golangci-lint will exit 1).

- [ ] **Step 8: Write `tests/callers/lint-go-happy.yml`**

```yaml
# tests/callers/lint-go-happy.yml
# Happy-path caller for lint-go.yml. Runs go vet + golangci-lint against
# the clean go fixture. Triggered by workflow_dispatch + paths-filtered PR.
name: caller-lint-go-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-go.yml'
      - 'tests/callers/lint-go-happy.yml'
      - 'tests/fixtures/lint-test/go-happy/**'

jobs:
  lint:
    uses: ./.github/workflows/lint-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-happy
```

- [ ] **Step 9: Write `tests/callers/lint-go-fail.yml`**

```yaml
# tests/callers/lint-go-fail.yml
# Failure-path caller for lint-go.yml. The lint-fail fixture has gofmt
# violations + unused vars; the atom MUST exit non-zero. We invoke the
# atom with continue-on-error: true and assert in a downstream job that
# the atom job failed.
name: caller-lint-go-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-go.yml'
      - 'tests/callers/lint-go-fail.yml'
      - 'tests/fixtures/lint-test/go-lint-fail/**'

jobs:
  lint:
    uses: ./.github/workflows/lint-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-lint-fail

  assert-failed:
    needs: lint
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.lint.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
          echo "lint-go-fail: correctly observed failure"
```

- [ ] **Step 10: Write `.github/workflows/lint-go.yml`**

```yaml
# .github/workflows/lint-go.yml
# Reusable workflow: lint Go code with `go vet` + golangci-lint.
#
# Stability surface: the shape of `inputs` below is the contract — changes
# are SemVer-significant. No `secrets:` block: callers pass `secrets: inherit`
# for transparency but the atom itself reads none.
#
# Auto-detect: when `go_version` is the empty string (default),
# actions/setup-go reads <working_directory>/go.mod.
name: lint-go
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux","X64"]'
      working_directory:
        description: 'Component sub-path. Atom resolves all paths relative to this.'
        required: false
        type: string
        default: '.'
      go_version:
        description: 'Go toolchain version. Empty → read from <working_directory>/go.mod.'
        required: false
        type: string
        default: ''
      # renovate: datasource=github-releases depName=golangci/golangci-lint
      golangci_lint_version:
        description: 'golangci-lint version (e.g. v2.0.2). Defaults to the atom-pinned version.'
        required: false
        type: string
        default: 'v2.0.2'

permissions:
  contents: read

concurrency:
  group: lint-go-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@v6

      - name: Setup Go (from go.mod)
        if: inputs.go_version == ''
        uses: actions/setup-go@v5
        with:
          go-version-file: ${{ inputs.working_directory }}/go.mod
          cache-dependency-path: ${{ inputs.working_directory }}/go.sum

      - name: Setup Go (explicit version)
        if: inputs.go_version != ''
        uses: actions/setup-go@v5
        with:
          go-version: ${{ inputs.go_version }}

      - name: go vet
        working-directory: ${{ inputs.working_directory }}
        run: go vet ./...

      - name: golangci-lint
        uses: golangci/golangci-lint-action@v6
        with:
          version: ${{ inputs.golangci_lint_version }}
          working-directory: ${{ inputs.working_directory }}
          args: --timeout=5m
```

Note: the fixture has no `go.sum`. `cache-dependency-path` is allowed to point at a missing file — `actions/setup-go` then skips the cache; that's the desired behavior for a no-deps fixture. Real adopters always have a `go.sum`.

- [ ] **Step 11: Run actionlint on the new files**

```bash
actionlint .github/workflows/lint-go.yml tests/callers/lint-go-happy.yml tests/callers/lint-go-fail.yml
```

Expected: no output, exit 0. If actionlint complains about `golangci/golangci-lint-action@v6` being unknown, add it via `-ignore` flag the same way `validate.yml` handles `create-github-app-token@v3` (see memory note `project_actionlint_clientid`).

- [ ] **Step 12: Commit**

```bash
git add tests/fixtures/lint-test/go-happy tests/fixtures/lint-test/go-lint-fail tests/callers/lint-go-happy.yml tests/callers/lint-go-fail.yml .github/workflows/lint-go.yml
git commit -m "feat(atom): lint-go reusable workflow + callers + fixtures"
```

---

### Task 2: `test-go.yml` + go-cov-fail fixture + callers

**Files:**
- Create: `tests/fixtures/lint-test/go-cov-fail/go.mod`
- Create: `tests/fixtures/lint-test/go-cov-fail/nocov.go`
- Create: `tests/callers/test-go-happy.yml`
- Create: `tests/callers/test-go-cov-fail.yml`
- Create: `.github/workflows/test-go.yml`

- [ ] **Step 1: Write `tests/fixtures/lint-test/go-cov-fail/go.mod`**

```
module example.com/lint-test/go-cov-fail

go 1.22
```

- [ ] **Step 2: Write `tests/fixtures/lint-test/go-cov-fail/nocov.go`**

```go
package gocovfail

// Untested returns a constant. Coverage = 0 % because no _test.go exists.
func Untested() int {
	return 1
}
```

- [ ] **Step 3: Sanity-check locally**

```bash
cd tests/fixtures/lint-test/go-cov-fail
go test -coverprofile=cover.out -covermode=atomic ./... || true
go tool cover -func=cover.out | tail -1
cd -
```

Expected: last line shows `total: (statements) 0.0%` (no tests = 0% coverage).

- [ ] **Step 4: Write `tests/callers/test-go-happy.yml`**

```yaml
# tests/callers/test-go-happy.yml
# Happy-path caller for test-go.yml against the clean fixture.
name: caller-test-go-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/test-go.yml'
      - 'tests/callers/test-go-happy.yml'
      - 'tests/fixtures/lint-test/go-happy/**'

jobs:
  test:
    uses: ./.github/workflows/test-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-happy
      coverage_threshold: 90
```

- [ ] **Step 5: Write `tests/callers/test-go-cov-fail.yml`**

```yaml
# tests/callers/test-go-cov-fail.yml
# Failure-path caller: cov-fail fixture has 0 % coverage; the atom MUST
# fail the coverage gate. Assertion job below asserts the test job failed.
name: caller-test-go-cov-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/test-go.yml'
      - 'tests/callers/test-go-cov-fail.yml'
      - 'tests/fixtures/lint-test/go-cov-fail/**'

jobs:
  test:
    uses: ./.github/workflows/test-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-cov-fail
      coverage_threshold: 90

  assert-failed:
    needs: test
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert test job failed
        env:
          RESULT: ${{ needs.test.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected test job to fail (coverage gate), got: $RESULT"
            exit 1
          fi
          echo "test-go-cov-fail: correctly observed failure"
```

- [ ] **Step 6: Write `.github/workflows/test-go.yml`**

```yaml
# .github/workflows/test-go.yml
# Reusable workflow: run `go test` with coverage gate.
#
# Stability surface: the shape of `inputs` below is the contract.
# Exit non-zero when measured line coverage < `coverage_threshold`.
name: test-go
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux","X64"]'
      working_directory:
        description: 'Component sub-path.'
        required: false
        type: string
        default: '.'
      go_version:
        description: 'Go toolchain version. Empty → read from <working_directory>/go.mod.'
        required: false
        type: string
        default: ''
      coverage_threshold:
        description: 'Minimum line coverage percentage (integer 0-100).'
        required: false
        type: number
        default: 90

permissions:
  contents: read

concurrency:
  group: test-go-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  test:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@v6

      - name: Setup Go (from go.mod)
        if: inputs.go_version == ''
        uses: actions/setup-go@v5
        with:
          go-version-file: ${{ inputs.working_directory }}/go.mod
          cache-dependency-path: ${{ inputs.working_directory }}/go.sum

      - name: Setup Go (explicit version)
        if: inputs.go_version != ''
        uses: actions/setup-go@v5
        with:
          go-version: ${{ inputs.go_version }}

      - name: go test with coverage
        working-directory: ${{ inputs.working_directory }}
        run: go test -coverprofile=cover.out -covermode=atomic ./...

      - name: Coverage gate
        working-directory: ${{ inputs.working_directory }}
        env:
          THRESHOLD: ${{ inputs.coverage_threshold }}
        run: |
          set -euo pipefail
          # Last line of `go tool cover -func` is the total: `total:    (statements)    87.5%`
          pct=$(go tool cover -func=cover.out | awk '/^total:/ {sub("%","",$3); print $3}')
          echo "coverage: ${pct}% (threshold: ${THRESHOLD}%)"
          # bash arithmetic is integer-only; multiply by 10 and compare ints
          pct_int=$(printf '%.0f' "$(echo "$pct * 10" | bc -l)")
          thr_int=$((THRESHOLD * 10))
          if (( pct_int < thr_int )); then
            echo "::error::coverage ${pct}% < threshold ${THRESHOLD}%"
            exit 1
          fi
```

- [ ] **Step 7: actionlint**

```bash
actionlint .github/workflows/test-go.yml tests/callers/test-go-happy.yml tests/callers/test-go-cov-fail.yml
```

Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/lint-test/go-cov-fail tests/callers/test-go-happy.yml tests/callers/test-go-cov-fail.yml .github/workflows/test-go.yml
git commit -m "feat(atom): test-go reusable workflow + callers + cov-fail fixture"
```

---

### Task 3: `actions/setup-python-deps` composite action

**Files:**
- Create: `actions/setup-python-deps/action.yml`

This composite is shared by `lint-python.yml` and `test-python.yml`. It probes for a package manager, sets up Python, installs pm + deps, and outputs `pm` (`poetry|uv|pip-bare|pip-dev`) and `run_prefix` (`poetry run`, `uv run`, or empty).

- [ ] **Step 1: Write `actions/setup-python-deps/action.yml`**

```yaml
# actions/setup-python-deps/action.yml
# Composite action used by lint-python.yml and test-python.yml. Detects the
# Python package manager in working_directory, sets up Python at the right
# version, installs the project and its dev deps, and exposes:
#   outputs.pm          one of poetry | uv | pip-dev | pip-bare
#   outputs.run_prefix  command prefix to invoke project tools:
#                       'poetry run' | 'uv run' | '' (pip paths run tools directly)
#
# Probe order: poetry.lock > uv.lock > pyproject.toml[project.optional-dependencies.dev] > requirements.txt.
# Hard error if none of the above is present.
name: setup-python-deps
description: Detect Python package manager and install deps for lint/test atoms.
inputs:
  working_directory:
    description: 'Project directory containing the lockfile or pyproject.toml.'
    required: false
    default: '.'
  python_version:
    description: 'Python version. Empty → read from <working_directory>/pyproject.toml.'
    required: false
    default: ''
  install_test_extras:
    description: 'When true, install pytest + pytest-cov on the pip-bare path.'
    required: false
    default: 'false'
outputs:
  pm:
    description: 'Detected package manager.'
    value: ${{ steps.detect.outputs.pm }}
  run_prefix:
    description: 'Prefix to invoke tools.'
    value: ${{ steps.detect.outputs.run_prefix }}
runs:
  using: composite
  steps:
    - name: Detect package manager
      id: detect
      shell: bash
      working-directory: ${{ inputs.working_directory }}
      run: |
        set -euo pipefail
        pm=""
        prefix=""
        if [[ -f poetry.lock ]]; then
          pm=poetry
          prefix="poetry run"
        elif [[ -f uv.lock ]]; then
          pm=uv
          prefix="uv run"
        elif [[ -f pyproject.toml ]] && python3 -c '
        import sys, tomllib
        with open("pyproject.toml","rb") as f:
            d = tomllib.load(f)
        opt = d.get("project", {}).get("optional-dependencies", {})
        sys.exit(0 if "dev" in opt else 1)
        ' 2>/dev/null; then
          pm=pip-dev
          prefix=""
        elif [[ -f requirements.txt ]]; then
          pm=pip-bare
          prefix=""
        else
          echo "::error::no python package manager detected at $(pwd) (need poetry.lock | uv.lock | pyproject.toml[project.optional-dependencies.dev] | requirements.txt)"
          exit 1
        fi
        echo "pm=$pm" >> "$GITHUB_OUTPUT"
        echo "run_prefix=$prefix" >> "$GITHUB_OUTPUT"
        echo "detected pm=$pm"

    - name: Setup Python (from pyproject.toml)
      if: inputs.python_version == ''
      uses: actions/setup-python@v5
      with:
        python-version-file: ${{ inputs.working_directory }}/pyproject.toml

    - name: Setup Python (explicit)
      if: inputs.python_version != ''
      uses: actions/setup-python@v5
      with:
        python-version: ${{ inputs.python_version }}

    - name: Install Poetry
      if: steps.detect.outputs.pm == 'poetry'
      shell: bash
      run: pipx install poetry

    - name: Install uv
      if: steps.detect.outputs.pm == 'uv'
      uses: astral-sh/setup-uv@v6

    - name: poetry install
      if: steps.detect.outputs.pm == 'poetry'
      shell: bash
      working-directory: ${{ inputs.working_directory }}
      run: poetry install --no-interaction --no-ansi

    - name: uv sync
      if: steps.detect.outputs.pm == 'uv'
      shell: bash
      working-directory: ${{ inputs.working_directory }}
      run: uv sync --frozen

    - name: pip install -e ".[dev]"
      if: steps.detect.outputs.pm == 'pip-dev'
      shell: bash
      working-directory: ${{ inputs.working_directory }}
      run: |
        python -m pip install --upgrade pip
        pip install -e ".[dev]"

    - name: pip install -r requirements.txt (+ optional test extras)
      if: steps.detect.outputs.pm == 'pip-bare'
      shell: bash
      working-directory: ${{ inputs.working_directory }}
      env:
        EXTRAS: ${{ inputs.install_test_extras }}
      run: |
        python -m pip install --upgrade pip
        pip install -r requirements.txt
        pip install ruff mypy
        if [[ "$EXTRAS" == "true" ]]; then
          pip install pytest pytest-cov
        fi
```

- [ ] **Step 2: actionlint**

```bash
actionlint actions/setup-python-deps/action.yml
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add actions/setup-python-deps/action.yml
git commit -m "feat(atom): setup-python-deps composite action"
```

---

### Task 4: `lint-python.yml` + python fixtures (poetry-happy, uv-happy, pip-happy, lint-fail) + callers

**Files:**
- Create: `tests/fixtures/lint-test/python-poetry-happy/{pyproject.toml,poetry.lock,lib/__init__.py,lib/add.py,tests/test_add.py}`
- Create: `tests/fixtures/lint-test/python-uv-happy/{pyproject.toml,uv.lock,lib/__init__.py,lib/add.py,tests/test_add.py}`
- Create: `tests/fixtures/lint-test/python-pip-happy/{pyproject.toml,lib/__init__.py,lib/add.py,tests/test_add.py}`
- Create: `tests/fixtures/lint-test/python-lint-fail/{pyproject.toml,poetry.lock,lib/bad.py}`
- Create: `tests/callers/lint-python-happy.yml`, `tests/callers/lint-python-fail.yml`
- Create: `.github/workflows/lint-python.yml`

**Note on lockfiles:** committed `poetry.lock` and `uv.lock` files must be regenerated locally using the respective tools (`poetry lock` and `uv lock`) — do not hand-edit. After writing `pyproject.toml`, run the lock command from inside the fixture directory and commit whatever the tool produces.

- [ ] **Step 1: Write `tests/fixtures/lint-test/python-poetry-happy/pyproject.toml`**

```toml
[tool.poetry]
name = "python-poetry-happy"
version = "0.1.0"
description = "Lint-test fixture (Poetry)"
authors = ["fixture <fixture@example.com>"]
packages = [{ include = "lib" }]

[tool.poetry.dependencies]
python = "^3.12"

[tool.poetry.group.dev.dependencies]
ruff = "^0.7"
mypy = "^1.13"
pytest = "^8.3"
pytest-cov = "^6.0"

[build-system]
requires = ["poetry-core>=1.0.0"]
build-backend = "poetry.core.masonry.api"

[tool.ruff]
line-length = 100

[tool.pytest.ini_options]
addopts = "--cov=lib --cov-report=term"
```

- [ ] **Step 2: Generate `poetry.lock` for the Poetry fixture**

```bash
cd tests/fixtures/lint-test/python-poetry-happy
poetry lock
cd -
```

Expected: a `poetry.lock` file is generated. Do not hand-edit; commit verbatim.

- [ ] **Step 3: Write `lib/__init__.py`, `lib/add.py`, `tests/test_add.py` for python-poetry-happy**

`lib/__init__.py`:

```python
```

(empty file — single newline so it's not zero-byte)

`lib/add.py`:

```python
"""Trivial arithmetic for lint-test fixtures."""


def add(a: int, b: int) -> int:
    """Return the sum of two integers."""
    return a + b
```

`tests/test_add.py`:

```python
from lib.add import add


def test_add_positive() -> None:
    assert add(2, 3) == 5


def test_add_negative() -> None:
    assert add(-1, 1) == 0
```

- [ ] **Step 4: Sanity-check the Poetry fixture locally**

```bash
cd tests/fixtures/lint-test/python-poetry-happy
poetry install --no-interaction
poetry run ruff check .
poetry run ruff format --check .
poetry run mypy lib
poetry run pytest --cov=lib --cov-fail-under=90
cd -
```

Expected: all four commands exit 0. Coverage is 100 % on `lib/add.py`.

- [ ] **Step 5: Write `tests/fixtures/lint-test/python-uv-happy/pyproject.toml`**

```toml
[project]
name = "python-uv-happy"
version = "0.1.0"
description = "Lint-test fixture (uv)"
requires-python = ">=3.12"
dependencies = []

[project.optional-dependencies]
dev = [
    "ruff>=0.7,<0.8",
    "mypy>=1.13,<2",
    "pytest>=8.3",
    "pytest-cov>=6.0",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["lib"]

[tool.ruff]
line-length = 100

[tool.pytest.ini_options]
addopts = "--cov=lib --cov-report=term"
```

- [ ] **Step 6: Generate `uv.lock` for the uv fixture**

```bash
cd tests/fixtures/lint-test/python-uv-happy
uv lock
cd -
```

Expected: a `uv.lock` file is generated.

- [ ] **Step 7: Copy `lib/` and `tests/` from python-poetry-happy into python-uv-happy**

```bash
cp -R tests/fixtures/lint-test/python-poetry-happy/lib tests/fixtures/lint-test/python-uv-happy/
cp -R tests/fixtures/lint-test/python-poetry-happy/tests tests/fixtures/lint-test/python-uv-happy/
```

- [ ] **Step 8: Sanity-check the uv fixture locally**

```bash
cd tests/fixtures/lint-test/python-uv-happy
uv sync --frozen
uv run ruff check .
uv run pytest --cov=lib --cov-fail-under=90
cd -
```

Expected: exit 0 for both.

- [ ] **Step 9: Write `tests/fixtures/lint-test/python-pip-happy/pyproject.toml`**

Same content as the uv fixture's pyproject.toml — `[project.optional-dependencies].dev` triggers the `pip-dev` probe path. Then:

```bash
cp tests/fixtures/lint-test/python-uv-happy/pyproject.toml tests/fixtures/lint-test/python-pip-happy/pyproject.toml
cp -R tests/fixtures/lint-test/python-poetry-happy/lib tests/fixtures/lint-test/python-pip-happy/
cp -R tests/fixtures/lint-test/python-poetry-happy/tests tests/fixtures/lint-test/python-pip-happy/
```

Edit the copied `pyproject.toml` to change `name = "python-uv-happy"` → `name = "python-pip-happy"`.

No lock file. The composite's `pip-dev` path will run `pip install -e ".[dev]"` against this pyproject.toml.

- [ ] **Step 10: Sanity-check the pip-dev fixture locally**

```bash
cd tests/fixtures/lint-test/python-pip-happy
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
ruff check .
pytest --cov=lib --cov-fail-under=90
deactivate && rm -rf .venv
cd -
```

Expected: exit 0 for both.

- [ ] **Step 11: Write `tests/fixtures/lint-test/python-lint-fail/pyproject.toml`**

```toml
[tool.poetry]
name = "python-lint-fail"
version = "0.1.0"
description = "Lint-fail fixture (Poetry)"
authors = ["fixture <fixture@example.com>"]
packages = [{ include = "lib" }]

[tool.poetry.dependencies]
python = "^3.12"

[tool.poetry.group.dev.dependencies]
ruff = "^0.7"
mypy = "^1.13"

[build-system]
requires = ["poetry-core>=1.0.0"]
build-backend = "poetry.core.masonry.api"

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["F", "E"]
```

- [ ] **Step 12: Generate the lock file for python-lint-fail**

```bash
cd tests/fixtures/lint-test/python-lint-fail
poetry lock
cd -
```

- [ ] **Step 13: Write `tests/fixtures/lint-test/python-lint-fail/lib/bad.py`**

```python
import os, sys

def Bad( ):
    x = 1
    return
```

This has multiple lint violations:
- multi-import on one line (`E401`)
- unused imports (`F401`)
- mixed-case function name + space-before-paren (formatting)
- unused local variable (`F841`)
- missing return value type for non-None

`ruff check .` will fail. Also add an empty `lib/__init__.py`.

- [ ] **Step 14: Sanity-check the lint-fail fixture locally**

```bash
cd tests/fixtures/lint-test/python-lint-fail
poetry install --no-interaction
poetry run ruff check . && echo "::error::expected ruff to fail" && exit 1
echo "lint-fail fixture correctly fails ruff"
cd -
```

Expected: `poetry run ruff check .` exits non-zero. The echo confirming the failure mode runs.

- [ ] **Step 15: Write `.github/workflows/lint-python.yml`**

```yaml
# .github/workflows/lint-python.yml
# Reusable workflow: lint Python with ruff (check + format) + mypy.
# Package manager (poetry/uv/pip) is auto-detected by setup-python-deps.
name: lint-python
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
      working_directory:
        description: 'Component sub-path.'
        required: false
        type: string
        default: '.'
      python_version:
        description: 'Python version. Empty → read from <working_directory>/pyproject.toml.'
        required: false
        type: string
        default: ''

permissions:
  contents: read

concurrency:
  group: lint-python-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@v6
      - id: setup
        uses: ./actions/setup-python-deps
        with:
          working_directory: ${{ inputs.working_directory }}
          python_version: ${{ inputs.python_version }}
          install_test_extras: 'false'

      - name: ruff check
        working-directory: ${{ inputs.working_directory }}
        run: ${{ steps.setup.outputs.run_prefix }} ruff check .

      - name: ruff format --check
        working-directory: ${{ inputs.working_directory }}
        run: ${{ steps.setup.outputs.run_prefix }} ruff format --check .

      - name: mypy
        working-directory: ${{ inputs.working_directory }}
        run: ${{ steps.setup.outputs.run_prefix }} mypy .
```

Note: `uses: ./actions/setup-python-deps` resolves against the **caller's repo checkout**. For the catalog's own self-CI callers in `tests/callers/`, this works because `actions/checkout@v6` checks out the catalog repo by default. For external adopters, the atom needs the composite to live inside the atom's own repo — the path `./actions/setup-python-deps` resolves to the **adopter's** checkout, which won't contain the composite.

**Resolution:** add an explicit `actions/checkout@v6` step that checks out the catalog repo into a sub-directory and references the composite from there. Modify the atom YAML to do this — write the corrected version now instead of the simplified one above:

```yaml
jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Checkout adopter repo
        uses: actions/checkout@v6
      - name: Checkout catalog (for composite actions)
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.action_ref || 'main' }}
          path: .catalog
      - id: setup
        uses: ./.catalog/actions/setup-python-deps
        with:
          working_directory: ${{ inputs.working_directory }}
          python_version: ${{ inputs.python_version }}
          install_test_extras: 'false'
      # … remaining steps unchanged
```

This mirrors the existing pattern in `onboard.yml` (`Checkout catalog at this workflow's SHA` step). The `github.action_ref` context resolves to the ref the consumer pinned (`@v3`, `@main`, etc.); the `|| 'main'` fallback only matters for local self-CI where `github.action_ref` may be empty.

Replace step `- id: setup` and onward in the atom above with the corrected `.catalog`-based version. Write the final file accordingly.

- [ ] **Step 16: Write `tests/callers/lint-python-happy.yml`**

```yaml
# tests/callers/lint-python-happy.yml
# Happy-path caller for lint-python.yml. Exercises all three package
# managers (poetry, uv, pip-dev) against the three happy fixtures.
name: caller-lint-python-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-python.yml'
      - 'actions/setup-python-deps/**'
      - 'tests/callers/lint-python-happy.yml'
      - 'tests/fixtures/lint-test/python-poetry-happy/**'
      - 'tests/fixtures/lint-test/python-uv-happy/**'
      - 'tests/fixtures/lint-test/python-pip-happy/**'

jobs:
  lint-poetry:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-poetry-happy

  lint-uv:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-uv-happy

  lint-pip:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-pip-happy
```

- [ ] **Step 17: Write `tests/callers/lint-python-fail.yml`**

```yaml
# tests/callers/lint-python-fail.yml
# Failure-path caller: lint-fail fixture has ruff violations.
name: caller-lint-python-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-python.yml'
      - 'actions/setup-python-deps/**'
      - 'tests/callers/lint-python-fail.yml'
      - 'tests/fixtures/lint-test/python-lint-fail/**'

jobs:
  lint:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-lint-fail

  assert-failed:
    needs: lint
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.lint.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
```

- [ ] **Step 18: actionlint**

```bash
actionlint .github/workflows/lint-python.yml tests/callers/lint-python-happy.yml tests/callers/lint-python-fail.yml
```

Expected: clean. If `astral-sh/setup-uv@v6` is unknown to actionlint, add an `-ignore` entry to `validate.yml`.

- [ ] **Step 19: Commit**

```bash
git add tests/fixtures/lint-test/python-poetry-happy tests/fixtures/lint-test/python-uv-happy tests/fixtures/lint-test/python-pip-happy tests/fixtures/lint-test/python-lint-fail tests/callers/lint-python-happy.yml tests/callers/lint-python-fail.yml .github/workflows/lint-python.yml
git commit -m "feat(atom): lint-python reusable workflow + callers + fixtures (poetry/uv/pip)"
```

---

### Task 5: `test-python.yml` + python-cov-fail fixture + callers

**Files:**
- Create: `tests/fixtures/lint-test/python-cov-fail/{pyproject.toml,poetry.lock,lib/__init__.py,lib/add.py}`
- Create: `tests/callers/test-python-happy.yml`, `tests/callers/test-python-cov-fail.yml`
- Create: `.github/workflows/test-python.yml`

- [ ] **Step 1: Write `tests/fixtures/lint-test/python-cov-fail/pyproject.toml`**

Same as `python-poetry-happy/pyproject.toml` except `name = "python-cov-fail"` and the package only ships `lib/add.py` with no tests.

```toml
[tool.poetry]
name = "python-cov-fail"
version = "0.1.0"
description = "Coverage-fail fixture (Poetry)"
authors = ["fixture <fixture@example.com>"]
packages = [{ include = "lib" }]

[tool.poetry.dependencies]
python = "^3.12"

[tool.poetry.group.dev.dependencies]
pytest = "^8.3"
pytest-cov = "^6.0"

[build-system]
requires = ["poetry-core>=1.0.0"]
build-backend = "poetry.core.masonry.api"

[tool.pytest.ini_options]
addopts = "--cov=lib --cov-report=term"
```

- [ ] **Step 2: Generate the lock file**

```bash
cd tests/fixtures/lint-test/python-cov-fail
poetry lock
cd -
```

- [ ] **Step 3: Write `lib/__init__.py` (empty) and `lib/add.py`** (same content as in python-poetry-happy's `lib/add.py`):

```python
"""Trivial arithmetic for lint-test fixtures."""


def add(a: int, b: int) -> int:
    """Return the sum of two integers."""
    return a + b
```

No `tests/` directory.

- [ ] **Step 4: Sanity-check locally**

```bash
cd tests/fixtures/lint-test/python-cov-fail
poetry install --no-interaction
poetry run pytest --cov=lib --cov-fail-under=90 || echo "cov-fail correctly failed"
cd -
```

Expected: pytest exits non-zero with "Required test coverage of 90% not reached".

- [ ] **Step 5: Write `.github/workflows/test-python.yml`**

```yaml
# .github/workflows/test-python.yml
# Reusable workflow: run pytest with coverage gate. Package manager
# (poetry/uv/pip) is auto-detected by setup-python-deps.
name: test-python
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
      working_directory:
        description: 'Component sub-path.'
        required: false
        type: string
        default: '.'
      python_version:
        description: 'Python version. Empty → read from <working_directory>/pyproject.toml.'
        required: false
        type: string
        default: ''
      coverage_threshold:
        description: 'Minimum line coverage percentage (integer 0-100).'
        required: false
        type: number
        default: 90

permissions:
  contents: read

concurrency:
  group: test-python-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  test:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Checkout adopter repo
        uses: actions/checkout@v6
      - name: Checkout catalog (for composite actions)
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.action_ref || 'main' }}
          path: .catalog
      - id: setup
        uses: ./.catalog/actions/setup-python-deps
        with:
          working_directory: ${{ inputs.working_directory }}
          python_version: ${{ inputs.python_version }}
          install_test_extras: 'true'

      - name: pytest --cov-fail-under
        working-directory: ${{ inputs.working_directory }}
        env:
          THRESHOLD: ${{ inputs.coverage_threshold }}
        run: ${{ steps.setup.outputs.run_prefix }} pytest --cov --cov-fail-under="$THRESHOLD"
```

- [ ] **Step 6: Write `tests/callers/test-python-happy.yml`**

```yaml
# tests/callers/test-python-happy.yml
# Happy-path caller for test-python.yml. Exercises all three package managers.
name: caller-test-python-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/test-python.yml'
      - 'actions/setup-python-deps/**'
      - 'tests/callers/test-python-happy.yml'
      - 'tests/fixtures/lint-test/python-poetry-happy/**'
      - 'tests/fixtures/lint-test/python-uv-happy/**'
      - 'tests/fixtures/lint-test/python-pip-happy/**'

jobs:
  test-poetry:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-poetry-happy
      coverage_threshold: 90

  test-uv:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-uv-happy
      coverage_threshold: 90

  test-pip:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-pip-happy
      coverage_threshold: 90
```

- [ ] **Step 7: Write `tests/callers/test-python-cov-fail.yml`**

```yaml
# tests/callers/test-python-cov-fail.yml
# Failure-path caller: cov-fail fixture has 0 % coverage.
name: caller-test-python-cov-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/test-python.yml'
      - 'actions/setup-python-deps/**'
      - 'tests/callers/test-python-cov-fail.yml'
      - 'tests/fixtures/lint-test/python-cov-fail/**'

jobs:
  test:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-cov-fail
      coverage_threshold: 90

  assert-failed:
    needs: test
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert test job failed
        env:
          RESULT: ${{ needs.test.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected test job to fail (coverage gate), got: $RESULT"
            exit 1
          fi
```

- [ ] **Step 8: actionlint**

```bash
actionlint .github/workflows/test-python.yml tests/callers/test-python-happy.yml tests/callers/test-python-cov-fail.yml
```

Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add tests/fixtures/lint-test/python-cov-fail tests/callers/test-python-happy.yml tests/callers/test-python-cov-fail.yml .github/workflows/test-python.yml
git commit -m "feat(atom): test-python reusable workflow + callers + cov-fail fixture"
```

---

### Task 6: `lint-rust.yml` + rust-happy + rust-lint-fail fixtures + callers

**Files:**
- Create: `tests/fixtures/lint-test/rust-happy/Cargo.toml`, `src/lib.rs`
- Create: `tests/fixtures/lint-test/rust-lint-fail/Cargo.toml`, `src/lib.rs`
- Create: `tests/callers/lint-rust-happy.yml`, `tests/callers/lint-rust-fail.yml`
- Create: `.github/workflows/lint-rust.yml`

- [ ] **Step 1: Write `tests/fixtures/lint-test/rust-happy/Cargo.toml`**

```toml
[package]
name = "rust-happy"
version = "0.1.0"
edition = "2021"
publish = false

[lib]
path = "src/lib.rs"
```

- [ ] **Step 2: Write `tests/fixtures/lint-test/rust-happy/src/lib.rs`**

```rust
//! Trivial arithmetic for lint-test fixtures.

/// Return the sum of two integers.
pub fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_positive() {
        assert_eq!(add(2, 3), 5);
    }

    #[test]
    fn add_negative() {
        assert_eq!(add(-1, 1), 0);
    }
}
```

- [ ] **Step 3: Sanity-check locally**

```bash
cd tests/fixtures/lint-test/rust-happy
cargo fmt --check
cargo clippy --no-deps -- -D warnings
cargo test
cd -
```

Expected: exit 0 for all three.

- [ ] **Step 4: Write `tests/fixtures/lint-test/rust-lint-fail/Cargo.toml`**

```toml
[package]
name = "rust-lint-fail"
version = "0.1.0"
edition = "2021"
publish = false

[lib]
path = "src/lib.rs"
```

- [ ] **Step 5: Write `tests/fixtures/lint-test/rust-lint-fail/src/lib.rs`**

```rust
//! Lint-failing fixture: bad formatting + clippy warnings.

pub fn  add(a:i64,b:i64)->i64{
    let _unused = 1;
    return a+b;
}
```

This triggers `rustfmt` (bad spacing), clippy's `needless_return`, and `unused_variables`.

- [ ] **Step 6: Sanity-check the lint-fail fixture**

```bash
cd tests/fixtures/lint-test/rust-lint-fail
cargo fmt --check || echo "rustfmt correctly fails"
cargo clippy --no-deps -- -D warnings || echo "clippy correctly fails"
cd -
```

Expected: both commands exit non-zero.

- [ ] **Step 7: Write `.github/workflows/lint-rust.yml`**

```yaml
# .github/workflows/lint-rust.yml
# Reusable workflow: lint Rust with cargo fmt --check + cargo clippy -D warnings.
name: lint-rust
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux","X64"]'
      working_directory:
        description: 'Crate root directory.'
        required: false
        type: string
        default: '.'
      rust_toolchain:
        description: 'rustup toolchain. Empty → rustup reads rust-toolchain.toml if present, else stable.'
        required: false
        type: string
        default: ''
      clippy_args:
        description: 'Extra arguments to clippy after `--`.'
        required: false
        type: string
        default: '-D warnings'

permissions:
  contents: read

concurrency:
  group: lint-rust-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@v6

      - name: Install Rust toolchain (explicit)
        if: inputs.rust_toolchain != ''
        uses: dtolnay/rust-toolchain@master
        with:
          toolchain: ${{ inputs.rust_toolchain }}
          components: rustfmt, clippy

      - name: Install Rust toolchain (from rust-toolchain.toml or stable)
        if: inputs.rust_toolchain == ''
        uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy

      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: ${{ inputs.working_directory }}

      - name: cargo fmt --check
        working-directory: ${{ inputs.working_directory }}
        run: cargo fmt --check

      - name: cargo clippy
        working-directory: ${{ inputs.working_directory }}
        run: cargo clippy --no-deps -- ${{ inputs.clippy_args }}
```

- [ ] **Step 8: Write `tests/callers/lint-rust-happy.yml`**

```yaml
# tests/callers/lint-rust-happy.yml
name: caller-lint-rust-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-rust.yml'
      - 'tests/callers/lint-rust-happy.yml'
      - 'tests/fixtures/lint-test/rust-happy/**'

jobs:
  lint:
    uses: ./.github/workflows/lint-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-happy
```

- [ ] **Step 9: Write `tests/callers/lint-rust-fail.yml`**

```yaml
# tests/callers/lint-rust-fail.yml
name: caller-lint-rust-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-rust.yml'
      - 'tests/callers/lint-rust-fail.yml'
      - 'tests/fixtures/lint-test/rust-lint-fail/**'

jobs:
  lint:
    uses: ./.github/workflows/lint-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-lint-fail

  assert-failed:
    needs: lint
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.lint.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
```

- [ ] **Step 10: actionlint**

```bash
actionlint .github/workflows/lint-rust.yml tests/callers/lint-rust-happy.yml tests/callers/lint-rust-fail.yml
```

Expected: clean.

- [ ] **Step 11: Commit**

```bash
git add tests/fixtures/lint-test/rust-happy tests/fixtures/lint-test/rust-lint-fail tests/callers/lint-rust-happy.yml tests/callers/lint-rust-fail.yml .github/workflows/lint-rust.yml
git commit -m "feat(atom): lint-rust reusable workflow + callers + fixtures"
```

---

### Task 7: `test-rust.yml` + rust-cov-fail fixture + callers

**Files:**
- Create: `tests/fixtures/lint-test/rust-cov-fail/Cargo.toml`, `src/lib.rs`
- Create: `tests/callers/test-rust-happy.yml`, `tests/callers/test-rust-cov-fail.yml`
- Create: `.github/workflows/test-rust.yml`

- [ ] **Step 1: Write `tests/fixtures/lint-test/rust-cov-fail/Cargo.toml`**

```toml
[package]
name = "rust-cov-fail"
version = "0.1.0"
edition = "2021"
publish = false

[lib]
path = "src/lib.rs"
```

- [ ] **Step 2: Write `tests/fixtures/lint-test/rust-cov-fail/src/lib.rs`**

```rust
//! Coverage-fail fixture: code with no tests.

pub fn untested(a: i64) -> i64 {
    a * 2
}
```

- [ ] **Step 3: Sanity-check locally (requires cargo-llvm-cov installed)**

```bash
cd tests/fixtures/lint-test/rust-cov-fail
cargo install cargo-llvm-cov --locked
cargo llvm-cov --summary-only --fail-under-lines 90 || echo "cov-fail correctly fails"
cd -
```

Expected: cargo-llvm-cov exits non-zero with "Coverage is less than --fail-under-lines threshold".

- [ ] **Step 4: Write `.github/workflows/test-rust.yml`**

```yaml
# .github/workflows/test-rust.yml
# Reusable workflow: run cargo test + cargo-llvm-cov coverage gate.
name: test-rust
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux","X64"]'
      working_directory:
        description: 'Crate root directory.'
        required: false
        type: string
        default: '.'
      rust_toolchain:
        description: 'rustup toolchain. Empty → rustup defaults.'
        required: false
        type: string
        default: ''
      coverage_threshold:
        description: 'Minimum line coverage percentage (integer 0-100).'
        required: false
        type: number
        default: 90
      # renovate: datasource=github-releases depName=taiki-e/cargo-llvm-cov
      cargo_llvm_cov_version:
        description: 'cargo-llvm-cov release tag.'
        required: false
        type: string
        default: 'v0.6.16'

permissions:
  contents: read

concurrency:
  group: test-rust-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  test:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@v6

      - name: Install Rust toolchain (explicit)
        if: inputs.rust_toolchain != ''
        uses: dtolnay/rust-toolchain@master
        with:
          toolchain: ${{ inputs.rust_toolchain }}
          components: llvm-tools-preview

      - name: Install Rust toolchain (default)
        if: inputs.rust_toolchain == ''
        uses: dtolnay/rust-toolchain@stable
        with:
          components: llvm-tools-preview

      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: ${{ inputs.working_directory }}

      - uses: taiki-e/install-action@v2
        with:
          tool: cargo-llvm-cov@${{ inputs.cargo_llvm_cov_version }}

      - name: cargo llvm-cov with threshold
        working-directory: ${{ inputs.working_directory }}
        run: cargo llvm-cov --summary-only --fail-under-lines ${{ inputs.coverage_threshold }}
```

- [ ] **Step 5: Write `tests/callers/test-rust-happy.yml`**

```yaml
# tests/callers/test-rust-happy.yml
name: caller-test-rust-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/test-rust.yml'
      - 'tests/callers/test-rust-happy.yml'
      - 'tests/fixtures/lint-test/rust-happy/**'

jobs:
  test:
    uses: ./.github/workflows/test-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-happy
      coverage_threshold: 90
```

- [ ] **Step 6: Write `tests/callers/test-rust-cov-fail.yml`**

```yaml
# tests/callers/test-rust-cov-fail.yml
name: caller-test-rust-cov-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/test-rust.yml'
      - 'tests/callers/test-rust-cov-fail.yml'
      - 'tests/fixtures/lint-test/rust-cov-fail/**'

jobs:
  test:
    uses: ./.github/workflows/test-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-cov-fail
      coverage_threshold: 90

  assert-failed:
    needs: test
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert test job failed
        env:
          RESULT: ${{ needs.test.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected test job to fail (coverage gate), got: $RESULT"
            exit 1
          fi
```

- [ ] **Step 7: actionlint**

```bash
actionlint .github/workflows/test-rust.yml tests/callers/test-rust-happy.yml tests/callers/test-rust-cov-fail.yml
```

Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/lint-test/rust-cov-fail tests/callers/test-rust-happy.yml tests/callers/test-rust-cov-fail.yml .github/workflows/test-rust.yml
git commit -m "feat(atom): test-rust reusable workflow + callers + cov-fail fixture"
```

---

### Task 8: `lint-helm.yml` + helm-lint-fail fixture + callers

**Files:**
- Create: `tests/fixtures/lint-test/helm-lint-fail/Chart.yaml`
- Create: `tests/callers/lint-helm-happy.yml`, `tests/callers/lint-helm-fail.yml`
- Create: `.github/workflows/lint-helm.yml`

The happy fixture **reuses the existing `tests/fixtures/helm-only/` directory** (a valid Helm chart added during Phase 1 of the smarter-onboarding work). Verify before starting:

```bash
ls tests/fixtures/helm-only/Chart.yaml tests/fixtures/helm-only/values.yaml
```

If either is missing, fall back to creating a minimal chart in `tests/fixtures/lint-test/helm-happy/` instead — but the smarter-onboarding work confirmed both exist as of `v3.1.0`.

- [ ] **Step 1: Verify the existing helm-only fixture passes `helm lint`**

```bash
helm lint tests/fixtures/helm-only
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 2: Write `tests/fixtures/lint-test/helm-lint-fail/Chart.yaml`**

```yaml
apiVersion: v2
# Intentionally invalid: missing required `name` field.
version: 0.1.0
description: Lint-fail fixture (Helm)
```

A Helm chart without `name` fails `helm lint` with `Error: validation: chart.metadata.name is required`.

- [ ] **Step 3: Sanity-check the lint-fail fixture**

```bash
helm lint tests/fixtures/lint-test/helm-lint-fail || echo "helm lint correctly failed"
```

Expected: non-zero exit + "chart.metadata.name is required" in stderr.

- [ ] **Step 4: Write `.github/workflows/lint-helm.yml`**

```yaml
# .github/workflows/lint-helm.yml
# Reusable workflow: lint Helm chart(s) with `helm lint` + `ct lint`.
name: lint-helm
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
      working_directory:
        description: 'Repo root for ct (charts_dir is relative to this).'
        required: false
        type: string
        default: '.'
      charts_dir:
        description: 'Directory containing one or more charts (relative to working_directory).'
        required: false
        type: string
        default: 'charts'
      # renovate: datasource=github-releases depName=helm/helm
      helm_version:
        description: 'Helm CLI version.'
        required: false
        type: string
        default: 'v3.16.3'
      # renovate: datasource=github-releases depName=helm/chart-testing
      ct_version:
        description: 'chart-testing (ct) version.'
        required: false
        type: string
        default: 'v3.11.0'

permissions:
  contents: read

concurrency:
  group: lint-helm-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}-${{ inputs.charts_dir }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0   # ct needs git history for --target-branch diff

      - uses: azure/setup-helm@v4
        with:
          version: ${{ inputs.helm_version }}

      - uses: helm/chart-testing-action@v3
        with:
          version: ${{ inputs.ct_version }}

      - name: helm lint (all charts)
        working-directory: ${{ inputs.working_directory }}
        env:
          CHARTS_DIR: ${{ inputs.charts_dir }}
        run: |
          set -euo pipefail
          shopt -s nullglob
          # If charts_dir is itself a chart, lint it directly; else lint each subdir that has Chart.yaml.
          if [[ -f "$CHARTS_DIR/Chart.yaml" ]]; then
            helm lint "$CHARTS_DIR"
          else
            found=0
            for d in "$CHARTS_DIR"/*/; do
              if [[ -f "${d%/}/Chart.yaml" ]]; then
                helm lint "${d%/}"
                found=1
              fi
            done
            if (( found == 0 )); then
              echo "::error::no chart found in $CHARTS_DIR (no Chart.yaml in $CHARTS_DIR or its immediate subdirs)"
              exit 1
            fi
          fi

      - name: ct lint
        working-directory: ${{ inputs.working_directory }}
        run: |
          ct lint --all --validate-maintainers=false \
            --chart-dirs="${{ inputs.charts_dir }}" \
            --target-branch="${{ github.base_ref || 'main' }}"
```

- [ ] **Step 5: Write `tests/callers/lint-helm-happy.yml`**

```yaml
# tests/callers/lint-helm-happy.yml
# Happy-path caller: reuses tests/fixtures/helm-only. `charts_dir` points
# at the fixture itself (which IS the chart), exercising the
# "Chart.yaml at charts_dir root" branch of the atom.
name: caller-lint-helm-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-helm.yml'
      - 'tests/callers/lint-helm-happy.yml'
      - 'tests/fixtures/helm-only/**'

jobs:
  lint:
    uses: ./.github/workflows/lint-helm.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures
      charts_dir: helm-only
```

- [ ] **Step 6: Write `tests/callers/lint-helm-fail.yml`**

```yaml
# tests/callers/lint-helm-fail.yml
# Failure-path caller: Chart.yaml is missing required fields.
name: caller-lint-helm-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/lint-helm.yml'
      - 'tests/callers/lint-helm-fail.yml'
      - 'tests/fixtures/lint-test/helm-lint-fail/**'

jobs:
  lint:
    uses: ./.github/workflows/lint-helm.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test
      charts_dir: helm-lint-fail

  assert-failed:
    needs: lint
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.lint.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
```

- [ ] **Step 7: actionlint**

```bash
actionlint .github/workflows/lint-helm.yml tests/callers/lint-helm-happy.yml tests/callers/lint-helm-fail.yml
```

Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/lint-test/helm-lint-fail tests/callers/lint-helm-happy.yml tests/callers/lint-helm-fail.yml .github/workflows/lint-helm.yml
git commit -m "feat(atom): lint-helm reusable workflow + callers + lint-fail fixture"
```

---

### Task 9: README + operations docs update

**Files:**
- Modify: `README.md` (add the 7 new atoms to whatever existing atom table/list there is)
- Modify: `docs/operations.md` (add a sentence to the atom section)

- [ ] **Step 1: Open `README.md` and locate the atoms list/table**

```bash
rg -n "docker-build|trivy-fs|atom" README.md | head -20
```

- [ ] **Step 2: Insert the seven new atoms following the existing row format**

For each atom, add a row with: atom path, one-sentence description, link to the workflow file. If the README uses prose rather than a table, append a paragraph listing the seven atoms with one sentence each. Match the surrounding tone — do not introduce a new heading style.

The seven entries to add, in declaration order:

- `.github/workflows/lint-go.yml` — Lint Go code (`go vet` + golangci-lint).
- `.github/workflows/test-go.yml` — Run `go test` with a coverage gate (default ≥ 90 %).
- `.github/workflows/lint-python.yml` — Lint Python (ruff check + format + mypy); auto-detects Poetry / uv / pip.
- `.github/workflows/test-python.yml` — Run pytest with coverage gate (default ≥ 90 %); same pm auto-detect.
- `.github/workflows/lint-rust.yml` — Lint Rust (`cargo fmt --check` + `cargo clippy -D warnings`).
- `.github/workflows/test-rust.yml` — Run `cargo test` with `cargo-llvm-cov` coverage gate.
- `.github/workflows/lint-helm.yml` — Lint Helm charts (`helm lint` + `ct lint`).

- [ ] **Step 3: Append a sentence to `docs/operations.md` under the existing atom section**

Same seven items; mirror the README phrasing. If there is no atom section, look for the section that describes consuming the catalog (likely titled "Reusable workflows" or similar) and append there.

- [ ] **Step 4: Run yamllint and actionlint on the workflows directory as a sanity pass**

```bash
yamllint .github/workflows/
actionlint
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/operations.md
git commit -m "docs: list lint/test atoms in README and operations.md"
```

---

### PR1 wrap-up

- [ ] **Push and open PR1**

```bash
git push -u origin feat/lint-test-atoms-pr1
gh pr create --fill --base main
```

PR title: `feat(atoms): lint-{go,python,rust,helm} and test-{go,python,rust}`. PR body: list the seven atoms and the new composite action; link to the spec.

- [ ] **Wait for self-CI to go green**

```bash
gh pr checks --watch
```

Expected: `validate` (actionlint + yamllint), all 14 caller workflows that triggered (only those whose `paths:` matched the diff). The fail-caller workflows should show their `assert-failed` job green (they correctly observed failure).

- [ ] **Address any review feedback, then merge with squash**

Use squash merge to keep `main` history clean (consistent with prior phase merges).

---

## PR2 tasks — detection warnings + template rewrite

Branch off `main` (after PR1 lands) as `feat/lint-test-atoms-pr2`.

### Task 10: Detection — warn on unsupported `primary_language`

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh`
- Modify: `scripts/onboard-detect.sh` (call site — exact line determined at edit time)
- Modify: `tests/shell/onboard-detect.bats` (add test)

The detector currently emits `primary_language` for each component but only supports `{go, python, rust, helm}` in the template. For any other value (today: `node`, future: anything new), the renderer would silently skip emitting lint/test jobs. We surface this by emitting a warning into `profile.json.warnings[]`.

- [ ] **Step 1: Read the existing detect-lib to find where warnings are emitted**

```bash
rg -n "warnings|emit_warning|profile_warn" scripts/lib/onboard-detect-lib.sh scripts/onboard-detect.sh
```

- [ ] **Step 2: Write the failing bats test in `tests/shell/onboard-detect.bats`**

Append this test at the end of the file (or in the appropriate `describe` block — match the existing test style):

```bash
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
```

- [ ] **Step 3: Run the test, confirm it fails**

```bash
bats tests/shell/onboard-detect.bats --filter "no lint/test atom"
```

Expected: FAIL — current code does not emit the `no_lint_test_atom` warning.

- [ ] **Step 4: Extend `scripts/lib/onboard-detect-lib.sh`**

Find the function that finalizes the profile JSON (it emits `warnings: [...]`). After the existing language detection assigns `primary_language` to each component, add:

```bash
# Emit a warning for any component whose primary_language has no lint/test atom
# in the catalog. Keep this list in sync with docs/adopter-templates/skeletons/ci.yml.tmpl.
emit_unsupported_language_warnings() {
  local profile_json="$1"
  local supported='go|python|rust|helm'
  echo "$profile_json" | jq --arg supported "$supported" '
    . as $root
    | .components
    | map(.primary_language)
    | unique
    | map(select(test("^(" + $supported + ")$") | not))
    | map({
        code: "no_lint_test_atom",
        primary_language: .,
        message: ("no lint/test atom for primary_language=" + . + "; rendered ci.yml will fall back to secscan only")
      })
    | $root | .warnings += .
  '
}
```

Replace the final profile-emit step to pipe through `emit_unsupported_language_warnings`. Exact wiring depends on the existing structure (a single `jq` pipeline or staged composition) — match the style.

If there is no clean seam, add a final pre-emit step in `scripts/onboard-detect.sh`:

```bash
profile=$(echo "$profile" | jq '.warnings += [(.components | map(.primary_language) | unique | map(select(. != "go" and . != "python" and . != "rust" and . != "helm")) | map({code: "no_lint_test_atom", primary_language: ., message: ("no lint/test atom for primary_language=" + . + "; rendered ci.yml will fall back to secscan only")}))[]]')
```

(One of these two patches goes in, not both — choose based on how the existing code is shaped.)

- [ ] **Step 5: Re-run the test, confirm it passes**

```bash
bats tests/shell/onboard-detect.bats --filter "no lint/test atom"
```

Expected: PASS.

- [ ] **Step 6: Run the full bats suite to confirm no regression**

```bash
bats tests/shell/
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh scripts/onboard-detect.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): warn when component primary_language has no lint/test atom"
```

---

### Task 11: Rewrite `ci.yml.tmpl` + golden tests

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl`
- Create: `tests/shell/golden/ci/single-go.yml`, `single-python.yml`, `single-rust.yml`, `single-helm.yml`, `monorepo-mixed.yml`, `unsupported-node.yml`
- Modify: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Inspect how onboard-render.bats currently invokes the renderer**

```bash
rg -n "onboard-render|gomplate|ci.yml.tmpl" tests/shell/onboard-render.bats
```

Note the exact invocation pattern: typically `bash scripts/onboard-render.sh <catalog> <target> <profile.json> <pin>` then inspecting `<target>/.github/workflows/ci.yml`.

- [ ] **Step 2: Add a helper to the top of `tests/shell/onboard-render.bats` (skip if already present)**

If the file already has a `render_profile()` or equivalent helper, reuse it. Otherwise add this above the first `@test` block:

```bash
# Run the renderer against an inline JSON profile and a tmpdir target,
# then return the rendered ci.yml path on stdout.
render_ci_for_profile() {
  local profile_json="$1"
  local profile="$BATS_TEST_TMPDIR/profile-$$.json"
  local target="$BATS_TEST_TMPDIR/target-$$"
  printf '%s' "$profile_json" > "$profile"
  mkdir -p "$target"
  bash "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$profile" "v3" >&2
  echo "$target/.github/workflows/ci.yml"
}
```

- [ ] **Step 3: Write the six failing golden-file tests** at the end of `tests/shell/onboard-render.bats`:

```bash
@test "ci.yml renders lint+test jobs for a single go component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-go.yml" "$rendered"
}

@test "ci.yml renders lint+test jobs for a single python component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["python"], "primary_language": "python",
      "release_please_type": "python", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-python.yml" "$rendered"
}

@test "ci.yml renders lint+test jobs for a single rust component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["rust"], "primary_language": "rust",
      "release_please_type": "rust", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-rust.yml" "$rendered"
}

@test "ci.yml renders lint job for a single helm component (no test-helm)" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["helm"], "primary_language": "helm",
      "release_please_type": "helm", "role": "chart",
      "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": "Chart.yaml"}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-helm.yml" "$rendered"
}

@test "ci.yml renders mixed monorepo (go service + helm chart)" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": true,
    "components": [
      {"path": "services/api", "languages": ["go"], "primary_language": "go",
       "release_please_type": "go", "role": "service",
       "dockerfiles": [{"path":"services/api/Dockerfile","image_name":"$REPO-api","image_name_source":"derived"}],
       "release_signals": {"goreleaser_config": null, "chart_yaml": null}},
      {"path": "charts/web", "languages": ["helm"], "primary_language": "helm",
       "release_please_type": "helm", "role": "chart",
       "dockerfiles": [],
       "release_signals": {"goreleaser_config": null, "chart_yaml": "charts/web/Chart.yaml"}}
    ],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/monorepo-mixed.yml" "$rendered"
}

@test "ci.yml renders secscan-only for an unsupported language" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["node"], "primary_language": "node",
      "release_please_type": "node", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [],
    "warnings": [{"code":"no_lint_test_atom","primary_language":"node","message":"no lint/test atom for primary_language=node; rendered ci.yml will fall back to secscan only"}]
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/unsupported-node.yml" "$rendered"
}
```

- [ ] **Step 4: Run the new tests, confirm they fail**

```bash
bats tests/shell/onboard-render.bats --filter "ci.yml renders"
```

Expected: FAIL on all six — either the template doesn't yet loop over components, or the golden files don't exist yet, or both.

- [ ] **Step 5: Rewrite `docs/adopter-templates/skeletons/ci.yml.tmpl`**

```yaml
{{- /*
  ci.yml — PR-time CI workflow.

  Always emits a `secscan` job (trivy-fs). For each profile component,
  emits per-language lint + test jobs keyed off `primary_language`.
  Job-id pattern: <kind>-<lang>-<suffix>.
  Suffix rule:  path == "."  → "root"
                otherwise    → path with `/` → `-`
  The conditional avoids the naive `replaceAll "." "root"` which would
  mangle paths containing dots (e.g. `services/v2.api`).
*/ -}}
{{- $pin := .pin -}}
name: ci
on:
  pull_request:

jobs:
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      actions: read
    secrets: inherit
{{ range $i, $c := .profile.components }}
{{- $suffix := "" -}}
{{- if eq $c.path "." -}}
{{- $suffix = "root" -}}
{{- else -}}
{{- $suffix = $c.path | replaceAll "/" "-" -}}
{{- end }}
{{- if eq $c.primary_language "go" }}
  lint-go-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-go.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
  test-go-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-go.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      coverage_threshold: 90
    secrets: inherit
{{- else if eq $c.primary_language "python" }}
  lint-python-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-python.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
  test-python-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-python.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      coverage_threshold: 90
    secrets: inherit
{{- else if eq $c.primary_language "rust" }}
  lint-rust-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-rust.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
  test-rust-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-rust.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      coverage_threshold: 90
    secrets: inherit
{{- else if eq $c.primary_language "helm" }}
  lint-helm-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-helm.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
{{- end }}
{{- end }}
```

- [ ] **Step 6: Capture each golden file by running the renderer once per case**

Create `tests/shell/golden/ci/` first:

```bash
mkdir -p tests/shell/golden/ci
```

For each case below, run the renderer and copy its output into the golden path. Each block is self-contained — engineer running tasks out of order can copy-paste any one.

**single-go:**

```bash
tmp=$(mktemp -d); cat > "$tmp/profile.json" <<'JSON'
{"schema_version":1,"target_repo":"serverkraken/svc","default_branch":"main","current_version":"0.1.0","monorepo":false,
 "components":[{"path":".","languages":["go"],"primary_language":"go","release_please_type":"go","role":"service",
   "dockerfiles":[{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
   "release_signals":{"goreleaser_config":null,"chart_yaml":null}}],
 "legacy_ci":[],"warnings":[]}
JSON
target=$(mktemp -d); bash scripts/onboard-render.sh . "$target" "$tmp/profile.json" v3
cp "$target/.github/workflows/ci.yml" tests/shell/golden/ci/single-go.yml
```

**single-python:**

```bash
tmp=$(mktemp -d); cat > "$tmp/profile.json" <<'JSON'
{"schema_version":1,"target_repo":"serverkraken/svc","default_branch":"main","current_version":"0.1.0","monorepo":false,
 "components":[{"path":".","languages":["python"],"primary_language":"python","release_please_type":"python","role":"service",
   "dockerfiles":[{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
   "release_signals":{"goreleaser_config":null,"chart_yaml":null}}],
 "legacy_ci":[],"warnings":[]}
JSON
target=$(mktemp -d); bash scripts/onboard-render.sh . "$target" "$tmp/profile.json" v3
cp "$target/.github/workflows/ci.yml" tests/shell/golden/ci/single-python.yml
```

**single-rust:**

```bash
tmp=$(mktemp -d); cat > "$tmp/profile.json" <<'JSON'
{"schema_version":1,"target_repo":"serverkraken/svc","default_branch":"main","current_version":"0.1.0","monorepo":false,
 "components":[{"path":".","languages":["rust"],"primary_language":"rust","release_please_type":"rust","role":"service",
   "dockerfiles":[{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
   "release_signals":{"goreleaser_config":null,"chart_yaml":null}}],
 "legacy_ci":[],"warnings":[]}
JSON
target=$(mktemp -d); bash scripts/onboard-render.sh . "$target" "$tmp/profile.json" v3
cp "$target/.github/workflows/ci.yml" tests/shell/golden/ci/single-rust.yml
```

**single-helm:**

```bash
tmp=$(mktemp -d); cat > "$tmp/profile.json" <<'JSON'
{"schema_version":1,"target_repo":"serverkraken/svc","default_branch":"main","current_version":"0.1.0","monorepo":false,
 "components":[{"path":".","languages":["helm"],"primary_language":"helm","release_please_type":"helm","role":"chart",
   "dockerfiles":[],
   "release_signals":{"goreleaser_config":null,"chart_yaml":"Chart.yaml"}}],
 "legacy_ci":[],"warnings":[]}
JSON
target=$(mktemp -d); bash scripts/onboard-render.sh . "$target" "$tmp/profile.json" v3
cp "$target/.github/workflows/ci.yml" tests/shell/golden/ci/single-helm.yml
```

**monorepo-mixed (go service + helm chart):**

```bash
tmp=$(mktemp -d); cat > "$tmp/profile.json" <<'JSON'
{"schema_version":1,"target_repo":"serverkraken/svc","default_branch":"main","current_version":"0.1.0","monorepo":true,
 "components":[
   {"path":"services/api","languages":["go"],"primary_language":"go","release_please_type":"go","role":"service",
    "dockerfiles":[{"path":"services/api/Dockerfile","image_name":"$REPO-api","image_name_source":"derived"}],
    "release_signals":{"goreleaser_config":null,"chart_yaml":null}},
   {"path":"charts/web","languages":["helm"],"primary_language":"helm","release_please_type":"helm","role":"chart",
    "dockerfiles":[],
    "release_signals":{"goreleaser_config":null,"chart_yaml":"charts/web/Chart.yaml"}}
 ],
 "legacy_ci":[],"warnings":[]}
JSON
target=$(mktemp -d); bash scripts/onboard-render.sh . "$target" "$tmp/profile.json" v3
cp "$target/.github/workflows/ci.yml" tests/shell/golden/ci/monorepo-mixed.yml
```

**unsupported-node:**

```bash
tmp=$(mktemp -d); cat > "$tmp/profile.json" <<'JSON'
{"schema_version":1,"target_repo":"serverkraken/svc","default_branch":"main","current_version":"0.1.0","monorepo":false,
 "components":[{"path":".","languages":["node"],"primary_language":"node","release_please_type":"node","role":"service",
   "dockerfiles":[{"path":"Dockerfile","image_name":"$REPO","image_name_source":"derived"}],
   "release_signals":{"goreleaser_config":null,"chart_yaml":null}}],
 "legacy_ci":[],
 "warnings":[{"code":"no_lint_test_atom","primary_language":"node","message":"no lint/test atom for primary_language=node; rendered ci.yml will fall back to secscan only"}]}
JSON
target=$(mktemp -d); bash scripts/onboard-render.sh . "$target" "$tmp/profile.json" v3
cp "$target/.github/workflows/ci.yml" tests/shell/golden/ci/unsupported-node.yml
```

- [ ] **Step 7: Eyeball each golden file**

Open all six and confirm:
- `single-go.yml` has `secscan`, `lint-go-root`, `test-go-root`.
- `single-python.yml` has `secscan`, `lint-python-root`, `test-python-root`.
- `single-rust.yml` has `secscan`, `lint-rust-root`, `test-rust-root`.
- `single-helm.yml` has `secscan`, `lint-helm-root`, no `test-helm-*`.
- `monorepo-mixed.yml` has `secscan`, `lint-go-services-api`, `test-go-services-api`, `lint-helm-charts-web`. No `test-helm-*`.
- `unsupported-node.yml` has `secscan` only — no `lint-*` or `test-*` jobs.

If any case looks wrong, fix the template in Step 5 and rerun the corresponding Step 6 block to refresh the golden.

- [ ] **Step 8: Run the bats suite, confirm all six pass**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all tests pass, including the six new ones.

- [ ] **Step 9: Commit**

```bash
git add docs/adopter-templates/skeletons/ci.yml.tmpl tests/shell/golden/ci tests/shell/onboard-render.bats
git commit -m "feat(onboard): wire lint/test atoms into ci.yml skeleton + golden tests"
```

---

### PR2 wrap-up

- [ ] **Push and open PR2**

```bash
git push -u origin feat/lint-test-atoms-pr2
gh pr create --fill --base main
```

PR title: `feat(onboard): consume lint/test atoms from ci.yml skeleton`. Body: link to the spec, mention the unsupported-language warning extension.

- [ ] **Wait for self-CI green**

```bash
gh pr checks --watch
```

- [ ] **Merge with squash**

---

## Release task (between PR2 merge and Task 12)

- [ ] **Wait for release-please to open its release PR**

After PR2 lands on `main`, the `release` workflow (release-please) opens a `chore(main): release X.Y.Z` PR within minutes. Watch for it:

```bash
gh pr list --search "release-please" --state open
```

- [ ] **Review the release PR's CHANGELOG entries and version bump**

Confirm the version bump is `minor` (3.1.x → 3.2.0) — both PRs were `feat:`, no `feat!:` or `BREAKING CHANGE:`.

- [ ] **Merge the release PR**

```bash
gh pr merge <release-pr-number> --squash
```

The `catalog-release` workflow then tags `v3.2.0` and moves the `v3` / `v3.2` floating tags.

- [ ] **Confirm the tags moved**

```bash
git fetch --tags --force origin
git tag --sort=-v:refname | head -5
# Expected:
# v3.2.0
# v3.2
# v3.1.0
# v3.1
# v3
```

---

## PR3 tasks — reference-adopter migration

This phase has no catalog file changes. It runs the onboard workflow against the two reference adopters.

### Task 12: Dry-run `onboard.yml` against blupod-ui and flow

- [ ] **Step 1: Dry-run against blupod-ui**

```bash
gh workflow run onboard.yml --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/blupod-ui \
  -f dry_run=true \
  -f pin_version=v3
```

- [ ] **Step 2: Watch and inspect step summary**

```bash
sleep 3
run_id=$(gh run list --workflow onboard.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run_id" --exit-status
gh run view "$run_id" --log | rg -n "Detected components|lint-python|test-python|warnings|legacy_ci|secscan"
```

Expected output: rendered `ci.yml` contains `secscan`, `lint-python-root`, `test-python-root`. Step summary's "Detected components" table shows the python component.

- [ ] **Step 3: Dry-run against flow**

```bash
gh workflow run onboard.yml --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/flow \
  -f dry_run=true \
  -f pin_version=v3
```

- [ ] **Step 4: Watch and inspect**

```bash
sleep 3
run_id=$(gh run list --workflow onboard.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run_id" --exit-status
gh run view "$run_id" --log | rg -n "Detected components|lint-go|test-go|warnings|legacy_ci|secscan"
```

Expected: rendered `ci.yml` contains `secscan`, `lint-go-root`, `test-go-root`.

- [ ] **Step 5: If either run flags unexpected drift, file an issue and stop**

If detection finds an unexpected `primary_language`, or rendered jobs are missing/extra, file a GitHub issue against `serverkraken/reusable-workflows` describing the discrepancy and stop the migration. Do **not** edit catalog code mid-migration. Resume only after the issue is fixed in a follow-up PR and a new release is cut.

### Task 13: Real onboarding run for blupod-ui

- [ ] **Step 1: Dispatch onboard.yml with dry_run=false against blupod-ui**

```bash
gh workflow run onboard.yml --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/blupod-ui \
  -f dry_run=false \
  -f pin_version=v3
```

- [ ] **Step 2: Watch the run, then inspect the resulting PRs**

```bash
sleep 5
run_id=$(gh run list --workflow onboard.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run_id" --exit-status
gh pr list --repo serverkraken/blupod-ui --search 'in:title onboard reusable workflows' --state open
gh pr list --repo serverkraken/blupod-ui --search 'in:title remove legacy workflows' --state open
```

Expected: two open PRs (Add + Cleanup).

- [ ] **Step 3: Verify the Add PR's new ci.yml runs green**

```bash
add_pr=$(gh pr list --repo serverkraken/blupod-ui --search 'in:title onboard reusable workflows' --state open --json number -q '.[0].number')
gh pr checks "$add_pr" --repo serverkraken/blupod-ui --watch
```

Expected: `secscan`, `lint-python-root`, `test-python-root` all green. If a test fails because blupod-ui's coverage is < 90 %, that is a real-world finding: do NOT lower the threshold in the catalog. Either fix the adopter's tests in a separate PR first, or close both onboarding PRs and revisit after the adopter improves coverage.

- [ ] **Step 4: Merge the Add PR, then the Cleanup PR**

```bash
gh pr merge "$add_pr" --repo serverkraken/blupod-ui --squash
cleanup_pr=$(gh pr list --repo serverkraken/blupod-ui --search 'in:title remove legacy workflows' --state open --json number -q '.[0].number')
gh pr merge "$cleanup_pr" --repo serverkraken/blupod-ui --squash
```

### Task 14: Real onboarding run for flow

Repeat Task 13 with `serverkraken/flow`:

- [ ] **Step 1: Dispatch**

```bash
gh workflow run onboard.yml --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/flow \
  -f dry_run=false \
  -f pin_version=v3
```

- [ ] **Step 2: Watch + verify**

```bash
sleep 5
run_id=$(gh run list --workflow onboard.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run_id" --exit-status
add_pr=$(gh pr list --repo serverkraken/flow --search 'in:title onboard reusable workflows' --state open --json number -q '.[0].number')
gh pr checks "$add_pr" --repo serverkraken/flow --watch
```

Expected: `secscan`, `lint-go-root`, `test-go-root` all green.

- [ ] **Step 3: Merge Add + Cleanup**

```bash
gh pr merge "$add_pr" --repo serverkraken/flow --squash
cleanup_pr=$(gh pr list --repo serverkraken/flow --search 'in:title remove legacy workflows' --state open --json number -q '.[0].number')
gh pr merge "$cleanup_pr" --repo serverkraken/flow --squash
```

### Task 15: Drift-check baseline confirmation

- [ ] **Step 1: Manually trigger drift-check.yml**

```bash
gh workflow run drift-check.yml --repo serverkraken/reusable-workflows
```

- [ ] **Step 2: Confirm both adopters report `clean` on `v3.2.0`**

```bash
sleep 5
run_id=$(gh run list --workflow drift-check.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run_id" --exit-status
gh issue list --repo serverkraken/reusable-workflows --search 'in:title Onboarding Drift Report'
```

Open the rolling issue; both `blupod-ui` and `flow` should be `status: clean` against `v3.2.0`.

If either shows `behind` or `modified`, investigate before declaring the spec shipped.

---

## Definition of done

- [ ] All 7 atom workflows live at `.github/workflows/<atom>.yml`, each green on its happy-path caller and red-then-asserted on its failure-path caller.
- [ ] `actions/setup-python-deps/action.yml` exists, all three pm probes covered by the python happy callers.
- [ ] `docs/adopter-templates/skeletons/ci.yml.tmpl` emits per-component lint+test jobs; 6 golden bats tests pass.
- [ ] Detection emits `no_lint_test_atom` warning for unsupported languages; bats test passes.
- [ ] `v3.2.0` tag exists; `v3` and `v3.2` floating tags point at it.
- [ ] `serverkraken/blupod-ui` and `serverkraken/flow` both have the new `ci.yml` merged, legacy workflows removed, and drift-check reports `clean`.
