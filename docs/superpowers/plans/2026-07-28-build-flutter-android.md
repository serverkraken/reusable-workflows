# build-flutter-android Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fourth Flutter atom `build-flutter-android.yml` (PR-time Android compile gate, no release semantics) plus a conditionally-rendered `ci-android.yml` onboarding skeleton so Flutter-app adopters (strassenfuchs) get the check automatically.

**Architecture:** The atom is a structural twin of `test-flutter.yml` (checkout → App token → catalog checkout → `setup-flutter-toolchain` composite → `flutter build apk --<mode>`). Onboarding renders `.github/workflows/ci-android.yml` from a new skeleton, gated on the existing `release_signals.flutter_android` profile flag, in BOTH render engines (Go `internal/app/render` and shell `scripts/onboard-render.sh`). The lock file is the staging manifest for onboard PRs and drift, so no changes are needed in `onboard.yml` or `onboard-drift.sh`.

**Tech Stack:** GitHub Actions reusable workflows, gomplate templates, Go 1.x (`internal/`), bash + bats, actionlint/yamllint.

**Spec:** `docs/superpowers/specs/2026-07-28-build-flutter-android-design.md`

## Global Constraints

- Work happens in the worktree `.worktrees/build-flutter-android` on branch `feat/build-flutter-android`. All paths below are relative to that worktree root.
- Action pins are commit SHAs with a `# vN` comment, copied verbatim from `test-flutter.yml` (`actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6`, `actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3`).
- Every workflow must pass `actionlint` and `yamllint -s .github/` (CI fails on warnings).
- Conventional Commits; this feature is `feat:` scope (minor within v4). Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Behavior changes to onboarding MUST land in both engines: Go (`internal/app/render/service.go`) and shell (`scripts/onboard-render.sh`) — org memory `sk-workflows-go-cli-und-shell`.
- The golden fixtures render with pin `v2` (see `golden_check` in `tests/shell/onboard-render.bats:158`); inline-profile render helpers use pin `v4`.
- Run bats as `bats tests/shell/onboard-render.bats`, Go tests as `go test ./internal/...` from the worktree root.

---

### Task 1: Atom `.github/workflows/build-flutter-android.yml`

**Files:**
- Create: `.github/workflows/build-flutter-android.yml`

**Interfaces:**
- Consumes: composite action `actions/setup-flutter-toolchain` (inputs `java-version`, `flutter-channel`, `flutter-version`, `use-build-runner`, `working-directory`, `sdk-cache`).
- Produces: `workflow_call` contract used by Tasks 2, 4, 5 — inputs `runs_on`, `working_directory`, `java_version`, `flutter_channel`, `flutter_version`, `use_build_runner`, `build_mode`, `flavor`, `sdk_cache`, `timeout_minutes`; secrets `release_please_app_client_id`, `release_please_app_private_key`.

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/build-flutter-android.yml` with exactly this content:

```yaml
# .github/workflows/build-flutter-android.yml
# Reusable workflow: PR-time Android compile gate. Verifies the Android side
# of a Flutter app still builds (flutter build apk) — no signing, no upload,
# no version handling, no release secrets.
#
# Complements release-flutter-android.yml: this atom guards pull requests;
# the release atom builds and publishes the signed artefacts.
#
# Auth: callers MUST pass `secrets: inherit` so the catalog-scoped App
# token can be minted. See lint-flutter.yml for the full explanation.
#
# Stability surface: all `inputs:` and `secrets:` keys below are stable
# within major v4. Any removal or rename is a major-version bump.
#
# Summary convention: docs/conventions/step-summary.md
name: build-flutter-android
on:
  workflow_call:
    inputs:
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux","X64","performance"]'
      working_directory:
        description: 'Path to the Flutter project root, relative to the repo root.'
        required: false
        type: string
        default: '.'
      java_version:
        description: 'Java major version.'
        required: false
        type: string
        default: '17'
      flutter_channel:
        description: 'Flutter release channel.'
        required: false
        type: string
        default: 'stable'
      flutter_version:
        description: 'Specific Flutter version (empty = latest on channel).'
        required: false
        type: string
        default: ''
      use_build_runner:
        description: 'When true, runs dart run build_runner build after pub get.'
        required: false
        type: boolean
        default: true
      build_mode:
        description: 'Flutter build mode: debug, profile, or release. debug needs no keystore and suffices as a compile gate.'
        required: false
        type: string
        default: 'debug'
      flavor:
        description: 'Build flavor name (empty = no --flavor flag).'
        required: false
        type: string
        default: ''
      sdk_cache:
        description: 'Cache the Flutter SDK via actions/cache. Off by default; see setup-flutter-toolchain.'
        required: false
        type: boolean
        default: false
      timeout_minutes:
        description: 'Job timeout in minutes.'
        required: false
        type: number
        default: 45
    secrets:
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'

