# Flutter Onboard-Renderer Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the onboard renderer to detect Flutter repos and render `ci.yml` (lint-flutter + test-flutter) and `release.yml` (release-flutter-android), closing the sweep-churn risk where Flutter repos render as generic secscan-only.

**Architecture:** Extend the two existing extension points — `primary_language` drives lint/test in `ci.yml.tmpl`; `release_signals` drives release jobs in `release.yml.tmpl`. Detection adds `flutter` as a `primary_language`, maps `release_please_type` to `dart`, and adds a `release_signals.flutter_android` boolean (true only when a Flutter app has an `android/` dir, which separates apps from pure-Dart packages).

**Tech Stack:** Bash (detection + render scripts), gomplate Go templates (skeletons), bats (tests), jq, actionlint + yamllint (integration validation).

**Spec:** `docs/superpowers/specs/2026-05-29-flutter-renderer-detection-design.md`

---

## Setup (execution-time, before Task 1)

Create the isolated worktree via the `superpowers:using-git-worktrees` skill:
- Branch: `feat/flutter-renderer-detection`
- Path: `.worktrees/flutter-renderer-detection/`
- Base: `origin/main` (currently `d95e6cd`, release 4.5.0)

All file paths below are relative to that worktree root. Run all `bats` / `git` commands from the worktree root.

## File Structure

- **Modify** `scripts/lib/onboard-detect-lib.sh` — add `_component_is_flutter` helper; flutter in `detect_languages`; `flutter→dart` in the `release_please_type` case; `flutter` in `SUPPORTED_LINT_TEST_LANGUAGES`; `flutter_android` in `detect_release_signals`; `mobile-app` in `detect_role`.
- **Modify** `scripts/onboard-detect.sh` — flutter marker in the `--emit-both` block and the legacy key=value block.
- **Modify** `actions/onboard-detect/action.yml` — add `flutter` to the `language_override` description (doc only).
- **Modify** `docs/adopter-templates/skeletons/ci.yml.tmpl` — flutter branch.
- **Modify** `docs/adopter-templates/skeletons/release.yml.tmpl` — flutter_android branch.
- **Modify** `docs/operations.md` — `SK_FLUTTER_DART_DEFINE_SECRETS` row in the override table.
- **Create** `tests/fixtures/onboard/flutter-app/{pubspec.yaml,android/.gitkeep}` — Flutter app fixture (has `android/`).
- **Create** `tests/fixtures/onboard/flutter-package/pubspec.yaml` — Flutter package fixture (no `android/`).
- **Create** `tests/shell/golden/ci/single-flutter.yml` — golden CI render.
- **Modify** `tests/shell/onboard-detect.bats` — Flutter detection tests.
- **Modify** `tests/shell/onboard-render.bats` — Flutter render tests + integration lint test.

---

## Task 1: Flutter onboard fixtures

Test data only (no test runner step). The detection tests in later tasks consume these.

**Files:**
- Create: `tests/fixtures/onboard/flutter-app/pubspec.yaml`
- Create: `tests/fixtures/onboard/flutter-app/android/.gitkeep`
- Create: `tests/fixtures/onboard/flutter-package/pubspec.yaml`

- [ ] **Step 1: Create the Flutter app fixture pubspec**

`tests/fixtures/onboard/flutter-app/pubspec.yaml`:

```yaml
name: catalog_test_flutter_app
description: "Onboard-detect fixture: Flutter app (has android/ → flutter_android=true)."
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

flutter:
  uses-material-design: true
```

- [ ] **Step 2: Create the `android/` dir marker**

`tests/fixtures/onboard/flutter-app/android/.gitkeep` — empty file (git does not track empty dirs; this keeps `android/` present so `[[ -d android ]]` is true).

```
```

- [ ] **Step 3: Create the Flutter package fixture pubspec** (no `android/` dir)

`tests/fixtures/onboard/flutter-package/pubspec.yaml`:

