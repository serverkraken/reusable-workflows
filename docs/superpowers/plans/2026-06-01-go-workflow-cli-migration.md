# Go Workflow CLI Migration Plan

**Date:** 2026-06-01  
**Branch:** `feat/go-workflow-cli-plan`  
**Goal:** Plan an incremental Go implementation for the complex onboarding, rendering, drift, and repository-defaults logic currently implemented in Bash.

## Branching Strategy (Decided)

Use a long-lived `next` branch as the integration stream for this migration, running in parallel to `main`.

- `main` stays the stable production branch.
- Go migration feature branches (including this one) open PRs into `next`.
- Validation and rollout hardening happen on `next` first.
- Merge `next -> main` only after the migration slice is green and intentionally approved.

Operational status on 2026-06-01:

- `origin/next` exists and tracks current `origin/main` baseline.
- PR #173 has been retargeted from `main` to `next`.

## Problem Statement

The current Bash implementation is mature and well-tested, but several scripts now behave like full applications: they parse JSON, call GitHub APIs, classify repository structure, render templates, compare lockfiles, and update repository settings. This increases fragility around quoting, `jq` shape changes, shell portability, and test stubbing.

The migration should not be a rewrite. The safe path is to introduce a Go CLI that preserves the current contracts and gradually replaces Bash internals.

## Proposed CLI Shape

Create a Go module at the repository root:

- `cmd/sk-workflows/main.go`
- `internal/detect`
- `internal/render`
- `internal/drift`
- `internal/defaults`
- `internal/github`
- `internal/profile`
- `internal/lockfile`

Initial command surface:

```bash
sk-workflows detect --repo-path <dir> --target-repo owner/repo --format profile-json
sk-workflows detect --repo-path <dir> --target-repo owner/repo --emit-both
sk-workflows render --catalog <dir> --target <dir> --profile profile.json --pin v4
sk-workflows drift --target <dir> --catalog <dir> --current-version v4
sk-workflows apply-defaults --repo owner/repo --target-path <dir> [--prev-marker ts] [--dry-run]
sk-workflows preview --repo-path <dir> --pin v4 --out <dir>
```

Keep command output compatible with the existing scripts:

- legacy `key=value` outputs for GitHub Actions
- `profile_json<<DELIM` block for `--emit-both`
- lockfile schema compatible with `.github/onboard.lock.json`
- status values compatible with `onboard-drift.sh`

## Migration Order

### Phase 1: Scaffold and Contract Types

Add the Go module, CLI skeleton, and typed data models for:

- profile JSON
- components, dockerfiles, release signals, warnings
- lockfile schema
- repo defaults config
- drift statuses

Acceptance:

- `go test ./...` passes.
- No workflow behavior changes.
- Bash remains authoritative.

### Phase 2: Port Detection First

Port `scripts/onboard-detect.sh` and `scripts/lib/onboard-detect-lib.sh` behavior into `sk-workflows detect`.

Why first:

- Detection has the most domain logic.
- It already has extensive Bats fixture coverage.
- It produces a stable JSON contract consumed by rendering.

Implementation details:

- Use Go filesystem walking for component detection.
- Use typed structs for `profile.json`.
- Use an interface for GitHub lookups: `DefaultBranch`, `LatestStableRelease`, `Topics`.
- Implement a `gh`-backed adapter first to avoid changing auth behavior.
- Add pure unit tests for all fixtures currently covered by Bats.

Acceptance:

- For each fixture under `tests/fixtures/onboard/`, Go detection output matches Bash detection after JSON normalization.
- Existing `bats tests/shell/onboard-detect.bats` remains green.
- `actions/onboard-detect/action.yml` can opt into Go via `SK_WORKFLOWS_GO=1` but defaults to Bash.

### Phase 3: Port Drift

Port `scripts/onboard-drift.sh` and `scripts/onboard-sweep-drift-status.sh`.

Implementation status:

- `sk-workflows drift` ports lock comparison and drift status classification to Go.
- Render-and-compare remains conservative and uses the existing catalog scripts through ports/adapters until rendering is ported.
- `actions/onboard-drift` can opt into Go with `use_go_cli: true`; Bash remains default.
- `drift-check.yml` can manually opt into Go via workflow dispatch while scheduled runs stay on Bash.

Implementation details:

- Reuse Go lockfile and profile types.
- Keep render-and-compare behavior conservative: render failures should preserve current status and emit `render_error`.
- Derive `TARGET_REPO` from git origin as today.

Acceptance:

- Existing drift fixtures produce identical `status`, `modified`, and `render_error`.
- Bats drift tests pass against both Bash and Go modes.

