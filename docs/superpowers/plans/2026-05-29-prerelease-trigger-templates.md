# Prerelease-Trigger Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the two prerelease-trigger patterns as adopter templates — a stack-aware manual `prerelease.yml` (Flutter branch replaces the noop) and a new opt-in `prerelease-on-push.yml` (auto on push to `develop`, gated by the `sk-prerelease-on-push` repo topic).

**Architecture:** Trigger-as-axis. Detection adds a general `topics` array to the profile. `prerelease.yml.tmpl` gains a Flutter branch. A new `prerelease-on-push.yml.tmpl` is rendered *conditionally* by `onboard-render.sh` (and conditionally tracked in the lock) only when the topic is present.

**Tech Stack:** Bash (detect + render), gomplate Go templates, jq, bats, actionlint + yamllint.

**Spec:** `docs/superpowers/specs/2026-05-29-prerelease-trigger-templates-design.md`

---

## Setup (execution-time, before Task 1)

Create the worktree via `superpowers:using-git-worktrees`:
- Branch: `feat/prerelease-trigger-templates`
- Path: `.worktrees/prerelease-templates/`
- Base: `origin/main`

All paths below are relative to that worktree root. Baseline: `bats tests/shell/onboard-detect.bats tests/shell/onboard-render.bats` must pass before starting.

## File Structure

- **Modify** `scripts/lib/onboard-detect-lib.sh` — `emit_profile_json` adds a top-level `topics` array; `detect_legacy_ci` `OWNED` adds `prerelease-on-push.yml`.
- **Modify** `docs/adopter-templates/skeletons/prerelease.yml.tmpl` — Flutter branch (replaces noop for Flutter apps).
- **Create** `docs/adopter-templates/skeletons/prerelease-on-push.yml.tmpl` — auto-on-push, stack-aware.
- **Modify** `scripts/onboard-render.sh` — conditionally render `prerelease-on-push.yml`, conditionally lock it, add it to the `$REPO` loop.
- **Modify** `tests/shell/onboard-detect.bats` — topics tests.
- **Modify** `tests/shell/onboard-render.bats` — prerelease Flutter + prerelease-on-push tests.
- **Modify** `tests/fixtures/onboard/flutter-app/expected/` — regenerated golden (prerelease.yml no longer noop).
- **Modify** `docs/operations.md` — document both callers + the topic.

---

## Task 1: Detection — `topics` array in the profile

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` (`emit_profile_json`)
- Test: `tests/shell/onboard-detect.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
# === topics ===

@test "profile-json: topics defaults to [] when TARGET_REPO unset" {
  unset TARGET_REPO
  run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.topics == []'
}

@test "profile-json: topics populated from gh api /repos/<repo>/topics" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
# Minimal gh mock honoring the calls emit_profile_json makes with -q.
case "$*" in
  *"/topics"*)       echo '["sk-prerelease-on-push","serverkraken-onboarded"]' ;;
  *"release list"*)  echo '' ;;
  *"/repos/o/r"*)    echo 'main' ;;
  *)                 echo '' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  TARGET_REPO=o/r PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$DETECT" --profile-json "$FIX/go-repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.topics | index("sk-prerelease-on-push")) != null'
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/shell/onboard-detect.bats -f topics`
Expected: FAIL — profile has no `.topics` key (jq `== []` is false on null).

- [ ] **Step 3: Fetch topics in `emit_profile_json`**

In `scripts/lib/onboard-detect-lib.sh`, the function currently has (after the default_branch/current_version `if` block, before `local components`):

```bash
  local components
  components=$(detect_components "$repo")