```yaml
name: catalog_test_flutter_package
description: "Onboard-detect fixture: Flutter package (no android/ → flutter_android=false)."
publish_to: 'none'
version: 0.0.0

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
```

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/onboard/flutter-app tests/fixtures/onboard/flutter-package
git commit -m "test(onboard): add flutter-app and flutter-package detect fixtures"
```

---

## Task 2: Detect `flutter` language (lib + legacy paths)

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (add helper + `detect_languages`)
- Modify: `scripts/onboard-detect.sh` (`--emit-both` + legacy marker lists)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write failing tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
# === Flutter detection ===

@test "detects flutter from pubspec sdk: flutter (legacy key=value)" {
  run "$DETECT" "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=flutter"* ]]
}

@test "profile-json: flutter-app primary_language=flutter" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "flutter"'
  echo "$output" | jq -e '.components[0].languages == ["flutter"]'
}

@test "profile-json: flutter-package is still detected as flutter" {
  run "$DETECT" --profile-json "$FIX/flutter-package"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].primary_language == "flutter"'
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/shell/onboard-detect.bats -f flutter`
Expected: FAIL — flutter-app currently detects as `simple`/`generic`.

- [ ] **Step 3: Add the `_component_is_flutter` helper**

In `scripts/lib/onboard-detect-lib.sh`, immediately after the `SUPPORTED_LINT_TEST_LANGUAGES='...'` line (~line 28), insert:

```bash

# Flutter detection helper. Arg: absolute component directory.
# True when pubspec.yaml exists AND declares the Flutter SDK dependency
# (`sdk: flutter`) — every Flutter app/package has it; a pure-Dart package
# does not.
_component_is_flutter() {
  local dir="$1"
  [[ -f "$dir/pubspec.yaml" ]] && grep -qE 'sdk:[[:space:]]*flutter' "$dir/pubspec.yaml"
}
```

- [ ] **Step 4: Add flutter to `detect_languages`**

In `detect_languages`, the marker list reads (after the Chart.yaml line):

```bash
  [[ -f "$p/Chart.yaml" ]]     && langs+=(helm)
  [[ -f "$p/package.json" ]]   && langs+=(node)
```

Insert the flutter probe **before** node so a Flutter+node repo classifies as flutter:

```bash
  [[ -f "$p/Chart.yaml" ]]     && langs+=(helm)
  _component_is_flutter "$p"   && langs+=(flutter)
  [[ -f "$p/package.json" ]]   && langs+=(node)
```

- [ ] **Step 5: Add flutter to `scripts/onboard-detect.sh` `--emit-both` block**

The `--emit-both` block sources the lib (so the helper is available). Its marker list reads:

```bash
    [[ -f "$REPO_PATH/Chart.yaml" ]]     && matches+=(helm)
    [[ -f "$REPO_PATH/package.json" ]]   && matches+=(node)
```

Change to:

```bash
    [[ -f "$REPO_PATH/Chart.yaml" ]]     && matches+=(helm)
    _component_is_flutter "$REPO_PATH"   && matches+=(flutter)
    [[ -f "$REPO_PATH/package.json" ]]   && matches+=(node)
```

- [ ] **Step 6: Add flutter to the legacy key=value block**

The legacy block (bottom of `scripts/onboard-detect.sh`) does **not** source the lib, so inline the probe. Its marker list reads:

```bash
  [[ -f "$REPO_PATH/Chart.yaml" ]]     && matches+=(helm)
  [[ -f "$REPO_PATH/package.json" ]]   && matches+=(node)
```

Change to:

```bash
  [[ -f "$REPO_PATH/Chart.yaml" ]]     && matches+=(helm)
  { [[ -f "$REPO_PATH/pubspec.yaml" ]] && grep -qE 'sdk:[[:space:]]*flutter' "$REPO_PATH/pubspec.yaml"; } && matches+=(flutter)
  [[ -f "$REPO_PATH/package.json" ]]   && matches+=(node)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bats tests/shell/onboard-detect.bats -f flutter`
Expected: PASS (3 tests).

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh scripts/onboard-detect.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): detect Flutter from pubspec sdk: flutter"
```

---

## Task 3: Map `release_please_type` flutter → dart

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (`detect_components` release_type case)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write failing test**

Append to `tests/shell/onboard-detect.bats`:

```bash
@test "profile-json: flutter-app release_please_type=dart" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_please_type == "dart"'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/shell/onboard-detect.bats -f "release_please_type=dart"`
Expected: FAIL — currently `release_please_type` passes `flutter` through unchanged.

- [ ] **Step 3: Add the dart mapping**

In `detect_components`, the case statement reads:

```bash
    case "$primary" in
      generic) release_type="simple" ;;
      *)       release_type="$primary" ;;
    esac
```

Change to:

```bash
    case "$primary" in
      generic) release_type="simple" ;;
      flutter) release_type="dart" ;;
      *)       release_type="$primary" ;;
    esac
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/shell/onboard-detect.bats -f "release_please_type=dart"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): map Flutter release-please type to dart"
```

---

## Task 4: Add `flutter` to supported lint/test languages

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (`SUPPORTED_LINT_TEST_LANGUAGES`)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write failing test**

Append to `tests/shell/onboard-detect.bats`:

```bash
@test "profile-json: flutter emits no no_lint_test_atom warning" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.warnings[] | select(.code == "no_lint_test_atom")] | length == 0'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/shell/onboard-detect.bats -f "no no_lint_test_atom"`
Expected: FAIL — flutter is not yet in the supported set, so a warning is emitted.

- [ ] **Step 3: Add flutter to the supported list**

In `scripts/lib/onboard-detect-lib.sh`, change:

```bash
SUPPORTED_LINT_TEST_LANGUAGES='go|python|rust|helm'
```

to:

```bash
SUPPORTED_LINT_TEST_LANGUAGES='go|python|rust|helm|flutter'
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/shell/onboard-detect.bats -f "no no_lint_test_atom"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): treat flutter as a supported lint/test language"
```

---

## Task 5: `flutter_android` release signal + `mobile-app` role

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (`detect_release_signals`, `detect_role`)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write failing tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
@test "profile-json: flutter-app has flutter_android=true and role=mobile-app" {
  run "$DETECT" --profile-json "$FIX/flutter-app"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_signals.flutter_android == true'
  echo "$output" | jq -e '.components[0].role == "mobile-app"'
}

@test "profile-json: flutter-package has flutter_android=false and role=library" {
  run "$DETECT" --profile-json "$FIX/flutter-package"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_signals.flutter_android == false'
  echo "$output" | jq -e '.components[0].role == "library"'
}

@test "profile-json: go-repo release_signals gains flutter_android=false (additive)" {
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.components[0].release_signals.flutter_android == false'
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/shell/onboard-detect.bats -f flutter_android`
Expected: FAIL — `release_signals` has no `flutter_android` key yet (jq comparison to `false` fails on null), role is `library` for flutter-app.

- [ ] **Step 3: Add `flutter_android` to `detect_release_signals`**

In `detect_release_signals`, the function ends with:

```bash
  jq -nc \
    --argjson goreleaser_config "$gorel" \
    --argjson chart_yaml "$chart" \
    '{goreleaser_config: $goreleaser_config, chart_yaml: $chart_yaml}'
}
```

Replace those lines with (note `$p` is already defined at the top of the function as `local p="$repo/$path"`):

```bash
  # Flutter Android release signal: a Flutter component (pubspec declares the
  # flutter SDK) that also has an android/ dir is an Android app and gets a
  # release-flutter-android job. A Flutter *package* (no android/) is linted
  # and tested but not released here.
  local flutter_android=false
  if _component_is_flutter "$p" && [[ -d "$p/android" ]]; then
    flutter_android=true
  fi

  jq -nc \
    --argjson goreleaser_config "$gorel" \
    --argjson chart_yaml "$chart" \
    --argjson flutter_android "$flutter_android" \
    '{goreleaser_config: $goreleaser_config, chart_yaml: $chart_yaml, flutter_android: $flutter_android}'
}
```

- [ ] **Step 4: Add `mobile-app` to `detect_role`**

In `detect_role`, the function ends with:

```bash
  if [[ -f "$p/Chart.yaml" ]]; then
    echo "helm-app"; return
  fi

  echo "library"
}
```

Insert a Flutter check before the `library` default:

```bash
  if [[ -f "$p/Chart.yaml" ]]; then
    echo "helm-app"; return
  fi

  if _component_is_flutter "$p" && [[ -d "$p/android" ]]; then
    echo "mobile-app"; return
  fi

  echo "library"
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `bats tests/shell/onboard-detect.bats -f flutter_android`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): add flutter_android release signal and mobile-app role"
```

---

## Task 6: Render Flutter `ci.yml` (lint-flutter + test-flutter)

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl`
- Create: `tests/shell/golden/ci/single-flutter.yml`
- Test: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Write the golden file** (the expected render output)

