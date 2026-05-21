# Per-Adopter Override Variables — Design

**Date:** 2026-05-21
**Status:** Approved, pending implementation plan

## Problem

Adopter repos onboard to the catalog via `onboard.yml`, which renders a static `ci.yml` (and `release.yml`, `prerelease.yml`, `cleanup.yml`) into the target repo. Every tunable parameter — coverage threshold, Go/Python/Rust toolchain version, golangci-lint version, Trivy severity, cgo toggle — lands as a literal value in the rendered ci.yml.

Today, an adopter who needs a different value (concrete prompt: skytrack failing at `coverage: 66% < threshold 80%`) has only two paths:

1. **Hand-edit the rendered ci.yml.** Works but drift-check then flags the file as `modified` indefinitely, and every future re-render via onboard would re-overwrite the change.
2. **Change the catalog default.** Reaches all adopters, not just the one that needs the change.

Both are bad. Adopters need a per-repo override that lives outside the rendered code and survives re-renders.

## Solution

Expose tunable atom inputs through **GitHub repository variables** (`vars.SK_*`), referenced from the rendered ci.yml via expression-fallbacks:

```yaml
coverage_threshold: ${{ vars.SK_COVERAGE_THRESHOLD || '80' }}
```

Adopters tune via `Settings → Secrets and variables → Actions → Variables`. No code change in the adopter repo. Drift-check stays clean because the rendered file content is identical for all adopters with the same profile.

Organization-level variables are inherited automatically by all adopter repos; repo-level overrides win where set. Catalog maintainers can shift org-wide defaults without re-rendering anything.

## Knob Registry

The initial PR exposes the following variables. Variable names use the `SK_` prefix (serverkraken namespace) to avoid collisions with adopter-app config.

