# Lint & Test Atoms — Design

**Status:** approved (brainstorm)
**Date:** 2026-05-19
**Backlog reference:** `docs/superpowers/backlog.md` § "Lint- und Test-Atoms (Sprach-spezifisch)"
**Related specs:** `2026-05-16-reusable-workflows-design.md` § "Out of Scope (future specs)", `2026-05-17-smarter-onboarding-design.md` (consumes the new atoms via the rendered `ci.yml`).

---

## 1. Motivation

The catalog currently exposes build, scan, and release atoms (`docker-build*.yml`, `trivy-*.yml`, `helm-publish.yml`, `goreleaser.yml`) plus the smarter-onboarding pipeline (`onboard.yml`, `drift-check.yml`). It does **not** expose lint or test atoms. Every downstream `serverkraken/*` repository therefore continues to hand-roll `golangci-lint`/`ruff`/`pytest`/`clippy`/`helm lint` invocations — the exact duplication this catalog exists to eliminate.

This spec adds the seven missing atoms in a single coordinated release and wires them into the smarter-onboarding `ci.yml` skeleton so newly-onboarded repos get linting and testing without bespoke YAML.

## 2. Goals

- Ship reusable `workflow_call` workflows for **lint** (Go, Python, Rust, Helm) and **test** (Go, Python, Rust) — seven atoms total.
- Every test atom enforces a configurable coverage gate (default ≥ 90 %).
- Atoms auto-detect their language toolchain version from the adopter's source files (`go.mod`, `pyproject.toml`, `rust-toolchain.toml`) and accept an explicit input override.
- Adopter `ci.yml.tmpl` consumes the atoms by looping over the smarter-onboarding `profile.json` components, so single-component repos and future monorepos work from the same template.
- Onboarding migration: after release, run `onboard.yml` against `serverkraken/blupod-ui` (Python) and `serverkraken/flow` (Go) end-to-end to prove the atoms on real adopters.

### Out of scope (deferred)

- SARIF upload to GitHub code-scanning from any lint atom. Atoms exit non-zero on findings; that is the gate. SARIF is a future spec.
- Coverage HTML / Cobertura artifact upload. Threshold gate only in v1.
- Non-pytest Python test runners (unittest, nose).
- Node.js atoms (`lint-node.yml`, `test-node.yml`). Detection emits `node` as a language; rendering will fall through to `secscan`-only with a warning.
- Caching tuning beyond the action-native defaults (`actions/setup-go` auto-caches modules, `Swatinem/rust-cache@v2` for cargo, etc.).
- Re-using atoms from atoms (e.g. `test-go` calling `lint-go`). Each atom is independent; the adopter `ci.yml` composes them.

## 3. Architecture Overview

```
adopter ci.yml  ──┬── lint-{lang}.yml@vX  ──► setup → install → tool → fail-on-finding
                  ├── test-{lang}.yml@vX  ──► setup → install → tool → coverage-gate
                  └── trivy-fs.yml@vX     (already shipped)

profile.json ─► onboard-render ─► ci.yml.tmpl ─► loops .components[] ─► emits lint+test jobs per language
```

The atoms are leaves. The renderer composes them. Detection (already shipped) supplies the `.components[]` array; this spec only extends `warnings[]` to flag unsupported languages.

## 4. Atom contracts

### 4.1 Common inputs (all 7 atoms)

| Input | Type | Default | Purpose |
|---|---|---|---|
| `runs_on` | string (JSON-array) | see § 4.2 per atom | Override runner pool. |
| `working_directory` | string | `.` | Component sub-path (for monorepos). Atom resolves all paths relative to this. |

### 4.2 Per-atom inputs