`tests/shell/golden/ci/single-flutter.yml`:

```yaml
name: ci
on:
  pull_request:

jobs:
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@v4
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      severity: ${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}
      trivy_version: ${{ vars.SK_TRIVY_VERSION || '' }}
    secrets: inherit

  lint-flutter-root:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-flutter.yml@v4
    with:
      working_directory: .
    secrets: inherit
  test-flutter-root:
    uses: serverkraken/reusable-workflows/.github/workflows/test-flutter.yml@v4
    with:
      working_directory: .
      coverage_threshold: ${{ fromJSON(vars.SK_COVERAGE_THRESHOLD || '80') }}
    secrets: inherit
```

- [ ] **Step 2: Write failing tests**

Append to `tests/shell/onboard-render.bats`:

```bash
# === Flutter ci.yml ===

@test "ci.yml renders lint+test jobs for a single flutter component" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }')
  diff -u "$BATS_TEST_DIRNAME/golden/ci/single-flutter.yml" "$rendered"
}

@test "ci.yml flutter test job carries the coverage SK_ override" {
  rendered=$(render_ci_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "lint-flutter.yml@v4" "$rendered"
  grep -qF "test-flutter.yml@v4" "$rendered"
  grep -qF "coverage_threshold: \${{ fromJSON(vars.SK_COVERAGE_THRESHOLD || '80') }}" "$rendered"
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `bats tests/shell/onboard-render.bats -f "flutter"`
Expected: FAIL — `ci.yml.tmpl` has no flutter branch, so the flutter component emits nothing (only secscan), diff fails.

- [ ] **Step 4: Add the flutter branch to `ci.yml.tmpl`**

The `primary_language` if-chain ends with the helm branch followed by `{{- end }}`:

```gotemplate
{{- else if eq $c.primary_language "helm" }}
  lint-helm-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-helm.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
{{- end }}
{{- end }}
```

Insert a flutter `else if` between the helm branch and the first `{{- end }}`:

```gotemplate
{{- else if eq $c.primary_language "helm" }}
  lint-helm-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-helm.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
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
{{- end }}
{{- end }}
```

- [ ] **Step 5: Run to verify they pass**

Run: `bats tests/shell/onboard-render.bats -f "flutter"`
Expected: PASS (the two new ci tests; release tests added in Task 7).

- [ ] **Step 6: Commit**

```bash
git add docs/adopter-templates/skeletons/ci.yml.tmpl tests/shell/golden/ci/single-flutter.yml tests/shell/onboard-render.bats
git commit -m "feat(onboard): render lint-flutter + test-flutter in ci.yml"
```

---

## Task 7: Render Flutter `release.yml` (release-flutter-android)

**Files:**
- Modify: `docs/adopter-templates/skeletons/release.yml.tmpl`
- Test: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Write failing tests**

Append to `tests/shell/onboard-render.bats`:

```bash
# === Flutter release.yml ===

@test "release.yml renders release-flutter-android when flutter_android=true" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "release-flutter-android.yml@v4" "$rendered"
  grep -qF "version: \${{ needs.release-please.outputs.tag_name }}" "$rendered"
  grep -qF "dart_define_secret_names: \${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}" "$rendered"
}

@test "release.yml omits release-flutter-android when flutter_android=false" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/pkg",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "library", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "warnings": []
  }')
  ! grep -q "release-flutter-android" "$rendered"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/shell/onboard-render.bats -f "release-flutter-android"`
Expected: FAIL — the first test fails (no release-flutter-android emitted yet); the second already passes (nothing emitted) but both must be present for the suite.

- [ ] **Step 3: Add the flutter_android branch to `release.yml.tmpl`**

The per-component body ends with the chart_yaml block followed by `{{ end }}` (the range close):

```gotemplate
{{- if $c.release_signals.chart_yaml }}
  helm-publish{{ $suffix }}:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/helm-publish.yml@{{ $pin }}
    with:
      chart_path: {{ path.Dir $c.release_signals.chart_yaml }}
      oci_registry: ghcr.io/{{ $.profile.target_repo }}/charts
    secrets: inherit
{{- end }}
{{ end }}
```

Insert a flutter_android block between the chart_yaml `{{- end }}` and the range-closing `{{ end }}`:

```gotemplate
{{- if $c.release_signals.chart_yaml }}
  helm-publish{{ $suffix }}:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/helm-publish.yml@{{ $pin }}
    with:
      chart_path: {{ path.Dir $c.release_signals.chart_yaml }}
      oci_registry: ghcr.io/{{ $.profile.target_repo }}/charts
    secrets: inherit
{{- end }}

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
{{ end }}
```

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/shell/onboard-render.bats -f "release-flutter-android"`
Expected: PASS (2 tests).

