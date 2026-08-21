# Adopter Manifest + Per-Component Releases — Design

**Date:** 2026-08-21
**Status:** approved (design approved in conversation, section by section)
**Origin:** mailstack cannot be onboarded without functional loss. A
`sk-workflows preview` run against `serverkraken/mailstack` (2026-08-21)
showed the renderer misclassifying the repo and dropping most of what the
hand-wired `@v4` workflows do today. While fixing that, Soenne asked for
the release model the renderer *should* produce: build an image only when
something inside it changed, with independent versions per component.

## Problem

mailstack is a Go module at the repo root (`cmd/`, `internal/`, `go.mod`),
six images under `images/<name>/Dockerfile` (all built with context `.`,
they `COPY images/<name>/…` and `images/tools` copies `go.mod`), a Helm
chart under `charts/mailstack`, a kind-based e2e suite, and a hand-rolled
`helm-unittest` job. It already calls every catalog atom it needs
(`trivy-fs`, `lint-go`, `test-go`, `lint-helm`, `helm-publish`,
`docker-build-multi`, `semantic-release`, `e2e-kind`) — by hand, without
an onboard lock.

The renderer cannot express that shape:

1. **Detect bug.** `detectComponents` (`internal/app/detect/service.go:146`)
   guards `fallbackMarkerPaths` with `rootHasMarker`, but not
   `fallbackDockerfilePaths`. A repo with `go.mod` at the root *and*
   Dockerfiles in sub-directories loses its root component: mailstack
   becomes a six-component `generic` monorepo. Rendered `ci.yml` keeps only
   `secscan`; `release-please-config.json` becomes six `simple` packages
   with `include-component-in-tag: true`; the chart disappears.
2. **Sub-directory Dockerfiles have no home.** `inventoryDockerfiles` reads
   only the component directory itself; a root component never sees
   `images/*/Dockerfile`. Rendered builds also use the sub-directory as
   context, which breaks mailstack's `COPY images/<name>/…`.
3. **Derived image names** are `$REPO-<dir>` (`mailstack-postfix`); mailstack
   publishes `serverkraken/mailstack/postfix`.
4. **Helm is a primary language only.** `ci.yml.tmpl` emits `lint-helm`
   solely when `primary_language == "helm"`; a chart next to Go code is
   ignored in CI. `release-please-config.json.tmpl` has no `extra-files`,
   so mailstack's `Chart.yaml` `appVersion` sync would be lost. There is no
   atom or input for `helm-unittest`.
5. **No e2e skeleton.** `e2e.yml` is reported as "unrecognized legacy
   workflow; manual review needed".
6. **Release gating is all-or-nothing.** `semantic-release.yml` exposes one
   `release_created` / `tag_name`; `release.yml.tmpl` gates every build on
   it. In a monorepo every release rebuilds every image.
7. **Prerelease template bug.** In monorepo mode `prerelease.yml.tmpl`
   renders only the first component, with `dockerfile: Dockerfile` and no
   context.

The net effect today: onboarding mailstack would rename its GHCR packages,
break its builds, and drop its chart release. Of the four live adopters
(blupod-ui, flow, skytrack, skytrack-ui) none is a monorepo, so none has
hit this.

## Scope

**In scope**

- An adopter-side manifest `.github/onboard.yml` (schema v1) that declares
  what detection cannot infer: component layout, attached Dockerfiles,
  image names, chart unit tests, an e2e workflow, the release dispatch
  trigger, and the GitOps consumers of the repo.
- Detect: manifest parsing, the `fallbackDockerfilePaths` fix, profile
  fields for the new data, manifest hash in the lock.
- `semantic-release.yml`: additive outputs `paths_released` and `releases`.
- `lint-helm.yml`: additive input `unittest`.
- Templates: per-component release gating in monorepo mode,
  `docker-build-multi` for multi-Dockerfile components, chart jobs driven
  by the chart signal, a new `e2e.yml.tmpl`, `workflow_dispatch` on
  release, monorepo release-please config with a Helm package.