| Atom | Toolchain input (empty → auto-detect from file) | Tool-version inputs (Renovate-managed defaults) | Gate inputs | Default `runs_on` |
|---|---|---|---|---|
| `lint-go.yml` | `go_version` ← `go.mod` | `golangci_lint_version` | — | `[self-hosted, Linux, X64]` |
| `test-go.yml` | `go_version` ← `go.mod` | — (Go built-in cover) | `coverage_threshold` (90) | `[self-hosted, Linux, X64]` |
| `lint-python.yml` | `python_version` ← `pyproject.toml` python constraint | — (tool versions follow adopter lockfile) | — | `[self-hosted, Linux]` |
| `test-python.yml` | `python_version` ← `pyproject.toml` | — | `coverage_threshold` (90) | `[self-hosted, Linux]` |
| `lint-rust.yml` | `rust_toolchain` ← `rust-toolchain.toml` (rustup native) | — | — | `[self-hosted, Linux, X64]` |
| `test-rust.yml` | `rust_toolchain` ← `rust-toolchain.toml` | `cargo_llvm_cov_version` | `coverage_threshold` (90) | `[self-hosted, Linux, X64]` |
| `lint-helm.yml` | — (Helm CLI not in adopter) | `helm_version`, `ct_version` | — | `[self-hosted, Linux]` |

Additional helm inputs: `charts_dir` (default `charts`).

### 4.3 Empty-string sentinel for auto-detect

Every toolchain input defaults to the empty string. An atom step interprets it as "let the underlying setup action read the source file":

- Go: `actions/setup-go@v5` with `go-version-file: ${{ inputs.working_directory }}/go.mod` when `inputs.go_version == ''`; otherwise `go-version: ${{ inputs.go_version }}`.
- Python: `actions/setup-python@v5` with `python-version-file: ${{ inputs.working_directory }}/pyproject.toml` when empty; otherwise `python-version`.
- Rust: when `rust_toolchain == ''`, rustup honors `rust-toolchain.toml` in `working_directory` natively. Otherwise `dtolnay/rust-toolchain@${{ inputs.rust_toolchain }}`.

This way the common case (`uses: …lint-python.yml@v3`) needs no `with:` block at all.

### 4.4 Permissions

Every atom declares `permissions: contents: read` at the top. No write permissions in v1 (no SARIF upload, no PR comments, no artifact uploads).

### 4.5 Secrets

No `secrets:` on the atom side. Adopters call with `secrets: inherit` so internal package indexes (PyPI mirror, private Git deps) get the existing `${{ secrets.* }}` plumbing without per-atom enumeration.

## 5. Python package-manager auto-detection

Both `lint-python.yml` and `test-python.yml` share a probe that runs inside `working_directory` and selects an install command:

| Detected file | Install | Tool invocation prefix |
|---|---|---|
| `poetry.lock` | `poetry install --no-interaction --no-ansi` | `poetry run` |
| `uv.lock` | `uv sync --frozen` | `uv run` |
| `pyproject.toml` with `[project.optional-dependencies].dev` | `pip install -e ".[dev]"` | _(none)_ |
| `requirements.txt` (no `pyproject.toml`) | `pip install -r requirements.txt && pip install ruff mypy pytest pytest-cov` | _(none)_ |
| None of the above | hard error: `no python package manager detected at <wd>` | — |

Probe order is significant: a Poetry repo can also have a `requirements.txt` for downstream pip consumers, so the lockfile probe wins.

To keep the workflow YAML readable, the probe + setup + install lives in a small composite action: `actions/setup-python-deps/action.yml`. Both Python atoms `uses: ./.github/actions/setup-python-deps` (resolved relative to the catalog checkout that the atom does first).

Tools (`ruff`, `mypy`, `pytest`) versions follow whatever the adopter has locked. Lockfile-driven version pinning is one of the reasons we don't expose per-tool version inputs for Python.

**Caveat for the pip-with-bare-`requirements.txt` fallback:** that path installs `ruff mypy pytest pytest-cov` unpinned from PyPI, so adopters on that path get whatever is latest at run time. This is acceptable as a fallback because (a) no current serverkraken Python repo uses this shape, and (b) the remediation is documented: add a `[project.optional-dependencies].dev` block to `pyproject.toml` and the atom switches to path 3 automatically. We do not introduce a `lint_tools_version` input — its scope (which set of tools, which combinations) would balloon faster than the rare pip-bare adopter justifies.

## 6. Adopter `ci.yml.tmpl` rewrite

### 6.1 Loop strategy

