# Flutter Atoms — Design

**Date:** 2026-05-27
**Status:** Approved (sections after section 1 approved as a batch via "ab jetzt unabhängig durchführen")

## Problem

The catalog has lint/test/release atoms for Go, Python, Rust, Helm — but nothing for Flutter. `serverkraken/strassenfuchs` is a Flutter app whose existing hand-rolled workflows (`manual-apk-build.yml`, `semantic-release.yml`, `test-coverage.yml`) duplicate setup boilerplate and predate the catalog's `workflow_call` conventions. Memory `project_phase8_atom_gaps` recorded the gap; this spec closes it for Android.

iOS, Play-Store upload, and adopter-side renderer detection are explicitly out of scope (Phase-2). The output of this spec is a usable Android Flutter atom trilogy plus a composite action, consumed initially by strassenfuchs through a hand-written caller until renderer support arrives.

## Solution

Three reusable `workflow_call` workflows plus one composite action, all under existing catalog conventions (App-token checkout pattern, step-summary contract, runner-pool input with reasonable default, caller-* self-CI wrappers).

- **`actions/setup-flutter-toolchain/action.yml`** — Composite action. Encapsulates Java + Android SDK + Flutter + `flutter pub get` + optional `dart run build_runner build --delete-conflicting-outputs`. Single source of truth for the toolchain step set; used by all three atoms.
- **`lint-flutter.yml`** — `dart format --set-exit-if-changed` + `flutter analyze`. Mirrors lint-go/lint-python shape.
- **`test-flutter.yml`** — `flutter test --coverage`, then gate the resulting `coverage/lcov.info` against `coverage_threshold` (default 80). Step-summary writes coverage %.
- **`release-flutter-android.yml`** — Pubspec-version-sync → build APK and/or AAB → sign with release keystore from secrets → rename artefact to `<repo>-<tag>.<ext>` → attach to existing GitHub Release (created by `semantic-release.yml`'s release-please step).

## Architecture

```
.github/workflows/
  lint-flutter.yml                  workflow_call
  test-flutter.yml                  workflow_call
  release-flutter-android.yml       workflow_call
  caller-flutter-lint-happy.yml     self-CI wrapper (pull_request)
  caller-flutter-test-happy.yml     self-CI wrapper (pull_request)
  caller-flutter-release-happy.yml  self-CI wrapper, uses fixture keystore + no real signing

actions/setup-flutter-toolchain/
  action.yml                        composite — java + android-sdk + flutter + pub get + (opt) build_runner

tests/fixtures/flutter-app/
  pubspec.yaml                      version: 0.0.0, name: catalog-test-flutter-app
  lib/main.dart                     one widget; parses --dart-define=GREETING=...
  test/widget_test.dart             one passing test, produces coverage > 80%
  android/                          minimal app/build.gradle.kts + AndroidManifest.xml
  android/release.keystore.b64      test-only keystore, base64'd; secret-free fixture (committed)
```

The three atoms share their setup chain via the composite action, so any toolchain bump (Java 17 → 21, Flutter channel pin) lands in one place. The atoms themselves contain only their distinct work (lint vs test vs release).

### Composite action — `actions/setup-flutter-toolchain/action.yml`

```yaml
name: 'Setup Flutter Toolchain'
description: 'Java + Android SDK + Flutter + pub get + optional build_runner.'
inputs:
  java-version:        { default: '17' }
  java-distribution:   { default: 'temurin' }
  flutter-channel:     { default: 'stable' }
  flutter-version:     { default: '' }            # empty = latest on channel
  use-build-runner:    { default: 'true' }        # boolean string per composite-input rules
  working-directory:   { default: '.' }
runs:
  using: composite
  steps:
    - uses: actions/setup-java@<SHA>     # v5
      with: { distribution: ${{ inputs.java-distribution }}, java-version: ${{ inputs.java-version }} }
    - uses: android-actions/setup-android@<SHA>   # v4
    - uses: subosito/flutter-action@<SHA>          # v2
      with: { channel: ${{ inputs.flutter-channel }}, flutter-version: ${{ inputs.flutter-version }}, cache: true }
    - shell: bash
      working-directory: ${{ inputs.working-directory }}
      run: flutter pub get
    - if: ${{ inputs.use-build-runner == 'true' }}
      shell: bash
      working-directory: ${{ inputs.working-directory }}
      run: dart run build_runner build --delete-conflicting-outputs
```

All third-party actions SHA-pinned per Renovate `helpers:pinGitHubActionDigests` (catalog convention).

### `lint-flutter.yml`

```yaml
on:
  workflow_call:
    inputs:
      runs_on:             { type: string, default: '["self-hosted","Linux","X64","performance"]' }
      working_directory:   { type: string, default: '.' }
      java_version:        { type: string, default: '17' }
      flutter_channel:     { type: string, default: 'stable' }
      flutter_version:     { type: string, default: '' }
      use_build_runner:    { type: boolean, default: true }

permissions: { contents: read }

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - uses: actions/checkout@<SHA>
      - uses: ./.catalog/actions/setup-flutter-toolchain
        with:
          java-version:       ${{ inputs.java_version }}
          flutter-channel:    ${{ inputs.flutter_channel }}
          flutter-version:    ${{ inputs.flutter_version }}
          use-build-runner:   ${{ inputs.use_build_runner }}
          working-directory:  ${{ inputs.working_directory }}
      - name: dart format check
        working-directory: ${{ inputs.working_directory }}
        run: dart format --set-exit-if-changed .
      - name: flutter analyze
        working-directory: ${{ inputs.working_directory }}
        run: flutter analyze
      - name: Step summary
        if: always()
        run: |
          {
            echo "## lint-flutter"
            echo ""
            echo "**Tool:** dart format --set-exit-if-changed + flutter analyze"
            echo "**Result:** ${{ job.status }}"
          } >> "$GITHUB_STEP_SUMMARY"
```

The catalog-checkout pattern is identical to existing atoms: the composite action is mounted from a relative path because the caller's calling workflow already checked out the catalog under `.catalog/` (via the App-token pattern). Same as `lint-go.yml`. The `<SHA>` placeholders are real action pins resolved at implementation time.

### `test-flutter.yml`

Same setup. After `flutter test --coverage` produces `coverage/lcov.info`, an inline bash block extracts the line-coverage percentage from the LCOV summary (sum of `LH:` / sum of `LF:`) and compares against `inputs.coverage_threshold` (default 80, type `number` wrapped via `fromJSON` per memory `troubleshooting_gha_type_coercion`).

```yaml
inputs:
  # ...same toolchain inputs as lint-flutter...
  coverage_threshold:  { type: number, default: 80 }
```

Step-summary section emits coverage %, threshold, and pass/fail glyph (`✓` / `✗`) per the catalog convention.

### `release-flutter-android.yml`

The most complex atom. Inputs/outputs/secrets contract:

```yaml
on:
  workflow_call:
    inputs:
      runs_on:                   { type: string,  default: '["self-hosted","Linux","X64","performance"]' }
      working_directory:         { type: string,  default: '.' }
      version:                   { type: string,  required: true }        # e.g. "1.2.3" (no leading v)
      java_version:              { type: string,  default: '17' }
      flutter_channel:           { type: string,  default: 'stable' }
      flutter_version:           { type: string,  default: '' }
      use_build_runner:          { type: boolean, default: true }
      build_apk:                 { type: boolean, default: true }
      build_aab:                 { type: boolean, default: false }
      flavor:                    { type: string,  default: '' }           # empty = no --flavor flag
      prerelease:                { type: boolean, default: false }
      dart_define_secret_names:  { type: string,  default: '' }           # comma-separated list
      artefact_name_prefix:      { type: string,  default: '' }           # empty → derive from repo name
    secrets:
      ANDROID_KEYSTORE_BASE64:   { required: true }
      ANDROID_STORE_PASSWORD:    { required: true }
      ANDROID_KEY_ALIAS:         { required: true }
      ANDROID_KEY_PASSWORD:      { required: true }
      # plus whatever dart_define_secret_names lists — resolved through `secrets: inherit` at the caller
permissions:
  contents: write     # to attach assets to existing release
```

Job-level flow:

```
1. checkout caller repo + ./.catalog/actions/setup-flutter-toolchain
2. Sync version into pubspec.yaml
   sed -i -E "s/^version: .*/version: ${INPUT_VERSION}+${GITHUB_RUN_NUMBER}/" pubspec.yaml
   (Flutter's pubspec version syntax: "<semver>+<build>". build = run number for monotonic increment.)
3. Decode keystore from secret
   echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/release.keystore
4. Build dart-define flags from dart_define_secret_names
   Atom reads secret names list. For each name, the catalog convention is `secrets: inherit` at the
   caller; the atom then reads each from the `${{ secrets }}` context via toJSON dump into a
   masked env, parses with jq, appends `--dart-define=NAME=VALUE` per entry. Empty list → no flags.
5. flutter build apk --release [--flavor=$FLAVOR] [--build-number=$RUN] $DART_DEFINE_FLAGS    (if build_apk)
   flutter build appbundle --release [--flavor=$FLAVOR] [--build-number=$RUN] $DART_DEFINE_FLAGS (if build_aab)
   env: ANDROID_KEYSTORE_PATH=../release.keystore, ANDROID_STORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD
6. Rename + locate artefacts
   APK: build/app/outputs/flutter-apk/app-release.apk → <prefix>-v<version>.apk
   AAB: build/app/outputs/bundle/release/app-release.aab → <prefix>-v<version>.aab
   prefix defaults to ${{ github.event.repository.name }}
7. Attach to existing release
   gh release upload "v${INPUT_VERSION}" <files...> --clobber
   (Release was created by semantic-release.yml's release-please step. --clobber lets reruns replace.)
   if [[ "${{ inputs.prerelease }}" == "true" ]]; then
     gh release edit "v${INPUT_VERSION}" --prerelease
   fi
   (Atom modifies the already-created release; release-please does not expose a per-tag prerelease toggle.)
8. Step summary
   ## release-flutter-android
   Tool: flutter build apk + appbundle (gated)
   Result: success
   | Artefact | Size |  …
```

#### dart-define secret resolution

Caller side:

```yaml
release-android:
  uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@v4
  needs: [release-please]
  if: needs.release-please.outputs.release_created == 'true'
  with:
    version: ${{ needs.release-please.outputs.tag_name }}             # "vX.Y.Z" — atom strips leading v
    dart_define_secret_names: "SUPABASE_URL,SUPABASE_ANON_KEY"
  secrets: inherit
```

Atom side:

```yaml
- name: Build dart-define flags
  env:
    SECRETS_JSON: ${{ toJSON(secrets) }}
    NAMES: ${{ inputs.dart_define_secret_names }}
  run: |
    set -euo pipefail
    flags=()
    if [[ -n "$NAMES" ]]; then
      IFS=',' read -ra arr <<< "$NAMES"
      for n in "${arr[@]}"; do
        n="${n//[[:space:]]/}"
        [[ -z "$n" ]] && continue
        v=$(echo "$SECRETS_JSON" | jq -r --arg k "$n" '.[$k] // ""')
        if [[ -z "$v" ]]; then
          echo "::error::dart_define_secret_names references unknown/empty secret: $n"
          exit 1
        fi
        flags+=("--dart-define=$n=$v")
      done
    fi
    printf '%s\n' "DART_DEFINE_FLAGS=${flags[*]}" >> "$GITHUB_ENV"
```

`toJSON(secrets)` dumps all inherited secrets into a masked env var. Each secret's value remains masked in logs by GitHub's auto-masking (registered on resolution). The atom never echoes the JSON, only looks up specific keys via `jq`. Builds with `$DART_DEFINE_FLAGS` interpolated.

## Data flow

```
release-please (semantic-release.yml)
   │
   ├── tag_name output → "v1.2.3"
   └── release_created → "true"
            ↓
release-flutter-android.yml (caller passes version: "1.2.3")
   │
   ├── pubspec.yaml: "version: 1.2.3+<run-number>"
   ├── build APK/AAB with --dart-define flags from secrets:inherit
   └── gh release upload v1.2.3 strassenfuchs-v1.2.3.apk
            ↓
GitHub Release v1.2.3 now has assets
```

Version is single-sourced from `release-please.outputs.tag_name`. pubspec.yaml is overwritten by the atom each run; the change is **not committed** (build-time only, vanishes after the runner ephemeral cleanup). If an adopter wants pubspec.yaml to also stay in sync on `main`, they configure release-please's `extra-files` block in their `release-please-config.json` — orthogonal to this atom.

## Adopter integration (until renderer extension lands)

strassenfuchs writes its `release.yml` manually:

```yaml
name: release
on:
  push: { branches: [main] }

permissions: { contents: write, pull-requests: write, issues: write, packages: write, id-token: write, attestations: write, artifact-metadata: write, security-events: write, actions: read }

jobs:
  release-please:
    uses: serverkraken/reusable-workflows/.github/workflows/semantic-release.yml@v4
    secrets: inherit

  android-build:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@v4
    with:
      version: ${{ needs.release-please.outputs.tag_name }}     # "vX.Y.Z"; atom strips leading v
      dart_define_secret_names: "SUPABASE_URL,SUPABASE_ANON_KEY"
      prerelease: true                                          # marks the GitHub Release as prerelease post-upload
    secrets: inherit
```

When the renderer extension lands later (Phase-2), strassenfuchs's `release.yml` becomes auto-generated by the catalog — but the atom contract stays the same.

## Testing strategy

Per catalog convention (memory `troubleshooting_continue_on_error_workflow_call`): two-job pattern for failure paths, branch-protection only on assert-*. For this spec, all three atoms have happy-path coverage; failure-paths land in the nightly cron later (memory `reference_phase9_aggregate_caller_wrapper`).

**Fixture:** `tests/fixtures/flutter-app/` — minimal Flutter project committed to the repo. Contains:
- `pubspec.yaml` with `version: 0.0.0` and a single dependency (`flutter`).
- `lib/main.dart` rendering a single widget; reads `String.fromEnvironment('GREETING', 'hello')` to exercise dart-define.
- `test/widget_test.dart` containing one widget-test that asserts the widget renders → coverage ≥ 80% on a one-file project trivially.
- `android/` directory with the minimum needed for `flutter build apk` to succeed: `app/build.gradle.kts` (release signingConfig referencing `keyAlias`/`storePassword`/`keyPassword`/`storeFile` env-driven), `AndroidManifest.xml`, `key.properties` template.
- `android/release.keystore.b64` — a deliberately throwaway debug keystore base64'd, committed. The fixture's "secret" is the same file — there's no real secret here, just a test artefact that lets `flutter build apk --release` complete. Memory `troubleshooting_python_pm_detection` applies the same principle (commit fixtures, don't rely on env).