- Drift/legacy: manifest-declared workflows are not legacy; manifest
  changes are `stale-lock`, not `modified`.
- Rollout for mailstack (manifest, onboarding, chart values, Renovate).

**Out of scope (recorded as extension points, see § Extension points)**

- `gitops[].mode: push` (release-triggered Renovate run in the consumer).
- Deprecating the `# onboard:image=` / `# onboard:release=` Dockerfile
  annotations.
- Tier-2 repo defaults (topics, required checks, bot-PR assignees) in the
  manifest.
- Path-filtered CI per component. CI keeps linting and testing the whole
  repo; only *release* is per component.
- A Bash implementation of the manifest parser (see § Detect, decision 3).

## Background — how detection feeds rendering today

`sk-workflows detect` walks the repo and emits `profile.json`
(`components[]` with `path`, `languages`, `dockerfiles[]`,
`release_signals{goreleaser_config, chart_yaml, flutter_android}`, `cgo`;
plus `monorepo`, `legacy_ci[]`, `warnings[]`). `sk-workflows render` feeds
that profile into the gomplate skeletons under `docs/adopter-templates/`
and writes `.github/onboard.lock.json` with a SHA-256 per rendered file.
`drift-check` compares lock hashes to the working tree (`modified`) and
re-renders from the current catalog to detect `stale-lock`. Renders must
be byte-reproducible for a given `(profile, pin)` — a bats test guards it.

Runtime tunables (coverage threshold, toolchain versions, sign/attest/sbom,
Trivy severity) are `SK_*` repository Variables read by the rendered
workflows at run time. They need no re-render and stay out of the manifest.

## Approaches considered

For the one question the file system cannot answer — "does
`images/tools` belong to the Go root?" — three options were weighed:

| Option | Verdict |
|---|---|
| **Dockerfile annotation** `# onboard:component=.` — extends the existing `onboard:image=` pattern. | Cheapest, but invisible in the repo tree and a fourth scattered override surface. Rejected in favour of the manifest once it became clear the file replaces *three* mechanisms, not one. |
| **Heuristic** — a Dockerfile that `COPY`s `go.mod` or `.` from the root belongs to the root. | Zero config but fragile (multi-stage variants, root context without root dependency) and impossible to explain when an image is suddenly bundled differently. Rejected. |
| **Adopter manifest** `.github/onboard.yml` — explicit, versioned, hashed into the lock. | **Chosen.** Justified because it also absorbs `language_override`, the legacy-workflow guesswork for `e2e.yml`, and the "who consumes this repo" inventory the org has never had. |

For how the chart learns per-image versions:

| Option | Verdict |
|---|---|
| **Coupled via release-please `extra-files`** (`yaml` updater with `jsonpath` per package into `values.yaml`). | Technically works (each package targets its own key; one combined release PR). Rejected: the release PR commit is `chore:` and does not bump the chart package, so the published chart lags with stale defaults until something under `charts/` changes. Would need special-case trigger logic in the template. |
| **Decoupled via Renovate** — `values.yaml` pins a default tag per image; Renovate's `helm-values` manager bumps it as `fix(chart): …`, which bumps and publishes the chart. | **Chosen.** The chart treats its images like any other dependency; it is the same Renovate machinery that rolls images into the GitOps repos — one mechanism for both hops. |

For a future push path ("roll out minutes after release"): a hand-written
`yq`/`sed` bumper was rejected because the GitOps repos use four reference
syntaxes for serverkraken images alone (combined `image:`, bare digest,
Kustomize `images[].newTag`+`digest`, Helm values `repository`/`tag` with
`tag: "x@sha256:…"`) across *two* copies each (`bootstrap/templates/**/*.j2`
and the rendered `kubernetes/**`). Renovate already handles all of them
(the homelab preset enables `argocd`, `helm-values`, `helmfile`,
`kubernetes`, `kustomize` — each with `(?:\.j2)?`). Syntax is therefore an
engine concern and never enters the manifest.