```

Insert the topics fetch immediately before `local components`:

```bash
  # Repo topics — a general signal consumed by the renderer (e.g. the
  # `sk-prerelease-on-push` opt-in). gh prints the HTTP error body to STDOUT on
  # failure, so the fallback MUST be outside the substitution (see
  # troubleshooting: gh-api-leaks-error-body-to-stdout); -q '.names' emits the
  # array as compact JSON.
  local topics='[]'
  if [[ -n "$target_repo" ]]; then
    topics=$(gh api "/repos/$target_repo/topics" -q '.names' 2>/dev/null) || topics='[]'
    [[ -z "$topics" || "$topics" == "null" ]] && topics='[]'
  fi

  local components
  components=$(detect_components "$repo")
```

- [ ] **Step 4: Add `topics` to the emitted JSON**

The `jq -n` call currently reads:

```bash
  profile=$(jq -n \
    --argjson schema_version 1 \
    --arg target_repo "$target_repo" \
    --arg default_branch "$default_branch" \
    --arg current_version "$current_version" \
    --argjson monorepo "$(echo "$components" | jq 'length > 1')" \
    --argjson components "$components" \
    --argjson legacy_ci "$legacy_ci" \
    --argjson warnings '[]' \
    '{
      schema_version: $schema_version,
      target_repo: $target_repo,
      default_branch: $default_branch,
      current_version: $current_version,
      monorepo: $monorepo,
      components: $components,
      legacy_ci: $legacy_ci,
      warnings: $warnings
    }')
```

Add a `--argjson topics "$topics"` arg and a `topics: $topics` field:

```bash
  profile=$(jq -n \
    --argjson schema_version 1 \
    --arg target_repo "$target_repo" \
    --arg default_branch "$default_branch" \
    --arg current_version "$current_version" \
    --argjson monorepo "$(echo "$components" | jq 'length > 1')" \
    --argjson components "$components" \
    --argjson legacy_ci "$legacy_ci" \
    --argjson topics "$topics" \
    --argjson warnings '[]' \
    '{
      schema_version: $schema_version,
      target_repo: $target_repo,
      default_branch: $default_branch,
      current_version: $current_version,
      monorepo: $monorepo,
      components: $components,
      legacy_ci: $legacy_ci,
      topics: $topics,
      warnings: $warnings
    }')
```

- [ ] **Step 5: Run to verify they pass**

Run: `bats tests/shell/onboard-detect.bats -f topics`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the full detect suite (no regressions)**

Run: `bats tests/shell/onboard-detect.bats`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): add repo topics to detection profile"
```

---

## Task 2: Manual prerelease — Flutter branch in `prerelease.yml.tmpl`

**Files:**
- Modify: `docs/adopter-templates/skeletons/prerelease.yml.tmpl`
- Test: `tests/shell/onboard-render.bats`
- Modify: `tests/fixtures/onboard/flutter-app/expected/` (golden regen)

- [ ] **Step 1: Write the failing tests**

Append to `tests/shell/onboard-render.bats`:

```bash
# === Flutter manual prerelease.yml ===

@test "prerelease.yml renders release-flutter-android create_release for a flutter app" {
  rendered=$(render_prerelease_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  grep -qF "release-flutter-android.yml@v4" "$rendered"
  grep -qF "create_release: true" "$rendered"
  grep -qF "version: \${{ inputs.version }}" "$rendered"
  grep -qF "dart_define_secret_names: \${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}" "$rendered"
  ! grep -q "noop" "$rendered"
}

@test "prerelease.yml keeps noop for a flutter package (no android/)" {
  rendered=$(render_prerelease_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/pkg",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "library", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  grep -q "noop" "$rendered"
  ! grep -q "release-flutter-android" "$rendered"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/shell/onboard-render.bats -f "manual prerelease"`
Expected: FAIL — the flutter app currently renders the `noop` (no flutter branch).

- [ ] **Step 3: Add the Flutter branch to `prerelease.yml.tmpl`**

The template's `on:` block and `jobs:` if-chain currently are:

```gotemplate
name: prerelease
on:
  workflow_dispatch: {}

jobs:
{{- if eq (len $c.dockerfiles) 1 }}
```