### Phase 4: Port Rendering

Port `scripts/onboard-render.sh`.

Implementation status:

- `sk-workflows render` ports render orchestration, template selection, lockfile writing, trailing-newline normalization, and `$REPO` substitution to Go.
- gomplate remains the template execution adapter, keeping the existing adopter templates authoritative.
- `actions/onboard-render` can opt into Go with `use_go_cli: true`; Bash remains default.
- Self-CI exercises the Go render path against an onboarding fixture.

Recommendation:

- Do not replace gomplate immediately.
- Go should initially build the render context, invoke gomplate, normalize output, substitute `$REPO`, and write the lockfile.
- A later phase can evaluate replacing gomplate templates with Go templates if the benefit is worth the churn.

Acceptance:

- Golden renders under `tests/shell/golden/` are byte-identical.
- Lockfile hashes are identical except for `rendered_at`.
- GitOps and prerelease-on-push conditional rendering remain covered.

### Phase 5: Port Repo Defaults

Port `scripts/apply-repo-defaults.sh` and `scripts/lib/apply-defaults-lib.sh`.

Implementation details:

- Use typed structs for `catalog/onboard-defaults.json`.
- Preserve tier behavior exactly:
  - Tier 1 always applies.
  - Tier 2 applies only when no previous marker exists.
- Keep `--dry-run` output GitHub Actions-compatible.

Acceptance:

- API call plans match existing stub expectations.
- Lock mutation behavior remains identical.
- Failure modes stay fail-loud for mutating API errors.

### Phase 6: Workflow Integration

After parity is proven, update composite actions to prefer the binary:

```bash
if command -v sk-workflows >/dev/null 2>&1; then
  sk-workflows detect ...
else
  scripts/onboard-detect.sh ...
fi
```

Then add an install step for released binaries in catalog workflows.

Acceptance:

- Self-CI exercises Go mode.
- Bash fallback remains available for one major version.
- Release notes document the compatibility window.

## Distribution Strategy

Preferred path:

1. Build `sk-workflows` in the catalog release workflow for `linux/amd64` and `linux/arm64`.
2. Attach binaries and checksums to GitHub Releases.
3. Add `actions/setup-sk-workflows` composite action that downloads by catalog version and verifies SHA256.
4. Self-CI can build from source on PRs to exercise feature branches.

Avoid requiring adopter repos to build Go from source during normal workflow runs.

## Test Strategy

Add:

- Go unit tests for internal packages.
- Golden JSON tests comparing Bash and Go detection.
- Render golden tests comparing file trees.
- Contract tests that validate docs/contracts.md against workflow inputs later.

Keep:

- Existing Bats tests during migration.
- Existing `yamllint` and `actionlint`.
- Existing fixture directories.

Suggested local commands:

```bash
go test ./...
bats tests/shell/
yamllint .github/ actions/ tests/
actionlint
```

## Compatibility Rules

- No change to public workflow `inputs`, `outputs`, or `secrets` during the migration.
- No change to rendered adopter workflows unless explicitly intended and covered by golden tests.
- No change to profile JSON keys without a schema version bump.
- Bash wrappers remain until Go has been proven in CI and at least one catalog release.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Go output differs subtly from Bash | Normalize JSON and compare against fixture goldens before integration |
| Binary distribution becomes a new supply-chain concern | Release checksums, verify downloads, keep Bash fallback |
| Replacing gomplate causes large template churn | Keep gomplate in Phase 4; only move orchestration and lockfile logic first |
| GitHub API behavior differs from `gh api` | Start with a `gh` adapter; move to `go-github` only after parity |
| Bigger PR becomes hard to review | Ship phases independently, each with tests and no public contract change |

## Initial PR Scope

The first implementation PR should include only:

- Go module scaffold.
- `sk-workflows detect` with typed profile output.
- Tests for language/component/Dockerfile/GitOps detection.
- Bash-vs-Go fixture parity test.
- Optional feature flag in `actions/onboard-detect` disabled by default.

Out of scope for the first PR:

- Replacing rendering.
- Replacing drift checks.
- Replacing repo-default mutations.
- Changing adopter-rendered workflows.

## Open Questions

- Should the binary eventually use `go-github`, or should it keep delegating to `gh` to preserve operator auth behavior?
- Should `preview` be introduced early as a local UX feature, even before workflows use the Go implementation?
- Should the Go CLI become part of the public catalog contract, or remain an internal implementation detail?
- How long should Bash fallback remain after Go becomes default: one minor release, one major release, or indefinitely?
