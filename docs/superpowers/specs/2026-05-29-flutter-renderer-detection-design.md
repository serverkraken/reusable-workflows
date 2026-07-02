# Flutter Onboard-Renderer Detection — Design

**Date:** 2026-05-29
**Status:** Approved (design approved in conversation; "Das passt so")
**Phase:** Phase-2, Item 1 (highest-leverage; closes the Flutter sweep-churn risk)

## Problem

The catalog has Flutter lint/test/release atoms (shipped Phase-8, PR #152; manual-release v4.5.0) but the **onboard renderer cannot detect Flutter**. `scripts/onboard-detect.sh` / `scripts/lib/onboard-detect-lib.sh` probe only `go.mod` / `pyproject.toml` / `Cargo.toml` / `Chart.yaml` / `package.json`. A Flutter repo (only `pubspec.yaml`) matches nothing → `primary_language=generic`, `release_please_type=simple` → the renderer emits a secscan-only `ci.yml` and a release-please-only `release.yml`, with no Flutter jobs.

Two consequences:

1. `serverkraken/strassenfuchs` had to be onboarded by hand (PR #24, still open) instead of catalog-rendered.
2. The `onboard-sweep` cron keeps generating generic/wrong PRs for any Flutter repo (the bogus, since-closed #22/#23) because detection can't see Flutter. This is an active sweep-churn risk until detection lands.

## Scope

**In scope (catalog-only this item):**
- Flutter detection in `onboard-detect-lib.sh` (profile.json) and the legacy `--emit-both` path.
- Rendering of Flutter `ci.yml` (lint-flutter + test-flutter) and `release.yml` (release-flutter-android) from the adopter-template skeletons.
- bats unit tests (detect + render) and an integration render against the existing `tests/fixtures/flutter-app/`.

**Out of scope (separate items):**
- `manual-release.yml` rendering → Phase-2 Item 3 (prerelease-trigger templates, generic manual + auto-on-push).
- Play-Store / AAB upload → Phase-2 Item 2.
- iOS (deferred indefinitely).
- pure-Dart-package release (no `android/`): such a repo is linted/tested but gets **no** release-flutter-android job.
- strassenfuchs re-onboard: handled separately later; PR #24 stays untouched. This item is verified against the fixture only.

## Background — how detection feeds rendering today

- `detect_languages` (lib) builds a per-component `languages[]` array from filesystem markers; `primary_language = languages[0]`. `release_please_type` is a small mapping off `primary_language` (`generic→simple`, else passthrough).
- `SUPPORTED_LINT_TEST_LANGUAGES='go|python|rust|helm'` — anything outside emits a `no_lint_test_atom` warning.
- `detect_release_signals` returns `{goreleaser_config, chart_yaml}`; release jobs key off these plus `dockerfiles[]`.
- `ci.yml.tmpl` branches on `$c.primary_language` (go/python/rust/helm). `release.yml.tmpl` branches on `dockerfiles[]` (→ docker-build / docker-build-multi) and `release_signals` (→ goreleaser / helm-publish).
- `release-please-config.json.tmpl` reads `(index .profile.components 0).release_please_type`.
- `onboard.yml` calls `onboard-detect.sh --emit-both`: the renderer consumes `profile_json`; the legacy `language=` line feeds only the status report (cosmetic); legacy `release_type=` is not consumed.

This design extends the **two existing extension points** — `primary_language` drives lint/test; `release_signals` drives release jobs — rather than adding a parallel mechanism.

## Approaches considered

- **A (chosen):** Flutter as a first-class `primary_language` value + a new `release_signals.flutter_android` boolean. Reuses both template branch points; smallest, most consistent change; correctly separates Flutter *app* (has `android/`) from Flutter *package* (no `android/`).
- **B (rejected):** dedicated top-level flutter component field + separate detection function. More template special-casing, diverges from the uniform structure.
- **C (rejected):** `primary_language=="flutter"` drives both ci and release. Cannot distinguish app from package → would emit a release-flutter-android job for a Flutter package with no `android/` → runtime failure.

## Design per concern

### 1. Detection — `scripts/lib/onboard-detect-lib.sh`

- **`detect_languages`** — append `flutter` when `pubspec.yaml` exists at the component path **and** it declares the Flutter SDK dependency:
  `grep -qE 'sdk:[[:space:]]*flutter' "$p/pubspec.yaml"`.
  Rationale: every Flutter app/package depends on the flutter SDK (`flutter: { sdk: flutter }` and/or `flutter_test: { sdk: flutter }`); a pure-Dart package has neither. The top-level `flutter:` block (assets/uses-material-design) is app-only and optional, so the SDK-dependency probe is the robust signal.
- **`release_please_type` mapping** — add `flutter) release_type="dart" ;;`. release-please's `dart` release-type bumps `pubspec.yaml`'s `version:`. Matches strassenfuchs #24 (`"release-type": "dart"`).
- **`SUPPORTED_LINT_TEST_LANGUAGES`** — `go|python|rust|helm` → `go|python|rust|helm|flutter` (no spurious `no_lint_test_atom` warning).
- **`detect_release_signals`** — add `flutter_android` to the emitted object: `true` when Flutter is detected at the component **and** an `android/` directory exists at the component root, else `false`. Object becomes `{goreleaser_config, chart_yaml, flutter_android}`.
- **`detect_role`** — when Flutter app (`flutter_android`-eligible, i.e. has `android/`), classify `mobile-app`; a Flutter package stays `library`. Role is informational only (status report + warnings), not load-bearing in templates.

### 2. Legacy path — `scripts/onboard-detect.sh`

Both the `--emit-both` dispatch and the legacy key=value path carry their own marker list (`matches+=(...)`). Add `[[ -f "$REPO_PATH/pubspec.yaml" ]] && grep -qE 'sdk:[[:space:]]*flutter' "$REPO_PATH/pubspec.yaml" && matches+=(flutter)` so `language=flutter` shows correctly in the onboarding status report. Cosmetic (renderer uses profile_json) but keeps the status truthful.

The `actions/onboard-detect/action.yml` `language_override` description string is updated to include `flutter` (doc only).

### 3. `ci.yml.tmpl` — Flutter branch

Add a branch to the `primary_language` chain:

```gotemplate
{{- else if eq $c.primary_language "flutter" }}
  lint-flutter-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-flutter.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
  test-flutter-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/test-flutter.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
      coverage_threshold: {{`${{ fromJSON(vars.SK_COVERAGE_THRESHOLD || '80') }}`}}
    secrets: inherit
```

`java_version` / `flutter_channel` use the atom defaults (Java 17, stable); not exposed as SK_ vars for now (YAGNI — strassenfuchs needs neither).

### 4. `release.yml.tmpl` — Flutter-Android branch

Add, per component, alongside the existing dockerfiles/goreleaser/chart branches:

```gotemplate
{{- if $c.release_signals.flutter_android }}
  release-flutter-android{{ $suffix }}:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@{{ $pin }}
    with:
    {{- if not $isRoot }}
      working_directory: {{ $ctxPath }}
    {{- end }}
      version: {{`${{ needs.release-please.outputs.tag_name }}`}}
      dart_define_secret_names: {{`${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}`}}
    secrets: inherit
{{- end }}
```

The existing top-level `permissions:` block in `release.yml.tmpl` is unchanged. It is a superset of the Flutter release needs (release-flutter-android needs `contents:write`; semantic-release needs `contents`/`pull-requests`/`issues:write`); the superset satisfies the chained-reusable permissions union rule. No trimming for no-docker renders (out of scope; pre-existing behavior for goreleaser/helm-only repos too).

### 5. release-please config — no change

`release-please-config.json.tmpl` already reads `release_please_type` from component 0; with the `flutter→dart` mapping it emits `"release-type": "dart"` automatically.

## Interface contracts

- **profile.json (additive; `schema_version` stays 1):**
  - `primary_language` may now be `"flutter"`.
  - `release_please_type` may now be `"dart"`.
  - `release_signals` gains `flutter_android: boolean` (present on every component, like the existing keys).
  - `role` may now be `"mobile-app"`.
  - All additive — no existing field changes shape → no break for Go/Python/Rust/Helm/Node adopters.
- **New adopter variable:** `SK_FLUTTER_DART_DEFINE_SECRETS` — comma-separated list of secret names forwarded to `release-flutter-android`'s `dart_define_secret_names`. Default empty (no dart-defines). Documented in `docs/operations.md` Per-Adopter Overrides.

## Test strategy

**bats — `tests/shell/onboard-detect.bats`:**
- detects `flutter` from `pubspec.yaml` with `sdk: flutter`.
- `release_please_type=dart` for a Flutter component.
- `flutter` is in supported languages → no `no_lint_test_atom` warning.
- `release_signals.flutter_android=true` when `android/` present; `=false` when absent.
- Flutter package (pubspec with flutter SDK dep but no `android/`) → `primary_language=flutter`, `flutter_android=false`.

**bats — `tests/shell/onboard-render.bats`:**
- Flutter profile → rendered `ci.yml` contains `lint-flutter` + `test-flutter` jobs with `working_directory` and the coverage var.
- Flutter-app profile → rendered `release.yml` contains `release-flutter-android` with `version: ${{ needs.release-please.outputs.tag_name }}` and `dart_define_secret_names: ${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}`.
- Flutter-package profile (no `android/`) → `ci.yml` has lint/test, `release.yml` has **no** release-flutter-android job.
- rendered `release-please-config.json` has `"release-type": "dart"`.

**Integration:** render the full template set against `tests/fixtures/flutter-app/` (has top-level `flutter:` block, `sdk: flutter`, `android/` dir) and assert `actionlint` + `yamllint` pass on the rendered `ci.yml` / `release.yml`. Follows the existing render-and-validate test convention.

## PR plan

Single PR, branch `feat/flutter-renderer-detection`, in a fresh worktree under `.worktrees/flutter-renderer-detection/` branched from `origin/main` (4.5.0). One logical concern → one implementer dispatch covering: detection lib + legacy path + onboard-detect action doc + both templates + bats (detect + render) + integration assertion. Conventional commit `feat(onboard): detect Flutter and render ci/release` (minor bump).

Two-stage review (spec-reviewer then code-quality-reviewer) per the established phase pattern before opening the PR.

## Acceptance criteria

- `onboard-detect.sh --profile-json tests/fixtures/flutter-app` →
  `primary_language=flutter`, `release_please_type=dart`, `release_signals.flutter_android=true`, `role=mobile-app`, zero warnings.
- Rendering the fixture → `ci.yml` has lint-flutter + test-flutter; `release.yml` has release-flutter-android wired to `tag_name` + `SK_FLUTTER_DART_DEFINE_SECRETS`; `release-please-config.json` has `release-type: dart`. Output is semantically equivalent to strassenfuchs #24 (modulo var-driven dart-define + coverage default).
- `actionlint` + `yamllint` + `bats` all green; existing non-Flutter detect/render tests unchanged and green.

## Open questions / accepted defaults

1. `coverage_threshold` renders the default (80), not strassenfuchs' non-blocking 0. Adopters that want non-blocking set `SK_COVERAGE_THRESHOLD=0`. **Accepted.**
2. `java_version` / `flutter_channel` are not exposed as SK_ vars; atom defaults (17, stable) are used. Add later if an adopter needs them. **Accepted.**
3. `release.yml` top-level permissions stay the full superset for no-docker (Flutter) renders. **Accepted.**
