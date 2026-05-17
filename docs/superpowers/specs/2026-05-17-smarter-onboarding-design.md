# Smarter Onboarding — Design

**Status:** approved (brainstorm)
**Date:** 2026-05-17
**Supersedes:** parts of `2026-05-16-onboarding-workflow-design.md` (which it extends without replacing).

---

## 1. Motivation

The current onboarding workflow (`onboard.yml` + `actions/onboard-detect` + `actions/onboard-render`) treats every adopter as a single-language, single-component, single-Dockerfile repository. It hard-fails on:

- repos with more than one language marker (e.g. `go.mod` + `Chart.yaml` in the same root),
- repos with more than one Dockerfile,
- monorepos with sub-component release granularity,
- pure libraries / CLIs that have no Dockerfile at all,
- pure Helm chart repositories.

It also gives consumers no way to verify, after the onboarding PR is merged, that they have not drifted from the catalog's template.

This spec extends detection, rendering, and adds a central drift-audit so the catalog can serve the real shape of the `serverkraken/*` repositories — not just the canonical service-with-one-Dockerfile case.

## 2. Goals

- **Detect** the adopter's real shape: monorepo or not, components, roles, Dockerfiles, release signals, legacy CI to retire.
- **Render** a workflow set that matches the detected shape via job composition, not template duplication.
- **Track** what was rendered, so a central audit can spot drift and out-of-date adopters.
- **Surface** the detection result in the onboarding PR body and step summary so a human can sanity-check before merge.

### Out of scope (see `docs/superpowers/backlog.md`)