## Design per concern

### 1. Adopter manifest — `.github/onboard.yml`, schema v1

```yaml
schema: 1
components:                      # optional; absent → auto-detect as today
  - path: .
    language: go                 # optional; overrides detection
    dockerfiles:                 # optional; in addition to those found in `path`
      - path: images/tools/Dockerfile
        image: serverkraken/mailstack/tools
        platforms: linux/amd64,linux/arm64   # optional; default = atom default
        release: true                        # optional; default by file name
  - path: images/postfix
    image: serverkraken/mailstack/postfix    # shorthand when `path` holds exactly one Dockerfile
  - path: images/dovecot
    image: serverkraken/mailstack/dovecot
  - path: images/unbound
    image: serverkraken/mailstack/unbound
  - path: images/fangfrisch
    image: serverkraken/mailstack/fangfrisch
  - path: images/olefy
    image: serverkraken/mailstack/olefy
  - path: charts/mailstack
    type: helm
    unittest: true
workflows:                       # optional
  e2e:
    script: test/e2e/run.sh
    schedule: "0 3 * * *"        # optional; dispatch + tag push are always on
release:                         # optional
  dispatch_trigger: true         # adds `workflow_dispatch: {}` to release.yml
gitops:                          # optional; list of consuming repos
  - repo: serverkraken/homelab-mail-nue
    scope:                       # optional file globs; default = whole repo
      - kubernetes/apps/mailstack/**
      - bootstrap/templates/kubernetes/apps/mailstack/**
    mode: renovate               # default; `push` reserved, rejected in v1
```

Semantics:

- **`components:` present ⇒ authoritative and complete.** No mixing with
  auto-detected components (otherwise nobody can tell where a component
  came from). Inside a component, absent fields are still detected:
  languages, Dockerfiles in `path` itself, `release_signals` (goreleaser,
  nested `Chart.yaml`, Flutter), `cgo`.
- **Build context = component path.** Every Dockerfile of a component —
  in `path` or attached via `dockerfiles[]` — builds with context `path`
  (`.` for the root). This is what makes mailstack's `COPY images/…` work.
- **`type: helm`** marks a chart component; `unittest: true` renders the
  `helm-unittest` step (via the new `lint-helm` input). `type` is only
  needed when the directory has no language marker; a `Chart.yaml` at
  `path` implies it.
- **Dockerfile annotations stay valid;** the manifest wins on conflict.
  Their deprecation is a separate major-version step.
- **Unknown keys are errors,** not warnings. A typo must not silently fall
  back to a default. Unknown `schema` values are errors too.
- **`gitops[]`** is an inventory in v1: validated, copied into the profile
  and the lock, surfaced in the onboarding PR body and
  `docs/onboarding-status.md` ("consumed by"). `mode: renovate` means the
  catalog does nothing active — rollout latency is governed by the
  consumer repo's Renovate preset. `mode: push` is reserved; v1 rejects it
  with "gitops mode push is not yet supported". `scope` is expressed in
  **file globs, never image references**; it documents both the template
  and the rendered copy on purpose.
- The manifest is a **render input**: its SHA-256 is recorded in the lock
  (`inputs.manifest_sha256`). See § 5.

### 2. Detect (`internal/app/detect/service.go`)

1. **Manifest parsing.** If `.github/onboard.yml` exists, parse and
   validate it (stdlib only — the Go CLI has zero external dependencies;
   the YAML subset above is flat enough for a small hand-written decoder
   or for shelling to `yq` through an adapter, to be decided in the plan;
   the contract is the schema, not the parser). Validation errors abort
   detect with a message naming the key and line.
2. **Fallback fix.** `fallbackDockerfilePaths` runs only when
   `!rootHasMarker`. A repo with a root language marker and sub-directory
   Dockerfiles but no manifest yields the root component plus warning
   `subdir_dockerfiles_unassigned` listing the orphaned Dockerfiles and
   pointing at the manifest. Honest instead of wrong.
