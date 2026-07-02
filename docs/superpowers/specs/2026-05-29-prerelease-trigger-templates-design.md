# Prerelease-Trigger Templates — Design

**Date:** 2026-05-29
**Status:** Approved (design approved in conversation; "Passt")
**Phase:** Phase-2, Item 3

## Problem

The onboard renderer produces `ci.yml` + `release.yml` + `prerelease.yml` + `cleanup.yml`. The two prerelease-*trigger* patterns the org actually uses are not yet first-class:

1. **Manual** (`workflow_dispatch`): a thin caller that builds and attaches an ad-hoc prerelease artifact. For docker this already exists in `prerelease.yml.tmpl`. For Flutter it does NOT — a Flutter repo renders `prerelease.yml` with a useless `noop` job (the `else` branch). strassenfuchs hand-wrote its own `manual-release.yml` (with hardcoded `dart_define_secret_names`) to fill the gap — an inconsistency now that `release.yml` is var-driven.
2. **Auto on push to a dev/staging branch**: continuous RC builds on every merge to a dev branch. Not built at all.

Captured in catalog PR #155 backlog. Dependencies (`create_release` input PR #156, Flutter renderer detection PR #157/v4.6.0) are shipped.

## Scope

**In scope:**
- Manual prerelease as a rendered, stack-aware `prerelease.yml` — add a Flutter branch (replacing the noop), keep docker as-is.
- Auto-on-push as a new rendered, opt-in `prerelease-on-push.yml` — stack-aware, triggered on push to `develop`, rendered only when the repo carries the `sk-prerelease-on-push` topic.
- Detection of repo topics into the profile (general signal, reused by Item 2 later).
- Render-script support for a conditionally-rendered file.
- bats (detect + render) + golden updates + integration lint; operations.md docs.

**Out of scope:**
- iOS; Play-Store upload (Item 2); `issue_comment`/`/prerelease` comment triggers (backlog).
- Runtime-configurable trigger branch (GitHub does not evaluate expressions in `on:`, so the branch is baked at render time — fixed `develop`).
- strassenfuchs's downstream re-onboard (this is catalog work; the adopter migration — its hand-written `manual-release.yml` being superseded — happens on a later re-onboard and is flagged by the cleanup-PR).

## Background

- `docs/adopter-templates/skeletons/prerelease.yml.tmpl` today: `on: workflow_dispatch: {}`; for a single Dockerfile → `docker-build.yml` (prerelease) + `trivy-image.yml`; multi → `docker-build-multi.yml`; no Dockerfiles → a `noop` job.
- `scripts/onboard-render.sh` renders a FIXED set of 6 files and locks all of them (`RENDERED=(...)`); it also runs a `$REPO`-substitution loop over `release.yml` + `prerelease.yml`.
- `detect_legacy_ci` in `onboard-detect-lib.sh` has `OWNED=(ci.yml release.yml prerelease.yml cleanup.yml)` — filenames the renderer owns and must not classify as legacy.
- `emit_profile_json` fetches `default_branch` + `current_version` via `gh` when `TARGET_REPO` is set; it does NOT fetch topics today.
- Flutter manual-release reference shape: `docs/operations.md` §9.2 (workflow_dispatch inputs `version`/`prerelease` → `release-flutter-android` with `create_release: true`).

## Approaches considered

- **A (chosen): trigger as the axis.** `prerelease.yml` = manual (workflow_dispatch), `prerelease-on-push.yml` = auto (push). Each is stack-aware and shares per-stack job logic, differing only in the `on:` block. Consistent: a file = a trigger, regardless of stack.
- **B (rejected): a separate `manual-release.yml`** for Flutter alongside the docker `prerelease.yml`. The same concept would have two filenames depending on stack.
- **C (rejected): stack as the axis** — one file per stack bundling both triggers via `on:` + `if:` gates. Fewer files but tangled `on:`/`if:` logic, harder to read.

## Design per concern

### 1. Detection — `scripts/lib/onboard-detect-lib.sh`

`emit_profile_json` gains a top-level `topics` array. When `TARGET_REPO` is set:
```
topics=$(gh api "/repos/$target_repo/topics" -q '.names' ... )   # default []
```
Emitted as `topics: [...]` in the profile (additive; `schema_version` stays 1). When `TARGET_REPO` is unset (local/test), `topics: []`. This is a general signal — Item 2's `sk-play-store` topic will reuse it.

### 2. Manual prerelease — `prerelease.yml.tmpl`

Add a Flutter branch, gated on `release_signals.flutter_android`:
- `on:` becomes conditional. Flutter:
  ```yaml
  on:
    workflow_dispatch:
      inputs:
        version: { description: 'Tag to build (empty → auto <latest>-rc.<run_number>)', required: false, type: string, default: '' }
        prerelease: { description: 'Mark the GitHub Release as prerelease.', type: boolean, default: true }
  ```
  Docker / other: unchanged `workflow_dispatch: {}`.
