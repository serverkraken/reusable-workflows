# Release-Eligibility + Sign/Attest/SBOM Overrides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Filter rendered `release.yml`'s docker-build call to release-eligible Dockerfiles only (default: only the bare `Dockerfile`/`Containerfile`); detect Containerfile variants alongside Dockerfile; add `SK_SIGN`/`SK_ATTEST`/`SK_SBOM` repo-variable overrides for the three security toggles.

**Architecture:** Detection emits per-Dockerfile `release_eligible` boolean derived from filename convention + `# onboard:release=true|false` header annotation. `release.yml.tmpl` filters the docker-build emit to release-eligible only; `prerelease.yml.tmpl` keeps the full list. Both templates emit `fromJSON()`-wrapped `vars.SK_SIGN/ATTEST/SBOM` expressions threaded into the docker-build / docker-build-multi atom inputs.

**Tech Stack:** bash + jq (detection), gomplate (templating), bats (tests), GitHub Actions (workflow_call atoms).

**Spec:** `docs/superpowers/specs/2026-05-21-release-eligibility-design.md`

**Branch:** `feat/release-eligibility` (worktree at `.worktrees/release-eligibility/`)

---

## File Structure

**Modified:**
- `scripts/lib/onboard-detect-lib.sh` — `read_release_override` (new fn), `inventory_dockerfiles` (Containerfile patterns + `release_eligible` field + warning emit), `derive_image_name` (Containerfile arms)
- `docs/adopter-templates/skeletons/release.yml.tmpl` — release-eligible filter + SK_SIGN/SK_ATTEST/SK_SBOM
- `docs/adopter-templates/skeletons/prerelease.yml.tmpl` — SK_SIGN/SK_ATTEST/SK_SBOM (no filter)
- `tests/shell/onboard-detect.bats` — new assertions for release_eligible + Containerfile
- `tests/shell/onboard-render.bats` — inline assertions for filter + SK vars
- `tests/shell/template-defaults.bats` — three new tests for SK_SIGN/SK_ATTEST/SK_SBOM
- All 8 existing `tests/fixtures/onboard/*/expected/` ci/release/prerelease.yml regen (filter changes docker-build emit)
- `docs/operations.md` — extend Knob Registry with the three new vars

**Created:**
- `tests/fixtures/onboard/release-eligibility-mixed/` — Dockerfile + Dockerfile.dev + Dockerfile.worker (with `# onboard:release=true` header)
- `tests/fixtures/onboard/containerfile-only/` — `Containerfile` instead of `Dockerfile`

---

## Phase 1: Detection — Containerfile patterns + release_eligible flag

### Task 1: Add `read_release_override` to onboard-detect-lib.sh

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` — append new function below `read_image_override` (around line 347).

- [ ] **Step 1: Write the failing bats test**

Append to `tests/shell/onboard-detect.bats`:

```bash
@test "read_release_override reads true from header" {
  tmpfile=$(mktemp)
  printf '%s\n' '# Dockerfile' '# onboard:release=true' 'FROM alpine' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ "$result" = "true" ]
}

@test "read_release_override reads false from header" {
  tmpfile=$(mktemp)
  printf '%s\n' '# Dockerfile' '# onboard:release=false' 'FROM alpine' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ "$result" = "false" ]
}

@test "read_release_override emits empty when annotation absent" {
  tmpfile=$(mktemp)
  printf '%s\n' 'FROM alpine' 'RUN echo hi' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ -z "$result" ]
}

@test "read_release_override ignores annotation beyond line 5" {
  tmpfile=$(mktemp)
  printf '%s\n' '1' '2' '3' '4' '5' '# onboard:release=true' 'FROM alpine' > "$tmpfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(read_release_override "$tmpfile")
  rm -f "$tmpfile"
  [ -z "$result" ]
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/release-eligibility
bats tests/shell/onboard-detect.bats --filter "read_release_override"
```

Expected: 4 tests fail with `command not found: read_release_override`.

- [ ] **Step 3: Implement `read_release_override`**

Add after `read_image_override` in `scripts/lib/onboard-detect-lib.sh`:

```bash
# Read `# onboard:release=true` or `# onboard:release=false` override from
# the first 5 lines of a Dockerfile. Emits "true", "false", or empty.
# Signature: read_release_override <file-path>
read_release_override() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return; }
  head -n 5 "$file" 2>/dev/null \
    | grep -m1 -oE '^# onboard:release=(true|false)' \
    | sed 's/^# onboard:release=//' || true
}
```

- [ ] **Step 4: Run to verify pass**

```bash
bats tests/shell/onboard-detect.bats --filter "read_release_override"
```

Expected: 4/4 ok.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): add read_release_override for # onboard:release= header"
```