permissions:
  contents: read

concurrency:
  group: build-flutter-android-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  build:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: ${{ inputs.timeout_minutes }}
    steps:
      - name: Validate build_mode
        # build_mode is interpolated into the flutter CLI call below — fail
        # fast on anything that is not a known mode.
        env:
          BUILD_MODE: ${{ inputs.build_mode }}
        run: |
          set -euo pipefail
          case "$BUILD_MODE" in
            debug|profile|release) ;;
            *)
              echo "::error::build_mode must be one of debug|profile|release, got: ${BUILD_MODE}"
              exit 1
              ;;
          esac
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
        # Self-CI (caller == catalog): use the caller's SHA so feature-branch
        # composite-action changes are exercised. Cross-repo (adopters):
        # pin to the floating major tag `v4`. Bump this hardcoded major when
        # a new major releases.
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
        with:
          java-version: ${{ inputs.java_version }}
          flutter-channel: ${{ inputs.flutter_channel }}
          flutter-version: ${{ inputs.flutter_version }}
          use-build-runner: ${{ inputs.use_build_runner }}
          working-directory: ${{ inputs.working_directory }}
          sdk-cache: ${{ inputs.sdk_cache }}

      - name: flutter build apk
        id: build
        working-directory: ${{ inputs.working_directory }}
        env:
          BUILD_MODE: ${{ inputs.build_mode }}
          FLAVOR: ${{ inputs.flavor }}
        run: |
          set -euo pipefail
          flavor_arg=""; [[ -n "$FLAVOR" ]] && flavor_arg="--flavor=$FLAVOR"
          # shellcheck disable=SC2086
          flutter build apk "--${BUILD_MODE}" $flavor_arg

      - name: Summary
        if: always()
        env:
          WD: ${{ inputs.working_directory }}
          BUILD_MODE: ${{ inputs.build_mode }}
          BUILD_OUTCOME: ${{ steps.build.outcome }}
        run: |
          if [[ "$BUILD_OUTCOME" == "success" ]]; then
            result="✓ passed"
          else
            result="✗ failed"
          fi
          {
            echo "## build-flutter-android"
            echo ""
            echo "**Tool:** flutter build apk --${BUILD_MODE}"
            echo "**Working dir:** \`${WD}\`"
            echo "**Result:** ${result}"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 2: Validate statically**

Run from the worktree root:

```bash
actionlint .github/workflows/build-flutter-android.yml
yamllint -s .github/workflows/build-flutter-android.yml
```

Expected: both exit 0, no output. If `actionlint`/`yamllint` are missing, install with `brew install actionlint yamllint`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-flutter-android.yml
git commit -m "feat: add build-flutter-android PR-time compile-gate atom

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Skeleton `ci-android.yml.tmpl` + shell render engine (TDD via bats)

**Files:**
- Create: `docs/adopter-templates/skeletons/ci-android.yml.tmpl`
- Modify: `scripts/onboard-render.sh` (render block ~line 110-130, lock array ~line 168-179)
- Modify: `tests/shell/onboard-render.bats` (new tests appended after the golden block)
- Modify (regenerate): `tests/fixtures/onboard/flutter-app/expected/` (new file `.github/workflows/ci-android.yml`, updated `onboard.lock.json`)

**Interfaces:**
- Consumes: atom contract from Task 1 (`build-flutter-android.yml`, input `working_directory`).
- Produces: rendered file `.github/workflows/ci-android.yml` + lock entry `".github/workflows/ci-android.yml"` — Task 3 must produce the identical file set in the Go engine.

- [ ] **Step 1: Write failing bats tests**

Append to `tests/shell/onboard-render.bats` (after the last `@test`), using the existing `seed_profile` helper:

```bash
# ---- ci-android.yml (build-flutter-android PR gate) ----
#
# Rendered ONLY when at least one component has release_signals.flutter_android
# — the same flag that gates release-flutter-android in the release skeletons.

@test "render: ci-android.yml emitted for flutter app with android dir" {
  seed_profile "flutter-app"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci-android.yml" ]
  grep -q "build-flutter-root:" "$TARGET/.github/workflows/ci-android.yml"
  grep -q "build-flutter-android.yml@v2" "$TARGET/.github/workflows/ci-android.yml"
  grep -q -- "- 'android/\*\*'" "$TARGET/.github/workflows/ci-android.yml"
  lock_entry=$(jq -r '.files[".github/workflows/ci-android.yml"]' "$TARGET/.github/onboard.lock.json")
  [[ "$lock_entry" =~ ^sha256: ]]
}

@test "render: ci-android.yml omitted for flutter package without android dir" {
  seed_profile "flutter-package"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ ! -f "$TARGET/.github/workflows/ci-android.yml" ]
  lock_entry=$(jq -r '.files[".github/workflows/ci-android.yml"] // "absent"' "$TARGET/.github/onboard.lock.json")
  [ "$lock_entry" = "absent" ]
}

@test "render: ci-android.yml omitted for non-flutter profile" {
  seed_profile "go-repo"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v2"
  [ "$status" -eq 0 ]
  [ ! -f "$TARGET/.github/workflows/ci-android.yml" ]
}
```

- [ ] **Step 2: Run the new tests, verify they fail**

```bash
bats tests/shell/onboard-render.bats -f "ci-android"
```

Expected: the "emitted for flutter app" test FAILS (file not rendered); the two "omitted" tests may already pass — that's fine, the positive test is the driver.

- [ ] **Step 3: Write the skeleton template**

Create `docs/adopter-templates/skeletons/ci-android.yml.tmpl`:

```
{{- /*
  ci-android.yml — PR-time Android compile gate for Flutter-app components.

  Rendered ONLY when at least one component has release_signals.flutter_android
  (i.e. a Flutter project with an android/ directory). The paths filter keeps
  pure Dart/docs PRs from paying the ~9-minute toolchain + Gradle cost — which
  also means this check MUST NOT be a required branch-protection check (it
  does not appear on filtered PRs at all).

  Job-id pattern matches ci.yml: build-flutter-<suffix>, where path == "." →
  "root", otherwise path with `/` → `-`.
*/ -}}
{{- $pin := .pin -}}
name: ci-android
on:
  pull_request:
    paths:
{{- range $i, $c := .profile.components }}
{{- if and (has $c.release_signals "flutter_android") $c.release_signals.flutter_android }}
{{- if eq $c.path "." }}
      - 'android/**'
      - 'pubspec.yaml'
      - 'pubspec.lock'
{{- else }}
      - '{{ $c.path }}/android/**'
      - '{{ $c.path }}/pubspec.yaml'
      - '{{ $c.path }}/pubspec.lock'
{{- end }}
{{- end }}
{{- end }}
      - '.github/workflows/ci-android.yml'

jobs:
{{- range $i, $c := .profile.components }}
{{- if and (has $c.release_signals "flutter_android") $c.release_signals.flutter_android }}
{{- $suffix := "" -}}
{{- if eq $c.path "." -}}
{{- $suffix = "root" -}}
{{- else -}}
{{- $suffix = $c.path | replaceAll "/" "-" -}}
{{- end }}
  build-flutter-{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/build-flutter-android.yml@{{ $pin }}
    with:
      working_directory: {{ $c.path }}
    secrets: inherit
{{- end }}
{{- end }}
```

- [ ] **Step 4: Wire the shell engine**

In `scripts/onboard-render.sh`, inside the `if [[ "$IS_GITOPS" != "true" ]]; then` block, directly after the `prerelease-on-push` opt-in block (after line ~121), add:

```bash
  # ci-android.yml — rendered only when at least one component is a Flutter
  # app with an android/ directory (release_signals.flutter_android). Gives
  # PRs a paths-filtered Android compile gate (build-flutter-android atom).
  if jq -e '[.components[].release_signals.flutter_android // false] | any' "$PROFILE" >/dev/null 2>&1; then
    render "$SKELETONS/ci-android.yml.tmpl" "$TARGET/.github/workflows/ci-android.yml"
    RENDER_ANDROID=1
  fi
```

Initialise the flag next to `RENDER_ON_PUSH=0` (line ~109):

```bash
RENDER_ANDROID=0
```

And in the lock array block (after the `RENDER_ON_PUSH` append, line ~176-178), add:

```bash
  if [[ "$RENDER_ANDROID" == "1" ]]; then
    RENDERED+=(".github/workflows/ci-android.yml")
  fi
```

- [ ] **Step 5: Run the new tests, verify they pass**

```bash
bats tests/shell/onboard-render.bats -f "ci-android"
```

Expected: all 3 PASS.

- [ ] **Step 6: Regenerate the flutter-app golden fixture**

The `golden: flutter-app` test now fails (new file not in `expected/`). Regenerate, then verify the full file passes:

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats -f "golden: flutter-app"
bats tests/shell/onboard-render.bats
```

Expected: second run — ALL tests pass. Inspect the regenerated files:

```bash
git diff --stat tests/fixtures/onboard/flutter-app/expected/
cat tests/fixtures/onboard/flutter-app/expected/.github/workflows/ci-android.yml
```

Expected content of the new golden file (pin v2, root component):

```yaml
name: ci-android
on:
  pull_request:
    paths:
      - 'android/**'
      - 'pubspec.yaml'
      - 'pubspec.lock'
      - '.github/workflows/ci-android.yml'

jobs:
  build-flutter-root:
    uses: serverkraken/reusable-workflows/.github/workflows/build-flutter-android.yml@v2
    with:
      working_directory: .
    secrets: inherit
```

Only `flutter-app/expected/` may change (new file + lock hash entry). If any other fixture's golden changed, STOP — the conditional is wrong.

- [ ] **Step 7: Validate the rendered YAML statically**

```bash
yamllint -s tests/fixtures/onboard/flutter-app/expected/.github/workflows/ci-android.yml
```

Expected: exit 0.

- [ ] **Step 8: Commit**

```bash
git add docs/adopter-templates/skeletons/ci-android.yml.tmpl scripts/onboard-render.sh tests/shell/onboard-render.bats tests/fixtures/onboard/flutter-app/expected/
git commit -m "feat: render paths-filtered ci-android.yml for flutter_android adopters (shell engine)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Go render engine parity (TDD)

**Files:**
- Modify: `internal/app/render/service.go` (`plannedFiles` line ~128-152, `lockPaths` line ~154-170, new predicate)
- Test: `internal/app/render/service_test.go` (`allTemplateFiles` line ~371-382, new tests)

**Interfaces:**
- Consumes: `domain.Profile.Components[].ReleaseSignals.FlutterAndroid` (`internal/domain/profile.go:37`), `renderFile{Template, Output}` struct.
- Produces: identical file set to Task 2's shell engine — template `skeletons/ci-android.yml.tmpl` → output `.github/workflows/ci-android.yml`, plus the matching lock path.

- [ ] **Step 1: Write failing Go tests**

In `internal/app/render/service_test.go`: first add the new skeleton to `allTemplateFiles()` so the fake catalog contains it:

```go
func allTemplateFiles() []string {
	return []string{
		"skeletons/ci.yml.tmpl",
		"skeletons/ci-android.yml.tmpl",
		"skeletons/release.yml.tmpl",
		"skeletons/prerelease.yml.tmpl",
		"skeletons/cleanup.yml.tmpl",
		"skeletons/prerelease-on-push.yml.tmpl",
		"configs/release-please-config.json.tmpl",
		"configs/release-please-config.monorepo.json.tmpl",
		"configs/release-please-manifest.json.tmpl",
	}
}
```

Then add these tests (after `TestRenderMonorepoUsesMonorepoConfig`):

```go
func TestRenderFlutterAndroidEmitsCIAndroid(t *testing.T) {
	catalog := renderCatalog(t, allTemplateFiles()...)
	target := t.TempDir()
	profile := writeProfile(t, target, `{
	  "schema_version": 1,
	  "target_repo": "serverkraken/strassenfuchs",
	  "default_branch": "main",
	  "monorepo": false,
	  "components": [{
	    "path": ".",
	    "primary_language": "flutter",
	    "release_please_type": "dart",
	    "release_signals": {"flutter_android": true}
	  }]
	}`)
	templates := &fakeTemplates{}
	if err := (Service{Templates: templates, Now: fixedNow}).Render(context.Background(), Request{
		CatalogPath:     catalog,
		TargetPath:      target,
		ProfileJSONPath: profile,
		PinVersion:      "v4",
	}); err != nil {
		t.Fatal(err)
	}
	if !calledTemplate(templates.calls, "ci-android.yml.tmpl") {
		t.Fatalf("ci-android.yml.tmpl not rendered: %+v", templates.calls)
	}
	lock := readLock(t, target)
	if lock.Files[".github/workflows/ci-android.yml"] == "" {
		t.Fatalf("lock missing ci-android.yml: %v", lock.Files)
	}
}

func TestRenderNoFlutterAndroidOmitsCIAndroid(t *testing.T) {
	catalog := renderCatalog(t, allTemplateFiles()...)
	target := t.TempDir()
	profile := writeProfile(t, target, `{
	  "schema_version": 1,
	  "target_repo": "serverkraken/pkg",
	  "monorepo": false,
	  "components": [{
	    "path": ".",
	    "primary_language": "flutter",
	    "release_please_type": "dart",
	    "release_signals": {"flutter_android": false}
	  }]
	}`)
	templates := &fakeTemplates{}
	if err := (Service{Templates: templates, Now: fixedNow}).Render(context.Background(), Request{
		CatalogPath:     catalog,
		TargetPath:      target,
		ProfileJSONPath: profile,
		PinVersion:      "v4",
	}); err != nil {
		t.Fatal(err)
	}
	if calledTemplate(templates.calls, "ci-android.yml.tmpl") {
		t.Fatalf("ci-android.yml.tmpl rendered for non-android profile: %+v", templates.calls)
	}
	lock := readLock(t, target)
	if lock.Files[".github/workflows/ci-android.yml"] != "" {
		t.Fatalf("lock contains ci-android.yml: %v", lock.Files)
	}
	if _, err := os.Stat(filepath.Join(target, ".github/workflows/ci-android.yml")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("ci-android.yml exists: %v", err)
	}
}
```

- [ ] **Step 2: Run tests, verify the positive one fails**

```bash
go test ./internal/app/render/ -run 'CIAndroid' -v
```

Expected: `TestRenderFlutterAndroidEmitsCIAndroid` FAILS ("ci-android.yml.tmpl not rendered"), `TestRenderNoFlutterAndroidOmitsCIAndroid` passes.

- [ ] **Step 3: Implement in `service.go`**

Add the predicate (next to `hasTopic`):

```go
func hasFlutterAndroid(profile domain.Profile) bool {
	for _, c := range profile.Components {
		if c.ReleaseSignals.FlutterAndroid {
			return true
		}
	}
	return false
}
```

In `plannedFiles`, after the `if profile.GitOps != nil { return files }` guard (line ~132-134), insert before the release entries:

```go
	if hasFlutterAndroid(profile) {
		files = append(files, renderFile{Template: "skeletons/ci-android.yml.tmpl", Output: ".github/workflows/ci-android.yml"})
	}
```

In `lockPaths`, mirror it — insert directly after the `files := []string{...}` slice literal (line ~158-165), before the `sk-prerelease-on-push` topic check:

```go
	if hasFlutterAndroid(profile) {
		files = append(files, ".github/workflows/ci-android.yml")
	}
```

- [ ] **Step 4: Run the full Go test suite**

```bash
go test ./internal/...
```

Expected: ALL pass (existing tests use profiles without `flutter_android`, so counts are unchanged).

- [ ] **Step 5: Commit**

```bash
git add internal/app/render/service.go internal/app/render/service_test.go
git commit -m "feat: render ci-android.yml for flutter_android adopters (Go engine)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Self-CI happy path + nightly failure path

**Files:**
- Modify: `.github/workflows/self-ci.yml` (after `test-flutter-happy` ~line 451, and `summary.needs` ~line 458-480)
- Modify: `.github/workflows/failure-paths-nightly.yml` (new job pair before `report-regressions` ~line 389, `report-regressions.needs` ~line 401-415, two "14" count references at lines ~390 and ~437)

**Interfaces:**
- Consumes: atom contract from Task 1; fixture `tests/fixtures/flutter-app` (already exists, root of a buildable Flutter app with android/).
- Produces: CI jobs `build-flutter-android-happy` (self-ci) and `test-build-flutter-android-fail` / `assert-build-flutter-android-fail` (nightly).

- [ ] **Step 1: Add the happy-path job to self-ci.yml**

After the `test-flutter-happy` job (line ~445-451), insert:

```yaml
  build-flutter-android-happy:
    uses: ./.github/workflows/build-flutter-android.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/flutter-app
      use_build_runner: false
```

And append to `summary.needs` (after `- test-flutter-happy`):

```yaml
      - build-flutter-android-happy
```

- [ ] **Step 2: Add the failure-path pair to failure-paths-nightly.yml**

Before the `# ----- Regression Reporter -----` comment block, insert:

```yaml
  # ----- build-flutter-android: fail-path -----
  # A --flavor that no Gradle flavor defines aborts the build (Gradle cannot
  # resolve the assemble task) — exercises failure propagation without a
  # dedicated broken fixture.
  test-build-flutter-android-fail:
    uses: ./.github/workflows/build-flutter-android.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/flutter-app
      use_build_runner: false
      flavor: nonexistent

  assert-build-flutter-android-fail:
    needs: test-build-flutter-android-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert build job failed
        env:
          RESULT: ${{ needs.test-build-flutter-android-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected build-flutter-android to fail on nonexistent flavor, got: $RESULT"
            exit 1
          fi
          echo "build-flutter-android-fail: correctly observed failure"
```

Append to `report-regressions.needs`:

```yaml
      - assert-build-flutter-android-fail
```

Update the two hardcoded counts: the comment `# Runs after all 14 assert-* jobs.` → `15`, and the echo `"All 14 assert-*-fail jobs returned success…"` → `"All 15 assert-*-fail jobs returned success…"`.

- [ ] **Step 3: Validate statically**

```bash
actionlint .github/workflows/self-ci.yml .github/workflows/failure-paths-nightly.yml
yamllint -s .github/workflows/self-ci.yml .github/workflows/failure-paths-nightly.yml
```

Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/self-ci.yml .github/workflows/failure-paths-nightly.yml
git commit -m "test: exercise build-flutter-android happy + failure paths in self-CI

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/contracts.md` (new atom section after `## Atomic Workflows` line ~9, i.e. alphabetically before `### cleanup-images.yml` line ~11; `setup-flutter-toolchain` description line ~382)
- Modify: `docs/operations.md` (§ 5.3 file list line ~110; stack-aware renderer section after the `prerelease-on-push.yml` bullet line ~387)
- Modify: `README.md` (atom table row after the `lint-flutter.yml / test-flutter.yml` row line ~122)

**Interfaces:**
- Consumes: the atom contract from Task 1 (input table) and skeleton behavior from Task 2.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: contracts.md — new atom section**

Insert after the `## Atomic Workflows` heading, before `### cleanup-images.yml`:

```markdown
### `build-flutter-android.yml`

PR-time Android compile gate: runs `flutter build apk --<build_mode>` with no
release semantics — no signing, no upload, no version handling. Complements
`release-flutter-android.yml`. Typically called from the rendered
`ci-android.yml` (paths-filtered; NOT suitable as a required check).

| Kind    | Name                 | Type    | Required | Default                                         | Description |
|---------|----------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`            | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory`  | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `java_version`       | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`    | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`    | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`   | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `build_mode`         | string  | no       | `'debug'`                                       | `debug` \| `profile` \| `release`; debug needs no keystore |
| input   | `flavor`             | string  | no       | `''`                                            | Build flavor (empty = no `--flavor` flag) |
| input   | `sdk_cache`          | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (off — key rotates per Flutter release) |
| input   | `timeout_minutes`    | number  | no       | `45`                                            | Job timeout |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |

---
```

Also update the `actions/setup-flutter-toolchain` intro sentence (line ~382) to:

```markdown
Shared by the lint-flutter, test-flutter, build-flutter-android, and release-flutter-android atoms:
```

- [ ] **Step 2: operations.md — onboarding + renderer notes**

In § 5.3, extend the PR A sentence so the file list reads:

```markdown
- **PR A** on `chore/onboard-reusable-workflows`: adds `ci.yml`, `release.yml`, `prerelease.yml`, `cleanup.yml`, `release-please-config.json`, `.release-please-manifest.json` — plus `ci-android.yml` for Flutter apps with an `android/` directory. Always opened when the rendered diff is non-empty.
```

After the `prerelease-on-push.yml` bullet in the "Prerelease callers (stack-aware)" section (line ~387), add a sibling bullet:

```markdown
- `ci-android.yml` — **PR-time** Android compile gate. Rendered **only** when a component has `release_signals.flutter_android` (Flutter app with `android/`). Calls `build-flutter-android` (`flutter build apk --debug`, unsigned) and is paths-filtered to `android/**`, `pubspec.yaml`, `pubspec.lock` — pure Dart/docs PRs skip it entirely. Because the check does not appear on filtered PRs, it must **not** be configured as a required branch-protection check.
```

- [ ] **Step 3: README.md — atom table row**

After the `lint-flutter.yml / test-flutter.yml` row (line ~122), add:

```markdown
| `build-flutter-android.yml`  | PR-Gate: flutter build apk (debug, unsigniert) — kompiliert die Android-Seite |
```

Match the table's column alignment style.

- [ ] **Step 4: Commit**

```bash
git add docs/contracts.md docs/operations.md README.md
git commit -m "docs: document build-flutter-android atom and ci-android.yml skeleton

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Full verification sweep

**Files:** none new — verification only.

- [ ] **Step 1: Static validation of everything**

```bash
actionlint
yamllint -s .github/
```

Expected: exit 0 each.

- [ ] **Step 2: Full shell test suite**

```bash
bats tests/shell/
```

Expected: ALL pass (including all goldens and the 3 new ci-android tests).

- [ ] **Step 3: Full Go test suite**

```bash
go test ./...
```

Expected: ALL pass.

- [ ] **Step 4: End-to-end render smoke test against the flutter-app fixture**

```bash
TMP=$(mktemp -d)
scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/flutter-app > "$TMP/profile.json"
scripts/onboard-render.sh . "$TMP" "$TMP/profile.json" v4
cat "$TMP/.github/workflows/ci-android.yml"
jq '.files' "$TMP/.github/onboard.lock.json"
rm -rf "$TMP"
```

Expected: `ci-android.yml` present with `build-flutter-android.yml@v4` and the lock lists it.

- [ ] **Step 5: Confirm clean tree, no stray commits**

```bash
git status --short
git log --oneline main..HEAD
```

Expected: clean tree; commits from Tasks 1-5 plus the spec/plan commits.