**Caller workflows:**
- `caller-flutter-lint-happy.yml` — calls `lint-flutter.yml` with `working_directory: tests/fixtures/flutter-app`. Triggered on PRs that touch `lint-flutter.yml`, the composite, or the fixture.
- `caller-flutter-test-happy.yml` — calls `test-flutter.yml`. Same trigger filter.
- `caller-flutter-release-happy.yml` — calls `release-flutter-android.yml` with `version: '0.0.1'`, `build_apk: true`, `build_aab: false`, `dart_define_secret_names: "GREETING"`, `secrets: inherit`. Catalog's own `secrets.GREETING` is a repository variable set to `"hello-from-catalog-CI"`. The catalog repo also holds **fixture** keystore secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`) at the repo level — they all point at the fixture's throwaway keystore so signing completes. After build, asserts the `.apk` exists in `build/app/outputs/flutter-apk/` and step-summary contains the expected glyph.
- All three callers are added to `.github/workflows/integration.yml`'s `needs:` list for `summary`, so they're gated by branch-protection's `integration / summary` context.

**Bats unit tests:** none needed — all logic is inline bash whose behaviour is exercised end-to-end by the caller workflows. Per memory `feedback_phase_workflow_pattern`, only extract bash to `scripts/*.sh` if logic grows past ~30 lines or is reused.

