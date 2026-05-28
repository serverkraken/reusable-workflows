# Flutter Atoms Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Flutter lint/test/release-android atoms + setup composite to the catalog, exactly matching the design at `docs/superpowers/specs/2026-05-27-flutter-atoms-design.md`. Output: serverkraken/strassenfuchs can adopt the v4 catalog with a hand-written `release.yml` until the Phase-2 renderer extension.

**Architecture:** Three `workflow_call` reusable workflows (`lint-flutter.yml`, `test-flutter.yml`, `release-flutter-android.yml`) sharing one composite action (`actions/setup-flutter-toolchain`). Plus a minimal committed Flutter fixture (`tests/fixtures/flutter-app/`) with throwaway keystore so the three caller-* self-CI wrappers can exercise the atoms end-to-end on every PR.

**Tech Stack:** GitHub Actions (workflow_call + composite action), Flutter SDK 3.x, Dart 3.x, Android SDK + Java 17, bash + jq + awk, actionlint + yamllint (already in catalog CI).

**Single PR strategy:** One branch `feat/flutter-atoms`, sequential commits per task, one PR at the end. Total expected diff: ~700–900 lines across ~12 new/modified files. If the implementation agent decides mid-flow to split into two PRs (e.g. composite+lint+test in PR A, release+secrets in PR B), that is acceptable — both halves are independently mergeable.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `actions/setup-flutter-toolchain/action.yml` | Create | Composite — Java + Android SDK + Flutter + pub get + opt build_runner |
| `.github/workflows/lint-flutter.yml` | Create | Atom — `dart format --set-exit-if-changed` + `flutter analyze` |
| `.github/workflows/test-flutter.yml` | Create | Atom — `flutter test --coverage` + LCOV-parsed threshold gate |
| `.github/workflows/release-flutter-android.yml` | Create | Atom — pubspec-sync + APK/AAB build + sign + attach |
| `.github/workflows/caller-flutter-lint-happy.yml` | Create | self-CI wrapper for lint-flutter |
| `.github/workflows/caller-flutter-test-happy.yml` | Create | self-CI wrapper for test-flutter |
| `.github/workflows/caller-flutter-release-happy.yml` | Create | self-CI wrapper for release-flutter-android |
| `.github/workflows/integration.yml` | Modify | Add three new caller jobs to the `summary` needs list |
| `tests/fixtures/flutter-app/pubspec.yaml` | Create | Minimal Flutter project descriptor |
| `tests/fixtures/flutter-app/lib/main.dart` | Create | One widget that reads `--dart-define=GREETING` |
| `tests/fixtures/flutter-app/test/widget_test.dart` | Create | One widget test → coverage ≥ 80% on the one-file project |
| `tests/fixtures/flutter-app/analysis_options.yaml` | Create | Standard `package:flutter_lints/flutter.yaml` include |
| `tests/fixtures/flutter-app/android/...` | Create | Minimum scaffold for `flutter build apk --release` |
| `tests/fixtures/flutter-app/android/release.keystore.b64` | Create | Throwaway debug keystore base64'd, committed |
| `tests/fixtures/flutter-app/README.md` | Create | Documents "this keystore is a test artefact, not a secret" |
| `docs/operations.md` | Modify | New section: Flutter atom set + adopter integration |

---

## PATTERN CORRECTION (discovered at execution time, 2026-05-28)

The simplified atom drafts in Tasks 5/7/9 below show `uses: ./.catalog/actions/setup-flutter-toolchain` without the preamble that makes it work. **`lint-python.yml` is the authoritative reference**, not `lint-go.yml`. Because `setup-flutter-toolchain` is a catalog-local composite (not a published marketplace action), every atom that uses it MUST first mint a catalog-scoped App token and check the catalog out into `.catalog/`. `lint-go.yml` does NOT do this only because `setup-go` is a published action; it is the wrong template here.

**Every Flutter atom (lint, test, release) MUST include this preamble before the composite step:**

```yaml
    secrets:
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'
      # release-flutter-android.yml ALSO declares the four ANDROID_* keystore secrets (see Task 9).

# ...in the job steps, before the composite:
      - name: Checkout adopter repo
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
      - name: Mint catalog-scoped App token
        id: catalog-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3
        with:
          client-id: ${{ secrets.release_please_app_client_id }}
          private-key: ${{ secrets.release_please_app_private_key }}
          owner: serverkraken
          repositories: reusable-workflows
      - name: Resolve catalog ref
        id: catalog-ref
        env:
          IS_SELF_CI: ${{ github.repository == 'serverkraken/reusable-workflows' }}
          SELF_SHA: ${{ github.sha }}
        run: |
          if [[ "$IS_SELF_CI" == "true" ]]; then
            echo "ref=$SELF_SHA" >> "$GITHUB_OUTPUT"
          else
            # renovate-marker: catalog-major-ref
            echo "ref=v4" >> "$GITHUB_OUTPUT"
          fi
      - name: Checkout catalog (for composite actions)
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ steps.catalog-ref.outputs.ref }}
          token: ${{ steps.catalog-token.outputs.token }}
          path: .catalog
      - name: Setup Flutter toolchain
        uses: ./.catalog/actions/setup-flutter-toolchain
        with: { ... }
```