Change the `on:` block to be Flutter-aware, and add a Flutter branch as the FIRST arm of the jobs if-chain. Replace:

```gotemplate
name: prerelease
on:
  workflow_dispatch: {}

jobs:
{{- if eq (len $c.dockerfiles) 1 }}
```

with:

```gotemplate
name: prerelease
on:
{{- if $c.release_signals.flutter_android }}
  workflow_dispatch:
    inputs:
      version:
        description: 'Tag to build (empty → auto <latest>-rc.<run_number>)'
        required: false
        type: string
        default: ''
      prerelease:
        description: 'Mark the GitHub Release as prerelease.'
        type: boolean
        default: true
{{- else }}
  workflow_dispatch: {}
{{- end }}

jobs:
{{- if $c.release_signals.flutter_android }}
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@{{ $pin }}
    secrets: inherit
    with:
      version: {{`${{ inputs.version }}`}}
      create_release: true
      prerelease: {{`${{ inputs.prerelease }}`}}
      dart_define_secret_names: {{`${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}`}}
{{- else if eq (len $c.dockerfiles) 1 }}
```

(Everything from `{{- else if eq (len $c.dockerfiles) 1 }}` onward — the existing docker single/multi/noop arms — stays unchanged.)

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/shell/onboard-render.bats -f "manual prerelease"`
Expected: PASS (2 tests).

- [ ] **Step 5: Verify docker prerelease unchanged**

Run: `bats tests/shell/onboard-render.bats -f "prerelease.yml emits SK_SIGN"`
Expected: PASS (the existing docker prerelease test).

- [ ] **Step 6: Regenerate the flutter-app golden (prerelease.yml is now real)**

The `golden: flutter-app` test compares against `tests/fixtures/onboard/flutter-app/expected/`, whose `prerelease.yml` is the old noop. Regenerate it:

Run: `UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats -f "golden: flutter-app"`
Then verify the new expected `prerelease.yml` is the real job:

Run: `grep -q "release-flutter-android" tests/fixtures/onboard/flutter-app/expected/.github/workflows/prerelease.yml && ! grep -q noop tests/fixtures/onboard/flutter-app/expected/.github/workflows/prerelease.yml && echo OK`
Expected: `OK`

Then run the golden test for real:

Run: `bats tests/shell/onboard-render.bats -f "golden: flutter-app"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add docs/adopter-templates/skeletons/prerelease.yml.tmpl tests/shell/onboard-render.bats tests/fixtures/onboard/flutter-app/expected
git commit -m "feat(onboard): render flutter manual prerelease (replaces noop)"
```

---

## Task 3: New `prerelease-on-push.yml.tmpl` + conditional render plumbing

**Files:**
- Create: `docs/adopter-templates/skeletons/prerelease-on-push.yml.tmpl`
- Modify: `scripts/onboard-render.sh`
- Modify: `scripts/lib/onboard-detect-lib.sh` (`detect_legacy_ci` OWNED)

- [ ] **Step 1: Create the template**

`docs/adopter-templates/skeletons/prerelease-on-push.yml.tmpl`:

```gotemplate
{{- /*
  prerelease-on-push.yml — auto prerelease build on push to the dev branch.

  Rendered ONLY when the repo carries the `sk-prerelease-on-push` topic
  (onboard-render.sh decides; this template assumes it is being rendered).
  Stack-aware, mirroring prerelease.yml's per-stack build jobs. The trigger
  branch is baked (`develop`) — GitHub does not evaluate expressions in `on:`.
*/ -}}
{{- $pin := .pin -}}
{{- $c := index .profile.components 0 -}}
name: prerelease-on-push
on:
  push:
    branches: [develop]