| Variable | Atom Input | Atoms Affected | Template Default | Type |
|---|---|---|---|---|
| `SK_COVERAGE_THRESHOLD` | `coverage_threshold` | test-go, test-python, test-rust | `'80'` | number |
| `SK_CGO_ENABLED` | `cgo_enabled` | lint-go, test-go | profile auto-detect (`'true'` or `'false'`) | boolean |
| `SK_GO_VERSION` | `go_version` | lint-go, test-go | `''` (atom reads from `go.mod`) | string |
| `SK_PYTHON_VERSION` | `python_version` | lint-python, test-python | `''` (atom reads from `pyproject.toml`) | string |
| `SK_RUST_TOOLCHAIN` | `rust_toolchain` | lint-rust, test-rust | `''` (atom reads from `rust-toolchain.toml`) | string |
| `SK_GOLANGCI_LINT_VERSION` | `golangci_lint_version` | lint-go | `'v2.12.2'` (mirror of atom default; Renovate-tracked) | string |
| `SK_CLIPPY_ARGS` | `clippy_args` | lint-rust | `''` (atom default is empty too) | string |
| `SK_CARGO_LLVM_COV_VERSION` | `cargo_llvm_cov_version` | test-rust | `'v0.6.16'` (mirror of atom default; Renovate-tracked) | string |
| `SK_TRIVY_SEVERITY` | `severity` | trivy-fs, trivy-image | `'HIGH,CRITICAL'` | string |
| `SK_TRIVY_VERSION` | `trivy_version` | trivy-fs, trivy-image | `''` (delegates to `install-trivy` composite's own default) | string |

**Critical:** for atom inputs whose `default:` is non-empty (`golangci_lint_version`, `cargo_llvm_cov_version`, `coverage_threshold`, etc.), the template literal MUST duplicate the atom default exactly. Passing an empty string from the template would override the atom's default with `""` — not fall through to it. The default-sync bats test (Testing §4) enforces this invariant.

**Explicitly excluded** from the variable surface:
- `fail_on_findings`, `ignore_unfixed` — change CI semantics; belong in code review, not Settings UI.
- `runs_on` — catalog-side global, not adopter-tunable.
- `working_directory`, `image_name`, `dockerfile`, `tag`, `prerelease` — per-component or build-derived.
- `paths_ignore` — multi-line strings are awkward in GitHub Variables UI; configure in adopter ci.yml as a code review.

### CGO Override Semantics

`SK_CGO_ENABLED` follows **override-wins** semantics: any non-empty value (the user set the var in Settings) replaces the profile auto-detect result. Both `true` and `false` work — adopters can force cgo on (auto-detect missed a transitive dep) or off (auto-detect false-positive).

Template per-component branch:

```
{{- if index $c "cgo" }}
    cgo_enabled: {{`${{ vars.SK_CGO_ENABLED || 'true' }}`}}
{{- else }}
    cgo_enabled: {{`${{ vars.SK_CGO_ENABLED || 'false' }}`}}
{{- end }}
```

## Architecture

### Template rendering

`ci.yml.tmpl` emits expression-fallbacks for every variable-tunable input. The outer `{{ }}` is gomplate, the inner `${{ }}` is GitHub Actions and stays literal in the rendered output. Same pattern already used for `tag: {{`${{ needs.release-please.outputs.tag_name }}`}}` in `release.yml.tmpl`.

Rendered example for a Go service:

```yaml
test-go-root:
  uses: serverkraken/reusable-workflows/.github/workflows/test-go.yml@v3
  with:
    working_directory: .
    coverage_threshold: ${{ vars.SK_COVERAGE_THRESHOLD || '80' }}
    cgo_enabled: ${{ vars.SK_CGO_ENABLED || 'true' }}
    go_version: ${{ vars.SK_GO_VERSION || '' }}
  secrets: inherit
```

Defaults are duplicated between the template literal and the atom's `default:` field. They must be kept in sync; a bats unit-test asserts equality (see Testing).

### Drift-check interaction

`scripts/onboard-drift.sh` hashes each rendered file and compares against `onboard.lock.json` SHAs. The rendered file content contains the literal expression string (e.g. `${{ vars.SK_COVERAGE_THRESHOLD || '80' }}`), which is:

- **Reproducible** — gomplate output is deterministic for identical profile data.
- **Stable across adopters** — Template defaults are hardcoded constants, not profile-derived, so adopter A and adopter B with the same component shape render identical files.
- **Resolution-time-independent** — `vars.SK_*` resolves at CI run time, never at render time. The YAML file always contains the expression string, never the resolved value.

CGO is the only profile-derived branch: adopters with `cgo: true` get `... || 'true'`, others get `... || 'false'`. Per-adopter the output remains reproducible.

The migration is a one-time re-render wave: all three current adopters (blupod-ui, flow, skytrack) need re-onboarding to update their `onboard.lock.json` SHAs. After that, steady-state.

### Org-level layering

GitHub Variables have a built-in precedence: repo-level overrides org-level. The catalog org sets `SK_COVERAGE_THRESHOLD = "80"` (mirror of the template default) once; all adopters inherit. Adopters with different needs (skytrack with 60) set the var at repo level.

A change to the org-wide default propagates to all non-overriding adopters instantly, with zero re-rendering. The template default becomes a safety net for the case where the org var is unset.

## Testing

Three layers:

1. **Onboard-render bats unit tests** — Update existing golden fixtures (`tests/fixtures/onboard/go-repo/`, `go-cgo/`, `monorepo-go/`, `multi-dockerfile/`, `service-with-helm/`, `cli-go-with-goreleaser/`, `library-go/`, `go-cgo-transitive/`) and inline render tests with the new expected ci.yml output that contains `${{ vars.SK_* }}` expressions.

2. **Onboard-drift bats unit tests** — Existing reproducibility test (`tests/shell/onboard-drift.bats`) covers the case implicitly: render → hash → re-render → assert hashes equal. The expressions are deterministic strings, so this continues to pass.

3. **Integration smoke test for type coercion** — New caller `tests/callers/test-go-vars-coercion.yml`. Sets `coverage_threshold: ${{ vars.TEST_COVERAGE_THRESHOLD_NUMERIC || '80' }}` and runs against the `tests/fixtures/minimal-go` fixture. Repo variable `TEST_COVERAGE_THRESHOLD_NUMERIC = "70"` set once via `gh variable set`. The coverage-gate step's logged threshold value must be `70`, not `80`. If GitHub Actions fails to coerce the string-typed variable to a number for the `type: number` atom input, this test goes red and we know before any adopter rollout.

4. **Default-sync sanity check** — New bats test `tests/shell/template-defaults.bats` that greps the template-default values out of `ci.yml.tmpl` and compares against the atom `default:` fields in `.github/workflows/{test,lint}-{go,python,rust}.yml` and `trivy-{fs,image}.yml`. Failures here block merges that would silently desync the two.

## Documentation

1. **`docs/operations.md`** — new top-level section `## Per-Adopter Overrides via Repository Variables` with:
   - Table mirroring the Knob Registry above.
   - Step-by-step on how to set a variable: `Settings → Secrets and variables → Actions → Variables tab → New repository variable`. Explicit warning about the Variables vs. Secrets tab confusion.
   - Brief on org-level layering for catalog maintainers.

2. **`ci.yml.tmpl`** — header comment ends with a one-liner pointer: *"Tunable inputs accept org/repo `vars.SK_*` overrides — see docs/operations.md §Per-Adopter Overrides."*

3. **`docs/onboarding-status.md`** — left unchanged in this PR. A future enhancement could add a "Overrides set" column populated via `gh api /repos/.../actions/variables`, but that's a separate observability concern.

## Migration

After merge:

1. Catalog auto-releases v3.9.0 (feat → minor).
2. Re-trigger `onboard.yml` against `serverkraken/blupod-ui,serverkraken/flow,serverkraken/skytrack`. New ci.yml renders + lock.json updates. Adopter PRs auto-update.
3. skytrack sets `SK_COVERAGE_THRESHOLD = "60"` in repo Settings to unblock its PR #13.
4. Optional follow-up: set `SK_COVERAGE_THRESHOLD = "80"` at the **org** level so future adopters inherit the explicit default (the template literal already provides this safety net, but org-level makes the intent visible).
5. Drift-check rolling issue (#66) reports the three adopters as `clean` once their re-onboard PRs merge.

## Open Questions / Known Limits

1. **Type coercion `string → number`** — `vars.SK_*` resolves to a string; atom inputs like `coverage_threshold` are `type: number`. GitHub Actions is expected to coerce on `workflow_call` input validation, but this is not formally documented. The integration smoke test (Testing §3) verifies. If broken: fallback is to switch affected atom inputs to `type: string` and parse internally — atom-API-breaking, requires a v4.0.0 major bump.

2. **Empty-string vs. unset semantics** — `vars.SK_GO_VERSION = ""` (user creates the variable then clears its value) is indistinguishable from unset for the `||` operator. Both evaluate to the template default. Acceptable; no edge case for the current variable list.

3. **Default-drift between template and atom** — Manually-mirrored literals can desync if either side bumps without the other. The risk is highest for Renovate-tracked inputs (`golangci_lint_version`, `cargo_llvm_cov_version`) where automated bumps land on the atom side only. Mitigated by the default-sync bats test (Testing §4) which fails CI on any desync. As a follow-up, Renovate `customManagers` regex could also target the template literal once we see the pattern stabilize.

4. **Secrets vs. Variables UI confusion** — An adopter who creates `SK_COVERAGE_THRESHOLD` as a *Secret* will see no effect at runtime (`vars.X` returns empty, fallback fires). Documentation warning is the only mitigation; no technical fix possible.

### Explicitly out of scope (future PRs if needed)

- Per-component variable granularity (`SK_COVERAGE_THRESHOLD_SERVICES_API` for a single monorepo path). Current design applies one value globally per adopter.
- Environment-scoped variables (`vars` has an `environment:` scope). Catalog atoms don't use Environments today.
- Server-side value validation (e.g. range check on numeric vars). GitHub Actions type validation runs on `workflow_call` input check and fails fast on invalid input — sufficient.
