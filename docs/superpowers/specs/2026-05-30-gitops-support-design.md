# GitOps Repo Support — Design

**Date:** 2026-05-30
**Status:** Approved (design approved in conversation; "ja")
**Phase:** Phase-2 / detection-coverage audit follow-up (PR #165 backlog: `gitops_kubernetes` profile + atom set)

## Problem

The org's Talos/cluster-template GitOps repos have no buildable language, so the onboard detector classifies them `generic` and the renderer emits a trivy-fs-only `ci.yml`. The 2026-05-30 detection-coverage audit confirmed two such repos:

- **`serverkraken/homelab-study`** — hand-maintains four validation workflows the catalog does not consolidate: `kubeconform.yaml` (calls a bespoke `scripts/kubeconform.sh`: `kustomize build --enable-helm/--enable-exec | kubeconform` over `kubernetes/argo` + `kubernetes/apps`, with a SOPS age key for decryption), `kube-linter.yaml`, `gitleaks.yaml`, and a hand-rolled `trivy.yaml` that is nearly identical to the catalog's existing `trivy-fs` atom (it only adds `--skip-files` for secret samples).
- **`serverkraken/homelab-incus-oracle`** — the same cluster-template fingerprint (`kubernetes/{apps,argo}` + `bootstrap/` + `.sops.yaml` + `makejinja.toml` + `Taskfile.yaml`) but **zero validation today** — only `e2e.yaml` + label workflows.

Net: `homelab-study` carries drift-prone copies of logic that belongs in the catalog, and `homelab-incus-oracle` has no manifest validation at all. Neither is reachable by the renderer.

## Scope

**In scope:**
- Three new reusable atoms: `kube-validate.yml` (opinionated kubeconform), `kube-lint.yml` (kube-linter), `secret-scan.yml` (gitleaks, **general** — usable by any adopter).
- One additive enhancement to `trivy-fs.yml` (`files_ignore` → `--skip-files`).
- Toolchain composites for the new atoms.
- A `gitops_kubernetes` detection profile in `scripts/lib/onboard-detect-lib.sh` (+ legacy `onboard-detect.sh` path) and `detect_legacy_ci` cleanup recognition for the four superseded workflows.
- A `gitops` branch in `ci.yml.tmpl`, plus making the render set and lock-file manifest variant-aware so gitops repos render `ci.yml` only.
- bats unit tests, fixtures (happy + failure), self-CI + failure-paths-nightly integration callers, renderer golden tests.
- Auto-onboarding both repos after release (Add-PR for both; cleanup of `homelab-study`'s four legacy workflows).

**Out of scope (stays repo-specific, catalog leaves untouched):**
- `e2e.yaml` — SOPS-keyed cluster-configure matrix, too individual per the audit.
- `label-sync.yaml` / `labeler.yaml` — org-label and PR-hygiene; belongs to the existing Repo-Hygiene-Bootstrapping backlog item, not this phase.
- `homelab-study`'s `release.yaml` — bespoke calendar-versioned (`YYYY.M.patch`, monthly cron, `gh release create --generate-notes`). Not release-please, not artifact publishing. The gitops profile must **not** render the catalog's release-please `release.yml` over it.
- iOS, Play-Store, .NET — unrelated Phase-2 items.

## Background — how detection feeds rendering today

- `detect_languages` (lib) builds a per-component `languages[]` from filesystem markers (`go.mod`/`pyproject.toml`/`Cargo.toml`/`Chart.yaml`/`pubspec.yaml`+SDK/`package.json`); `primary_language = languages[0] // "generic"`.
- `SUPPORTED_LINT_TEST_LANGUAGES` gates which primaries avoid the `no_lint_test_atom` warning ("rendered ci.yml will fall back to secscan only").
- `detect_role` → service / cli / helm-app / mobile-app / library (informational; status report + warnings).
- `detect_legacy_ci` classifies an adopter's existing `.github/workflows/*` and suggests catalog replacements → drives the cleanup-PR path.
- `ci.yml.tmpl` always emits a `secscan` job (trivy-fs), then `range .profile.components` with branches keyed off `$c.primary_language` (go/python/rust/helm/flutter).
- `onboard-render.sh` renders a **fixed** skeleton set (`ci.yml`, `release.yml`, `prerelease.yml`, `cleanup.yml`) + release-please config/manifest from `docs/adopter-templates/{skeletons,configs}`, then writes a **fixed** file list into the schema-1 lock file. Drift-check compares against that lock list.

Both target repos carry `requirements.txt` + `mise.toml`/`Taskfile.yaml` but **no** `pyproject.toml`/`go.mod`/etc., so they are `generic` today — exactly where the gitops profile slots in.

## Approaches considered

- **A (chosen):** Opinionated `kube-validate` (catalog owns the build logic; inputs expressive enough to reproduce homelab-study's validated build), a **general** `secret-scan` atom, `primary_language="gitops"` as the renderer hook (reuses the component-range + lock machinery with one branch), and the **full phase** (atoms + detection + renderer + auto-onboard) in one spec.
- **B (rejected):** Thin-wrapper / hybrid `kube-validate` calling the adopter's own script. Lower consolidation; gives `incus-oracle` (no script) nothing to call. Rejected in favour of an opinionated atom whose inputs reproduce the bespoke build.
- **C (rejected):** gitleaks bundled gitops-only. Re-derives the same atom later when another repo wants history-aware secret scanning. Rejected for a general atom.
- **D (rejected):** A top-level `profile_kind` flag instead of `primary_language="gitops"`. More template special-casing; diverges from the uniform component structure.
- **E (rejected):** Atoms-first now, detection/renderer as a later phase. Cleaner handoffs but slower; user chose the full phase.

## Design per concern

### 1. `kube-validate.yml` (new, opinionated)

The catalog owns `kustomize build | kubeconform` in a bats-tested `scripts/kube-validate.sh`. The script generalizes `homelab-study`'s `scripts/kubeconform.sh`: for each root in `manifests_paths`, validate standalone top-level `*.yaml` **and** recursively-discovered `kustomization.yaml` trees (`kustomize build <dir> <kustomize_args> | kubeconform <kubeconform_args>`), failing on the first non-zero `PIPESTATUS`.

Inputs (defaults reproduce homelab-study's build exactly):

| Input | Type | Default | Notes |
|---|---|---|---|
| `manifests_paths` | string | `kubernetes` | Newline list of validate roots (rendered as `kubernetes/apps` + `kubernetes/argo` for both repos). |
| `kustomize_args` | string | `--load-restrictor=LoadRestrictionsNone --enable-helm --enable-alpha-plugins --enable-exec` | |
| `schema_locations` | string | `default` + `https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json` | Newline list → repeated `-schema-location`. |
| `skip_kinds` | string | `Secret` | → `-skip`. |
| `strict` | boolean | `true` | → `-strict`. |
| `ignore_missing_schemas` | boolean | `true` | → `-ignore-missing-schemas`. |
| `sops` | boolean | `false` | When true, write `age.key` from the secret and export `SOPS_AGE_KEY_FILE` before the build. Both repos decrypt via **ksops** (a kustomize exec-plugin: `kind: ksops` + `config.kubernetes.io/function: exec: path: ksops`); `--enable-exec` makes kustomize invoke the `ksops` binary, which reads `SOPS_AGE_KEY_FILE` natively. So the toolchain must ship `ksops` (+ `sops`), not standalone `age`. |
| `kustomize_version` / `kubeconform_version` | string | pinned in composite | Renovate-managed. |
| `runs_on` | string | `["self-hosted","Linux"]` | |

- **Secret:** `sops_age_key` (optional; required only when `sops: true`) + the standard catalog App-token secrets (`release_please_app_client_id`, `release_please_app_private_key`) for `.catalog` checkout.
- **Permissions:** `contents: read`. (No SARIF; kubeconform output is logs + step summary.)
- **Summary:** `## kube-validate` block per the step-summary convention (roots validated, pass/fail count).
- Drops the `mise`/`Taskfile`/`requirements.txt` dependency — the atom installs its own toolchain. This is the consolidation win.

### 2. `kube-lint.yml` (new)

kube-linter → SARIF → code-scanning, faithful to `homelab-study`'s `kube-linter.yaml` (install pinned CLI, lint, upload SARIF, fail on findings).

- Inputs: `manifests_path` (default `kubernetes/apps`), `config_path` (optional), `kube_linter_version` (pinned), `fail_on_findings` (default true), `upload_sarif` (default true), `runs_on`.
- **Config fallback:** when `config_path` is empty, the atom uses a baseline `.kube-linter.yaml` shipped in the catalog (read from the `.catalog` checkout), so `incus-oracle` (no config) gets coverage without authoring one. The renderer passes `config_path: .kube-linter.yaml` only when the adopter has its own (`profile.gitops.has_kube_linter_config`). The baseline is **not** committed into the adopter — the gitops render stays `ci.yml`-only.
- Permissions: `contents: read`, `security-events: write`, `actions: read`.
- Findings counted from SARIF (`jq '[.runs[].results[]] | length'`); SARIF upload guarded `if: ... github.event.pull_request.head.repo.full_name == github.repository` (fork-safe, matching trivy-fs).

### 3. `secret-scan.yml` (new, general)

gitleaks with the three modes from `homelab-study`'s `gitleaks.yaml` selected by `github.event_name`: PR-diff (`--log-opts=--no-merges BASE..HEAD`), push (`-1 HEAD`), manual full scan. `fetch-depth: 0` checkout for history.

- Inputs: `config_path` (optional `.gitleaks.toml`), `gitleaks_version` (pinned), `fail_on_findings` (default true), `upload_sarif` (default true), `fetch_depth` (default `0`), `runs_on`.
- **Config fallback:** empty `config_path` → gitleaks' built-in default ruleset. The renderer passes `config_path: .gitleaks.toml` only when the adopter has one (`profile.gitops.has_gitleaks_config`).
- Permissions: `contents: read`, `security-events: write`, `actions: read`.
- **General-purpose:** any adopter may call it directly; the gitops profile wires it in, but it is not gitops-coupled.

### 4. `trivy-fs.yml` (enhancement)

Add `files_ignore` (string, newline list, default `''`) → repeated `--skip-files`, alongside the existing `paths_ignore` (`--skip-dirs`). Additive, backwards-compatible. Lets the rendered gitops `secscan` reproduce `homelab-study`'s `trivy.yaml` skips (`secrets.sample.yaml`, `age.key`, `config.yaml`, …) and `--skip-dirs bootstrap/templates`.

### 5. Toolchain composites (`actions/`)

Following the `install-trivy` pattern (pinned, Renovate-managed, CLI install — never third-party scanning actions):
- `setup-kube-toolchain` — kustomize + kubeconform always; **sops + ksops** when `sops: true` (ksops is the exec-plugin that decrypts the in-tree `*.sops.yaml` generators during `kustomize build`). `helm` is **not** installed: both target repos pass `--enable-helm` but have zero `helmCharts:` kustomizations, so kustomize never invokes helm — add it to the composite only if a future adopter introduces in-kustomize helm inflation. Consumed by `kube-validate`.
- `install-kube-linter` — consumed by `kube-lint`.
- `install-gitleaks` — consumed by `secret-scan`.

### 6. Detection — `scripts/lib/onboard-detect-lib.sh`

- **`detect_gitops_kubernetes <repo>`** (new, repo-level): returns true when `kubernetes/` (dir) **AND** `.sops.yaml` **AND** (`makejinja.toml` **OR** `bootstrap/templates/`) all exist. The `.sops.yaml`+cluster-template conjunction prevents false positives on a service repo that merely ships a `kubernetes/` deploy dir.
- Applies **only** when no buildable language is detected at any component (both targets are `generic`). When matched, set the root component's `primary_language="gitops"`.
- Emit a `.profile.gitops` object: `{ manifests_paths, has_kube_linter_config, has_gitleaks_config, sops }`.
  - `manifests_paths` = the `kubernetes/{apps,argo}` dirs that exist (both repos have both; `bootstrap/` excluded — Talos bootstrap, not cluster workloads, matching homelab-study's script).
  - `has_kube_linter_config` = `.kube-linter.yaml` present; `has_gitleaks_config` = `.gitleaks.toml` present (these gate whether the renderer passes `config_path`); `sops` = `.sops.yaml` present.
- Register `gitops` as a known profile kind so it is **excluded** from the `no_lint_test_atom` warning (it has an atom set, just not lint/test-named).
- **`detect_role`** — return `gitops` for a matched repo (informational only).
- **`detect_legacy_ci`** — recognize `kubeconform.yaml`, `kube-linter.yaml`, `gitleaks.yaml`, and a manifest-scoped `trivy.yaml` as superseded by `kube-validate` / `kube-lint` / `secret-scan` / `trivy-fs`, so the cleanup-PR removes them on `homelab-study`'s onboard.

### 7. Legacy path — `scripts/onboard-detect.sh`

Add the gitops marker conjunction to the legacy `matches+=(...)` list so `language=gitops` shows in the onboarding status report (cosmetic; renderer uses `profile_json`). Update `actions/onboard-detect/action.yml` `language_override` doc string to mention `gitops`.

### 8. Rendering — `ci.yml.tmpl` + `onboard-render.sh`

- **`ci.yml.tmpl`** — add a branch to the `primary_language` chain:

```gotemplate
{{- else if eq $c.primary_language "gitops" }}
  kube-validate:
    uses: serverkraken/reusable-workflows/.github/workflows/kube-validate.yml@{{ $pin }}
    with:
      manifests_paths: |-
        {{- range $.profile.gitops.manifests_paths }}
        {{ . }}
        {{- end }}
      sops: {{ $.profile.gitops.sops }}
    secrets: inherit
  kube-lint:
    uses: serverkraken/reusable-workflows/.github/workflows/kube-lint.yml@{{ $pin }}
    {{- if $.profile.gitops.has_kube_linter_config }}
    with:
      config_path: .kube-linter.yaml
    {{- end }}
    secrets: inherit
  secret-scan:
    uses: serverkraken/reusable-workflows/.github/workflows/secret-scan.yml@{{ $pin }}
    {{- if $.profile.gitops.has_gitleaks_config }}
    with:
      config_path: .gitleaks.toml
    {{- end }}
    secrets: inherit
{{- end }}
```

  Top-level profile fields are reached with `$.profile.gitops` (the `$` root) because `.` is rebound to `$c` inside `range .profile.components`. The always-on `secscan` (trivy-fs) job renders with the generic gitops skip set — `paths_ignore: bootstrap/templates` (jinja templates, not live manifests) and `files_ignore` covering `*.sample.yaml` / `age.key` secret artifacts. Caller `permissions:` at the top of `ci.yml` declare the **union** of the nested atoms' needs (`contents: read`, `security-events: write`, `actions: read`) per the chained-reusable ceiling rule.

- **`onboard-render.sh`** — gate `release.yml`, `prerelease.yml`, `cleanup.yml`, `release-please-config.json`, `.release-please-manifest.json` behind "not gitops". For a gitops profile, render **`ci.yml` only**.
- **Lock file** — make the `files=(...)` array (and the post-render existence assertions) variant-aware: gitops locks `[".github/workflows/ci.yml"]`. Drift-check already iterates the lock's file list, so it follows automatically.

## Interface contracts

- **profile.json (additive; `schema_version` stays 1):**
  - `primary_language` may now be `"gitops"`; `role` may now be `"gitops"`.
  - New `profile.gitops` object as in §6. All additive — no existing field changes shape; no break for any current adopter.
- **New atoms** — input/secret/output shapes documented at the top of each file (the catalog's stability surface). `secret-scan` and the `trivy-fs` `files_ignore` addition are independently consumable.
- **Adopter secret:** `kube-validate` with `sops: true` requires an adopter `SOPS_AGE_KEY` (both repos already have it for `e2e`). **Gate:** per the standing rule, get explicit confirmation before wiring any secret name into rendered adopter workflows.
- **Adopter override vars (optional, documented in `docs/operations.md`):** `SK_KUBECONFORM_VERSION`, `SK_KUSTOMIZE_VERSION`, `SK_KUBE_LINTER_VERSION`, `SK_GITLEAKS_VERSION` — version pins, mirroring `SK_TRIVY_VERSION`. Defaults empty → composite defaults.

## Test strategy

- **bats — detection:** `detect_gitops_kubernetes` true on the marker conjunction, false when any leg missing (esp. `kubernetes/` without `.sops.yaml`); `primary_language=gitops`, no `no_lint_test_atom` warning; `profile.gitops.manifests_paths` = `[kubernetes/apps, kubernetes/argo]`; `detect_legacy_ci` flags the four workflows.
- **bats — `scripts/kube-validate.sh`:** standalone-manifest pass/fail, kustomization build+validate pass/fail, multi-root iteration, first-failure exit, sops-key wiring. ≥90% line coverage (catalog policy).
- **bats — render:** gitops profile → `ci.yml` has `kube-validate` (with `manifests_paths` + `sops`), `kube-lint`, `secret-scan`, `secscan`; **no** `release.yml`/`prerelease.yml`/`cleanup.yml`/release-please files rendered; lock lists `ci.yml` only.
- **Fixtures:** `tests/fixtures/gitops-cluster/` — minimal `kubernetes/{apps,argo}` with a kustomization + a skippable sops secret + `.kube-linter.yaml` + `.gitleaks.toml` (happy path); plus invalid-manifest / lint-violation / planted-secret variants for failures.
- **Integration:** gitops happy-path callers in `self-ci.yml`; failure callers in `failure-paths-nightly.yml` using the `test-X-fail` + `assert-X-fail (if: always())` two-job pattern (`continue-on-error` is unsupported on `workflow_call` jobs); branch protection requires only the `assert-*` summaries.
- **Static:** actionlint + yamllint on the new atoms; reuse the `create-github-app-token` v3 `-ignore` flags for `client-id` in `validate.yml` for any new atom that mints the App token.

## PR plan (full phase; sequencing finalized in the implementation plan)

Each PR in its own worktree under `.worktrees/`, branched from `origin/main`, two-stage review (spec-reviewer → code-quality-reviewer) before opening.

1. **Atoms + composites + trivy-fs enhancement + fixtures + bats + integration callers.** `feat(atoms): kube-validate, kube-lint, secret-scan + trivy-fs files_ignore`.
2. **Detection + renderer + golden tests + legacy-ci recognition.** `feat(onboard): detect gitops_kubernetes and render kube validation ci`.
3. Release the catalog (minor bump → **v4.8.0**; everything additive).
4. **Auto-onboard** (post-release): onboard-sweep opens an Add-PR for both repos — `homelab-study`'s also cleans up the four legacy workflows; `incus-oracle`'s is net-new validation falling back to the catalog baseline kube-linter config and gitleaks' built-in ruleset. Confirm `SOPS_AGE_KEY` presence before merge.

## Acceptance criteria

- `onboard-detect.sh --profile-json <homelab-study>` → `primary_language=gitops`, `role=gitops`, `profile.gitops.manifests_paths=["kubernetes/apps","kubernetes/argo"]`, `profile.gitops.sops=true`, zero warnings.
- Rendering that profile → `ci.yml` has `secscan` + `kube-validate` (sops, both roots) + `kube-lint` + `secret-scan`; **no** release/prerelease/cleanup/release-please files; lock lists `ci.yml` only.
- `kube-validate` against `tests/fixtures/gitops-cluster/` passes the valid tree and fails the invalid one; `kube-lint`/`secret-scan` likewise green/red on their fixtures.
- The rendered `homelab-study` `ci.yml` is functionally equivalent to its four hand-rolled workflows (same roots, schema locations, kustomize flags, skip rules), so adoption is a no-regression swap.
- `actionlint` + `yamllint` + `bats` all green; existing non-gitops detect/render tests unchanged and green.

## Open questions / accepted defaults

1. **Atom naming:** `kube-validate.yml` + `kube-lint.yml` (groups the kube-* concern) vs. `lint-kube.yml` for `lint-*` family consistency. **Accepted:** `kube-validate` + `kube-lint`.
2. **Runner label drift:** both repos use a non-canonical `[self-hosted, amd64]`. Rendered workflows standardize to the canonical `[self-hosted, Linux]` (atom default). **Accepted.**
3. **`SOPS_AGE_KEY` secret** wiring into rendered adopter workflows requires explicit confirmation before the onboard step. **Gate, not a default.**
4. **Baseline `.kube-linter.yaml` / `.gitleaks.toml`** content (for adopters without their own) to be authored in PR 1; start permissive, tighten later. **Accepted.**
5. **`manifests_paths`** detection assumes the cluster-template `apps`+`argo` convention. If a future gitops adopter diverges, the detector enumerates existing `kubernetes/*` workload dirs (excluding `bootstrap`). **Accepted.**