jobs:
{{- if $c.release_signals.flutter_android }}
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/release-flutter-android.yml@{{ $pin }}
    secrets: inherit
    with:
      version: ''
      create_release: true
      prerelease: true
      dart_define_secret_names: {{`${{ vars.SK_FLUTTER_DART_DEFINE_SECRETS || '' }}`}}
{{- else if eq (len $c.dockerfiles) 1 }}
{{- $df := index $c.dockerfiles 0 }}
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@{{ $pin }}
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      artifact-metadata: write
      pull-requests: write
    secrets: inherit
    with:
      prerelease: true
      dockerfile: {{ $df.path }}
      image_name: {{ $df.image_name }}
      sign: {{`${{ fromJSON(vars.SK_SIGN || 'true') }}`}}
      attest: {{`${{ fromJSON(vars.SK_ATTEST || 'true') }}`}}
      sbom: {{`${{ fromJSON(vars.SK_SBOM || 'true') }}`}}
  scan:
    needs: build
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-image.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      packages: read
      actions: read
    secrets: inherit
    with:
      image_ref: {{`${{ needs.build.outputs.image_ref }}`}}
      severity: {{`${{ vars.SK_TRIVY_SEVERITY || 'HIGH,CRITICAL' }}`}}
      trivy_version: {{`${{ vars.SK_TRIVY_VERSION || '' }}`}}
{{- else if gt (len $c.dockerfiles) 1 -}}
{{- $images := coll.Slice -}}
{{- range $c.dockerfiles -}}
  {{- $images = coll.Append (coll.Dict "dockerfile" .path "image_name" .image_name) $images -}}
{{- end }}
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build-multi.yml@{{ $pin }}
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      artifact-metadata: write
      pull-requests: write
    secrets: inherit
    with:
      prerelease: true
      images: |
        {{ $images | toJSON }}
      sign: {{`${{ fromJSON(vars.SK_SIGN || 'true') }}`}}
      attest: {{`${{ fromJSON(vars.SK_ATTEST || 'true') }}`}}
      sbom: {{`${{ fromJSON(vars.SK_SBOM || 'true') }}`}}
{{- else }}
  # No prerelease-able artifact for this component.
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo "No on-push prerelease artifacts for this repo."
{{- end }}
```

- [ ] **Step 2: Add `prerelease-on-push.yml` to the OWNED filenames**

In `scripts/lib/onboard-detect-lib.sh`, `detect_legacy_ci` has:

```bash
  local OWNED=(ci.yml release.yml prerelease.yml cleanup.yml)
```

Change to:

```bash
  local OWNED=(ci.yml release.yml prerelease.yml prerelease-on-push.yml cleanup.yml)
```

- [ ] **Step 3: Conditionally render in `onboard-render.sh`**

In `scripts/onboard-render.sh`, after the four fixed skeleton renders:

```bash
render "$SKELETONS/ci.yml.tmpl"         "$TARGET/.github/workflows/ci.yml"
render "$SKELETONS/release.yml.tmpl"    "$TARGET/.github/workflows/release.yml"
render "$SKELETONS/prerelease.yml.tmpl" "$TARGET/.github/workflows/prerelease.yml"
render "$SKELETONS/cleanup.yml.tmpl"    "$TARGET/.github/workflows/cleanup.yml"
```

insert:

```bash
# prerelease-on-push.yml — opt-in: rendered only when the repo carries the
# `sk-prerelease-on-push` topic. Tracked in the lock + $REPO loop below only
# when actually rendered.
RENDER_ON_PUSH=0
if jq -e '(.topics // []) | index("sk-prerelease-on-push")' "$PROFILE" >/dev/null 2>&1; then
  render "$SKELETONS/prerelease-on-push.yml.tmpl" "$TARGET/.github/workflows/prerelease-on-push.yml"
  RENDER_ON_PUSH=1