The template iterates `.profile.components[]` and emits per-component lint + test jobs:

```gotemplate
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

  {{- range $i, $c := .profile.components }}
  {{- $suffix := $c.path | replaceAll "/" "-" | replaceAll "." "root" }}
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
    with: { working_directory: {{ $c.path }} }
    secrets: inherit
  test-python-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-python.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      coverage_threshold: 90
    secrets: inherit
  {{- else if eq $c.primary_language "rust" }}
  lint-rust-{{ $suffix }}: …  # analogous
  test-rust-{{ $suffix }}:  …
  {{- else if eq $c.primary_language "helm" }}
  lint-helm-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-helm.yml@{{ $pin }}
    with: { working_directory: {{ $c.path }} }
    secrets: inherit
  # no test-helm
  {{- end }}
  {{- end }}
```

### 6.2 Job-id derivation

`<kind>-<lang>-<suffix>` where `<suffix>` = `path | replaceAll "/" "-" | replaceAll "." "root"`. Results:

- Single-component repo (`.path = "."`) → `lint-python-root`, `test-python-root`.
- Monorepo with `services/api` → `lint-go-services-api`, `test-go-services-api`.

### 6.3 Helm components

Emit `lint-helm-<suffix>` only. No `test-helm` — there's no industry-standard "run the chart" gate inside CI (helm install --dry-run is closer to lint than test).

### 6.4 Unsupported languages

If `primary_language` is not in `{go, python, rust, helm}`, the template skips it. **Detection writes a warning to `profile.json.warnings[]`**: `no lint/test atom for primary_language=<x>; falling back to secscan only`. This is a small extension to `scripts/onboard-detect.sh` / `scripts/lib/onboard-detect-lib.sh`.

### 6.5 Coverage threshold

Hardcoded to `90` in the template. Rationale: org policy is uniform; configurability is YAGNI. Adopters who need to deviate can manually edit the rendered `ci.yml`; the lock file will then show the file as `modified` in drift-check — making the deviation visible by design.

## 7. Testing strategy

### 7.1 Caller workflows (integration)

For each of the 7 atoms, one happy-path caller and one failure-path caller under `tests/callers/`:

```
tests/callers/
  lint-go-happy.yml         lint-go-fail.yml
  test-go-happy.yml         test-go-cov-fail.yml
  lint-python-happy.yml     lint-python-fail.yml
  test-python-happy.yml     test-python-cov-fail.yml
  lint-rust-happy.yml       lint-rust-fail.yml
  test-rust-happy.yml       test-rust-cov-fail.yml
  lint-helm-happy.yml       lint-helm-fail.yml
```

Failure callers use `continue-on-error: true` on the atom call + a follow-up step with `if: failure()` that asserts the prior step failed — the established pattern from `test-trivy-fs-failure` in `.github/workflows/integration.yml`.

### 7.2 Fixtures

New fixtures under `tests/fixtures/lint-test/`:

- `go-happy/` — clean module, one tested function (≥ 90 % cover).
- `go-lint-fail/` — `gofmt`-violating file.
- `go-cov-fail/` — module with no `_test.go` (0 % cover).
- `python-poetry-happy/`, `python-uv-happy/`, `python-pip-happy/` — minimum module per pm, ≥ 90 % cover with one trivial test.
- `python-lint-fail/` — `ruff`-violating file (Poetry-based).
- `python-cov-fail/` — Poetry-based, no tests.
- `rust-happy/`, `rust-lint-fail/`, `rust-cov-fail/`.
- `helm-happy/` — reuses existing `tests/fixtures/helm-only`.
- `helm-lint-fail/` — Chart.yaml missing required `name` field.

Each fixture is the smallest possible repo that exercises the atom; no real product code.

### 7.3 Renderer golden tests

`tests/shell/onboard-render.bats` gains golden-file tests asserting the new `ci.yml.tmpl` produces the expected output for these synthetic profiles:

- python-only single component
- go-only single component
- rust-only single component
- helm-only single component
- mixed monorepo (`services/api` = go, `charts/web` = helm) — proves the loop and suffixing
- unsupported language (`node`) — proves the skip + warning