- Flutter job:
  ```yaml
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@{{ $pin }}
    with:
      version: {{`${{ inputs.version }}`}}
      create_release: true
      prerelease: {{`${{ inputs.prerelease }}`}}
      dart_define_secret_names: {{`${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}`}}
    secrets: inherit
  ```
- A Flutter *package* (no `android/` → `flutter_android=false`) keeps the `noop` (nothing to build). Docker branches unchanged.

### 3. Auto-on-push — `prerelease-on-push.yml.tmpl` (new)

Rendered ONLY when `topics` contains `sk-prerelease-on-push`. Otherwise the file is not produced at all.
- `on: push: branches: [develop]` (static, baked).
- Stack-aware, mirroring the per-stack job logic of `prerelease.yml`:
  - Flutter (flutter_android): `release-flutter-android` with `create_release: true`, `version: ''` (→ auto `<latest>-rc.<run_number>`), `prerelease: true`, `dart_define_secret_names` via the var.
  - Docker single/multi: `docker-build(-multi).yml` with `prerelease: true` (+ trivy-image scan for single), same `SK_SIGN/ATTEST/SBOM` threading as the manual prerelease.

### 4. Render plumbing — `scripts/onboard-render.sh`

- After rendering the fixed set, conditionally render `prerelease-on-push.yml` when the profile's `topics` includes `sk-prerelease-on-push`.
- When rendered: include it in the `$REPO`-substitution loop (docker image names) and append it to the lock `RENDERED` list so the lock + drift-check stay consistent. When not rendered: it is absent from disk AND from the lock.
- `detect_legacy_ci` `OWNED += prerelease-on-push.yml`.

## Interface contracts

- **profile.json (additive; `schema_version` stays 1):** new top-level `topics: [string]`.
- **New opt-in topic:** `sk-prerelease-on-push` — its presence renders `prerelease-on-push.yml`.
- **New owned file:** `.github/workflows/prerelease-on-push.yml` (optional — only when opted in).
- **Reused:** `vars.SK_FLUTTER_DART_DEFINE_SECRETS`, `vars.SK_SIGN/SK_ATTEST/SK_SBOM/SK_TRIVY_*`.
- **Baked convention:** auto-on-push trigger branch = `develop`.

## Test strategy

**bats — `onboard-detect.bats`:** profile carries `topics` (via gh-stub topics fixture); `topics == []` when `TARGET_REPO` unset.

**bats — `onboard-render.bats`:**
- `prerelease.yml`: Flutter-app profile → release-flutter-android `create_release` job with `version: ${{ inputs.version }}` + `dart_define_secret_names` var + workflow_dispatch inputs (no `noop`); docker single/multi unchanged (existing tests stay green); Flutter package (flutter_android=false) → `noop`.
- `prerelease-on-push.yml`: profile with `topics:["sk-prerelease-on-push"]` → file rendered (Flutter variant has `on: push: branches: [develop]` + release-flutter-android; docker variant has docker-build prerelease) and present in the lock; profile without the topic → file NOT rendered and NOT in the lock.
- Golden: regenerate `flutter-app` expected/ (its `prerelease.yml` is now the real manual job, not noop); add a fixture exercising the topic.

**Integration:** render the topic-bearing Flutter fixture; `actionlint` + `yamllint` on `prerelease.yml` + `prerelease-on-push.yml`.

## PR plan

Single PR, branch `feat/prerelease-trigger-templates`, worktree `.worktrees/prerelease-templates/` from `origin/main`. One concern: detection topics + `prerelease.yml.tmpl` Flutter branch + new `prerelease-on-push.yml.tmpl` + `onboard-render.sh` conditional render + `OWNED` update + bats + golden + operations.md. Conventional commit `feat(onboard): render manual + auto-on-push prerelease callers` (minor). Two-stage review (spec then code-quality) per the established phase pattern.

## Acceptance criteria

- `onboard-detect --profile-json` carries a `topics` array (empty without `TARGET_REPO`).
- Rendering the `flutter-app` fixture → `prerelease.yml` contains the `release-flutter-android` `create_release` job (no `noop`).
- Rendering a Flutter fixture with topic `sk-prerelease-on-push` → `prerelease-on-push.yml` exists (`on: push: branches: [develop]`, release-flutter-android) and is in the lock; without the topic → no such file and the lock omits it.
- docker `prerelease.yml` output unchanged; all existing detect/render/golden tests green; `actionlint` + `yamllint` pass on the new/changed rendered files.

## Open questions / accepted defaults

1. `prerelease-on-push.yml` is stack-aware (docker + Flutter), not Flutter-only — per the trigger-as-axis, language-agnostic decision.
2. Auto-on-push trigger branch is fixed to `develop` (cannot be a runtime var; `on:` is static). Revisit if an adopter needs a different branch.
3. strassenfuchs's hand-written `manual-release.yml` is superseded by the working rendered `prerelease.yml` on its next re-onboard (cleanup-PR flags it); not part of this catalog PR.