fi
```

- [ ] **Step 4: Include it in the `$REPO`-substitution loop**

The loop currently reads:

```bash
for f in "$TARGET/.github/workflows/release.yml" "$TARGET/.github/workflows/prerelease.yml"; do
```

Change to (the existing `[[ -f "$f" ]]` guard skips it when not rendered):

```bash
for f in "$TARGET/.github/workflows/release.yml" "$TARGET/.github/workflows/prerelease.yml" "$TARGET/.github/workflows/prerelease-on-push.yml"; do
```

- [ ] **Step 5: Conditionally add it to the lock `RENDERED` list**

The `RENDERED` array currently reads:

```bash
RENDERED=(
  ".github/workflows/ci.yml"
  ".github/workflows/release.yml"
  ".github/workflows/prerelease.yml"
  ".github/workflows/cleanup.yml"
  "release-please-config.json"
  ".release-please-manifest.json"
)
```

Immediately after the closing `)`, append:

```bash
if [[ "$RENDER_ON_PUSH" == "1" ]]; then
  RENDERED+=(".github/workflows/prerelease-on-push.yml")
fi
```

- [ ] **Step 6: Sanity-check render (no topic → no file; topic → file)**

Run:
```bash
tmp=$(mktemp -d)
printf '%s' '{"schema_version":1,"target_repo":"serverkraken/app","default_branch":"main","current_version":"0.1.0","monorepo":false,"components":[{"path":".","languages":["flutter"],"primary_language":"flutter","release_please_type":"dart","role":"mobile-app","dockerfiles":[],"release_signals":{"goreleaser_config":null,"chart_yaml":null,"flutter_android":true}}],"legacy_ci":[],"topics":[],"warnings":[]}' > "$tmp/p.json"
bash scripts/onboard-render.sh . "$tmp" "$tmp/p.json" v4 >/dev/null
test ! -f "$tmp/.github/workflows/prerelease-on-push.yml" && echo "no-topic: absent OK"
printf '%s' '{"schema_version":1,"target_repo":"serverkraken/app","default_branch":"main","current_version":"0.1.0","monorepo":false,"components":[{"path":".","languages":["flutter"],"primary_language":"flutter","release_please_type":"dart","role":"mobile-app","dockerfiles":[],"release_signals":{"goreleaser_config":null,"chart_yaml":null,"flutter_android":true}}],"legacy_ci":[],"topics":["sk-prerelease-on-push"],"warnings":[]}' > "$tmp/p.json"
bash scripts/onboard-render.sh . "$tmp" "$tmp/p.json" v4 >/dev/null
test -f "$tmp/.github/workflows/prerelease-on-push.yml" && echo "topic: present OK"
jq -e '.files["'.github/workflows/prerelease-on-push.yml'"]' "$tmp/.github/onboard.lock.json" >/dev/null && echo "lock: tracked OK"
rm -rf "$tmp"
```
Expected: `no-topic: absent OK`, `topic: present OK`, `lock: tracked OK`.

- [ ] **Step 7: Commit**

```bash
git add docs/adopter-templates/skeletons/prerelease-on-push.yml.tmpl scripts/onboard-render.sh scripts/lib/onboard-detect-lib.sh
git commit -m "feat(onboard): conditionally render prerelease-on-push caller (opt-in topic)"
```

---

## Task 4: Render tests for `prerelease-on-push.yml`

**Files:**
- Test: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Add a target-dir render helper + tests**

Append to `tests/shell/onboard-render.bats`:

```bash
# === prerelease-on-push.yml (opt-in topic) ===

# Render the full set for an inline profile; echo the target dir.
render_target_for_profile() {
  local profile="$1"
  local target="$BATS_TEST_TMPDIR/render-onpush-$$"
  rm -rf "$target"; mkdir -p "$target"
  printf '%s' "$profile" > "$target/_profile.json"
  "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$target/_profile.json" "v4" >&2
  echo "$target"
}