Golden files live alongside the bats file under `tests/shell/golden/ci/`.

### 7.4 Self-CI wiring

Each new caller is referenced from `.github/workflows/integration.yml` (or whichever current self-CI workflow runs callers; the same place `test-trivy-fs-*` lives). All 14 callers run on every PR to this repo.

## 8. Release & migration

### 8.1 Release order

Two PRs to keep review surface manageable, both targeting `main`:

1. **Atoms + caller tests + fixtures.** Seven `workflow_*.yml` files, the `actions/setup-python-deps` composite, the 14 callers, the new fixtures. No template change yet. Tested independently. Conventional-commit: `feat(atoms): lint-{go,python,rust,helm} and test-{go,python,rust}`.
2. **Template wiring + renderer tests + warnings extension.** New `ci.yml.tmpl`, golden files, bats tests, detection `warnings[]` extension for unsupported languages. Conventional-commit: `feat(onboard): wire lint/test atoms into ci.yml skeleton`.

After **both** PRs land on `main`, release-please opens a single bot-authored release PR; merging it minor-bumps to **v3.2.0** (feat-only, additive — no breaking changes to any existing atom contract) and the `catalog-release` workflow moves the floating `v3` and `v3.2` tags. The reference-adopter migration in § 8.2 starts only after that release PR is merged and the tag is published.

### 8.2 Reference-adopter migration

After `v3.2.0` is tagged:

1. Dry-run `onboard.yml` against `serverkraken/blupod-ui` (Python) and `serverkraken/flow` (Go). Verify the step summary's "Detected components" table and that the rendered diff includes the expected `lint-<lang>-root` + `test-<lang>-root` jobs. Investigate any drift between rendered output and the prior hand-rolled ci.yml.
2. Real run (sequentially, not parallel): each adopter gets PR A (add new `ci.yml` + lock file) and PR B (remove legacy lint/test bits from the existing workflows). Merge after the new ci.yml runs green on the PR.

If either adopter reveals a detection or rendering bug, file a follow-up; do not edit catalog code mid-migration.

## 9. Migration impact on existing adopters

This release does not break any existing onboarded repo:

- Currently rendered `ci.yml` (only `secscan`) keeps working — the template change only **adds** jobs.
- `drift-check.yml` will start flagging onboarded repos as `behind` until they are re-onboarded onto `v3.2.0`. That is the intended UX — re-running `onboard.yml` after a major template change is the documented remediation.

## 10. Implementation order (informational, real plan lives in the plan doc)

1. `lint-go.yml` + happy/fail callers + go fixtures.
2. `test-go.yml` + callers + cover fixture.
3. `actions/setup-python-deps/action.yml` (shared probe).
4. `lint-python.yml` + 3 happy callers (poetry/uv/pip) + 1 fail caller + fixtures.
5. `test-python.yml` + callers + cover fixture.
6. `lint-rust.yml` + callers + fixtures.
7. `test-rust.yml` + callers + fixtures.
8. `lint-helm.yml` + callers + fixtures.
9. Detection `warnings[]` extension for unsupported languages.
10. `ci.yml.tmpl` rewrite + bats golden tests.
11. README + `docs/operations.md` update (list the new atoms).
12. Release v3.2.0 (release-please bot).
13. Onboard `blupod-ui` and `flow`.

## 11. Open questions

None outstanding from brainstorm. Items the implementer should sanity-check:

- Confirm `actions/setup-python@v5` `python-version-file: pyproject.toml` actually reads the `[tool.poetry.dependencies].python` constraint or only `[project.requires-python]`. If the former, blupod-ui works; if the latter, a `pyproject.toml` shim or explicit input may be needed. Document in CLAUDE-troubleshooting.md if it bites.
- `actions/setup-go@v5` `cache: true` (the default) caches per-job; verify it interacts cleanly with `working_directory != .` (the cache key should incorporate the sub-path).
- Decide at PR time whether the helm fixture `helm-lint-fail/` is its own directory or just a flag toggle inside `helm-happy/`. Smaller blast radius if it's a separate dir.