3. **Bash fallback (`scripts/onboard-detect.sh`, `scripts/lib/`) gets no
   parser.** If it finds `.github/onboard.yml` it exits non-zero with
   "adopter manifest requires the Go CLI (use_go_cli: true)". This
   knowingly departs from the "fixes land in both engines" rule: a second
   YAML-schema implementation in Bash+yq would be a second parser with its
   own bug class, for a rollback path the Go default has not needed since
   2026-07-26. Fail-loud is the safer fallback. Adopters without a manifest
   run through Bash unchanged.
4. **Profile additions (additive, `schema_version` stays 1):**
   `components[].dockerfiles[].context`, `…platforms`, `components[].type`,
   `components[].unittest`, `workflows.e2e{script, schedule}`,
   `release.dispatch_trigger`, `gitops[]`, `manifest_sha256` (empty when no
   manifest). `image_name_source` gains the value `manifest`.
5. **Legacy scan** treats workflows the manifest declares (`e2e.yml`) as
   managed, not legacy.

### 3. Atoms

**`semantic-release.yml`** — two new outputs, existing ones unchanged:

| Output | Type | Content |
|---|---|---|
| `paths_released` | JSON array (string) | package paths released in this run, straight from `release-please-action` (`[]` when none) |
| `releases` | JSON object (string) | `{"<path>": {"tag_name", "version", "major", "minor"}}`, assembled with `jq` from the action's dynamic `<path>--*` outputs (workflow_call outputs must be declared statically, so the map is the only way to forward them) |

Single-package repos get `paths_released: ["."]` and a one-entry map;
`release_created` / `tag_name` / `major_tag` / `minor_tag` keep their
meaning, so existing callers see no change.

**`lint-helm.yml`** — new input `unittest` (boolean, default `false`).
When true the atom installs `helm-unittest` into a job-private
`HELM_PLUGINS` directory (pinned via a `# renovate:` annotation, `<1.1.0`
while Helm v3 is the default — 1.1.0 switched `plugin.yaml` to
`platformHooks`, which Helm v3 rejects) and runs `helm unittest
<chart_path>`. This replaces mailstack's inline job.

### 4. Templates (`docs/adopter-templates/`)

Hard constraint: **single-component adopters render byte-identically.**
Every change below lives behind `monorepo` / manifest conditions; a
snapshot test over the four live adopter profiles is the release gate.

- **`release.yml.tmpl`, monorepo branch.** Each component job is gated
  `if: contains(fromJSON(needs.release-please.outputs.paths_released), '<path>')`
  and receives
  `tag: v${{ fromJSON(needs.release-please.outputs.releases)['<path>'].version }}`
  — `version` is clean semver, so component tags like `postfix-v1.2.0`
  never need stripping. Components with more than one Dockerfile (the
  mailstack root: its own `tools` image, possibly more) call
  `docker-build-multi.yml` with `context: <path>` and an `images` JSON
  built from the profile. `release.dispatch_trigger` adds
  `workflow_dispatch: {}`.
- **`prerelease.yml.tmpl`.** Same component loop as release (fixes the
  first-component-only bug); builds every release-eligible image, no path
  gating (prerelease is manual/PR-scoped).
- **`release-please-config.monorepo.json.tmpl`.** Root `.` with
  `include-component-in-tag: false` (tags stay `vX.Y.Z`); sub-directory
  packages with `include-component-in-tag: true` (`postfix-vX.Y.Z`); chart
  components `release-type: helm` (release-please bumps `Chart.yaml`
  `version`); `separate-pull-requests: false` (one combined release PR);
  the standard `changelog-sections`. `.release-please-manifest.json` seeds
  every package from the current version (chart from its `Chart.yaml`).