@test "prerelease-on-push.yml is rendered + locked when topic present (flutter)" {
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  [ -f "$tgt/.github/workflows/prerelease-on-push.yml" ]
  grep -qF "on:" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "branches: [develop]" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "release-flutter-android.yml@v4" "$tgt/.github/workflows/prerelease-on-push.yml"
  jq -e '.files[".github/workflows/prerelease-on-push.yml"]' "$tgt/.github/onboard.lock.json"
}

@test "prerelease-on-push.yml is NOT rendered when topic absent" {
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": [], "warnings": []
  }')
  [ ! -f "$tgt/.github/workflows/prerelease-on-push.yml" ]
  ! jq -e '.files[".github/workflows/prerelease-on-push.yml"]' "$tgt/.github/onboard.lock.json"
}

@test "prerelease-on-push.yml docker variant builds prerelease image" {
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": false}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  [ -f "$tgt/.github/workflows/prerelease-on-push.yml" ]
  grep -qF "docker-build.yml@v4" "$tgt/.github/workflows/prerelease-on-push.yml"
  grep -qF "prerelease: true" "$tgt/.github/workflows/prerelease-on-push.yml"
}
```

- [ ] **Step 2: Run to verify they pass**

Run: `bats tests/shell/onboard-render.bats -f "prerelease-on-push"`
Expected: PASS (3 tests). (The template + plumbing from Task 3 are already in place.)

- [ ] **Step 3: Full render suite (no regressions — existing golden trees lack the topic so the optional file stays absent)**

Run: `bats tests/shell/onboard-render.bats`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add tests/shell/onboard-render.bats
git commit -m "test(onboard): cover prerelease-on-push render + lock gating"
```

---

## Task 5: Integration — actionlint + yamllint on rendered prerelease files

**Files:**
- Test: `tests/shell/onboard-render.bats`

- [ ] **Step 1: Add the integration test**

Append to `tests/shell/onboard-render.bats`:

```bash
@test "integration: rendered prerelease + prerelease-on-push pass actionlint and yamllint" {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint not installed"
  command -v yamllint  >/dev/null 2>&1 || skip "yamllint not installed"
  tgt=$(render_target_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/app",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["flutter"], "primary_language": "flutter",
      "release_please_type": "dart", "role": "mobile-app", "dockerfiles": [],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null, "flutter_android": true}}],
    "legacy_ci": [], "topics": ["sk-prerelease-on-push"], "warnings": []
  }')
  yamllint -d relaxed "$tgt/.github/workflows/prerelease.yml" "$tgt/.github/workflows/prerelease-on-push.yml"
  actionlint "$tgt/.github/workflows/prerelease.yml" "$tgt/.github/workflows/prerelease-on-push.yml"
}
```

- [ ] **Step 2: Run it**