**Step-summary lint:** `tests/conventions/check-step-summary.sh` already enforces the schema across all atoms; the three new ones will be picked up automatically.

## Out of scope

- **iOS build** (`release-flutter-ios.yml`) — Soenne 2026-05-27: "IOS ist erstmal zu vernachlässigen". Deferred indefinitely.
- **Play-Store upload** — Phase-2 spec will add (a) an `upload_to_play_store` boolean input + `play_store_track` string input to `release-flutter-android.yml`, and (b) a topic-detection branch in `scripts/onboard-detect.sh` so adopters opt in via a repo topic. The atom-side input lands first; the renderer wiring follows.
- **Onboard renderer extension** — `scripts/onboard-detect.sh` needs a Flutter component-detection branch (probe for `pubspec.yaml` with a `flutter:` block), and `docs/adopter-templates/skeletons/{ci,release}.yml.tmpl` need Flutter-language branches. Both are Phase-2 work, planned right after this spec ships and is exercised by strassenfuchs's manually-written caller.
- **Pubspec.yaml committing** — atom only modifies pubspec.yaml in the runner tmpdir, never pushes. Adopters who want it committed long-term wire release-please's `extra-files: pubspec.yaml` themselves.
- **Flavor matrix** — `flavor` is a single-string input. Matrix-style (build dev + staging + prod in one workflow run) waits for a real adopter need.