- **`ci.yml.tmpl`.** A chart component (or `release_signals.chart_yaml` on
  any component) emits `lint-helm` (with `unittest` from the manifest) and
  `helm-publish` with `dry_run: true`. Go/Python/Rust/Flutter jobs stay as
  they are — CI is not path-filtered.
- **`e2e.yml.tmpl` (new).** Calls `e2e-kind.yml` with `script` from the
  manifest; triggers: `schedule` (if set), `workflow_dispatch`, tag push
  `v*`. Mirrors mailstack's hand-written `e2e.yml`.

### 5. Lock and drift

- `.github/onboard.lock.json` gains `inputs.manifest_sha256`.
- `drift` classifies a changed manifest as **`stale-lock`** (re-render
  required), never `modified` (hand edit). The existing render-and-compare
  path already picks this up because it re-renders from the working tree.
- The sweep's `no-lock` / `stale-lock` buckets handle manifest adopters
  like any other.

### 6. GitOps consumers — invariants recorded here, enforced later

- **Image references in `bootstrap/templates/**/*.j2` stay literal.** The
  moment a tag becomes `{{ wartung_version }}`, the Renovate match breaks
  and the version moves into `config.yaml` — a third copy. This is a rule
  for the GitOps repos, documented here because the manifest's `scope`
  relies on it.
- **Syntax detection is the engine's job.** Any future push path must
  reuse Renovate (see § Extension points), not re-implement its managers.

## Interface contracts

| Surface | Change | SemVer |
|---|---|---|
| `.github/onboard.yml` schema v1 | new adopter-facing contract | additive; breaking schema changes bump `schema` |
| `semantic-release.yml` outputs | `+paths_released`, `+releases` | minor |
| `lint-helm.yml` inputs | `+unittest` (default false) | minor |
| `profile.json` | new optional fields, `image_name_source: manifest` | minor (readers ignore unknown fields) |
| `onboard.lock.json` | `+inputs.manifest_sha256` | minor |
| Bash detect | errors on manifest presence | minor (new failure mode, documented) |
| Rendered output, single component | **unchanged** | — |

Catalog release: **v4.14.0**.

## Test strategy

- **Go unit tests:** manifest parsing (valid, unknown key, bad schema,
  `mode: push`), authoritative components with detected fill-ins, the
  fallback fix and its warning, image name precedence
  (manifest > annotation > derived), context derivation.
- **bats:** Bash detect fails loud on a manifest; every template stays
  byte-reproducible; **snapshot test: the four live adopter profiles
  (blupod-ui, flow, skytrack, skytrack-ui) render identically before and
  after** — this is the v4.14 release gate.
- **Golden renders:** new fixture `tests/fixtures/onboard/go-root-multi-image`
  (root `go.mod`, `images/{a,b}/Dockerfile` copying from root,
  `charts/demo`, `test/e2e/run.sh`, manifest) with expected `ci.yml`,
  `prerelease.yml`, `release.yml`, `e2e.yml`, release-please config +
  manifest, lock.
- **Integration (`integration.yml`):** the fixture through real
  `onboard` detect+render; `semantic-release.yml` dry-run asserting
  `paths_released`/`releases` shape for single and multi package;
  `lint-helm` with `unittest: true` on a chart fixture carrying one
  passing test.
- **Acceptance for mailstack:** `sk-workflows preview` against mailstack
  with its manifest must render what is hand-wired today. The 2026-08-21
  diff has to go to zero except for intended improvements (per-image
  `trivy-image` scan, `lint-helm`-owned unittest).

## Rollout