Run: `bats tests/shell/onboard-render.bats -f "integration: rendered prerelease"`
Expected: PASS (or SKIP if the tools aren't installed locally; it runs for real in self-CI). If actionlint flags a real problem in either rendered file, fix the template and re-run.

- [ ] **Step 3: Commit**

```bash
git add tests/shell/onboard-render.bats
git commit -m "test(onboard): integration lint of rendered prerelease workflows"
```

---

## Task 6: Document the callers in `docs/operations.md`

**Files:**
- Modify: `docs/operations.md`

- [ ] **Step 1: Update the prerelease description**

Find the existing sentence (≈ line 403) that reads:

```markdown
By default, `release.yml` ships **only the bare `Dockerfile` (or `Containerfile`)** to GHCR on release-please-driven releases. Any `Dockerfile.*` / `Containerfile.*` variant (e.g. `Dockerfile.dev`, `Dockerfile.debug`) is **excluded** from release builds and only ships via the manual `prerelease.yml` workflow_dispatch path.
```

Immediately after that paragraph, add:

```markdown
**Prerelease callers (stack-aware).** The renderer emits up to two prerelease workflows:

- `prerelease.yml` — **manual** (`workflow_dispatch`). For docker components it builds a prerelease image (+ trivy scan). For a Flutter app it calls `release-flutter-android` with `create_release: true` and `workflow_dispatch` inputs `version` (empty → auto `<latest>-rc.<run_number>`) and `prerelease` (default `true`); dart-defines come from `vars.SK_FLUTTER_DART_DEFINE_SECRETS`. A Flutter package (no `android/`) renders a no-op.
- `prerelease-on-push.yml` — **automatic** on push to `develop`. Rendered **only** when the repo carries the `sk-prerelease-on-push` topic. Same stack-aware build jobs as `prerelease.yml`, with no manual inputs (Flutter uses the auto-rc version). The trigger branch is baked at render time (`develop`) because GitHub does not evaluate expressions in `on:`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): document manual + auto-on-push prerelease callers"
```

---

## Task 7: Full-suite verification + wrap-up

**Files:** none (verification only)

- [ ] **Step 1: Run the full detect + render suites**

Run: `bats tests/shell/onboard-detect.bats tests/shell/onboard-render.bats`
Expected: all pass (no regressions; the optional file stays absent for every non-topic fixture).

- [ ] **Step 2: Shellcheck the modified scripts**

Run: `shellcheck scripts/onboard-render.sh scripts/lib/onboard-detect-lib.sh`
Expected: clean (only the pre-existing SC1091 info on the relative `source`).

- [ ] **Step 3: Acceptance check against the real fixture**

Run:
```bash
scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/flutter-app | jq -c '{topics, fa: .components[0].release_signals.flutter_android}'
```
Expected: `{"topics":[],"fa":true}` (local mode → no topics; flutter app).

And confirm the rendered manual prerelease for that fixture is the real job:
```bash
grep -q release-flutter-android tests/fixtures/onboard/flutter-app/expected/.github/workflows/prerelease.yml && echo "manual prerelease OK"
```
Expected: `manual prerelease OK`

- [ ] **Step 4: Tick the plan checkboxes and proceed to review/PR** per `superpowers:subagent-driven-development` (two-stage review: spec-reviewer then `feature-dev:code-reviewer`), then open the PR with a multi-line body. PR title: `feat(onboard): render manual + auto-on-push prerelease callers` (no attribution footer, per project convention).

---

## Self-Review

**Spec coverage:**
- Detection `topics` array → Task 1. ✓
- `prerelease.yml` Flutter branch (replaces noop; package keeps noop; docker unchanged) → Task 2. ✓
- New `prerelease-on-push.yml.tmpl` (stack-aware, `on: push: [develop]`) → Task 3 Step 1. ✓
- Conditional render + lock + `$REPO` loop → Task 3 Steps 3-5. ✓
- `OWNED += prerelease-on-push.yml` → Task 3 Step 2. ✓
- bats detect (topics) + render (manual flutter, on-push gating, docker variant) → Tasks 1, 2, 4. ✓
- golden regen for flutter-app → Task 2 Step 6. ✓
- integration actionlint/yamllint → Task 5. ✓
- operations.md docs → Task 6. ✓
- Acceptance criteria → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every step shows exact content/commands.

**Type/name consistency:** `topics` (profile field) consistent across detection (Task 1), render gate `jq '.topics | index(...)'` (Task 3), and all test profiles. Topic string `sk-prerelease-on-push` consistent (Tasks 3/4). `release_signals.flutter_android` gate consistent (Tasks 2/3). `RENDER_ON_PUSH` defined + used in Task 3. Helper `render_target_for_profile` defined in Task 4 Step 1 before use. Filename `prerelease-on-push.yml` consistent (OWNED, render, lock, tests, docs).

**Note on gh safety:** Task 1 Step 3 uses the `$(...) || topics='[]'` pattern (fallback outside the substitution) deliberately — `gh api` leaks its error body to stdout on failure, so the `|| echo` idiom would corrupt the value (see the gh-api-leaks-error-body-to-stdout troubleshooting note / catalog 4.5.1).