- [ ] **Step 5: Verify no regression in existing release tests**

Run: `bats tests/shell/onboard-render.bats`
Expected: PASS (all, including the existing go/python/rust/helm/docker release tests — flutter_android is absent from their inline profiles, which gomplate treats as falsey).

- [ ] **Step 6: Commit**

```bash
git add docs/adopter-templates/skeletons/release.yml.tmpl tests/shell/onboard-render.bats
git commit -m "feat(onboard): render release-flutter-android in release.yml"
```

---

## Task 8: Verify release-please-config renders `release-type: dart`

No template change — `release-please-config.json.tmpl` already reads `release_please_type`. This task locks the end-to-end behavior with a test.

**Files:**
- Test: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Write the test**

Append to `tests/shell/onboard-render.bats`:

```bash
@test "release-please-config renders release-type dart for flutter" {
  local target="$BATS_TEST_TMPDIR/rp-flutter-$$"
  mkdir -p "$target"
  printf '%s' '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "warnings": []
  }' > "$target/_profile.json"
  "$RENDER" "$REPO_ROOT" "$target" "$target/_profile.json" "v4" >&2
  jq -e '.packages["."]["release-type"] == "dart"' "$target/release-please-config.json"
}
```

- [ ] **Step 2: Run to verify it passes** (mapping already flows through Task 3)

Run: `bats tests/shell/onboard-render.bats -f "release-type dart"`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/shell/onboard-render.bats
git commit -m "test(onboard): lock release-please-config dart type for flutter"
```

---

## Task 9: Document `flutter` in the onboard-detect action

**Files:**
- Modify: `actions/onboard-detect/action.yml`

- [ ] **Step 1: Update the `language_override` description**

Change:

```yaml
  language_override:
    description: 'auto | go | python | rust | helm | node | simple (auto = file-signal detection)'
```

to:

```yaml
  language_override:
    description: 'auto | go | python | rust | helm | flutter | node | simple (auto = file-signal detection)'
```

- [ ] **Step 2: Commit**

```bash
git add actions/onboard-detect/action.yml
git commit -m "docs(onboard): list flutter in language_override options"
```

---

## Task 10: Integration — render fixture + actionlint + yamllint

**Files:**
- Test: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Write the integration test** (guarded; skips if tools absent)

Append to `tests/shell/onboard-render.bats`:

```bash
@test "integration: rendered flutter-app ci.yml + release.yml pass actionlint and yamllint" {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint not installed"
  command -v yamllint  >/dev/null 2>&1 || skip "yamllint not installed"
  seed_profile "flutter-app"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4" >&2
  yamllint -d relaxed "$TARGET/.github/workflows/ci.yml" "$TARGET/.github/workflows/release.yml"
  actionlint "$TARGET/.github/workflows/ci.yml" "$TARGET/.github/workflows/release.yml"
}
```

- [ ] **Step 2: Run the test**

Run: `bats tests/shell/onboard-render.bats -f "integration: rendered flutter-app"`
Expected: PASS (or SKIP if actionlint/yamllint not installed locally — it runs in self-CI where both are present).

- [ ] **Step 3: If tools are installed locally, confirm a real PASS**

Run: `command -v actionlint && command -v yamllint && bats tests/shell/onboard-render.bats -f "integration: rendered flutter-app"`
Expected: PASS (not SKIP). If actionlint reports an issue on the rendered files, fix the template, re-render, and re-run.

- [ ] **Step 4: Commit**

```bash
git add tests/shell/onboard-render.bats
git commit -m "test(onboard): integration lint of rendered flutter workflows"
```

---

## Task 11: Document `SK_FLUTTER_DART_DEFINE_SECRETS`

**Files:**
- Modify: `docs/operations.md`

- [ ] **Step 1: Add the override-table row**

In the "Per-Adopter Overrides via Repository Variables" table, after the `SK_TRIVY_VERSION` row, add:

```markdown
| `SK_FLUTTER_DART_DEFINE_SECRETS` | `dart_define_secret_names` | release-flutter-android (release.yml) | (empty) | string (comma-list of secret names) |
```

- [ ] **Step 2: Add an explanatory paragraph** after the `SK_CGO_ENABLED override-wins` paragraph at the end of the section:

```markdown
**`SK_FLUTTER_DART_DEFINE_SECRETS`:** a comma-separated list of *secret names* (not values) that the rendered `release.yml` forwards to `release-flutter-android`'s `dart_define_secret_names`, which injects each as `--dart-define=NAME=$VALUE` at build time. The secrets themselves must exist at org or repo level; `secrets: inherit` makes them available. Example value: `SUPABASE_URL,SUPABASE_ANON_KEY`. Empty (default) means no dart-defines.
```

- [ ] **Step 3: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): document SK_FLUTTER_DART_DEFINE_SECRETS override"
```