**Consequences for each atom:**
- `lint-flutter.yml` / `test-flutter.yml`: add the two `release_please_app_*` secrets (required). The `permissions: contents: read` stays.
- `release-flutter-android.yml`: declare BOTH the two `release_please_app_*` secrets AND the four `ANDROID_*` keystore secrets. `permissions: contents: write`.
- **`.catalog` exclusion:** the catalog checkout lands at the adopter workspace root. `flutter analyze` respects package boundaries (won't descend into `.catalog/tests/fixtures/flutter-app` — separate package), but `dart format .` walks all `.dart` files. Run `dart format --set-exit-if-changed --exclude .catalog .` (dart format supports `--exclude`). For `flutter analyze`, scope by running in `working_directory`; if `working_directory == '.'` the analyzer's package boundary already protects it, but add an `analysis_options.yaml` `analyzer: exclude: [.catalog/**]` note in the adopter if needed (out of scope for the atom — the fixture's working_directory is `tests/fixtures/flutter-app`, so `.catalog` at root is never in scope during self-CI).
- **Caller wrappers**: must pass `secrets: inherit` (they currently only set `with:`). Update Tasks 6/8/10 callers to add `secrets: inherit`.
- **Self-CI nuance:** in self-CI the catalog checkout into `.catalog/` duplicates the repo. The fixture lives at `tests/fixtures/flutter-app` (working_directory), and `.catalog/tests/fixtures/flutter-app` is a duplicate — harmless because analysis is scoped to working_directory. Confirm `dart format`'s `--exclude .catalog` keeps it clean.

Implementer subagents: treat this section as overriding the simplified drafts in Tasks 5/7/9 wherever they conflict. Read `.github/workflows/lint-python.yml` start-to-finish before writing the first atom.

### Second correction: callers are inline jobs, not separate files (Phase-9 pattern)

Tasks 6/8/10 describe creating separate `caller-flutter-*-happy.yml` files. **That is the pre-Phase-9 pattern and is wrong for the current catalog.** Phase 9 (memory `reference_phase9_aggregate_caller_wrapper`) replaced all 22 `caller-*.yml` files with inline jobs in `self-ci.yml` and `integration.yml`, gated by the `self-ci / summary` / `integration / summary` branch-protection contexts. Implement the happy-path callers as inline jobs instead:

- **`self-ci.yml`**: add `lint-flutter-happy` (`uses: ./.github/workflows/lint-flutter.yml`, `secrets: inherit`, `with: { working_directory: tests/fixtures/flutter-app, use_build_runner: false }`) and `test-flutter-happy` (same + `coverage_threshold: 80`). Append both to the `self-ci / summary` job's `needs:` list.
- **`integration.yml`**: add a `prepare-flutter-release → test-release-flutter-android → cleanup-flutter-release` trio (the release atom needs a real release to upload to; prepare mints a throwaway prerelease, cleanup deletes it with `--cleanup-tag` under `if: always()`). Append `test-release-flutter-android` to the `integration / summary` `needs:` list.

No `caller-flutter-*.yml` files are created.

---

## Task 1: Branch + worktree setup

**Files:**
- Modify: working tree only (no commits)

- [ ] **Step 1: Ensure we're on a fresh branch off main**

```bash
git fetch origin main
git checkout main
git pull --ff-only
git checkout -b feat/flutter-atoms
```

- [ ] **Step 2: Confirm worktree state is clean**

```bash
git status --short
```

Expected: empty output. If not, stop and ask the user before modifying anything else.

- [ ] **Step 3: Look up SHA pins for the three third-party actions used by the composite**

```bash
gh api repos/actions/setup-java/git/refs/tags/v5 --jq '.object.sha'
gh api repos/android-actions/setup-android/git/refs/tags/v4 --jq '.object.sha'
gh api repos/subosito/flutter-action/git/refs/tags/v2 --jq '.object.sha'
```

Record each SHA. They go into the composite action with a `# v5` / `# v4` / `# v2` trailing comment so Renovate's pin updater recognises them.

For `actions/checkout`, reuse the SHA already in use across the catalog: `de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6`. Confirm with `rg "de0fac2e4500dabe" .github/workflows/ | head -1`.

---

## Task 2: Fixture — Flutter project (pubspec + lib + test)

**Files:**
- Create: `tests/fixtures/flutter-app/pubspec.yaml`
- Create: `tests/fixtures/flutter-app/lib/main.dart`
- Create: `tests/fixtures/flutter-app/test/widget_test.dart`
- Create: `tests/fixtures/flutter-app/analysis_options.yaml`
- Create: `tests/fixtures/flutter-app/README.md`

- [ ] **Step 1: Write `pubspec.yaml`**

```yaml
name: catalog_test_flutter_app
description: "Minimal Flutter app used as a fixture for the catalog's Flutter atom callers. Not a real app."
publish_to: 'none'
version: 0.0.0+0

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
```

- [ ] **Step 2: Write `lib/main.dart`**

```dart
import 'package:flutter/material.dart';

void main() => runApp(const FixtureApp());

class FixtureApp extends StatelessWidget {
  const FixtureApp({super.key});

  static const greeting = String.fromEnvironment('GREETING', defaultValue: 'hello');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(greeting, key: const Key('greeting')),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Write `test/widget_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:catalog_test_flutter_app/main.dart';

void main() {
  testWidgets('renders the greeting widget', (tester) async {
    await tester.pumpWidget(const FixtureApp());
    expect(find.byKey(const Key('greeting')), findsOneWidget);
  });
}
```

This single test, exercising the only widget in `main.dart`, takes coverage above 80% by construction (the file has ~12 statements; the widget tree all executes in the build call).

- [ ] **Step 4: Write `analysis_options.yaml`**

```yaml
include: package:flutter_lints/flutter.yaml
```

- [ ] **Step 5: Write `README.md`**

```markdown
# catalog_test_flutter_app

Minimal Flutter project used as a fixture by the catalog's Flutter atom callers
(`caller-flutter-{lint,test,release}-happy.yml`). Not a real app.

The `android/release.keystore.b64` in this directory is a deliberately
**throwaway keystore** committed as base64. It exists so `flutter build apk
--release` can complete inside CI without any real signing material. Do not
copy it into a production project. Trivy fs is configured to skip this
directory via the existing `tests/fixtures/**` exclusion.
```

- [ ] **Step 6: Verify YAML syntax**

```bash
yamllint tests/fixtures/flutter-app/pubspec.yaml tests/fixtures/flutter-app/analysis_options.yaml
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/flutter-app/pubspec.yaml \
        tests/fixtures/flutter-app/analysis_options.yaml \
        tests/fixtures/flutter-app/lib/main.dart \
        tests/fixtures/flutter-app/test/widget_test.dart \
        tests/fixtures/flutter-app/README.md
git commit -m "test(flutter-fixture): add minimal Flutter app for caller workflows"
```

---

## Task 3: Fixture — Android scaffolding + throwaway keystore

**Files:**
- Create: `tests/fixtures/flutter-app/android/build.gradle.kts`
- Create: `tests/fixtures/flutter-app/android/settings.gradle.kts`
- Create: `tests/fixtures/flutter-app/android/gradle.properties`
- Create: `tests/fixtures/flutter-app/android/app/build.gradle.kts`
- Create: `tests/fixtures/flutter-app/android/app/src/main/AndroidManifest.xml`
- Create: `tests/fixtures/flutter-app/android/app/src/main/kotlin/com/serverkraken/catalog_test_flutter_app/MainActivity.kt`
- Create: `tests/fixtures/flutter-app/android/key.properties.example`
- Create: `tests/fixtures/flutter-app/android/release.keystore.b64`

The exact Gradle / Manifest contents depend on the Flutter version chosen by the composite (latest stable). Generate them via `flutter create --platforms=android --org com.serverkraken --project-name catalog_test_flutter_app .` inside a scratch dir, then copy the `android/` output into the fixture. This task spells the manual fallback out below in case `flutter create` is not available locally.

- [ ] **Step 1: Generate the android/ scaffold via `flutter create` (preferred)**

```bash
TMP=$(mktemp -d)
( cd "$TMP" && flutter create --platforms=android --org com.serverkraken --project-name catalog_test_flutter_app . )
cp -r "$TMP/android" tests/fixtures/flutter-app/
rm -rf "$TMP"
```

If `flutter` is not installed locally, write the files by hand using the templates below (Step 1b–1g). Skip Step 1b–1g if Step 1 worked.

- [ ] **Step 1b (fallback): `android/build.gradle.kts`**

```kotlin
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
```

- [ ] **Step 1c (fallback): `android/settings.gradle.kts`**

```kotlin
pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.1.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.0" apply false
}

include(":app")
```

- [ ] **Step 1d (fallback): `android/gradle.properties`**

```properties
org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G -XX:+HeapDumpOnOutOfMemoryError
android.useAndroidX=true
android.enableJetifier=true
```

- [ ] **Step 1e (fallback): `android/app/build.gradle.kts`**

```kotlin
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.serverkraken.catalog_test_flutter_app"
    compileSdk = 34
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.serverkraken.catalog_test_flutter_app"
        minSdk = 21
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String? ?: System.getenv("ANDROID_KEY_ALIAS")
            keyPassword = keystoreProperties["keyPassword"] as String? ?: System.getenv("ANDROID_KEY_PASSWORD")
            storeFile = file(keystoreProperties["storeFile"] as String? ?: System.getenv("ANDROID_KEYSTORE_PATH") ?: "release.keystore")
            storePassword = keystoreProperties["storePassword"] as String? ?: System.getenv("ANDROID_STORE_PASSWORD")
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
```

- [ ] **Step 1f (fallback): `android/app/src/main/AndroidManifest.xml`**

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="catalog_test_flutter_app">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
    </application>
</manifest>
```

- [ ] **Step 1g (fallback): `android/app/src/main/kotlin/com/serverkraken/catalog_test_flutter_app/MainActivity.kt`**

```kotlin
package com.serverkraken.catalog_test_flutter_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
```

- [ ] **Step 2: Generate a throwaway keystore locally and base64 it**

```bash
TMPSTORE=$(mktemp -d)/release.keystore
keytool -genkeypair -v \
  -keystore "$TMPSTORE" \
  -alias catalogtest \
  -keyalg RSA -keysize 2048 -validity 36500 \
  -storepass catalog-fixture-storepw \
  -keypass catalog-fixture-keypw \
  -dname "CN=catalog-fixture, OU=test, O=serverkraken, L=test, S=test, C=DE"
base64 -i "$TMPSTORE" -o tests/fixtures/flutter-app/android/release.keystore.b64
rm -f "$TMPSTORE"
```

If `keytool` is unavailable, install Java 17 locally first (`brew install --cask temurin@17` or equivalent). The exact alias and passwords used here MUST match the secret values written in Task 9 Step 4.

- [ ] **Step 3: Write `android/key.properties.example`**

```properties
# Filled at build time from $ANDROID_KEY_ALIAS / $ANDROID_STORE_PASSWORD / $ANDROID_KEY_PASSWORD env vars
storeFile=release.keystore
storePassword=
keyAlias=
keyPassword=
```

- [ ] **Step 4: Verify the fixture builds (optional but recommended if Flutter is installed)**

```bash
cd tests/fixtures/flutter-app
flutter pub get
flutter analyze --no-fatal-infos
flutter test --coverage
cd -
```

Expected: no analyzer errors; tests pass; `coverage/lcov.info` is produced.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/flutter-app/android/ \
        tests/fixtures/flutter-app/android/release.keystore.b64
git commit -m "test(flutter-fixture): add android scaffolding + throwaway keystore"
```

---

## Task 4: Composite action — `actions/setup-flutter-toolchain/action.yml`

**Files:**
- Create: `actions/setup-flutter-toolchain/action.yml`

- [ ] **Step 1: Write the composite action**

Insert the SHAs you fetched in Task 1 Step 3. The structure:

```yaml
name: 'Setup Flutter Toolchain'
description: 'Sets up Java, the Android SDK, Flutter, and runs pub get (optionally build_runner). Single source of truth for the shared toolchain step set in the lint-flutter, test-flutter, and release-flutter-android atoms.'

inputs:
  java-version:
    description: 'Java major version'
    default: '17'
  java-distribution:
    description: 'Java distribution slug for actions/setup-java'
    default: 'temurin'
  flutter-channel:
    description: 'Flutter release channel'
    default: 'stable'
  flutter-version:
    description: 'Specific Flutter version (empty = latest on channel)'
    default: ''
  use-build-runner:
    description: 'When "true", runs `dart run build_runner build --delete-conflicting-outputs` after pub get'
    default: 'true'
  working-directory:
    description: 'Path to the Flutter project root, relative to the runner workspace'
    default: '.'

runs:
  using: composite
  steps:
    - name: Setup Java
      uses: actions/setup-java@<SETUP_JAVA_SHA> # v5
      with:
        distribution: ${{ inputs.java-distribution }}
        java-version: ${{ inputs.java-version }}

    - name: Setup Android SDK
      uses: android-actions/setup-android@<SETUP_ANDROID_SHA> # v4

    - name: Setup Flutter
      uses: subosito/flutter-action@<FLUTTER_ACTION_SHA> # v2
      with:
        channel: ${{ inputs.flutter-channel }}
        flutter-version: ${{ inputs.flutter-version }}
        cache: true

    - name: flutter pub get
      shell: bash
      working-directory: ${{ inputs.working-directory }}
      run: flutter pub get

    - name: dart run build_runner
      if: ${{ inputs.use-build-runner == 'true' }}
      shell: bash
      working-directory: ${{ inputs.working-directory }}
      run: dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 2: Run actionlint over the composite**

```bash
actionlint actions/setup-flutter-toolchain/action.yml
```

Expected: clean. If actionlint flags pin syntax on the SHAs, ignore — it's a known false positive across other catalog actions (memory `project_actionlint_clientid`).

- [ ] **Step 3: Commit**

```bash
git add actions/setup-flutter-toolchain/action.yml
git commit -m "feat(flutter): add setup-flutter-toolchain composite action"
```

---

## Task 5: Atom — `lint-flutter.yml`

**Files:**
- Create: `.github/workflows/lint-flutter.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# Reusable workflow: dart format check + flutter analyze.
#
# Stability surface: inputs (runs_on, working_directory, java_version,
# flutter_channel, flutter_version, use_build_runner). Breaking changes to
# these names or types require a major bump on the catalog.
name: lint-flutter

on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded runner labels'
        required: false
        type: string
        default: '["self-hosted","Linux","X64","performance"]'
      working_directory:
        description: 'Flutter project root, relative to the caller workspace'
        required: false
        type: string
        default: '.'
      java_version:
        required: false
        type: string
        default: '17'
      flutter_channel:
        required: false
        type: string
        default: 'stable'
      flutter_version:
        required: false
        type: string
        default: ''
      use_build_runner:
        required: false
        type: boolean
        default: true

permissions:
  contents: read

concurrency:
  group: lint-flutter-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Checkout caller
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Setup Flutter toolchain
        uses: ./.catalog/actions/setup-flutter-toolchain
        with:
          java-version: ${{ inputs.java_version }}
          flutter-channel: ${{ inputs.flutter_channel }}
          flutter-version: ${{ inputs.flutter_version }}
          use-build-runner: ${{ inputs.use_build_runner }}
          working-directory: ${{ inputs.working_directory }}

      - name: dart format --set-exit-if-changed
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        run: dart format --set-exit-if-changed .

      - name: flutter analyze
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        run: flutter analyze

      - name: Step summary
        if: always()
        shell: bash
        run: |
          {
            echo "## lint-flutter"
            echo ""
            echo "**Tool:** dart format --set-exit-if-changed + flutter analyze"
            echo "**Result:** ${{ job.status }}"
          } >> "$GITHUB_STEP_SUMMARY"
```

**Note on the catalog-checkout pattern:** lint-flutter does NOT use the App-token catalog-checkout pattern (no `uses: ./.catalog/actions/onboard-detect` etc.) because the composite action lives in the **catalog repo itself**, not in the caller. The caller wires the composite by checking out the catalog under `.catalog/` ahead of the atom call — same as the existing `lint-go.yml` pattern. Look at `.github/workflows/lint-go.yml` for the exact precedent before editing further.

Verify by inspection: read `lint-go.yml` and confirm it also uses `./` relative paths into the catalog — not the App-token mint pattern. If `lint-go.yml` mints an App token before the composite, follow its lead and add the same mint step here.

- [ ] **Step 2: Inspect the precedent**

```bash
rg -A 10 "actions/onboard-detect|setup-go-toolchain|setup-python" .github/workflows/lint-go.yml | head -40
```

Compare structure side-by-side with the draft. Adjust the lint-flutter draft to match the precedent (App-token mint or not, checkout-path or not).

- [ ] **Step 3: Run actionlint locally**

```bash
actionlint .github/workflows/lint-flutter.yml
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint-flutter.yml
git commit -m "feat(flutter): add lint-flutter atom"
```

---

## Task 6: Caller — `caller-flutter-lint-happy.yml` + integration wire-up

**Files:**
- Create: `.github/workflows/caller-flutter-lint-happy.yml`
- Modify: `.github/workflows/integration.yml`

- [ ] **Step 1: Inspect an existing caller for the exact shape**

```bash
cat .github/workflows/caller-go-lint-happy.yml
```

Or whichever go/python/rust caller-*-happy.yml file exists. Follow its `paths:` filter style, `permissions` block, and `uses:` reference style. Note that callers `uses: ./.github/workflows/lint-flutter.yml` (relative path inside the catalog) so the self-CI tests the current branch state.

- [ ] **Step 2: Write the caller**

```yaml
name: caller-flutter-lint-happy

on:
  pull_request:
    paths:
      - '.github/workflows/lint-flutter.yml'
      - '.github/workflows/caller-flutter-lint-happy.yml'
      - 'actions/setup-flutter-toolchain/**'
      - 'tests/fixtures/flutter-app/**'

permissions:
  contents: read

jobs:
  lint:
    uses: ./.github/workflows/lint-flutter.yml
    with:
      working_directory: tests/fixtures/flutter-app
      use_build_runner: false   # fixture has no build_runner deps; skip to keep CI lean
```

- [ ] **Step 3: Add the caller to `integration.yml`'s `summary` needs**

```bash
rg -n "^  summary:" .github/workflows/integration.yml
```

The summary job is at line ~271 (per recent edits). Open `.github/workflows/integration.yml` and add the new caller job above the summary, plus add it to the `needs:` list of `summary`. Pattern:

```yaml
  caller-flutter-lint-happy:
    uses: ./.github/workflows/caller-flutter-lint-happy.yml
    permissions:
      contents: read

  summary:
    name: "integration / summary"
    needs:
      - test-docker-build
      - assert-attestation-verifies
      # ... existing entries ...
      - caller-flutter-lint-happy
```

The exact list of existing `needs` entries is whatever is on `main` at execution time; do NOT replace, just append.

- [ ] **Step 4: actionlint over both modified workflows**

```bash
actionlint .github/workflows/caller-flutter-lint-happy.yml \
           .github/workflows/integration.yml
```

Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/caller-flutter-lint-happy.yml \
        .github/workflows/integration.yml
git commit -m "test(flutter): add caller-flutter-lint-happy + wire into integration"
```

---

## Task 7: Atom — `test-flutter.yml`

**Files:**
- Create: `.github/workflows/test-flutter.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# Reusable workflow: flutter test --coverage + threshold gate.
name: test-flutter

on:
  workflow_call:
    inputs:
      runs_on:
        required: false
        type: string
        default: '["self-hosted","Linux","X64","performance"]'
      working_directory:
        required: false
        type: string
        default: '.'
      java_version:
        required: false
        type: string
        default: '17'
      flutter_channel:
        required: false
        type: string
        default: 'stable'
      flutter_version:
        required: false
        type: string
        default: ''
      use_build_runner:
        required: false
        type: boolean
        default: true
      coverage_threshold:
        description: 'Minimum line-coverage percentage (0-100)'
        required: false
        type: number
        default: 80

permissions:
  contents: read

concurrency:
  group: test-flutter-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Checkout caller
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Setup Flutter toolchain
        uses: ./.catalog/actions/setup-flutter-toolchain
        with:
          java-version: ${{ inputs.java_version }}
          flutter-channel: ${{ inputs.flutter_channel }}
          flutter-version: ${{ inputs.flutter_version }}
          use-build-runner: ${{ inputs.use_build_runner }}
          working-directory: ${{ inputs.working_directory }}

      - name: flutter test --coverage
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        run: flutter test --coverage

      - name: Coverage gate
        id: gate
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          THRESHOLD: ${{ inputs.coverage_threshold }}
        run: |
          set -euo pipefail
          if [[ ! -f coverage/lcov.info ]]; then
            echo "::error::coverage/lcov.info not produced — flutter test --coverage failed silently"
            exit 1
          fi
          TOTAL_LF=$(awk -F: '/^LF:/ { sum += $2 } END { print sum+0 }' coverage/lcov.info)
          TOTAL_LH=$(awk -F: '/^LH:/ { sum += $2 } END { print sum+0 }' coverage/lcov.info)
          if [[ "$TOTAL_LF" -eq 0 ]]; then
            echo "::error::No instrumented lines found in lcov.info (LF total = 0)"
            exit 1
          fi
          PCT=$(awk -v h="$TOTAL_LH" -v f="$TOTAL_LF" 'BEGIN { printf "%.2f", (h/f)*100 }')
          echo "pct=$PCT" >> "$GITHUB_OUTPUT"
          echo "threshold=$THRESHOLD" >> "$GITHUB_OUTPUT"
          # bash arithmetic does not handle floats — use awk for the gate.
          if awk -v p="$PCT" -v t="$THRESHOLD" 'BEGIN { exit !(p+0 >= t+0) }'; then
            echo "gate=pass" >> "$GITHUB_OUTPUT"
          else
            echo "gate=fail" >> "$GITHUB_OUTPUT"
            exit 1
          fi

      - name: Step summary
        if: always()
        shell: bash
        env:
          PCT: ${{ steps.gate.outputs.pct }}
          THRESHOLD: ${{ steps.gate.outputs.threshold }}
          GATE: ${{ steps.gate.outputs.gate }}
        run: |
          if [[ "$GATE" == "pass" ]]; then glyph="✓"; result="pass"; fi
          if [[ "$GATE" == "fail" ]]; then glyph="✗"; result="fail"; fi
          {
            echo "## test-flutter"
            echo ""
            echo "**Tool:** flutter test --coverage"
            echo "**Result:** ${glyph:-✗} ${result:-fail} (${PCT:-?}% / ${THRESHOLD:-?}%)"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/test-flutter.yml
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test-flutter.yml
git commit -m "feat(flutter): add test-flutter atom with lcov-parsed coverage gate"
```

---

## Task 8: Caller — `caller-flutter-test-happy.yml` + integration wire-up

**Files:**
- Create: `.github/workflows/caller-flutter-test-happy.yml`
- Modify: `.github/workflows/integration.yml`

- [ ] **Step 1: Write the caller**

```yaml
name: caller-flutter-test-happy

on:
  pull_request:
    paths:
      - '.github/workflows/test-flutter.yml'
      - '.github/workflows/caller-flutter-test-happy.yml'
      - 'actions/setup-flutter-toolchain/**'
      - 'tests/fixtures/flutter-app/**'

permissions:
  contents: read

jobs:
  test:
    uses: ./.github/workflows/test-flutter.yml
    with:
      working_directory: tests/fixtures/flutter-app
      use_build_runner: false
      coverage_threshold: 80
```

- [ ] **Step 2: Add to integration.yml summary needs**

Same procedure as Task 6 Step 3 — append a new job entry above `summary:` and add `caller-flutter-test-happy` to the `summary.needs` list.

- [ ] **Step 3: actionlint**

```bash
actionlint .github/workflows/caller-flutter-test-happy.yml \
           .github/workflows/integration.yml
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/caller-flutter-test-happy.yml \
        .github/workflows/integration.yml
git commit -m "test(flutter): add caller-flutter-test-happy + wire into integration"
```

---

## Task 9: Atom — `release-flutter-android.yml`

**Files:**
- Create: `.github/workflows/release-flutter-android.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# Reusable workflow: build signed Android APK and/or AAB, attach to existing release.
#
# Caller pre-conditions:
#   - release-please (or equivalent) has already created the GitHub Release at tag $version
#   - secrets: inherit at the caller
#
# Stability surface: inputs (version, build_apk, build_aab, flavor, prerelease,
# dart_define_secret_names, artefact_name_prefix, runs_on, working_directory,
# java_version, flutter_channel, flutter_version, use_build_runner) plus the
# required keystore secrets. Breaking changes require a major bump.
name: release-flutter-android

on:
  workflow_call:
    inputs:
      runs_on:
        required: false
        type: string
        default: '["self-hosted","Linux","X64","performance"]'
      working_directory:
        required: false
        type: string
        default: '.'
      version:
        description: 'Semver, with or without leading v. Atom strips leading v internally.'
        required: true
        type: string
      java_version:
        required: false
        type: string
        default: '17'
      flutter_channel:
        required: false
        type: string
        default: 'stable'
      flutter_version:
        required: false
        type: string
        default: ''
      use_build_runner:
        required: false
        type: boolean
        default: true
      build_apk:
        required: false
        type: boolean
        default: true
      build_aab:
        required: false
        type: boolean
        default: false
      flavor:
        description: 'Flutter flavor (empty = no --flavor flag)'
        required: false
        type: string
        default: ''
      prerelease:
        description: 'When true, mark the GitHub Release as prerelease after upload'
        required: false
        type: boolean
        default: false
      dart_define_secret_names:
        description: 'Comma-separated list of secret names to forward as --dart-define=NAME=$VALUE'
        required: false
        type: string
        default: ''
      artefact_name_prefix:
        description: 'Prefix for the renamed artefact. Empty = ${{ github.event.repository.name }}'
        required: false
        type: string
        default: ''
    secrets:
      ANDROID_KEYSTORE_BASE64:
        required: true
      ANDROID_STORE_PASSWORD:
        required: true
      ANDROID_KEY_ALIAS:
        required: true
      ANDROID_KEY_PASSWORD:
        required: true

permissions:
  contents: write     # to attach assets + edit release flags

concurrency:
  group: release-flutter-android-${{ github.workflow }}-${{ inputs.version }}
  cancel-in-progress: false

jobs:
  build:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Checkout caller
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Setup Flutter toolchain
        uses: ./.catalog/actions/setup-flutter-toolchain
        with:
          java-version: ${{ inputs.java_version }}
          flutter-channel: ${{ inputs.flutter_channel }}
          flutter-version: ${{ inputs.flutter_version }}
          use-build-runner: ${{ inputs.use_build_runner }}
          working-directory: ${{ inputs.working_directory }}

      - name: Resolve version + sync pubspec.yaml
        id: ver
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          INPUT_VERSION: ${{ inputs.version }}
        run: |
          set -euo pipefail
          V="${INPUT_VERSION#v}"
          if [[ ! "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "::error::version input does not look like semver: $INPUT_VERSION"
            exit 1
          fi
          # Flutter's pubspec syntax: <semver>+<build>. Use run_number as build.
          sed -i -E "s/^version: .*/version: ${V}+${GITHUB_RUN_NUMBER}/" pubspec.yaml
          echo "bare=$V" >> "$GITHUB_OUTPUT"
          echo "tag=v$V" >> "$GITHUB_OUTPUT"

      - name: Decode keystore
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          KS: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
        run: |
          set -euo pipefail
          mkdir -p android
          echo "$KS" | base64 -d > android/release.keystore
          test -s android/release.keystore

      - name: Build dart-define flags
        id: dd
        shell: bash
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
          # printf %q would help re-quote, but flags are not echoed; we pass via env to next steps.
          printf '%s\n' "${flags[*]}" > /tmp/dart-define-flags
          echo "count=${#flags[@]}" >> "$GITHUB_OUTPUT"

      - name: Build APK
        if: ${{ inputs.build_apk }}
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          ANDROID_KEYSTORE_PATH: release.keystore
          ANDROID_STORE_PASSWORD: ${{ secrets.ANDROID_STORE_PASSWORD }}
          ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
          FLAVOR: ${{ inputs.flavor }}
        run: |
          set -euo pipefail
          DD=$(cat /tmp/dart-define-flags || true)
          flavor_arg=""
          [[ -n "$FLAVOR" ]] && flavor_arg="--flavor=$FLAVOR"
          # shellcheck disable=SC2086  # DD is intentionally word-split
          flutter build apk --release \
            --build-number="$GITHUB_RUN_NUMBER" \
            $flavor_arg $DD

      - name: Build AAB
        if: ${{ inputs.build_aab }}
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          ANDROID_KEYSTORE_PATH: release.keystore
          ANDROID_STORE_PASSWORD: ${{ secrets.ANDROID_STORE_PASSWORD }}
          ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
          FLAVOR: ${{ inputs.flavor }}
        run: |
          set -euo pipefail
          DD=$(cat /tmp/dart-define-flags || true)
          flavor_arg=""
          [[ -n "$FLAVOR" ]] && flavor_arg="--flavor=$FLAVOR"
          # shellcheck disable=SC2086
          flutter build appbundle --release \
            --build-number="$GITHUB_RUN_NUMBER" \
            $flavor_arg $DD

      - name: Rename + collect artefacts
        id: artefacts
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          PREFIX: ${{ inputs.artefact_name_prefix }}
          VERSION_TAG: ${{ steps.ver.outputs.tag }}
        run: |
          set -euo pipefail
          name_prefix="${PREFIX:-${{ github.event.repository.name }}}"
          paths=()
          if [[ -f build/app/outputs/flutter-apk/app-release.apk ]]; then
            target="${name_prefix}-${VERSION_TAG}.apk"
            mv build/app/outputs/flutter-apk/app-release.apk "$target"
            paths+=("$target")
          fi
          if [[ -f build/app/outputs/bundle/release/app-release.aab ]]; then
            target="${name_prefix}-${VERSION_TAG}.aab"
            mv build/app/outputs/bundle/release/app-release.aab "$target"
            paths+=("$target")
          fi
          if [[ ${#paths[@]} -eq 0 ]]; then
            echo "::error::neither APK nor AAB produced — check build_apk / build_aab inputs"
            exit 1
          fi
          # GitHub env can't store newline-separated arrays cleanly; pass as space-joined.
          printf '%s\n' "files=${paths[*]}" >> "$GITHUB_OUTPUT"

      - name: Attach to release
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ steps.ver.outputs.tag }}
          FILES: ${{ steps.artefacts.outputs.files }}
          PRE: ${{ inputs.prerelease }}
        run: |
          set -euo pipefail
          # shellcheck disable=SC2086
          gh release upload "$TAG" $FILES --clobber
          if [[ "$PRE" == "true" ]]; then
            gh release edit "$TAG" --prerelease
          fi

      - name: Step summary
        if: always()
        shell: bash
        working-directory: ${{ inputs.working_directory }}
        env:
          FILES: ${{ steps.artefacts.outputs.files }}
          TAG: ${{ steps.ver.outputs.tag }}
        run: |
          {
            echo "## release-flutter-android"
            echo ""
            echo "**Tool:** flutter build apk/appbundle + gh release upload"
            echo "**Result:** ${{ job.status }}"
            echo ""
            if [[ -n "${FILES:-}" ]]; then
              echo "| Artefact | Size |"
              echo "|---|---|"
              for f in $FILES; do
                if [[ -f "$f" ]]; then
                  size=$(wc -c < "$f" | tr -d ' ')
                  echo "| \`$f\` | $((size / 1024 / 1024)) MiB |"
                fi
              done
              echo ""
              echo "Attached to release [\`$TAG\`](https://github.com/${{ github.repository }}/releases/tag/$TAG)."
            fi
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/release-flutter-android.yml
```

Expected: clean. Shellcheck inside actionlint may flag `SC2086` on the intentional `$DD` word-split — the inline `disable=SC2086` comment suppresses it.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-flutter-android.yml
git commit -m "feat(flutter): add release-flutter-android atom"
```

---

## Task 10: Caller — `caller-flutter-release-happy.yml` + repo secrets + integration wire-up

**Files:**
- Create: `.github/workflows/caller-flutter-release-happy.yml`
- Modify: `.github/workflows/integration.yml`
- Modify: Catalog repo secrets (set via `gh secret set`)

- [ ] **Step 1: Set up the four fixture secrets at the catalog repo level**

These secrets exist ONLY in the catalog repo and point at the throwaway fixture keystore generated in Task 3 Step 2.

```bash
# ANDROID_KEYSTORE_BASE64 — content of the b64'd fixture keystore
cat tests/fixtures/flutter-app/android/release.keystore.b64 | \
  gh secret set ANDROID_KEYSTORE_BASE64 --repo serverkraken/reusable-workflows

# Must match the values used in `keytool -genkeypair` in Task 3 Step 2.
gh secret set ANDROID_STORE_PASSWORD --body 'catalog-fixture-storepw' --repo serverkraken/reusable-workflows
gh secret set ANDROID_KEY_PASSWORD   --body 'catalog-fixture-keypw'   --repo serverkraken/reusable-workflows
gh secret set ANDROID_KEY_ALIAS      --body 'catalogtest'             --repo serverkraken/reusable-workflows
```

Also set the dart-define probe secret:

```bash
gh secret set DART_DEFINE_GREETING --body 'hello-from-catalog-CI' --repo serverkraken/reusable-workflows
```

The caller will reference this secret by the conventional dart-define name `GREETING`. Wait — naming alignment matters: the caller passes `dart_define_secret_names: "GREETING"`, so the SECRET name MUST be `GREETING`, not `DART_DEFINE_GREETING`. Adjust:

```bash
gh secret set GREETING --body 'hello-from-catalog-CI' --repo serverkraken/reusable-workflows
```

- [ ] **Step 2: Write the caller**

```yaml
name: caller-flutter-release-happy

on:
  pull_request:
    paths:
      - '.github/workflows/release-flutter-android.yml'
      - '.github/workflows/caller-flutter-release-happy.yml'
      - 'actions/setup-flutter-toolchain/**'
      - 'tests/fixtures/flutter-app/**'

permissions:
  contents: write     # caller-side mints the release for the test then deletes it

jobs:
  # Mint a throwaway release at tag v0.0.1-fixture so the atom's `gh release upload`
  # has a target. The atom does not create releases; release-please does that in adopter repos.
  prepare-release:
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.tag.outputs.name }}
    steps:
      - name: Compute fixture tag
        id: tag
        run: echo "name=v0.0.1-fixture-${{ github.run_id }}" >> "$GITHUB_OUTPUT"
      - name: Create release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${{ steps.tag.outputs.name }}" \
            --repo "${{ github.repository }}" \
            --title "Fixture release (PR ${{ github.event.pull_request.number }})" \
            --notes "Throwaway release created by caller-flutter-release-happy. Auto-deleted after the run." \
            --prerelease \
            --target "${{ github.event.pull_request.head.sha }}"

  release:
    needs: prepare-release
    uses: ./.github/workflows/release-flutter-android.yml
    with:
      working_directory: tests/fixtures/flutter-app
      version: ${{ needs.prepare-release.outputs.tag }}
      use_build_runner: false
      build_apk: true
      build_aab: false
      flavor: ''
      prerelease: true
      dart_define_secret_names: "GREETING"
      artefact_name_prefix: catalog-test-flutter-app
    secrets: inherit

  cleanup-release:
    needs: [prepare-release, release]
    if: always()
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Delete fixture release
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ needs.prepare-release.outputs.tag }}
        run: |
          gh release delete "$TAG" --repo "${{ github.repository }}" --yes --cleanup-tag || true
```

- [ ] **Step 3: Verify the prepare → release → cleanup flow concept**

Read the caller end-to-end against the atom's `Attach to release` step. Confirm:
- `prepare-release` creates a release at `v0.0.1-fixture-<run-id>` on the PR head SHA.
- The atom's `gh release upload "$TAG"` will find it.
- `cleanup-release` removes it with `--cleanup-tag` so PR retries don't leave stale tags.

If the catalog's branch-protection prevents creating tags from PR-triggered workflows, this caller will fail at `prepare-release`. In that case, switch the caller to `workflow_dispatch` only and add a separate `assert-release-flutter-fixture` job that runs `gh release view` to confirm. For now, write the PR-triggered version above and surface the issue if it fails at the integration step.

- [ ] **Step 4: Add to integration.yml summary needs**

Append `caller-flutter-release-happy` to `summary.needs`. Same procedure as Tasks 6/8.

- [ ] **Step 5: actionlint**

```bash
actionlint .github/workflows/caller-flutter-release-happy.yml \
           .github/workflows/integration.yml
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/caller-flutter-release-happy.yml \
        .github/workflows/integration.yml
git commit -m "test(flutter): add caller-flutter-release-happy + fixture-release lifecycle"
```

---

## Task 11: docs/operations.md — Flutter atoms section

**Files:**
- Modify: `docs/operations.md`

- [ ] **Step 1: Locate the right insertion point**

```bash
rg -n "^## [0-9]" docs/operations.md | tail -10
```

Pick the next-available numbered section. Add the Flutter atoms section there.

- [ ] **Step 2: Write the section**

```markdown
## N. Flutter Atom Set (v4.x+)

The catalog ships three Flutter `workflow_call` atoms plus a shared composite action:

| Reusable workflow | Purpose |
|---|---|
| `lint-flutter.yml`            | `dart format --set-exit-if-changed` + `flutter analyze` |
| `test-flutter.yml`            | `flutter test --coverage` + LCOV threshold gate (default 80) |
| `release-flutter-android.yml` | pubspec-version sync → APK and/or AAB build → sign → attach to existing release |

The shared toolchain (Java + Android SDK + Flutter + `pub get` + optional `build_runner`) lives in `actions/setup-flutter-toolchain/action.yml` — a composite action consumed by all three atoms.

### N.1 Adopter integration (current)

Until the onboard renderer learns to detect Flutter components, adopters wire the atoms manually. Reference template:

```yaml
jobs:
  release-please:
    uses: serverkraken/reusable-workflows/.github/workflows/semantic-release.yml@v4
    secrets: inherit

  release-android:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@v4
    with:
      version: ${{ needs.release-please.outputs.tag_name }}
      dart_define_secret_names: "SUPABASE_URL,SUPABASE_ANON_KEY"
      prerelease: true
    secrets: inherit
```

The adopter sets the four `ANDROID_KEYSTORE_BASE64` / `ANDROID_STORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` secrets at the org or repo level (org-level + `secrets: inherit` is the convention).

### N.2 Out of scope (Phase-2)

- iOS build.
- Play-Store upload — atom will gain an `upload_to_play_store` input plus a `play_store_track` input; the renderer will gain a topic-detection branch.
- pubspec.yaml commit-back — adopters who want the bump committed configure release-please's `extra-files`.
```

Replace `N` with the actual next section number.

- [ ] **Step 3: Yamllint sanity (no, but for markdown verify)**

```bash
# Verify no broken markdown
rg -n "^## [0-9]+\." docs/operations.md | tail -5
```

Expected: monotonically numbered.

- [ ] **Step 4: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): add Flutter atom set section"
```

---

## Task 12: Self-review + PR open

- [ ] **Step 1: Re-read every commit on the branch**

```bash
git log --oneline main..HEAD
```

Expected: roughly 10 commits, one per task. Each commit message should follow conventional-commits + match its diff scope.

- [ ] **Step 2: Run the full local validation set**

```bash
actionlint .github/workflows/*.yml
yamllint -s .github/ tests/fixtures/flutter-app/ 2>&1 | head -20
```

Expected: zero errors.

- [ ] **Step 3: Verify step-summary lint passes**

```bash
bash tests/conventions/check-step-summary.sh 2>&1 | tail -10
```

Expected: each new atom emits `## <atom-name>` + `**Tool:**` + `**Result:**`. Caller-*.yml files are skipped by the convention check (memory `v421-train-done-2026-05-27` — bug 8 in PR #141).

- [ ] **Step 4: Push branch and open PR**

```bash
git push -u origin feat/flutter-atoms
gh pr create --title "feat(flutter): add lint+test+release-android atoms + setup composite" --body "$(cat <<'EOF'
## Summary

Implements `docs/superpowers/specs/2026-05-27-flutter-atoms-design.md`. Closes the Flutter gap recorded in memory `project_phase8_atom_gaps`, enabling `serverkraken/strassenfuchs` adoption on v4.

## Deliverables

- `actions/setup-flutter-toolchain` composite — Java + Android SDK + Flutter + pub get + opt build_runner.
- `lint-flutter.yml` — dart format check + analyze.
- `test-flutter.yml` — flutter test --coverage + threshold gate (default 80%).
- `release-flutter-android.yml` — pubspec sync + APK/AAB build + sign + attach to existing release.
- Three caller-flutter-*-happy.yml self-CI wrappers wired into `integration.yml`'s summary.
- `tests/fixtures/flutter-app/` — committed Flutter project + throwaway keystore.
- Repo secrets: ANDROID_* (fixture keystore) + GREETING (dart-define probe).

## Out of scope (Phase-2)

iOS, Play-Store upload, onboard renderer extension for Flutter components.

## Test plan

- [x] actionlint clean across all new workflows
- [x] yamllint clean
- [x] step-summary lint clean
- [ ] CI green on this PR (integration / summary turns green when all three caller-flutter-* run pass)
- [ ] After merge: strassenfuchs writes its release.yml referencing @v4 atoms and ships a binary release end-to-end
EOF
)"
```

- [ ] **Step 5: Wait for CI on the PR**

The three caller-flutter-*-happy.yml workflows trigger on `pull_request: paths:` matches; the changes in this PR touch all the listed paths so all three should run. Monitor:

```bash
PR=$(gh pr view --json number --jq .number)
until [ "$(gh pr checks $PR --json state --jq '.state' 2>/dev/null)" = "PASS" ]; do
  sleep 60
  gh pr checks $PR | rg -i "flutter|summary" | head -5
done
```

If any caller-flutter-* fails, drill into the run logs and fix. The most likely failure modes:
1. Fixture's android scaffolding incomplete → `flutter build apk` errors. Fix: regenerate via `flutter create` (Task 3 Step 1) and recommit.
2. Keystore alias/password mismatch → `apksigner` complains. Fix: re-do Task 3 Step 2 with matching values to Task 10 Step 1 secrets.
3. `dart_define_secret_names: "GREETING"` not resolved → fixture build still succeeds (GREETING has a default), but the value reaching the widget is `hello` not `hello-from-catalog-CI`. Not a hard failure unless we add an assert step. Acceptable for happy-path coverage.

- [ ] **Step 6: Add the new troubleshooting/reference memory entries (after PR merges)**

Two memory entries:

```
memory/troubleshooting_flutter_keystore_fixture.md
  — note that the fixture keystore is a real-looking but throwaway test artefact;
    do NOT recycle into production; flag where alias/password live.

memory/reference_phase8_flutter_atoms_done.md
  — DONE marker analogous to v421-train-done-2026-05-27; records the
    three atoms + composite + fixture, and points at the Phase-2 backlog
    (iOS, Play-Store, renderer extension).
```

Update `memory/MEMORY.md` index lines accordingly. Mark `project_phase8_atom_gaps.md` partially-complete (Flutter done, .NET still open).

- [ ] **Step 7: Tell the user**

Surface PR URL plus the strassenfuchs-side follow-up: strassenfuchs needs its own `release.yml` written + the four ANDROID_* secrets set at org or repo level. The atom is ready; the adopter wiring is a separate (smaller) PR in strassenfuchs.

---

## Self-Review

**Spec coverage:** All seven sections of the spec map to tasks above:
- Composite action → Task 4
- lint-flutter → Tasks 5, 6
- test-flutter → Tasks 7, 8
- release-flutter-android → Tasks 9, 10
- Fixture → Tasks 2, 3
- Adopter integration doc → Task 11
- Out-of-scope notes → Task 11 doc section + spec is the canonical source

**Placeholder check:** Section numbers in Task 11 carry an `N` placeholder by design — there is no way to predict the next section number without inspecting `main` at execution time. The Step instructs the agent to compute it. All other "TODO"/"TBD"/"<X>" patterns are SHA placeholders that the agent resolves in Task 1 Step 3 and Task 4 Step 1.

**Type consistency:** Inputs across the three atoms reuse identical names (`runs_on`, `working_directory`, `java_version`, `flutter_channel`, `flutter_version`, `use_build_runner`). The composite-action input names use kebab-case (`java-version`, `working-directory`) per GitHub Actions composite convention; the workflow_call inputs use snake_case per existing catalog convention. The atom-to-composite wiring spells out the mapping at every call site.

**Scope check:** Plan is one PR, ~10 commits, ~12 files. Independently mergeable as a coherent feature. No subsystem requires its own plan.