### Task 2: Extend `inventory_dockerfiles` with Containerfile patterns + release_eligible

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` lines 300-336 (`inventory_dockerfiles`).

- [ ] **Step 1: Write failing bats tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
@test "inventory_dockerfiles detects Containerfile alongside Dockerfile" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Containerfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].path == "Containerfile"'
}

@test "inventory_dockerfiles classifies Dockerfile release_eligible=true by default" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == true'
}

@test "inventory_dockerfiles classifies Dockerfile.dev release_eligible=false by default" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile.dev"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == false'
}

@test "inventory_dockerfiles honors release=true override on Dockerfile.*" {
  tmpdir=$(mktemp -d)
  printf '%s\n' '# onboard:release=true' 'FROM alpine' > "$tmpdir/Dockerfile.worker"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == true'
}

@test "inventory_dockerfiles honors release=false override on Dockerfile" {
  tmpdir=$(mktemp -d)
  printf '%s\n' '# onboard:release=false' 'FROM alpine' > "$tmpdir/Dockerfile"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == false'
}

@test "inventory_dockerfiles classifies Containerfile.dev release_eligible=false" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Containerfile.dev"
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(inventory_dockerfiles "$tmpdir" ".")
  rm -rf "$tmpdir"
  echo "$result" | jq -e '.[0].release_eligible == false'
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
bats tests/shell/onboard-detect.bats --filter "inventory_dockerfiles"
```

Expected: at least the Containerfile + release_eligible tests fail (the field doesn't exist yet; Containerfile pattern not matched).

- [ ] **Step 3: Update `inventory_dockerfiles` find pattern + emit release_eligible**

In `scripts/lib/onboard-detect-lib.sh`, replace the function body (around lines 301-336):

```bash
inventory_dockerfiles() {
  local repo="$1" path="$2"
  local p="$repo/$path"
  [[ -d "$p" ]] || { echo '[]'; return; }

  # Collect Dockerfile + Containerfile names at component root only.
  local files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$(basename "$f")")
  done < <(find "$p" -maxdepth 1 -type f \( \
             -name 'Dockerfile' -o -name 'Dockerfile.*' \
             -o -name 'Containerfile' -o -name 'Containerfile.*' \
           \) 2>/dev/null | sort || true)

  if (( ${#files[@]} == 0 )); then
    echo '[]'; return
  fi

  local arr='[]'
  local fname
  for fname in "${files[@]}"; do
    local override image_name image_name_source release_override release_eligible
    override=$(read_image_override "$p/$fname")
    if [[ -n "$override" ]]; then
      image_name="$override"
      image_name_source="override"
    else
      image_name=$(derive_image_name "$fname" "$path")
      image_name_source="derived"
    fi
    # release-eligibility: bare `Dockerfile`/`Containerfile` default true,
    # any `*.<suffix>` default false. Header override wins.
    if [[ "$fname" == "Dockerfile" || "$fname" == "Containerfile" ]]; then
      release_eligible="true"
    else
      release_eligible="false"
    fi
    release_override=$(read_release_override "$p/$fname")
    if [[ -n "$release_override" ]]; then
      release_eligible="$release_override"
    fi
    arr=$(echo "$arr" | jq \
      --arg path "$fname" \
      --arg image_name "$image_name" \
      --arg image_name_source "$image_name_source" \
      --argjson release_eligible "$release_eligible" \
      '. + [{
        path: $path,
        image_name: $image_name,
        image_name_source: $image_name_source,
        release_eligible: $release_eligible
      }]')
  done
  echo "$arr"
}
```

- [ ] **Step 4: Run to verify pass**

```bash
bats tests/shell/onboard-detect.bats --filter "inventory_dockerfiles"
```

Expected: 6/6 new tests ok. (Existing inventory_dockerfiles tests should also still pass; if they fail with `release_eligible` missing, those tests need updating in Task 3.)

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): Containerfile detection + release_eligible field"
```

### Task 3: Extend `derive_image_name` with Containerfile arms

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` lines 356-378 (`derive_image_name`).

- [ ] **Step 1: Write failing bats tests**

Append to `tests/shell/onboard-detect.bats`:

```bash
@test "derive_image_name handles Containerfile root case" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(derive_image_name "Containerfile" ".")
  [ "$result" = "\$REPO" ]
}

@test "derive_image_name handles Containerfile.suffix" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(derive_image_name "Containerfile.worker" ".")
  [ "$result" = "\$REPO-worker" ]
}

@test "derive_image_name handles Containerfile in subpath" {
  source "$BATS_TEST_DIRNAME/../../scripts/lib/onboard-detect-lib.sh"
  result=$(derive_image_name "Containerfile.worker" "services/api")
  [ "$result" = "\$REPO-api-worker" ]
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
bats tests/shell/onboard-detect.bats --filter "derive_image_name handles Containerfile"
```

Expected: tests fail because the function only matches `Dockerfile`/`Dockerfile.*`.

- [ ] **Step 3: Extend `derive_image_name` filename regex**

Replace the filename-matching block in `derive_image_name`:

```bash
derive_image_name() {
  local filename="$1" cpath="$2"
  local suffix=""
  if [[ "$filename" == "Dockerfile" || "$filename" == "Containerfile" ]]; then
    suffix=""
  elif [[ "$filename" =~ ^(Dockerfile|Containerfile)\.(.+)$ ]]; then
    suffix="${BASH_REMATCH[2]}"
  fi

  local seg=""
  if [[ "$cpath" != "." ]]; then
    seg="${cpath##*/}"
  fi

  if [[ -n "$seg" && -n "$suffix" ]]; then
    echo "\$REPO-${seg}-${suffix}"
  elif [[ -n "$seg" ]]; then
    echo "\$REPO-${seg}"
  elif [[ -n "$suffix" ]]; then
    echo "\$REPO-${suffix}"
  else
    echo "\$REPO"
  fi
}
```