---

## Task 12: Full-suite verification + wrap-up

**Files:** none (verification only)

- [ ] **Step 1: Run the full detect + render suites**

Run: `bats tests/shell/onboard-detect.bats tests/shell/onboard-render.bats`
Expected: PASS — all tests, including pre-existing non-Flutter ones (no regressions).

- [ ] **Step 2: Lint the catalog's own changed files**

Run: `actionlint && yamllint -s .github/` (install on first use if missing, per CONTRIBUTING).
Expected: clean — note this lints the catalog's own workflows; the templates under `docs/adopter-templates/` are `.tmpl` and not linted directly (they are validated via the rendered output in Task 10).

- [ ] **Step 3: Shellcheck the modified scripts**

Run: `shellcheck scripts/onboard-detect.sh scripts/lib/onboard-detect-lib.sh`
Expected: clean (or only the pre-existing disables already present in those files).

- [ ] **Step 4: Confirm the spec acceptance criteria against the real fixture**

Run:
```bash
scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/flutter-app | jq '{primary: .components[0].primary_language, rp: .components[0].release_please_type, fa: .components[0].release_signals.flutter_android, role: .components[0].role, warnings: (.warnings|length)}'
```
Expected: `{"primary":"flutter","rp":"dart","fa":true,"role":"mobile-app","warnings":0}`

- [ ] **Step 5: Tick all checkboxes in this plan and proceed to review/PR** per `superpowers:subagent-driven-development` (two-stage review: spec-reviewer then `feature-dev:code-reviewer`), then open the PR with a multi-line body (summary + test plan). PR title: `feat(onboard): detect Flutter and render ci/release` (no attribution footer, per project convention).

---

## Self-Review

**Spec coverage:**
- Detection (detect_languages, release_please_type, SUPPORTED_LINT_TEST_LANGUAGES, flutter_android, mobile-app role) → Tasks 2-5. ✓
- Legacy/--emit-both marker lists + action.yml doc → Tasks 2, 9. ✓
- ci.yml flutter branch → Task 6. ✓
- release.yml flutter_android branch → Task 7. ✓
- release-please-config dart → Task 8 (verification; mapping in Task 3). ✓
- bats detect + render → Tasks 2-8. ✓
- Integration render + actionlint/yamllint against fixture → Task 10. ✓
- SK_FLUTTER_DART_DEFINE_SECRETS docs → Task 11. ✓
- Acceptance criteria check → Task 12 Step 4. ✓

**Placeholder scan:** No TBD/TODO; every code/edit step shows exact content. ✓

**Type/name consistency:** `_component_is_flutter` defined in Task 2 Step 3, reused in Tasks 2/5 consistently. `flutter_android` key name consistent across detection (Task 5), templates (Task 7), tests (Tasks 5/7/8). `release_please_type` value `dart` consistent (Tasks 3/8). Golden filename `single-flutter.yml` consistent (Task 6). ✓

**Note on existing tests:** Adding `flutter_android` to `detect_release_signals` is additive — existing detect tests access `.goreleaser_config`/`.chart_yaml` by field (not full-object equality) and existing render tests omit the key (gomplate treats a missing map key as falsey), so no existing test needs editing. Task 7 Step 5 and Task 12 Step 1 verify this explicitly.
```