- Lint/test atoms per language.
- Repo-hygiene bootstrapping (CODEOWNERS, branch protection, PR templates).
- PR-comment-driven retries (`/onboard rerun`).
- Rollback / un-onboard workflow.
- `detect-only.yml` as a public reusable workflow (today it's an internal action; promotion is a YAGNI item until an adopter asks).

## 3. Architecture Overview

```
.github/workflows/
  onboard.yml                       # EXTENDED — consumes structured profile.json
  docker-build-multi.yml            # NEW — image-matrix wrapper around docker-build.yml
  goreleaser.yml                    # NEW — release-asset attach via goreleaser
  helm-publish.yml                  # NEW — chart-releaser / OCI push
  drift-check.yml                   # NEW — weekly central audit across all adopters

actions/
  onboard-detect/action.yml         # EXTENDED — emits structured profile.json
  onboard-render/action.yml         # EXTENDED — variant-aware via gomplate
  onboard-drift/action.yml          # NEW — two-stage compare (lock + content)

docs/adopter-templates/
  skeletons/                        # gomplate templates with conditionals
    ci.yml.tmpl
    release.yml.tmpl
    prerelease.yml.tmpl
    cleanup.yml.tmpl
  configs/
    release-please-config.json.tmpl
    release-please-config.monorepo.json.tmpl
    release-please-manifest.json.tmpl

scripts/
  onboard-detect.sh                 # EXTENDED — emits JSON
  onboard-render.sh                 # EXTENDED — variant-aware
  onboard-drift.sh                  # NEW

tests/
  fixtures/onboard/
    single-service/                 # exists
    multi-image/                    # NEW
    monorepo-go/                    # NEW
    library-go/                     # NEW
    cli-go-with-goreleaser/         # NEW
    service-with-helm/              # NEW
    helm-only/                      # NEW
  shell/
    onboard-detect.bats             # EXTENDED
    onboard-render.bats             # EXTENDED
    onboard-drift.bats              # NEW
```

**Per-target data flow:**

```
checkout target → onboard-detect → profile.json
                                     │
                                     ├─ Step Summary (Markdown report)
                                     ├─ PR body (richer migration report)
                                     └─ onboard-render(profile.json, catalog, pin)
                                            │
                                            ├─ gomplate over skeletons/ + configs/
                                            ├─ writes .github/onboard.lock.json
                                            └─ rendered files → working tree
```

**API surface separation:**

| Surface | Public / Internal | SemVer obligation |
|---|---|---|
| `docker-build.yml`, `docker-build-multi.yml`, `goreleaser.yml`, `helm-publish.yml`, `trivy-*.yml`, `cleanup-images.yml`, `release-please.yml` | Public | Inputs/outputs/secrets honour SemVer. New atoms launch at `v1.0.0` in the next catalog release. |
| `onboard.yml`, `drift-check.yml`, all `actions/onboard-*` | Internal | Input contracts may break without major bump; dated change notes in the workflow header. |
| `profile.json` schema | Internal (detect ↔ render) | `schema_version` field; renderer validates. |
| `.github/onboard.lock.json` | Visible in adopter | `schema_version` field; drift-check tolerates older versions. |

## 4. Detection (`onboard-detect`)

### 4.1 `profile.json` schema

```json
{
  "schema_version": 1,
  "target_repo": "serverkraken/foo",
  "default_branch": "main",
  "current_version": "1.2.3",
  "monorepo": false,
  "components": [
    {
      "path": ".",
      "languages": ["go", "helm"],
      "primary_language": "go",
      "release_please_type": "go",
      "role": "service",
      "dockerfiles": [
        {
          "path": "Dockerfile",
          "image_name": "foo",
          "image_name_source": "derived"
        },
        {
          "path": "Dockerfile.worker",
          "image_name": "custom-worker",
          "image_name_source": "override"
        }
      ],
      "release_signals": {
        "goreleaser_config": null,
        "chart_yaml": "charts/foo/Chart.yaml"
      }
    }
  ],
  "legacy_ci": [
    {
      "path": ".github/workflows/build.yml",
      "summary": "ad-hoc docker buildx + manual ghcr push",
      "replaced_by": ["release.yml", "docker-build.yml"]
    }
  ],
  "warnings": []
}
```

### 4.2 Detection steps

1. **Monorepo markers (root):** `go.work`, `Cargo.toml[workspace]`, `pnpm-workspace.yaml`, `package.json[workspaces]`, `lerna.json`, `nx.json`. First match wins; components come from the marker.
2. **Fallback monorepo:** more than one `go.mod` / `pyproject.toml` / `Cargo.toml` / `Chart.yaml` in subdirectories. Components = direct parent directories of the markers.
3. **Sub-Dockerfile heuristic (no sub-marker):** if a repo has multiple Dockerfiles under sibling subdirectories (e.g. `services/api/Dockerfile` and `services/worker/Dockerfile`) but no sub-language markers, **treat as monorepo** with two components and `release_please_type = "generic"` per component.
4. **Per component:**
   - Collect language markers (`languages[]`).
   - Inventory Dockerfiles (`Dockerfile`, `Dockerfile.*`).
   - Read each Dockerfile's first five lines for `# onboard:image=<name>` override.
   - Derive `image_name` (override wins; else `<repo>` for root single Dockerfile, `<repo>-<suffix>` for variant or sub-path).
   - Detect release signals (`goreleaser` config, `Chart.yaml` inside component path other than the component root itself).
5. **Role heuristic:**
   - Dockerfile present → `service`.
   - No Dockerfile + binary entrypoint (`cmd/*/main.go` for Go, `[[bin]]` for Cargo, `[project.scripts]` for Python) → `cli`.
   - Only `Chart.yaml` → `helm-app`.
   - Otherwise → `library`.
6. **CLI confirmation:** if `role = cli` but `release_signals.goreleaser_config` is null, renderer renders a CLI release that only tags (no binary build). With goreleaser config present, the goreleaser job is added.
7. **Legacy CI scan:** every `.github/workflows/*.yml` that is not in the rendered output. Classify by signature patterns (`uses: aquasecurity/trivy-action` → trivy atom replacement; `docker/build-push-action` → docker-build replacement; `docker buildx … docker push` shell → ad-hoc). Emit one `legacy_ci[]` entry per file.
8. **Ambiguities:** push to `warnings[]` (e.g. multiple plausible `primary_language` candidates, unrecognized Dockerfile naming). Detection does **not** fail; warnings show up in the PR body and step summary for human review.

### 4.3 Hard errors

Detection exits non-zero only on:

- repo path missing / not a directory,
- target repo not accessible via `gh`,
- malformed monorepo marker file (e.g. invalid TOML),
- no detectable component (empty repo).

## 5. Rendering (`onboard-render`)

### 5.1 Toolchain

**`gomplate`** as the template engine. Installed in the workflow runner from the GitHub release tarball.

Reasons over Bash + `sed` + `yq`:

- 4 conditional jobs in `release.yml` + a monorepo `packages` map + per-component CI loops add up to a Bash mini-DSL that is hard to maintain.
- gomplate is a static binary, no Python/Go runtime in the catalog.
- gomplate consumes the detection's `profile.json` directly.
- Drift-check can run the same template engine to reproduce the expected output.

`yq` stays around for Detection (parsing legacy workflow YAML), not Rendering.

### 5.2 Invocation

```bash
onboard-render.sh <catalog-path> <target-path> <profile-json> <pin-version>
```

Single profile-JSON input replaces today's per-field positional args.

### 5.3 Steps

**Step 1 — Decide job composition** by reading `profile.json` with `jq`:

```
per component:
  has_docker     = (dockerfiles.length > 0)
  multi_docker   = (dockerfiles.length > 1)
  has_goreleaser = (release_signals.goreleaser_config != null)
  has_chart      = (release_signals.chart_yaml != null)
```

**Step 2 — Render `release-please-config.json`:**

- **Single-component:** gomplate over `configs/release-please-config.json.tmpl` with `release_please_type` from `components[0]`.
- **Monorepo:** `configs/release-please-config.monorepo.json.tmpl` with a `packages` map built inside the template via `{{ range .components }}…{{ end }}`.

**Step 3 — Render workflows:**

```bash
gomplate -d profile=profile.json \
         -c pin=<pin_version> \
         -f docs/adopter-templates/skeletons/<name>.yml.tmpl \
         -o <target>/.github/workflows/<name>.yml
```

For monorepos, `ci.yml` is rendered as a single file with a component matrix and `paths-filter` jobs inside.

`@v1`/`@v2` pinning is a template variable (`{{ .pin }}`), no post-render `sed`.

**Step 4 — Write `.github/onboard.lock.json`:**

```json
{
  "schema_version": 1,
  "catalog_version": "v2.0.4",
  "rendered_at": "2026-05-17T14:00:00Z",
  "files": {
    ".github/workflows/ci.yml":            "sha256:abc…",
    ".github/workflows/release.yml":       "sha256:def…",
    ".github/workflows/prerelease.yml":    "sha256:111…",
    ".github/workflows/cleanup.yml":       "sha256:222…",
    "release-please-config.json":          "sha256:123…",
    ".release-please-manifest.json":       "sha256:456…"
  }
}
```

Lock file is committed in the add-PR.

### 5.4 Job-composition example (excerpt from `release.yml.tmpl`)

```yaml
jobs:
  release-please:
    uses: serverkraken/reusable-workflows/.github/workflows/release-please.yml@{{ .pin }}
    secrets: inherit

  {{- $c := index .profile.components 0 }}
  {{- if eq (len $c.dockerfiles) 1 }}
  docker-build:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: …/docker-build.yml@{{ .pin }}
    with:
      dockerfile: {{ (index $c.dockerfiles 0).path }}
      image_name: {{ (index $c.dockerfiles 0).image_name }}
  {{- else if gt (len $c.dockerfiles) 1 }}
  docker-build:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: …/docker-build-multi.yml@{{ .pin }}
    with:
      images: |
        {{- range $c.dockerfiles }}
        - dockerfile: {{ .path }}
          image_name: {{ .image_name }}
        {{- end }}
  {{- end }}

  {{- if $c.release_signals.goreleaser_config }}
  goreleaser:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: …/goreleaser.yml@{{ .pin }}
  {{- end }}

  {{- if $c.release_signals.chart_yaml }}
  helm-publish:
    needs: [release-please]
    if: needs.release-please.outputs.release_created
    uses: …/helm-publish.yml@{{ .pin }}
    with:
      chart_path: {{ $c.release_signals.chart_yaml | dir }}
  {{- end }}
```

Monorepo `release.yml.tmpl` wraps the same logic in `{{ range .profile.components }}…{{ end }}` and suffixes job names with a sanitized component path.

### 5.5 Render-time errors

Hard fail on:

- gomplate non-zero exit (template error),
- required `profile.json` field missing (renderer logs which one),
- lock-file generation fails.

No hard-fail on "ambiguous" any more — Detection allows ambiguity, only `warnings[]` propagate.

## 6. Drift-Check (`drift-check.yml`)

### 6.1 Where and when

- **Location:** central, `.github/workflows/drift-check.yml` in the catalog repo.
- **Schedule:** weekly cron (`0 6 * * 1`) plus `workflow_dispatch`.
- **Permissions:** matrix per target uses an App-minted token; catalog itself needs `contents: read`. Issue write happens via the App token scoped to the catalog repo.

### 6.2 Algorithm

```
for each onboarded target (enumerated from docs/onboarding-status.md):

  lock = read .github/onboard.lock.json
  if not lock:
    status = no-lock
    continue

  if lock.catalog_version != current_catalog_version:
    flag behind

  expected = re-render the target using catalog @ lock.catalog_version
  for each file in lock.files:
    if sha256(target/<file>) != lock.files[<file>]:
      flag modified, list file

  status =
    clean             if not behind and not modified
    behind            if behind and not modified
    modified          if modified and not behind
    behind+modified   if both
```

The re-render step requires Detection to be **reproducible** at the locked catalog version. That's a hard requirement and a test gate (see § 7).

### 6.3 Output

- **Step summary** with a table of all targets.
- **GitHub Issue** in the catalog repo, **titled exactly** `Onboarding Drift Report`. Drift-check looks up the existing open issue by title and edits the body; if none exists, it creates one. This avoids issue-list noise from a weekly cron.

Example body:

```markdown
# Onboarding Drift Report — 2026-05-18

| Repo | Status | Catalog (lock → current) | Modified files |
|---|---|---|---|
| serverkraken/blupod-ui          | clean    | v2.0.4            | — |
| serverkraken/flow               | behind   | v2.0.1 → v2.0.4   | — |
| serverkraken/juke.gallery-rest  | modified | v2.0.4            | .github/workflows/ci.yml |
| serverkraken/foo                | no-lock  | — → v2.0.4        | — (needs re-onboard) |
```

### 6.4 What drift-check does NOT do

- No auto-update PRs. Drift is read-only audit; remediation is a manual `onboard.yml` dispatch.
- No comparison against `catalog @ current` for hypothetical changes ("would re-rendering at HEAD change anything?"). That belongs to re-onboard, not drift.

## 7. Testing

### 7.1 Bats unit tests (`tests/shell/`)

**`onboard-detect.bats` (extended):**

- emits `profile.json` with correct `schema_version`,
- monorepo via `go.work` recognized,
- monorepo via multiple `go.mod` (no `go.work`) recognized,
- single-component multi-Dockerfile (`dockerfiles[]` length > 1),
- mixed-language in one component (go + helm) → `release_signals.chart_yaml` set,
- `role = cli` when binary entry present and no Dockerfile,
- `role = service` when Dockerfile present even though `cmd/main.go` exists,
- image-name override from Dockerfile comment beats convention,
- `legacy_ci` recognizes `aquasecurity/trivy-action` → `trivy-fs` replacement mapping,
- `default_branch` + `current_version` via `gh` stub (with `TARGET_REPO`).

**`onboard-render.bats` (extended):**

- single-component service renders 4 workflows + lock + 2 configs (= 7 targets),
- multi-image service renders `docker-build-multi` job, not `docker-build`,
- library renders no docker job, no trivy,
- CLI with goreleaser config renders goreleaser job,
- service with chart renders helm-publish job,
- monorepo renders `release-please-config.json` with a `packages` map,
- monorepo renders `ci.yml` with a component matrix,
- lock file enumerates every rendered path,
- lock file's `catalog_version` equals the `pin_version` argument.

**`onboard-drift.bats` (new):**

- clean state → status `clean`, exit 0,
- one file hand-edited → status `modified`, exit 0, file listed,
- lock-version < current → status `behind`,
- both → status `behind+modified`,
- missing lock file → status `no-lock`,
- re-render at locked catalog version produces byte-identical output (reproducibility gate).

Coverage target: `bashcov` ≥ 90 % on `onboard-detect.sh`, `onboard-render.sh`, `onboard-drift.sh`.

### 7.2 Golden-file fixtures

```
tests/fixtures/onboard/
  single-service/         expected/.github/workflows/{ci,release,prerelease,cleanup}.yml + lock + configs
  multi-image/            expected/…
  library-go/             expected/…
  cli-go-with-goreleaser/ expected/…
  service-with-helm/      expected/…
  helm-only/              expected/…
  monorepo-go/            expected/…
```

Driver pattern:

```bash
@test "single-service renders to expected output" {
  ./scripts/onboard-detect.sh fixtures/single-service > /tmp/profile.json
  ./scripts/onboard-render.sh "$CATALOG" /tmp/out /tmp/profile.json v2
  diff -r fixtures/single-service/expected /tmp/out
}
```

Update workflow: `UPDATE_GOLDEN=1 bats …` overwrites expected files. Explicit, never automatic.

### 7.3 Integration via callers

Existing pattern extended with new atoms:

```
tests/callers/
  docker-build-multi-happy.yml   # 2 fake Dockerfiles → 2 manifest lists
  docker-build-multi-fail.yml    # broken Dockerfile → failure-path
  goreleaser-happy.yml           # uses CLI fixture
  helm-publish-happy.yml         # publishes test chart to scratch GHCR namespace
  drift-check-happy.yml          # constructs a fake target with lock, runs drift action
```

### 7.4 Static

`actionlint` + `yamllint` run on every workflow including expected fixtures. Output drift caught at static-check time, before runtime.

### 7.5 Not covered

- Live API calls against `serverkraken/*` repos in CI (stubbed via `TARGET_REPO` path).
- Drift-check performance at scale (today's adopter count is fine; revisit beyond ~50 adopters as a separate spec).

## 8. Migration for existing adopters

- Adopters onboarded under the previous spec (no `onboard.lock.json`) keep working; their files are not touched.
- The first re-dispatch of `onboard.yml` re-renders via the new pipeline and writes the lock file. The PR body explains the lock-file addition.
- Drift-check reports such adopters as `no-lock` until they are re-onboarded.

## 9. Implementation order (high-level)

1. New atoms first: `docker-build-multi.yml`, `goreleaser.yml`, `helm-publish.yml`. They are independently useful and unblock everything else.
2. `onboard-detect` rewrite to emit `profile.json` (schema, all detection steps, override parser, legacy-CI scan).
3. `onboard-render` rewrite on gomplate with new skeletons and configs.
4. `.github/onboard.lock.json` generation in the renderer.
5. `onboard.yml` updates: pass `profile.json` between detect and render, richer PR body, warnings into step summary.
6. `drift-check.yml` + `onboard-drift` action.
7. Fixtures and golden-file tests follow each step.

Detailed task breakdown is the job of the implementation plan (next).

## 10. Open questions for implementation plan

- Exact gomplate version pin and install snippet (release tarball or `go install`).
- Whether to extract a shared "render one workflow file" helper in `onboard-render.sh` or keep four explicit gomplate calls inline.
- Whether `image_name` derivation needs a sanitization pass for path segments (`services/foo` → `foo`, but what about `apps/v2-api` → `v2-api`?).

These are deliberately deferred to the plan because they don't change the design's shape.