- [ ] **Step 4: Run to verify pass**

```bash
bats tests/shell/onboard-detect.bats
```

Expected: all tests pass including the 3 new derive_image_name + Containerfile tests.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): derive_image_name handles Containerfile + Containerfile.suffix"
```

### Task 4: Emit `no_release_eligible` warning when component has Dockerfiles but none are eligible

**Files:**
- Modify: `scripts/lib/onboard-detect-lib.sh` — find the warnings emission block (search for `no_lint_test_atom`).

- [ ] **Step 1: Locate the warnings block**

```bash
rg -n "no_lint_test_atom" scripts/lib/onboard-detect-lib.sh
```

Note: should be in `emit_unsupported_language_warnings` or similar. If the warning is currently a one-off pattern rather than a generic warnings helper, follow that same one-off pattern.

- [ ] **Step 2: Write failing bats test**

Append to `tests/shell/onboard-detect.bats`:

```bash
@test "profile-json: warns when component has Dockerfiles but none release-eligible" {
  tmpdir=$(mktemp -d)
  : > "$tmpdir/Dockerfile.dev"
  : > "$tmpdir/Dockerfile.debug"
  run "$DETECT" --profile-json "$tmpdir"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.warnings[] | select(.type == "no_release_eligible")'
}
```

- [ ] **Step 3: Run to confirm failure**

```bash
bats tests/shell/onboard-detect.bats --filter "no_release_eligible"
```

Expected: fail (warning not emitted).

- [ ] **Step 4: Implement the warning**

Where component-level warnings are emitted in `onboard-detect-lib.sh`, add (adjusting jq path / variable names to match the actual codebase pattern — read the existing `no_lint_test_atom` flow and follow its shape exactly):

```bash
# Warn when a component has dockerfiles but none release-eligible — the
# rendered release.yml will skip the docker-build job entirely, which may
# be a surprise. Adopters opt-in via `# onboard:release=true` header on
# the dockerfile they want shipped.
emit_no_release_eligible_warnings() {
  local components_json="$1"  # the components array from the profile builder
  echo "$components_json" | jq '
    map(
      select(
        (.dockerfiles | length > 0) and
        ([.dockerfiles[] | select(.release_eligible)] | length == 0)
      )
      | {type: "no_release_eligible", path: .path,
         message: ("component at " + .path + " has " + ((.dockerfiles | length) | tostring) +
                   " Dockerfiles but none are release-eligible; rendered release.yml will skip docker-build. Set `# onboard:release=true` on the dockerfile(s) to ship.")}
    )
  '
}
```

And invoke it where `no_lint_test_atom` warnings are added to the profile's `warnings` array, appending the output of `emit_no_release_eligible_warnings` to the same warnings array.

- [ ] **Step 5: Run to verify pass**

```bash
bats tests/shell/onboard-detect.bats --filter "no_release_eligible"
```

Expected: ok.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/onboard-detect-lib.sh tests/shell/onboard-detect.bats
git commit -m "feat(onboard): warn when component has Dockerfiles but none release-eligible"
```

---

## Phase 2: Template-Rendering — `release.yml.tmpl`

### Task 5: Filter dockerfiles to release-eligible in release.yml.tmpl

**Files:**
- Modify: `docs/adopter-templates/skeletons/release.yml.tmpl` lines ~37-79

- [ ] **Step 1: Read current Go template logic**

Open `docs/adopter-templates/skeletons/release.yml.tmpl`. The relevant block is the per-component dockerfile branching:

```
{{- if eq (len $c.dockerfiles) 1 }}
{{- $df := index $c.dockerfiles 0 }}
  docker-build{{ $suffix }}:
    ...
{{- else if gt (len $c.dockerfiles) 1 -}}
{{- $images := coll.Slice -}}
{{- range $c.dockerfiles -}}
  {{- $images = coll.Append (coll.Dict "dockerfile" .path "image_name" .image_name) $images -}}
{{- end }}
  docker-build{{ $suffix }}:
    ...
{{- end }}
```

- [ ] **Step 2: Replace with filtered version**

Replace the dockerfile-branching block above with this, which first computes `$releaseDfs` then branches on `len($releaseDfs)`:

```
{{- /* Filter to release-eligible Dockerfiles only — non-eligible variants (Dockerfile.dev, Dockerfile.debug, …) ship in prerelease.yml only. */ -}}
{{- $releaseDfs := coll.Slice -}}
{{- range $c.dockerfiles -}}
  {{- if .release_eligible -}}
    {{- $releaseDfs = coll.Append . $releaseDfs -}}
  {{- end -}}
{{- end -}}

{{- if eq (len $releaseDfs) 1 }}
{{- $df := index $releaseDfs 0 }}
  docker-build{{ $suffix }}:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@{{ $pin }}
    with:
    {{- if not $isRoot }}
      context: {{ $ctxPath }}
      dockerfile: {{ $ctxPath }}/{{ $df.path }}
    {{- else }}
      dockerfile: {{ $df.path }}
    {{- end }}
      image_name: {{ $df.image_name }}
      tag: {{`${{ needs.release-please.outputs.tag_name }}`}}
    secrets: inherit
{{- else if gt (len $releaseDfs) 1 -}}
{{- $images := coll.Slice -}}
{{- range $releaseDfs -}}
  {{- $images = coll.Append (coll.Dict "dockerfile" .path "image_name" .image_name) $images -}}
{{- end }}
  docker-build{{ $suffix }}:
    needs: [release-please]
    if: needs.release-please.outputs.release_created == 'true'
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build-multi.yml@{{ $pin }}
    with:
    {{- if not $isRoot }}
      context: {{ $ctxPath }}
    {{- end }}
      images: |
        {{ $images | toJSON }}
      tag: {{`${{ needs.release-please.outputs.tag_name }}`}}
    secrets: inherit
{{- end }}
```