| Stage | Repo | Content | Gate |
|---|---|---|---|
| 1 — atoms | reusable-workflows | `semantic-release.yml` outputs; `lint-helm.yml` `unittest` | self-CI + integration; no template change → no drift |
| 2 — detect + templates | reusable-workflows | manifest parser, fallback fix, profile fields, monorepo templates, `e2e.yml.tmpl`, lock hash, Bash fail-loud, docs | snapshot test of the four live adopters green → tag v4.14.0 |
| 3 — mailstack | mailstack | commit `.github/onboard.yml`; dispatch `onboard.yml` → bot PR with rendered workflows + lock; `values.yaml` gets a default tag per image, `appVersion` `extra-files` removed; `Chart.yaml` seeded in the release-please manifest | first real release: a `fix(postfix): …` commit builds **only** postfix |
| 4 — Renovate | renovate-config, mailstack | homelab preset: `packageRule` for `ghcr.io/serverkraken/**` — no schedule, `minimumReleaseAge: 0`, automerge (own images are signed and scanned); mailstack `renovate.json`: `helm-values` on `charts/mailstack/values.yaml` so image bumps land as `fix(chart): …` | watch for automerge firing too early on own images |

homelab-mail-nue does not reference mailstack yet, so stage 3 migrates
nothing on the consumer side.

## Acceptance criteria

1. `sk-workflows preview` on the four live adopters is byte-identical to
   their current lock.
2. `sk-workflows preview` on mailstack with the manifest renders `ci.yml`
   (secscan, lint-go, test-go, lint-helm+unittest, helm-publish dry-run),
   `prerelease.yml` (six images, context `.`), `release.yml`
   (release-please; six path-gated image builds — `tools` bundled with the
   root —, per-image scan, path-gated `helm-publish`, `workflow_dispatch`),
   `e2e.yml`, monorepo release-please config with root `go`, five
   `simple` image packages and one `helm` package.
3. Image names are exactly `serverkraken/mailstack/<name>`.
4. A release touching only `images/postfix/**` produces tag
   `postfix-vX.Y.Z`, builds and scans only postfix, publishes no chart.
5. A manifest with an unknown key, `schema: 2`, or `mode: push` fails
   detect with a message naming the offending key.
6. Bash detect exits non-zero on a manifest with the documented message.
7. `docs/onboarding-status.md` lists mailstack's GitOps consumers.

## Extension points (not built now)

- **`gitops[].mode: push`** — `release.yml` sends a `repository_dispatch`
  to each consumer; a workflow there runs `renovatebot/github-action`
  scoped to the released package (`packageRules` via env, `scope` →
  `matchFileNames`). Minutes instead of the weekend schedule, one syntax
  engine, no duplicated logic. **Must be resolved first:** coexistence with
  the hosted Renovate app (two bot identities on the same `renovate/*`
  branches). Design it when stage 4 proves insufficient.
- **Annotation deprecation** — once every adopter with annotations carries
  a manifest, remove `onboard:image=` / `onboard:release=` in a major.
- **Tier-2 repo defaults in the manifest** — topics, required status
  checks, bot-PR assignees; replaces the `defaults_applied_at` lock marker
  gating.
- **Path-filtered CI** — only if monorepo CI time becomes a problem.

## Open questions / accepted defaults

- **YAML parsing without a dependency.** The plan decides between a
  minimal in-tree decoder for the flat schema and a `yq` adapter (the CLI
  already shells to `gh`, `git`, `gomplate`). Either way the contract is
  the schema; the CLI's zero-dependency stance is kept.
- **Component tag prefix** follows release-please's default
  (`<package-name>-vX.Y.Z`); not configurable in v1.
- **Chart package name** is the directory name (`mailstack`), tag
  `mailstack-vX.Y.Z` — distinct from the root's `vX.Y.Z`.
- **`cleanup-images.yml`** is assumed to handle slash-nested package names
  (`mailstack/postfix`); verify during stage 3, fix as a separate patch if
  not.
- The stale `docs/backlog-helm-and-detection-gaps` branch predates this
  spec; its backlog entries already live on `main`.

Related: `2026-05-30-gitops-support-design.md` (validation atoms for the
GitOps cluster repos themselves — a different concern),
`2026-08-20-e2e-kind-design.md` (the atom `e2e.yml.tmpl` targets).