## Open questions / risks

- **Risk: `toJSON(secrets)` includes the keystore base64.** The base64 keystore is one of `secrets:inherit`'s payload; when dumped to env it becomes a long string that GitHub's masker should auto-mask. Verify during implementation that no step echoes `$SECRETS_JSON` or `$DART_DEFINE_FLAGS` in plain. The atom only does targeted `jq -r` lookups; this is fine, but the linter/CI for step-summary should also confirm no accidental echo regressed it.
- **Risk: keystore-fixture in the repo.** Committing a real-looking keystore is OK (it's a test artefact, not a production cert) but flag explicitly in the fixture's README and exclude its `.b64` from Trivy fs scans via the existing `tests/fixtures/**` skip rule.
- **Resolved: tag_name format.** release-please emits `tag_name` as `vX.Y.Z`; the atom internally strips the leading `v` at step 2 (`INPUT_VERSION="${VERSION#v}"`) before writing to `pubspec.yaml`. Step 7 then re-prepends `v` for `gh release upload "v${INPUT_VERSION}"`. Caller passes `tag_name` raw — bare semver also works because `${V#v}` is a no-op when there's no v prefix.
- **Resolved: prerelease flag location.** Atom modifies the already-created GitHub Release via `gh release edit "v${VERSION}" --prerelease` after asset upload. release-please does not expose a per-tag prerelease toggle in its config, so the post-edit is the cleanest contract; the atom owns this since it already holds `contents: write`.
- **Risk: build_runner conflicts on cached `.dart_tool`.** `--delete-conflicting-outputs` already handles it; document in composite-action `description`.
- **Open: composite-action SHA-pinning during initial PR.** Renovate's `helpers:pinGitHubActionDigests` will auto-pin third-party actions, but the first commit must already use tag references (not `@main`) so Renovate has something to pin from. Implementation step lists v-tags; the immediate follow-up Renovate PR pins to SHA.