(The SK_SIGN/SK_ATTEST/SK_SBOM additions come in Task 6 — keep this task focused on the filter.)

- [ ] **Step 3: Regenerate per-fixture goldens**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/release-eligibility
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
```

Expected: every `golden:` test reports `# skip UPDATE_GOLDEN — rewrote <fixture>/expected`. No `not ok` lines.

- [ ] **Step 4: Spot-check `multi-dockerfile` golden release.yml**

```bash
cat tests/fixtures/onboard/multi-dockerfile/expected/.github/workflows/release.yml | rg "image_name|images" | head
```

Expected: contains only the bare `Dockerfile` entry (no `Dockerfile.worker` unless that fixture's worker file has `# onboard:release=true`). Compare against the current state before this task — `Dockerfile.worker` should be GONE from release.yml.

If multi-dockerfile DID previously test the worker-included-in-release path, the fixture itself should be updated in Task 7 (new fixture for that scenario). Don't worry about the existing fixture losing the worker — that's the intentional behavior change.

- [ ] **Step 5: Re-run bats clean**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all `golden:` tests now `ok`. Inline tests still pass.

- [ ] **Step 6: Commit**

```bash
git add docs/adopter-templates/skeletons/release.yml.tmpl tests/fixtures/onboard
git commit -m "feat(onboard): filter release.yml docker-build to release-eligible Dockerfiles only"
```

### Task 6: Add SK_SIGN/SK_ATTEST/SK_SBOM to release.yml.tmpl

**Files:**
- Modify: `docs/adopter-templates/skeletons/release.yml.tmpl` (same docker-build / docker-build-multi blocks)

- [ ] **Step 1: Add the three SK_* lines to the single-call branch**

In the `{{- if eq (len $releaseDfs) 1 }}` branch's `with:` block, after the existing `tag:` line and before `secrets: inherit`, add:

```
      sign: {{`${{ fromJSON(vars.SK_SIGN || 'true') }}`}}
      attest: {{`${{ fromJSON(vars.SK_ATTEST || 'true') }}`}}
      sbom: {{`${{ fromJSON(vars.SK_SBOM || 'true') }}`}}
```

- [ ] **Step 2: Add same to the multi-call branch**

In the `{{- else if gt (len $releaseDfs) 1 -}}` branch's `with:` block (after the `tag:` line and before `secrets: inherit`), add the identical three lines.

- [ ] **Step 3: Add inline bats assertions**

Append to `tests/shell/onboard-render.bats` (after the existing SK_*-related Go test):

```bash
@test "release.yml emits SK_SIGN/SK_ATTEST/SK_SBOM expressions on single-Dockerfile case" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "sign: \${{ fromJSON(vars.SK_SIGN || 'true') }}" "$rendered"
  grep -qF "attest: \${{ fromJSON(vars.SK_ATTEST || 'true') }}" "$rendered"
  grep -qF "sbom: \${{ fromJSON(vars.SK_SBOM || 'true') }}" "$rendered"
}

@test "release.yml emits SK_*  on multi-Dockerfile case" {
  rendered=$(render_release_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [
        {"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true},
        {"path":"Dockerfile.worker","image_name":"serverkraken/svc-worker","image_name_source":"derived","release_eligible":true}
      ],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "sign: \${{ fromJSON(vars.SK_SIGN || 'true') }}" "$rendered"
  grep -qF "attest: \${{ fromJSON(vars.SK_ATTEST || 'true') }}" "$rendered"
  grep -qF "sbom: \${{ fromJSON(vars.SK_SBOM || 'true') }}" "$rendered"
}
```

These tests use `render_release_for_profile` — a helper that may not exist yet. If `tests/shell/onboard-render.bats` only has `render_ci_for_profile`, add a sibling helper that renders just `release.yml` from the same gomplate context. Pattern: mirror the existing `render_ci_for_profile` body but point at `release.yml.tmpl` and output `release.yml` instead.

- [ ] **Step 4: Add render_release_for_profile helper if absent**

Search for the existing helper:

```bash
rg -n "render_ci_for_profile" tests/shell/onboard-render.bats | head
```

If only `render_ci_for_profile` exists, add this sibling just below it (replace `ci` with `release` in path strings):

```bash
render_release_for_profile() {
  local profile="$1"
  local target
  target=$(mktemp -d)
  printf '%s' "$profile" > "$target/_profile.json"
  "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$target/_profile.json" "v3" >&2
  echo "$target/.github/workflows/release.yml"
}
```

- [ ] **Step 5: Regenerate goldens**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
```

- [ ] **Step 6: Re-run bats verifying clean**

```bash
bats tests/shell/onboard-render.bats
```

Expected: all green, the two new SK_*-on-release tests pass.

- [ ] **Step 7: Commit**

```bash
git add docs/adopter-templates/skeletons/release.yml.tmpl tests/fixtures/onboard tests/shell/onboard-render.bats
git commit -m "feat(onboard): SK_SIGN+SK_ATTEST+SK_SBOM threaded into adopter release.yml"
```

---

## Phase 3: Template-Rendering — `prerelease.yml.tmpl`

### Task 7: Add SK_SIGN/SK_ATTEST/SK_SBOM to prerelease.yml.tmpl (no filter)

**Files:**
- Modify: `docs/adopter-templates/skeletons/prerelease.yml.tmpl` (both single and multi branches)

- [ ] **Step 1: Locate the `build:` job**

The prerelease.yml.tmpl has two branches based on `len $c.dockerfiles`:
- `eq (len $c.dockerfiles) 1` → calls `docker-build.yml`
- `gt (len $c.dockerfiles) 1` → calls `docker-build-multi.yml`

`prerelease.yml.tmpl` does NOT filter on release_eligible — keeps all dockerfiles.

- [ ] **Step 2: Add SK_* in single-call branch**

In the `build:` job's `with:` block, after the existing `image_name:` line and before the end of `with:`:

```
      sign: {{`${{ fromJSON(vars.SK_SIGN || 'true') }}`}}
      attest: {{`${{ fromJSON(vars.SK_ATTEST || 'true') }}`}}
      sbom: {{`${{ fromJSON(vars.SK_SBOM || 'true') }}`}}
```

- [ ] **Step 3: Add SK_* in multi-call branch**

In the `gt (len ...) 1` branch's `build:` job, after the existing `images: |` block and before the end of `with:`:

```
      sign: {{`${{ fromJSON(vars.SK_SIGN || 'true') }}`}}
      attest: {{`${{ fromJSON(vars.SK_ATTEST || 'true') }}`}}
      sbom: {{`${{ fromJSON(vars.SK_SBOM || 'true') }}`}}
```

- [ ] **Step 4: Append inline bats assertion**

Add to `tests/shell/onboard-render.bats`:

```bash
@test "prerelease.yml emits SK_SIGN/SK_ATTEST/SK_SBOM expressions" {
  # Need a profile with at least one dockerfile (single-build branch).
  rendered=$(render_prerelease_for_profile '{
    "schema_version": 1, "target_repo": "serverkraken/svc",
    "default_branch": "main", "current_version": "0.1.0", "monorepo": false,
    "components": [{"path": ".", "languages": ["go"], "primary_language": "go",
      "release_please_type": "go", "role": "service",
      "dockerfiles": [{"path":"Dockerfile","image_name":"serverkraken/svc","image_name_source":"derived","release_eligible":true}],
      "release_signals": {"goreleaser_config": null, "chart_yaml": null}}],
    "legacy_ci": [], "warnings": []
  }')
  grep -qF "sign: \${{ fromJSON(vars.SK_SIGN || 'true') }}" "$rendered"
  grep -qF "attest: \${{ fromJSON(vars.SK_ATTEST || 'true') }}" "$rendered"
  grep -qF "sbom: \${{ fromJSON(vars.SK_SBOM || 'true') }}" "$rendered"
}
```

Add the `render_prerelease_for_profile` helper alongside `render_release_for_profile`:

```bash
render_prerelease_for_profile() {
  local profile="$1"
  local target
  target=$(mktemp -d)
  printf '%s' "$profile" > "$target/_profile.json"
  "$BATS_TEST_DIRNAME/../../scripts/onboard-render.sh" \
    "$BATS_TEST_DIRNAME/../.." "$target" "$target/_profile.json" "v3" >&2
  echo "$target/.github/workflows/prerelease.yml"
}
```

- [ ] **Step 5: Regenerate goldens + verify**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats
bats tests/shell/onboard-render.bats
```

Expected: clean re-run, all green.

- [ ] **Step 6: Commit**

```bash
git add docs/adopter-templates/skeletons/prerelease.yml.tmpl tests/fixtures/onboard tests/shell/onboard-render.bats
git commit -m "feat(onboard): SK_SIGN+SK_ATTEST+SK_SBOM threaded into adopter prerelease.yml"
```

---

## Phase 4: New test fixtures

### Task 8: Add `release-eligibility-mixed` fixture

**Files:**
- Create: `tests/fixtures/onboard/release-eligibility-mixed/Dockerfile`
- Create: `tests/fixtures/onboard/release-eligibility-mixed/Dockerfile.dev`
- Create: `tests/fixtures/onboard/release-eligibility-mixed/Dockerfile.worker`
- Create: `tests/fixtures/onboard/release-eligibility-mixed/go.mod` (so detect classifies as Go)
- Create: `tests/fixtures/onboard/release-eligibility-mixed/main.go` (matches Go fixture pattern)

- [ ] **Step 1: Write fixture files**

```bash
mkdir -p tests/fixtures/onboard/release-eligibility-mixed
cat > tests/fixtures/onboard/release-eligibility-mixed/Dockerfile <<'EOF'
# Dockerfile — production image, default release-eligible.
FROM alpine:3.19
EOF

cat > tests/fixtures/onboard/release-eligibility-mixed/Dockerfile.dev <<'EOF'
# Dockerfile.dev — dev variant. Default not release-eligible.
FROM alpine:3.19
EOF

cat > tests/fixtures/onboard/release-eligibility-mixed/Dockerfile.worker <<'EOF'
# Dockerfile.worker — worker variant, explicitly opted-in for release.
# onboard:release=true
FROM alpine:3.19
EOF

cat > tests/fixtures/onboard/release-eligibility-mixed/go.mod <<'EOF'
module example.com/onboard-fixture-release-eligibility-mixed

go 1.22
EOF

cat > tests/fixtures/onboard/release-eligibility-mixed/main.go <<'EOF'
package main

func main() {}
EOF
```

- [ ] **Step 2: Add golden_check registration**

In `tests/shell/onboard-render.bats`, find the list of `@test "golden: …"` lines and add a new entry:

```bash
@test "golden: release-eligibility-mixed" { golden_check "release-eligibility-mixed"; }
```

- [ ] **Step 3: Generate expected/ via UPDATE_GOLDEN**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats --filter "release-eligibility-mixed"
```

- [ ] **Step 4: Spot-check the generated release.yml + prerelease.yml**

```bash
cat tests/fixtures/onboard/release-eligibility-mixed/expected/.github/workflows/release.yml | rg "image_name|images"
cat tests/fixtures/onboard/release-eligibility-mixed/expected/.github/workflows/prerelease.yml | rg "image_name|images"
```

Expected: release.yml lists only `Dockerfile` + `Dockerfile.worker` (worker is opted-in). prerelease.yml lists all three (Dockerfile, Dockerfile.dev, Dockerfile.worker).

If the multi-call uses `docker-build-multi.yml@v2` (older pin) due to fixture pin convention, that's expected — the fixture system uses v2 for stability.

- [ ] **Step 5: Re-run bats clean**

```bash
bats tests/shell/onboard-render.bats --filter "release-eligibility-mixed"
```

Expected: ok.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/onboard/release-eligibility-mixed tests/shell/onboard-render.bats
git commit -m "test(onboard): release-eligibility-mixed fixture (Dockerfile + .dev + .worker)"
```

### Task 9: Add `containerfile-only` fixture

**Files:**
- Create: `tests/fixtures/onboard/containerfile-only/Containerfile`
- Create: `tests/fixtures/onboard/containerfile-only/go.mod`
- Create: `tests/fixtures/onboard/containerfile-only/main.go`

- [ ] **Step 1: Write fixture files**

```bash
mkdir -p tests/fixtures/onboard/containerfile-only
cat > tests/fixtures/onboard/containerfile-only/Containerfile <<'EOF'
# Containerfile — Podman/OCI synonym for Dockerfile.
FROM alpine:3.19
EOF

cat > tests/fixtures/onboard/containerfile-only/go.mod <<'EOF'
module example.com/onboard-fixture-containerfile-only

go 1.22
EOF

cat > tests/fixtures/onboard/containerfile-only/main.go <<'EOF'
package main

func main() {}
EOF
```

- [ ] **Step 2: Register golden test**

In `tests/shell/onboard-render.bats`:

```bash
@test "golden: containerfile-only" { golden_check "containerfile-only"; }
```

- [ ] **Step 3: Generate expected/**

```bash
UPDATE_GOLDEN=1 bats tests/shell/onboard-render.bats --filter "containerfile-only"
```

- [ ] **Step 4: Spot-check the generated release.yml**

```bash
cat tests/fixtures/onboard/containerfile-only/expected/.github/workflows/release.yml | rg "image_name|dockerfile"
```

Expected: lists `Containerfile` as the dockerfile, `image_name` like `serverkraken/containerfile-only` or similar.

- [ ] **Step 5: Re-run bats clean**

```bash
bats tests/shell/onboard-render.bats --filter "containerfile-only"
```

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/onboard/containerfile-only tests/shell/onboard-render.bats
git commit -m "test(onboard): containerfile-only fixture (Podman/OCI Containerfile)"
```

---

## Phase 5: Default-sync bats extension

### Task 10: Add SK_SIGN/SK_ATTEST/SK_SBOM default-sync tests

**Files:**
- Modify: `tests/shell/template-defaults.bats` — append after existing tests.

- [ ] **Step 1: Write the three new tests**

Append to `tests/shell/template-defaults.bats`:

```bash
@test "SK_SIGN template default matches docker-build atom default" {
  t=$(template_default "$RELEASE_TMPL" "SK_SIGN")
  a=$(atom_default "$REPO_ROOT/.github/workflows/docker-build.yml" "sign")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_ATTEST template default matches docker-build atom default" {
  t=$(template_default "$RELEASE_TMPL" "SK_ATTEST")
  a=$(atom_default "$REPO_ROOT/.github/workflows/docker-build.yml" "attest")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}

@test "SK_SBOM template default matches docker-build atom default" {
  t=$(template_default "$RELEASE_TMPL" "SK_SBOM")
  a=$(atom_default "$REPO_ROOT/.github/workflows/docker-build.yml" "sbom")
  [ "$t" = "$a" ] || { echo "tmpl=$t atom=$a"; false; }
}
```

These reference `$RELEASE_TMPL` — verify the setup block already defines this. If only `$CI_TMPL` / `$PRE_TMPL` exist, extend the setup block:

```bash
setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  CI_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/ci.yml.tmpl"
  PRE_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/prerelease.yml.tmpl"
  RELEASE_TMPL="$REPO_ROOT/docs/adopter-templates/skeletons/release.yml.tmpl"
}
```

- [ ] **Step 2: Run + verify pass**

```bash
bats tests/shell/template-defaults.bats
```

Expected: previously-existing tests still pass + 3 new tests ok.

- [ ] **Step 3: Commit**

```bash
git add tests/shell/template-defaults.bats
git commit -m "test(onboard): default-sync SK_SIGN/SK_ATTEST/SK_SBOM"
```

---

## Phase 6: Docs

### Task 11: Update `docs/operations.md` Knob Registry

**Files:**
- Modify: `docs/operations.md` — find the "Per-Adopter Overrides via Repository Variables" section's Knob Registry table.

- [ ] **Step 1: Append three rows to the variables table**

Find the existing table in `docs/operations.md` (the one with `SK_COVERAGE_THRESHOLD`, `SK_CGO_ENABLED`, etc.). Append three rows:

```markdown
| `SK_SIGN` | `sign` | docker-build, docker-build-multi (release + prerelease) | `true` | boolean |
| `SK_ATTEST` | `attest` | docker-build, docker-build-multi (release + prerelease) | `true` | boolean |
| `SK_SBOM` | `sbom` | docker-build, docker-build-multi (release + prerelease) | `true` | boolean |
```

Keep the existing prose explaining the variable + Secrets warning + org-level layering unchanged.

- [ ] **Step 2: Add a new section on release-eligibility**

Add a new top-level section after the existing "Per-Adopter Overrides" block:

```markdown
## Release-Eligibility per Dockerfile

By default, `release.yml` ships **only the bare `Dockerfile` (or `Containerfile`)** to GHCR on release-please-driven releases. Any `Dockerfile.*` / `Containerfile.*` variant (e.g. `Dockerfile.dev`, `Dockerfile.debug`) is **excluded** from release builds and only ships via the manual `prerelease.yml` workflow_dispatch path.

### Convention

| File matches | `release_eligible` default |
|---|---|
| `Dockerfile` / `Containerfile` (exact) | `true` |
| `Dockerfile.*` / `Containerfile.*` (any extension) | `false` |

### Per-file override

To opt a variant IN for release (e.g. `Dockerfile.worker` for a worker image that ships alongside the main service):

```dockerfile
# Dockerfile.worker
# onboard:release=true
FROM alpine:3.19
...
```

To opt the bare `Dockerfile` OUT of release (e.g. a dev-only repo with no production Dockerfile):

```dockerfile
# Dockerfile
# onboard:release=false
FROM alpine:3.19
...
```

Only the first 5 lines of the file are scanned. Override wins over convention. The annotation extends the existing `# onboard:image=<name>` convention from `read_image_override`.

### If no Dockerfile is release-eligible

The rendered `release.yml` simply omits the docker-build job. release-please + any other release-signal jobs (goreleaser, helm-publish) continue to run. `onboard-detect` emits a `no_release_eligible` warning into the onboard run's step summary so this isn't a silent surprise.
```

- [ ] **Step 3: Commit**

```bash
git add docs/operations.md
git commit -m "docs(operations): SK_SIGN/SK_ATTEST/SK_SBOM + release-eligibility section"
```

---

## Phase 7: PR + release + migration

### Task 12: Open the PR

- [ ] **Step 1: Confirm branch is fully pushed**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/release-eligibility
git push origin feat/release-eligibility
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --base main --head feat/release-eligibility \
  --title "feat(onboard): release-eligibility per Dockerfile + SK_SIGN/SK_ATTEST/SK_SBOM vars" \
  --body "$(cat <<'EOF'
## Summary

Three coupled changes:

1. **Per-Dockerfile `release_eligible` flag**: default convention has only the bare `Dockerfile`/`Containerfile` shipping on release-please releases. `Dockerfile.dev`/`Dockerfile.debug`/etc. ship only via the manual `prerelease.yml` workflow_dispatch. Override per-file with `# onboard:release=true|false` header annotation.
2. **Containerfile detection**: `Containerfile` + `Containerfile.*` (Podman/OCI synonym) now detected equivalently to `Dockerfile` patterns throughout the inventory.
3. **`SK_SIGN`, `SK_ATTEST`, `SK_SBOM` vars**: three new repo-variable overrides, plumbed through both `release.yml.tmpl` and `prerelease.yml.tmpl` into the docker-build / docker-build-multi atom inputs. Defaults all `true`. fromJSON wrap to coerce vars-string into atom `type: boolean`.

## Spec + plan

- `docs/superpowers/specs/2026-05-21-release-eligibility-design.md`
- `docs/superpowers/plans/2026-05-21-release-eligibility.md`

## Behavior change for existing adopters

After v3.10.0 publishes + re-onboarding:

- **blupod-ui**: had `Dockerfile` + `Dockerfile.dev` in release.yml. After: only `Dockerfile`. `Dockerfile.dev` remains in prerelease.yml only.
- **skytrack-ui**: identical to blupod-ui.
- **flow / skytrack**: no behavior change (single-Dockerfile or no-Dockerfile setups).

Re-onboard will be triggered as part of merge — adopter PRs reflect the diff explicitly.

## Test plan

- [x] `bats tests/shell/` — all green
- [x] `actionlint` clean
- [ ] CI green
- [ ] Re-onboard blupod-ui + skytrack-ui after merge — verify release.yml no longer includes Dockerfile.dev
EOF
)"
```

### Task 13: Wait for CI + merge

- [ ] **Step 1: Watch checks**

```bash
gh pr checks <PR-NUMBER> --repo serverkraken/reusable-workflows --watch
```

Expected: all green incl. integration smoke tests.

- [ ] **Step 2: Squash-merge**

```bash
gh pr merge <PR-NUMBER> --repo serverkraken/reusable-workflows --squash
```

- [ ] **Step 3: Wait for release-please PR + merge it**

```bash
until gh pr list --repo serverkraken/reusable-workflows --base main \
  --head release-please--branches--main --state open --json number 2>/dev/null \
  | jq -e 'length > 0' > /dev/null; do sleep 30; done
release_pr=$(gh pr list --repo serverkraken/reusable-workflows --base main \
  --head release-please--branches--main --state open --json number --jq '.[0].number')
gh pr checks "$release_pr" --repo serverkraken/reusable-workflows --watch
gh pr merge "$release_pr" --repo serverkraken/reusable-workflows --squash
```

- [ ] **Step 4: Wait for v3 floating tag to move**

```bash
until [[ "$(git ls-remote --tags origin v3 | awk '{print $1}')" \
       == "$(git ls-remote --tags origin v3.10.0 | awk '{print $1}')" \
       && -n "$(git ls-remote --tags origin v3.10.0 | awk '{print $1}')" ]]; do
  sleep 20
done
echo "v3 → v3.10.0 confirmed"
```

### Task 14: Re-onboard the four adopters

- [ ] **Step 1: Trigger onboard for all four**

```bash
gh workflow run onboard.yml --repo serverkraken/reusable-workflows \
  -f target_repos=serverkraken/blupod-ui,serverkraken/flow,serverkraken/skytrack,serverkraken/skytrack-ui \
  -f pin_version=v3 \
  -f dry_run=false
```

- [ ] **Step 2: Wait + confirm all four success**

```bash
run_id=$(gh run list --repo serverkraken/reusable-workflows \
  --workflow onboard.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run_id" --repo serverkraken/reusable-workflows
gh run view "$run_id" --repo serverkraken/reusable-workflows \
  --json jobs --jq '.jobs[] | select(.name | startswith("onboard")) | "\(.name): \(.conclusion)"'
```

Expected: all four `success`.

- [ ] **Step 3: Verify release.yml diff per adopter**

For blupod-ui + skytrack-ui (the two with behavior change):

```bash
for repo in blupod-ui skytrack-ui; do
  echo "=== $repo ==="
  gh api "repos/serverkraken/$repo/contents/.github/workflows/release.yml?ref=chore%2Fonboard-reusable-workflows" \
    --jq '.content' | base64 -d | rg "image_name|images:"
done
```

Expected: each release.yml's `images:` array now contains only entries with `serverkraken/<repo>` (no `serverkraken/<repo>-dev`). The dev image_names continue to appear in prerelease.yml only.

### Task 15: Trigger drift-check baseline

- [ ] **Step 1: Dispatch drift-check**

```bash
gh workflow run drift-check.yml --repo serverkraken/reusable-workflows
```

- [ ] **Step 2: Read drift report**

```bash
run_id=$(gh run list --repo serverkraken/reusable-workflows \
  --workflow drift-check.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run_id" --repo serverkraken/reusable-workflows
gh issue view 66 --repo serverkraken/reusable-workflows --json body --jq .body
```

Expected: blupod-ui, flow, skytrack, skytrack-ui all report `clean` against v3 once their re-onboard PRs merge. If the PRs haven't merged yet, they'll report `behind` or `no-lock` — that's expected pre-merge.

---

## Self-Review

- **Spec coverage:** Every requirement in the spec maps to a task. Detection-layer changes (read_release_override, inventory_dockerfiles patterns + release_eligible, derive_image_name Containerfile arms, no_release_eligible warning) → Tasks 1-4. Template changes (release.yml.tmpl filter + SK_*, prerelease.yml.tmpl SK_*) → Tasks 5-7. New fixtures → Tasks 8-9. Default-sync → Task 10. Docs → Task 11. Migration → Tasks 12-15.
- **Placeholder scan:** No TBD / TODO / "etc." — all code blocks, commands, and expected outputs concrete.
- **Type consistency:** `release_eligible` field name used consistently across detection lib, inventory schema, template logic, fixture goldens. `SK_SIGN`/`SK_ATTEST`/`SK_SBOM` variable names consistent across templates, defaults bats, docs.
- **TDD discipline:** Tasks 1-4 (detection) follow strict TDD — test first, fail, implement, pass. Tasks 5-9 (templates + fixtures) use the established UPDATE_GOLDEN regen pattern, which is the codebase's accepted shortcut.
- **Migration completeness:** Behavior diff explicitly listed for each adopter. Drift-check baseline captures end state.
