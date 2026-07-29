# build-flutter-android — PR-time Android build atom

**Date:** 2026-07-28
**Status:** approved
**Origin:** FR from adopter `serverkraken/strassenfuchs` (flow doc `notes/fr-build-flutter-android`)

## Problem

The catalog has three Flutter atoms. `lint-flutter.yml` and `test-flutter.yml` are
PR-suitable but never invoke Gradle; `release-flutter-android.yml` invokes Gradle but
is bound to release semantics (version, signing keystore, GitHub Release upload,
required release secrets). There is no way to verify on a pull request that the
Android side of a Flutter app still compiles.

Real-world impact: in strassenfuchs, Renovate PRs bumping the Gradle wrapper (#21)
and the Kotlin Android plugin (#29) sat green for months — none of the four checks
touched Gradle. The breakage would only have surfaced at release time.

## Goals

- A fourth Flutter atom `build-flutter-android.yml` that compiles the Android app on
  PRs — no signing, no upload, no version handling, no release secrets.
- Onboarding renders a paths-filtered `ci-android.yml` for Flutter-app adopters so
  pure Dart/docs PRs never pay the ~9-minute toolchain + Gradle cost.
- strassenfuchs (and any other Flutter-app adopter) picks the check up automatically
  on the next onboard sweep.

## Non-Goals

- No replacement for `release-flutter-android.yml`; the two complement each other.
- No AAB build, no artefact upload — the check answers "does the Android side
  compile", not "produce an installable".
- No required-check guarantee: with `paths:` filtering the check does not appear on
  unrelated PRs, so it must not be listed as a required branch-protection check.

## Design

### 1. Atom: `.github/workflows/build-flutter-android.yml`

Structural twin of `test-flutter.yml`: checkout adopter repo → mint catalog-scoped
App token → resolve catalog ref (self-CI SHA vs. `v4`) → checkout catalog →
`setup-flutter-toolchain` composite → build step → step summary.

Inputs (all optional, defaults matching the sibling atoms):

| Input | Type | Default | Purpose |
|---|---|---|---|
| `runs_on` | string | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| `working_directory` | string | `.` | Flutter project root |
| `java_version` | string | `17` | Java major version |
| `flutter_channel` | string | `stable` | Flutter release channel |
| `flutter_version` | string | `''` | specific Flutter version (empty = latest on channel) |
| `use_build_runner` | boolean | `true` | run build_runner after pub get |
| `build_mode` | string | `debug` | `debug` \| `profile` \| `release`; debug suffices for verification and needs no keystore |
| `flavor` | string | `''` | build flavor (empty = no `--flavor` flag) |
| `sdk_cache` | boolean | `false` | Flutter SDK cache (see setup-flutter-toolchain) |
| `timeout_minutes` | number | `45` | job timeout |

Secrets: only `release_please_app_client_id` + `release_please_app_private_key`
(both required — catalog checkout), identical to lint/test siblings.

Build step (after toolchain setup):

```
flutter build apk --<build_mode> [--flavor=<flavor>]
```

`build_mode` is validated against `debug|profile|release` in a small guard step
(fail fast with `::error::` on anything else, since it is interpolated into the
command). `permissions: contents: read`. Concurrency group mirrors `test-flutter`
(`cancel-in-progress` on PRs). Summary follows `docs/conventions/step-summary.md`
(`## build-flutter-android`, tool line, working dir, result).

Stability surface comment at the top of the file, as in every atom: all inputs and
secrets stable within major v4.

### 2. Onboarding skeleton: `docs/adopter-templates/skeletons/ci-android.yml.tmpl`

New rendered file `.github/workflows/ci-android.yml`, emitted **only when at least
one component has `release_signals.flutter_android == true`** (same flag the release
skeletons already gate on).

Trigger with per-component prefixed paths (component at `.` → no prefix; component
at `app/` → `app/` prefix):

```yaml
on:
  pull_request:
    paths:
      - 'android/**'
      - 'pubspec.yaml'
      - 'pubspec.lock'
      - '.github/workflows/ci-android.yml'
```

One job per flutter_android component, following the existing job-id pattern:
`build-flutter-<suffix>` (suffix rule identical to `ci.yml.tmpl`: `.` → `root`,
else path with `/` → `-`). Each job calls the atom with `working_directory` and
`secrets: inherit`. `vars.SK_*` overrides mirror the ci.yml conventions where an
atom input has a matching var (none new; `build_mode` stays at its default —
adopters needing overrides edit via vars later if demand appears).

### 3. Render engines (both must change)

- **Go** (`internal/app/render/service.go`): `plannedFiles` and `lockPaths` gain the
  conditional entry `skeletons/ci-android.yml.tmpl` → `.github/workflows/ci-android.yml`
  when a new predicate `hasFlutterAndroid(profile)` (any component's
  `ReleaseSignals.FlutterAndroid`) is true. GitOps profiles are unaffected (they
  cannot carry flutter components, but the predicate ordering keeps it safe).
- **Shell** (`scripts/onboard-render.sh`): same conditional via
  `jq -e '[.components[].release_signals.flutter_android] | any'`, plus the lock
  and rendered-files list entries.
- Drift check: no code change expected — it walks the lock file — but verify
  `drift-check` covers the new file via the lock entries.

### 4. Fixtures & tests

- `tests/fixtures/onboard/flutter-app/expected/.github/workflows/ci-android.yml`
  added; `flutter-package` expected output stays unchanged (no android/ dir →
  `flutter_android=false`).
- `tests/shell/onboard-render.bats`: render tests — emitted when
  `flutter_android=true`, omitted when `false`/absent, lock contains/omits the entry.
- `internal/app/render/service_test.go`: same two cases for the Go engine.
- Self-CI (`self-ci.yml`): `build-flutter-android-happy` against
  `tests/fixtures/flutter-app`, next to `lint-flutter-happy`/`test-flutter-happy`,
  and wired into the aggregate needs-list.
- Failure path (`failure-paths-nightly.yml`): `test-build-flutter-android-fail`
  calls the atom with `flavor: nonexistent` against the same fixture — Gradle
  aborts on an unknown flavor — plus the standard `assert-*-fail` companion job.

### 5. Docs

- `docs/contracts.md`: new atom section (inputs/secrets table, stability surface).
- `docs/operations.md`: mention the atom in the Flutter composition section; note
  the ci-android.yml skeleton and the required-check caveat.
- `README.md`: add the atom to the catalog list.
- flow: FR doc gets resolution note; orientation note's open item closed (after merge).

### 6. Versioning

Pure addition: new atom + new conditionally-rendered skeleton. `feat:` → minor
release within v4. No existing contract changes.

## Error handling

- Invalid `build_mode` → guard step fails with `::error::` before any build work.
- Gradle/build failure → job fails; summary step (`if: always()`) reports ✗.
- Missing android/ directory in the adopter (misconfigured call) → `flutter build
  apk` fails naturally with Flutter's own error; no extra pre-check (YAGNI).

## Testing summary

| Layer | What |
|---|---|
| Static | actionlint + yamllint via existing validate self-CI |
| Unit (shell) | onboard-render.bats: conditional emission + lock |
| Unit (Go) | render service_test.go: conditional emission + lock |
| Integration happy | self-ci.yml `build-flutter-android-happy` vs. flutter-app fixture |
| Integration failure | failure-paths-nightly `flavor: nonexistent` |
