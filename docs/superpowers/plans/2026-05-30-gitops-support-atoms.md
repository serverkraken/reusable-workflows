# GitOps Support — Plan 1: Atom Set Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three new reusable atoms (`kube-validate`, `kube-lint`, `secret-scan`), their toolchain composites, a `files_ignore` enhancement to `trivy-fs`, GitOps fixtures, bats tests, and PR-time integration wiring — so the catalog can validate Talos/cluster-template Kubernetes repos.

**Architecture:** Each atom follows the established catalog plumbing: `actions/checkout` → mint catalog-scoped GitHub App token → resolve catalog ref (self-CI = `github.sha`, cross-repo = floating `v4`) → checkout `.catalog` → run a `.catalog/actions/<composite>` install + a `.catalog/scripts/*.sh` (for `kube-validate`) → count/summarize/gate. `kube-validate` and `kube-lint` scan a path scope; `secret-scan` is git-history-aware (PR-diff / push / full) with an additional `--no-git --source <dir>` filesystem mode for deterministic fixture testing. `kube-lint` and `secret-scan` expose a `findings_count` output and are tested with the count-based "find-something" pattern in `integration.yml`; `kube-validate` is a hard-fail validator tested happy in `integration.yml` and red in `failure-paths-nightly.yml`.

**Tech Stack:** GitHub Actions reusable workflows (`workflow_call`) + composite actions, bash, bats (≥90% line coverage policy on shell), kustomize, kubeconform, ksops/sops, kube-linter, gitleaks, trivy. Validation: `actionlint` + `yamllint -s .github/` + `bats tests/shell/`.

**Spec:** `docs/superpowers/specs/2026-05-30-gitops-support-design.md`. This plan implements PR 1 (atoms). PR 2 (detection + renderer + onboard) is a separate plan that depends on these atoms existing.

---

## Preamble: worktree

This plan's work lives on a dedicated branch in its own worktree (catalog convention; see spec PR plan). Before Task 1:

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git worktree list                       # confirm no conflicting worktree
git fetch origin
git worktree add .worktrees/gitops-atoms -b feat/gitops-atoms origin/main
cd .worktrees/gitops-atoms
```

All subsequent paths in this plan are relative to the worktree root (which mirrors the repo root). Tools (`actionlint`, `yamllint`, `bats`, `shellcheck`) install on first use per CONTRIBUTING.

---

## File Structure

**Create:**
- `actions/setup-kube-toolchain/action.yml` — installs kustomize + kubeconform; sops + ksops when `sops: 'true'`. (Task 1)
- `actions/install-kube-linter/action.yml` — installs kube-linter CLI. (Task 4)
- `actions/install-gitleaks/action.yml` — installs gitleaks CLI. (Task 5)
- `scripts/kube-validate.sh` — `kustomize build | kubeconform` over manifest roots; collect-all-then-fail. (Task 2)
- `tests/shell/kube-validate.bats` — unit tests for the script (stubbed kustomize/kubeconform). (Task 2)
- `configs/kube-linter.yaml` — catalog baseline kube-linter config (used when the adopter has none). (Task 4)
- `.github/workflows/kube-validate.yml` — opinionated manifest validation atom. (Task 3)
- `.github/workflows/kube-lint.yml` — kube-linter atom (SARIF, `findings_count`). (Task 4)
- `.github/workflows/secret-scan.yml` — general gitleaks atom (SARIF, `findings_count`). (Task 5)
- `tests/fixtures/gitops-cluster/**` — happy fixture (valid manifests, clean of secrets). (Task 7)
- `tests/fixtures/gitops-invalid-manifest/**` — kubeconform-failing fixture. (Task 7)
- `tests/fixtures/gitops-lint-violation/**` — kube-linter-tripping fixture. (Task 7)
- `tests/fixtures/gitops-planted-secret/**` — gitleaks-detectable fixture. (Task 7)

**Modify:**
- `.github/workflows/trivy-fs.yml` — add `files_ignore` input → `--skip-files`. (Task 6)
- `.github/workflows/integration.yml` — add happy + find-something callers for the three atoms. (Task 8)
- `.github/workflows/failure-paths-nightly.yml` — add `test-kube-validate-fail` + `assert-kube-validate-fail`; extend `report-regressions` needs. (Task 8)
- `docs/operations.md` — document new `SK_*` version override vars and the three atoms. (Task 10)

**Pinned action SHAs (reuse verbatim; do not re-resolve):**
- `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6`
- `actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3`
- `github/codeql-action/upload-sarif@7211b7c8077ea37d8641b6271f6a365a22a5fbfa # v4`
- `actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7`

---

### Task 1: `setup-kube-toolchain` composite

**Files:**
- Create: `actions/setup-kube-toolchain/action.yml`

- [ ] **Step 1: Write the composite**

Create `actions/setup-kube-toolchain/action.yml`:

```yaml
name: setup-kube-toolchain
description: |
  Install kustomize + kubeconform (direct binary installs, pinned,
  Renovate-managed — never third-party setup actions). When `sops: 'true'`,
  also install sops + ksops so `kustomize build --enable-exec` can decrypt
  in-tree SOPS generators (kind: ksops). Mirrors the install-trivy pattern.
  Does NOT install helm: the current GitOps adopters pass --enable-helm but
  have zero in-kustomize helmCharts, so kustomize never invokes helm.

inputs:
  kustomize_version:
    description: 'kustomize version (no leading v). Empty → pinned default.'
    required: false
    default: ''
  kubeconform_version:
    description: 'kubeconform version (no leading v). Empty → pinned default.'
    required: false
    default: ''
  sops:
    description: 'When "true", also install sops + ksops for SOPS decryption.'
    required: false
    default: 'false'

runs:
  using: composite
  steps:
    - name: Install kustomize
      shell: bash
      env:
        # renovate: datasource=github-releases depName=kubernetes-sigs/kustomize extractVersion=^kustomize/v(?<version>.+)$
        KUSTOMIZE_VERSION: '5.5.0'
        REQUESTED: ${{ inputs.kustomize_version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$KUSTOMIZE_VERSION}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=amd64 ;;
          aarch64|arm64) A=arm64 ;;
          *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; cd "$TMP"
        curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${VERSION}/kustomize_v${VERSION}_linux_${A}.tar.gz" -o k.tar.gz
        tar -xzf k.tar.gz kustomize
        sudo install -m 0755 kustomize /usr/local/bin/kustomize
        kustomize version

    - name: Install kubeconform
      shell: bash
      env:
        # renovate: datasource=github-releases depName=yannh/kubeconform
        KUBECONFORM_VERSION: '0.6.7'
        REQUESTED: ${{ inputs.kubeconform_version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$KUBECONFORM_VERSION}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=amd64 ;;
          aarch64|arm64) A=arm64 ;;
          *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; cd "$TMP"
        curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${VERSION}/kubeconform-linux-${A}.tar.gz" -o kc.tar.gz
        tar -xzf kc.tar.gz kubeconform
        sudo install -m 0755 kubeconform /usr/local/bin/kubeconform
        kubeconform -v

    - name: Install sops + ksops
      if: ${{ inputs.sops == 'true' }}
      shell: bash
      env:
        # renovate: datasource=github-releases depName=getsops/sops
        SOPS_VERSION: '3.9.4'
        # renovate: datasource=github-releases depName=viaduct-ai/kustomize-sops
        KSOPS_VERSION: '4.3.3'
      run: |
        set -euo pipefail
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=amd64; KA=x86_64 ;;
          aarch64|arm64) A=arm64; KA=arm64 ;;
          *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        # sops — single static binary
        curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${A}" -o sops
        sudo install -m 0755 sops /usr/local/bin/sops
        sops --version
        # ksops — kustomize exec-plugin; MUST be on PATH for --enable-exec
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        curl -fsSL "https://github.com/viaduct-ai/kustomize-sops/releases/download/v${KSOPS_VERSION}/ksops_${KSOPS_VERSION}_Linux_${KA}.tar.gz" -o "$TMP/ksops.tar.gz"
        tar -xzf "$TMP/ksops.tar.gz" -C "$TMP" ksops
        sudo install -m 0755 "$TMP/ksops" /usr/local/bin/ksops
        ksops --version || true
```

- [ ] **Step 2: Validate**

Run: `actionlint actions/setup-kube-toolchain/action.yml && yamllint -s actions/setup-kube-toolchain/action.yml`
Expected: no output (pass). If actionlint complains it can't find the file as a workflow, run repo-root `actionlint` (it lints `.github/workflows`); composite YAML is covered by `yamllint`. Also run `shellcheck` on the embedded scripts is not directly possible; rely on `set -euo pipefail` + the actionlint shellcheck integration during `validate.yml`.

- [ ] **Step 3: Commit**

```bash
git add actions/setup-kube-toolchain/action.yml
git commit -m "feat(actions): add setup-kube-toolchain composite (kustomize, kubeconform, ksops)"
```

---

### Task 2: `scripts/kube-validate.sh` + bats (TDD)

The core orchestration logic. The bats stubs `kustomize`/`kubeconform` on `PATH` to test iteration, arg construction, and failure propagation hermetically (real tools are exercised by the Task 8 integration job). Generalizes `homelab-study/scripts/kubeconform.sh`, fixing two latent bugs in the original: (a) it only checked `PIPESTATUS[0]` (kustomize), missing kubeconform failures; (b) its `find | while … exit 1` ran the loop in a pipe subshell, so an `exit 1` could not abort the script. This version uses `done < <(find …)` (loop in the current shell) and a `fail` flag with a final `exit 1`, so it **collects all failures then fails** (friendlier than fail-fast and still satisfies "fails the invalid tree").

**Files:**
- Create: `scripts/kube-validate.sh`
- Test: `tests/shell/kube-validate.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/shell/kube-validate.bats`:

```bash
#!/usr/bin/env bats
# Unit tests for scripts/kube-validate.sh. Stubs kustomize + kubeconform on
# PATH so the orchestration logic is tested without the real binaries.

setup() {
  TESTDIR="$(mktemp -d)"
  BINDIR="$TESTDIR/bin"
  mkdir -p "$BINDIR"
  ARGLOG="$TESTDIR/arglog"; : > "$ARGLOG"

  cat > "$BINDIR/kubeconform" <<'EOF'
#!/usr/bin/env bash
echo "kubeconform $*" >> "$ARGLOG"
exit "${KUBECONFORM_EXIT:-0}"
EOF
  cat > "$BINDIR/kustomize" <<'EOF'
#!/usr/bin/env bash
echo "kustomize $*" >> "$ARGLOG"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n'
exit "${KUSTOMIZE_EXIT:-0}"
EOF
  chmod +x "$BINDIR/kubeconform" "$BINDIR/kustomize"
  export PATH="$BINDIR:$PATH" ARGLOG
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/kube-validate.sh"
  TREE="$TESTDIR/tree"
}
teardown() { rm -rf "$TESTDIR"; }

@test "validates a standalone top-level yaml via kubeconform" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "kubeconform .*$TREE/argo/app.yaml" "$ARGLOG"
}

@test "builds and validates a kustomization tree" {
  mkdir -p "$TREE/apps/web"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n' > "$TREE/apps/web/kustomization.yaml"
  MANIFESTS_PATHS="$TREE/apps" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "kustomize build $TREE/apps/web" "$ARGLOG"
}

@test "fails when kubeconform rejects a manifest" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/bad.yaml"
  KUBECONFORM_EXIT=1 MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when kustomize build errors (pipefail catches the producer)" {
  mkdir -p "$TREE/apps/web"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n' > "$TREE/apps/web/kustomization.yaml"
  KUSTOMIZE_EXIT=1 MANIFESTS_PATHS="$TREE/apps" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "iterates every newline-separated root" {
  mkdir -p "$TREE/apps/web" "$TREE/argo"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n' > "$TREE/apps/web/kustomization.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  MANIFESTS_PATHS=$'%s\n%s' run bash -c 'MANIFESTS_PATHS="'"$TREE/apps"$'\n'"$TREE/argo"'" bash "$0"' "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "kustomize build $TREE/apps/web" "$ARGLOG"
  grep -q "kubeconform .*$TREE/argo/app.yaml" "$ARGLOG"
}

@test "STRICT=false omits -strict and does not abort under errexit" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  STRICT=false MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q -- "-strict" "$ARGLOG"
}

@test "SKIP_KINDS and SCHEMA_LOCATIONS flow into kubeconform argv" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  SKIP_KINDS="Secret" SCHEMA_LOCATIONS=$'default\nhttps://example.test/{{.ResourceKind}}.json' \
    MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- "-skip Secret" "$ARGLOG"
  grep -q -- "-schema-location default" "$ARGLOG"
  grep -q -- "-schema-location https://example.test" "$ARGLOG"
}

@test "missing root warns and does not fail" {
  MANIFESTS_PATHS="$TREE/does-not-exist" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/shell/kube-validate.bats`
Expected: FAIL — `scripts/kube-validate.sh` does not exist yet (all tests error).

- [ ] **Step 3: Write the script**

Create `scripts/kube-validate.sh`:

```bash
#!/usr/bin/env bash
# Validate Kubernetes manifests under each root in MANIFESTS_PATHS:
#   - kubeconform every standalone top-level *.yaml (maxdepth 1)
#   - `kustomize build <dir> | kubeconform` for every discovered
#     kustomization.yaml tree
# Collects all failures, then exits non-zero if any occurred.
#
# Generalizes serverkraken/homelab-study scripts/kubeconform.sh. Two fixes
# vs. the original: (1) honour BOTH pipe stages (pipefail), not just
# PIPESTATUS[0]=kustomize; (2) run the find-loop in the current shell
# (`done < <(...)`) so failures actually abort instead of dying in a pipe
# subshell.
#
# Env contract (set by .github/workflows/kube-validate.yml):
#   MANIFESTS_PATHS        newline-separated roots (required)
#   KUSTOMIZE_ARGS         args passed verbatim to `kustomize build`
#   SCHEMA_LOCATIONS       newline-separated kubeconform -schema-location values
#   SKIP_KINDS             comma-separated kinds → kubeconform -skip
#   STRICT                 "true"|"false" → kubeconform -strict
#   IGNORE_MISSING_SCHEMAS "true"|"false" → kubeconform -ignore-missing-schemas
set -o errexit
set -o nounset
set -o pipefail

: "${MANIFESTS_PATHS:?MANIFESTS_PATHS is required (newline-separated roots)}"
KUSTOMIZE_ARGS="${KUSTOMIZE_ARGS:-}"
SCHEMA_LOCATIONS="${SCHEMA_LOCATIONS:-default}"
SKIP_KINDS="${SKIP_KINDS:-}"
STRICT="${STRICT:-true}"
IGNORE_MISSING_SCHEMAS="${IGNORE_MISSING_SCHEMAS:-true}"

kubeconform_args=(-verbose)
if [[ "$STRICT" == "true" ]]; then
  kubeconform_args+=(-strict)
fi
if [[ "$IGNORE_MISSING_SCHEMAS" == "true" ]]; then
  kubeconform_args+=(-ignore-missing-schemas)
fi
if [[ -n "$SKIP_KINDS" ]]; then
  kubeconform_args+=(-skip "$SKIP_KINDS")
fi
while IFS= read -r loc; do
  [[ -z "$loc" ]] && continue
  kubeconform_args+=(-schema-location "$loc")
done <<< "$SCHEMA_LOCATIONS"

# Intentional word-splitting of the verbatim kustomize args string.
read -r -a kustomize_args <<< "$KUSTOMIZE_ARGS" || true

fail=0

validate_root() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    echo "::warning::kube-validate: manifests root not found: ${root} (skipping)"
    return 0
  fi

  echo "=== Standalone manifests in ${root} ==="
  local file
  while IFS= read -r -d '' file; do
    echo "--- kubeconform ${file}"
    if ! kubeconform "${kubeconform_args[@]}" "$file"; then
      echo "::error::kubeconform failed: ${file}"
      fail=1
    fi
  done < <(find "$root" -maxdepth 1 -type f -name '*.yaml' -print0)

  echo "=== Kustomizations in ${root} ==="
  local kfile dir
  while IFS= read -r -d '' kfile; do
    dir="$(dirname "$kfile")"
    echo "--- kustomize build ${dir}"
    if ! kustomize build "$dir" "${kustomize_args[@]}" | kubeconform "${kubeconform_args[@]}"; then
      echo "::error::validation failed: ${dir}"
      fail=1
    fi
  done < <(find "$root" -type f -name 'kustomization.yaml' -print0)
}

while IFS= read -r root; do
  [[ -z "$root" ]] && continue
  validate_root "$root"
done <<< "$MANIFESTS_PATHS"

if [[ "$fail" -ne 0 ]]; then
  echo "::error::kube-validate: one or more manifests failed validation"
  exit 1
fi
echo "kube-validate: all manifests valid"
```

Then make it executable:

```bash
chmod +x scripts/kube-validate.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/shell/kube-validate.bats`
Expected: PASS (8 tests).

- [ ] **Step 5: Coverage check (catalog ≥90% policy)**

Run: `kcov --include-path=scripts/kube-validate.sh /tmp/kcov-kv bats tests/shell/kube-validate.bats` (or `bashcov` if that is the configured tool). Confirm `scripts/kube-validate.sh` ≥90% line coverage. If a branch is uncovered, add a focused bats case.

- [ ] **Step 6: Commit**

```bash
git add scripts/kube-validate.sh tests/shell/kube-validate.bats
git commit -m "feat(scripts): add kube-validate.sh (kustomize build | kubeconform over roots)"
```

---

### Task 3: `kube-validate.yml` atom

**Files:**
- Create: `.github/workflows/kube-validate.yml`

- [ ] **Step 1: Write the atom**

Create `.github/workflows/kube-validate.yml`:

```yaml
# .github/workflows/kube-validate.yml
# Summary convention: docs/conventions/step-summary.md
#
# Stability surface (workflow_call contract — breaking changes = major bump):
#   inputs:  manifests_paths, kustomize_args, schema_locations, skip_kinds,
#            strict, ignore_missing_schemas, sops, kustomize_version,
#            kubeconform_version, runs_on
#   secrets: sops_age_key (optional; required when sops: true),
#            release_please_app_client_id, release_please_app_private_key
#   outputs: (none — pass/fail validator)
name: kube-validate
on:
  workflow_call:
    inputs:
      manifests_paths:
        description: 'Newline-separated validate roots (e.g. kubernetes/apps).'
        required: false
        type: string
        default: 'kubernetes'
      kustomize_args:
        description: 'Args passed verbatim to `kustomize build`.'
        required: false
        type: string
        default: '--load-restrictor=LoadRestrictionsNone --enable-helm --enable-alpha-plugins --enable-exec'
      schema_locations:
        description: 'Newline-separated kubeconform -schema-location values.'
        required: false
        type: string
        default: |-
          default
          https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
      skip_kinds:
        description: 'Comma-separated kinds passed to kubeconform -skip.'
        required: false
        type: string
        default: 'Secret'
      strict:
        description: 'Pass -strict to kubeconform.'
        required: false
        type: boolean
        default: true
      ignore_missing_schemas:
        description: 'Pass -ignore-missing-schemas to kubeconform.'
        required: false
        type: boolean
        default: true
      sops:
        description: 'Decrypt in-tree SOPS generators via ksops during build. Requires the sops_age_key secret.'
        required: false
        type: boolean
        default: false
      kustomize_version:
        description: 'Override kustomize version (empty → composite default).'
        required: false
        type: string
        default: ''
      kubeconform_version:
        description: 'Override kubeconform version (empty → composite default).'
        required: false
        type: string
        default: ''
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
    secrets:
      sops_age_key:
        required: false
        description: 'AGE secret key for SOPS decryption (required only when sops: true).'
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'

permissions:
  contents: read

concurrency:
  group: kube-validate-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  validate:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
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
            echo "Self-CI: catalog ref = $SELF_SHA"
          else
            # renovate-marker: catalog-major-ref
            echo "ref=v4" >> "$GITHUB_OUTPUT"
            echo "Cross-repo: catalog ref = v4 (floating)"
          fi
      - name: Checkout catalog for composite actions
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ steps.catalog-ref.outputs.ref }}
          token: ${{ steps.catalog-token.outputs.token }}
          path: .catalog
      - name: Setup kube toolchain
        uses: ./.catalog/actions/setup-kube-toolchain
        with:
          kustomize_version: ${{ inputs.kustomize_version }}
          kubeconform_version: ${{ inputs.kubeconform_version }}
          sops: ${{ inputs.sops }}
      - name: Write SOPS age key
        if: inputs.sops
        env:
          SOPS_AGE_KEY: ${{ secrets.sops_age_key }}
        run: |
          if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
            echo "::error::sops: true but secret sops_age_key is empty"
            exit 1
          fi
          echo "$SOPS_AGE_KEY" > age.key
          chmod 600 age.key
          echo "SOPS_AGE_KEY_FILE=$GITHUB_WORKSPACE/age.key" >> "$GITHUB_ENV"
      - name: Validate manifests
        env:
          MANIFESTS_PATHS: ${{ inputs.manifests_paths }}
          KUSTOMIZE_ARGS: ${{ inputs.kustomize_args }}
          SCHEMA_LOCATIONS: ${{ inputs.schema_locations }}
          SKIP_KINDS: ${{ inputs.skip_kinds }}
          STRICT: ${{ inputs.strict }}
          IGNORE_MISSING_SCHEMAS: ${{ inputs.ignore_missing_schemas }}
        run: bash .catalog/scripts/kube-validate.sh
      - name: Cleanup age key
        if: always() && inputs.sops
        run: rm -f age.key
      - name: Summary
        if: always()
        env:
          MANIFESTS_PATHS: ${{ inputs.manifests_paths }}
          OUTCOME: ${{ job.status }}
        run: |
          if [[ "$OUTCOME" == "success" ]]; then
            result="✓ all manifests valid"
          else
            result="✗ validation failed"
          fi
          {
            echo "## kube-validate"
            echo ""
            echo "**Result:** ${result}"
            echo ""
            echo "**Roots:**"
            while IFS= read -r r; do
              [[ -z "$r" ]] && continue
              echo "- \`${r}\`"
            done <<< "$MANIFESTS_PATHS"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 2: Validate**

Run: `actionlint && yamllint -s .github/workflows/kube-validate.yml`
Expected: pass (the `client-id` / `app-id` actionlint warnings are globally `-ignore`d in `validate.yml`; running bare `actionlint` locally may surface them — that is expected and handled in CI).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/kube-validate.yml
git commit -m "feat(atoms): add kube-validate workflow (opinionated kubeconform)"
```

---

### Task 4: `install-kube-linter` composite + baseline config + `kube-lint.yml` atom

**Files:**
- Create: `actions/install-kube-linter/action.yml`
- Create: `configs/kube-linter.yaml`
- Create: `.github/workflows/kube-lint.yml`

- [ ] **Step 1: Write the install composite**

Create `actions/install-kube-linter/action.yml`:

```yaml
name: install-kube-linter
description: |
  Install the kube-linter CLI at a pinned version (direct binary install,
  Renovate-managed). Empty `version` → pinned default.

inputs:
  version:
    description: 'kube-linter version (with or without leading v). Empty → pinned default.'
    required: false
    default: ''

runs:
  using: composite
  steps:
    - name: Install kube-linter CLI
      shell: bash
      env:
        # renovate: datasource=github-releases depName=stackrox/kube-linter
        KUBE_LINTER_VERSION: 'v0.8.3'
        REQUESTED: ${{ inputs.version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$KUBE_LINTER_VERSION}"
        case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) ASSET=kube-linter-linux.tar.gz ;;
          aarch64|arm64) ASSET=kube-linter-linux-arm64.tar.gz ;;
          *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; cd "$TMP"
        curl -fsSL "https://github.com/stackrox/kube-linter/releases/download/${VERSION}/${ASSET}" -o kl.tar.gz
        tar -xzf kl.tar.gz kube-linter
        sudo install -m 0755 kube-linter /usr/local/bin/kube-linter
        kube-linter version
```

- [ ] **Step 2: Write the baseline config**

Create `configs/kube-linter.yaml` (permissive baseline per spec open-Q 4 — keeps kube-linter's default checks so an adopter without a config still gets coverage; tighten later):

```yaml
# Catalog baseline kube-linter config. Consumed at runtime by kube-lint.yml
# (from the .catalog checkout) when an adopter passes no config_path. Keeps
# kube-linter's built-in default checks; intentionally adds no custom checks
# and disables none, so the baseline = upstream defaults. Tighten in a later
# pass once adopters are clean.
checks:
  addAllBuiltIn: false
  doNotAutoAddDefaults: false
```

- [ ] **Step 3: Write the atom**

Create `.github/workflows/kube-lint.yml`:

```yaml
# .github/workflows/kube-lint.yml
# Summary convention: docs/conventions/step-summary.md
#
# Stability surface (workflow_call contract — breaking changes = major bump):
#   inputs:  manifests_path, config_path, kube_linter_version,
#            fail_on_findings, upload_sarif, runs_on
#   secrets: release_please_app_client_id, release_please_app_private_key
#   outputs: findings_count
name: kube-lint
on:
  workflow_call:
    inputs:
      manifests_path:
        description: 'Path to lint (passed to kube-linter lint).'
        required: false
        type: string
        default: 'kubernetes/apps'
      config_path:
        description: 'Path to a .kube-linter.yaml. Empty → catalog baseline.'
        required: false
        type: string
        default: ''
      kube_linter_version:
        description: 'Override kube-linter version (empty → composite default).'
        required: false
        type: string
        default: ''
      fail_on_findings:
        description: 'Exit non-zero when kube-linter reports findings.'
        required: false
        type: boolean
        default: true
      upload_sarif:
        description: 'Upload SARIF to GitHub code-scanning. Auto-skipped on forks.'
        required: false
        type: boolean
        default: true
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
    outputs:
      findings_count:
        description: 'Number of kube-linter findings.'
        value: ${{ jobs.lint.outputs.findings_count }}
    secrets:
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'

permissions:
  contents: read
  security-events: write
  actions: read

concurrency:
  group: kube-lint-${{ github.workflow }}-${{ github.ref }}-${{ inputs.manifests_path }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 15
    outputs:
      findings_count: ${{ steps.count.outputs.findings_count }}
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
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
      - name: Checkout catalog for composite actions
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ steps.catalog-ref.outputs.ref }}
          token: ${{ steps.catalog-token.outputs.token }}
          path: .catalog
      - name: Install kube-linter
        uses: ./.catalog/actions/install-kube-linter
        with:
          version: ${{ inputs.kube_linter_version }}
      - name: Resolve config args
        id: cfg
        env:
          CONFIG_PATH: ${{ inputs.config_path }}
        run: |
          if [[ -n "$CONFIG_PATH" ]]; then
            echo "args=--config $CONFIG_PATH" >> "$GITHUB_OUTPUT"
          else
            echo "args=--config .catalog/configs/kube-linter.yaml" >> "$GITHUB_OUTPUT"
          fi
      - name: Run kube-linter (SARIF)
        env:
          MANIFESTS_PATH: ${{ inputs.manifests_path }}
          CFG_ARGS: ${{ steps.cfg.outputs.args }}
        # kube-linter exits non-zero on findings; `|| true` keeps the job alive
        # so SARIF can upload and the count/gate steps run deterministically.
        run: |
          # shellcheck disable=SC2086
          kube-linter lint $CFG_ARGS --format sarif "$MANIFESTS_PATH" > kube-linter.sarif || true
      - name: Count findings
        id: count
        run: |
          COUNT=$(jq '[.runs[].results[]] | length' kube-linter.sarif 2>/dev/null || echo 0)
          echo "findings_count=$COUNT" >> "$GITHUB_OUTPUT"
          echo "kube-linter findings: $COUNT"
      - name: Upload SARIF to code-scanning
        if: inputs.upload_sarif && github.event.pull_request.head.repo.full_name == github.repository
        uses: github/codeql-action/upload-sarif@7211b7c8077ea37d8641b6271f6a365a22a5fbfa # v4
        with:
          sarif_file: kube-linter.sarif
          category: kube-lint
      - name: Summary
        if: always()
        env:
          MANIFESTS_PATH: ${{ inputs.manifests_path }}
          COUNT: ${{ steps.count.outputs.findings_count }}
          FAIL_ON_FINDINGS: ${{ inputs.fail_on_findings }}
        run: |
          if [[ "$COUNT" == "0" ]]; then
            result="✓ no findings"
          elif [[ "$FAIL_ON_FINDINGS" == "true" ]]; then
            result="✗ ${COUNT} findings"
          else
            result="▲ ${COUNT} findings (gate disabled)"
          fi
          {
            echo "## kube-lint"
            echo ""
            echo "**Path:** \`${MANIFESTS_PATH}\`"
            echo "**Result:** ${result}"
          } >> "$GITHUB_STEP_SUMMARY" || true
      - name: Fail on findings
        if: inputs.fail_on_findings && steps.count.outputs.findings_count != '0'
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
        run: |
          echo "::error::kube-linter found $COUNT issue(s)"
          exit 1
```

- [ ] **Step 4: Validate**

Run: `actionlint && yamllint -s .github/workflows/kube-lint.yml && yamllint -s configs/kube-linter.yaml`
Expected: pass (modulo the globally-ignored `client-id`/`app-id` actionlint notes).

- [ ] **Step 5: Commit**

```bash
git add actions/install-kube-linter/action.yml configs/kube-linter.yaml .github/workflows/kube-lint.yml
git commit -m "feat(atoms): add kube-lint workflow + install-kube-linter composite + baseline config"
```

---

### Task 5: `install-gitleaks` composite + `secret-scan.yml` atom

`secret-scan` is general (any adopter may call it). It supports git-history modes (PR-diff / push / full, by `github.event_name`, mirroring homelab-study's gitleaks.yaml) and an additional `--no-git --source <dir>` filesystem mode (`no_git: true`) used for deterministic fixture testing and one-off directory scans.

**Files:**
- Create: `actions/install-gitleaks/action.yml`
- Create: `.github/workflows/secret-scan.yml`

- [ ] **Step 1: Write the install composite**

Create `actions/install-gitleaks/action.yml`:

```yaml
name: install-gitleaks
description: |
  Install the gitleaks CLI at a pinned version (direct binary install,
  Renovate-managed). Empty `version` → pinned default.

inputs:
  version:
    description: 'gitleaks version (with or without leading v). Empty → pinned default.'
    required: false
    default: ''

runs:
  using: composite
  steps:
    - name: Install gitleaks CLI
      shell: bash
      env:
        # renovate: datasource=github-releases depName=gitleaks/gitleaks
        GITLEAKS_VERSION: '8.24.3'
        REQUESTED: ${{ inputs.version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$GITLEAKS_VERSION}"
        VERSION="${VERSION#v}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=x64 ;;
          aarch64|arm64) A=arm64 ;;
          *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; cd "$TMP"
        curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/gitleaks_${VERSION}_linux_${A}.tar.gz" -o gl.tar.gz
        tar -xzf gl.tar.gz gitleaks
        sudo install -m 0755 gitleaks /usr/local/bin/gitleaks
        gitleaks version
```

- [ ] **Step 2: Write the atom**

Create `.github/workflows/secret-scan.yml`:

```yaml
# .github/workflows/secret-scan.yml
# Summary convention: docs/conventions/step-summary.md
#
# General-purpose gitleaks secret scanner. Git-history-aware by default
# (PR-diff / push / full by event); set no_git: true to scan a directory's
# files without git history (used for fixture tests and ad-hoc scans).
#
# Stability surface (workflow_call contract — breaking changes = major bump):
#   inputs:  config_path, gitleaks_version, fail_on_findings, upload_sarif,
#            fetch_depth, no_git, scan_path, runs_on
#   secrets: release_please_app_client_id, release_please_app_private_key
#   outputs: findings_count
name: secret-scan
on:
  workflow_call:
    inputs:
      config_path:
        description: 'Path to a .gitleaks.toml. Empty → gitleaks built-in ruleset.'
        required: false
        type: string
        default: ''
      gitleaks_version:
        description: 'Override gitleaks version (empty → composite default).'
        required: false
        type: string
        default: ''
      fail_on_findings:
        description: 'Exit non-zero when gitleaks reports findings.'
        required: false
        type: boolean
        default: true
      upload_sarif:
        description: 'Upload SARIF to GitHub code-scanning. Auto-skipped on forks.'
        required: false
        type: boolean
        default: true
      fetch_depth:
        description: 'Checkout fetch-depth (0 = full history; needed for PR-diff/full scans).'
        required: false
        type: number
        default: 0
      no_git:
        description: 'Scan files under scan_path without git history (gitleaks --no-git).'
        required: false
        type: boolean
        default: false
      scan_path:
        description: 'Directory to scan when no_git: true.'
        required: false
        type: string
        default: '.'
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
    outputs:
      findings_count:
        description: 'Number of gitleaks findings.'
        value: ${{ jobs.scan.outputs.findings_count }}
    secrets:
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'

permissions:
  contents: read
  security-events: write
  actions: read

concurrency:
  group: secret-scan-${{ github.workflow }}-${{ github.ref }}-${{ inputs.scan_path }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  scan:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 15
    outputs:
      findings_count: ${{ steps.count.outputs.findings_count }}
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          fetch-depth: ${{ inputs.fetch_depth }}
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
      - name: Checkout catalog for composite actions
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ steps.catalog-ref.outputs.ref }}
          token: ${{ steps.catalog-token.outputs.token }}
          path: .catalog
      - name: Install gitleaks
        uses: ./.catalog/actions/install-gitleaks
        with:
          version: ${{ inputs.gitleaks_version }}
      - name: Run gitleaks
        env:
          CONFIG_PATH: ${{ inputs.config_path }}
          NO_GIT: ${{ inputs.no_git }}
          SCAN_PATH: ${{ inputs.scan_path }}
          EVENT: ${{ github.event_name }}
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        # --exit-code 0 keeps the job alive so SARIF uploads and the count/gate
        # steps run deterministically; the gate is enforced by "Fail on findings".
        run: |
          set -euo pipefail
          args=(detect --redact --verbose --no-banner --report-format sarif --report-path gitleaks.sarif --exit-code 0)
          if [[ -n "$CONFIG_PATH" ]]; then
            args+=(--config "$CONFIG_PATH")
          fi
          if [[ "$NO_GIT" == "true" ]]; then
            args+=(--no-git --source "$SCAN_PATH")
          elif [[ "$EVENT" == "pull_request" ]]; then
            args+=(--log-opts="--no-merges ${BASE_SHA}..${HEAD_SHA}")
          elif [[ "$EVENT" == "push" ]]; then
            args+=(--log-opts="--no-merges -1 HEAD")
          fi
          # else (workflow_dispatch / schedule): full-history scan, no log-opts.
          gitleaks "${args[@]}"
      - name: Count findings
        id: count
        run: |
          COUNT=$(jq '[.runs[].results[]] | length' gitleaks.sarif 2>/dev/null || echo 0)
          echo "findings_count=$COUNT" >> "$GITHUB_OUTPUT"
          echo "gitleaks findings: $COUNT"
      - name: Upload SARIF to code-scanning
        if: inputs.upload_sarif && github.event.pull_request.head.repo.full_name == github.repository
        uses: github/codeql-action/upload-sarif@7211b7c8077ea37d8641b6271f6a365a22a5fbfa # v4
        with:
          sarif_file: gitleaks.sarif
          category: secret-scan
      - name: Summary
        if: always()
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
          FAIL_ON_FINDINGS: ${{ inputs.fail_on_findings }}
        run: |
          if [[ "$COUNT" == "0" ]]; then
            result="✓ no secrets"
          elif [[ "$FAIL_ON_FINDINGS" == "true" ]]; then
            result="✗ ${COUNT} secret(s)"
          else
            result="▲ ${COUNT} secret(s) (gate disabled)"
          fi
          {
            echo "## secret-scan"
            echo ""
            echo "**Result:** ${result}"
          } >> "$GITHUB_STEP_SUMMARY" || true
      - name: Fail on findings
        if: inputs.fail_on_findings && steps.count.outputs.findings_count != '0'
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
        run: |
          echo "::error::gitleaks found $COUNT secret(s)"
          exit 1
```

- [ ] **Step 3: Validate**

Run: `actionlint && yamllint -s .github/workflows/secret-scan.yml`
Expected: pass (modulo globally-ignored `client-id`/`app-id`).

- [ ] **Step 4: Commit**

```bash
git add actions/install-gitleaks/action.yml .github/workflows/secret-scan.yml
git commit -m "feat(atoms): add secret-scan workflow + install-gitleaks composite"
```

---

### Task 6: `trivy-fs.yml` — `files_ignore` enhancement

Additive, backwards-compatible. Lets a rendered GitOps `secscan` reproduce homelab-study's `trivy.yaml` skips (`--skip-files secrets.sample.yaml,age.key,…`).

**Files:**
- Modify: `.github/workflows/trivy-fs.yml`

- [ ] **Step 1: Add the input**

In `.github/workflows/trivy-fs.yml`, after the `paths_ignore` input block (ends at the `default: ''` for `paths_ignore`), add:

```yaml
      files_ignore:
        description: 'Newline-separated files to skip (--skip-files).'
        required: false
        type: string
        default: ''
```

- [ ] **Step 2: Extend the ignore-args step to build `--skip-files`**

Replace the existing `Build ignore-paths args` step (currently named `Build ignore-paths args`, id `ignore`) with:

```yaml
      - name: Build ignore args
        id: ignore
        env:
          PATHS: ${{ inputs.paths_ignore }}
          FILES: ${{ inputs.files_ignore }}
        run: |
          ARGS=""
          if [[ -n "$PATHS" ]]; then
            while IFS= read -r line; do
              [[ -z "$line" ]] && continue
              ARGS="$ARGS --skip-dirs $line"
            done <<< "$PATHS"
          fi
          if [[ -n "$FILES" ]]; then
            while IFS= read -r line; do
              [[ -z "$line" ]] && continue
              ARGS="$ARGS --skip-files $line"
            done <<< "$FILES"
          fi
          echo "args=$ARGS" >> "$GITHUB_OUTPUT"
```

(The two `trivy fs` invocations already consume `IGNORE_ARGS: ${{ steps.ignore.outputs.args }}` via `$IGNORE_ARGS` — no change needed there.)

- [ ] **Step 3: Add `files_ignore` to the concurrency key**

Change the `concurrency.group` line from:

```yaml
  group: trivy-fs-${{ github.workflow }}-${{ github.ref }}-${{ inputs.fail_on_findings }}-${{ inputs.paths_ignore }}
```

to:

```yaml
  group: trivy-fs-${{ github.workflow }}-${{ github.ref }}-${{ inputs.fail_on_findings }}-${{ inputs.paths_ignore }}-${{ inputs.files_ignore }}
```

- [ ] **Step 4: Validate**

Run: `actionlint && yamllint -s .github/workflows/trivy-fs.yml`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/trivy-fs.yml
git commit -m "feat(trivy-fs): add files_ignore input (--skip-files)"
```

---

### Task 7: GitOps fixtures

Minimal fixtures for the integration tests. The happy fixture must `kustomize build` cleanly (no ksops — `sops: false`) and pass kubeconform; it must be clean of gitleaks-detectable secrets (the integration secret-scan happy path scans it). Failure fixtures each trip exactly one tool.

**Files:**
- Create: `tests/fixtures/gitops-cluster/kubernetes/apps/web/kustomization.yaml`
- Create: `tests/fixtures/gitops-cluster/kubernetes/apps/web/deployment.yaml`
- Create: `tests/fixtures/gitops-cluster/kubernetes/apps/web/service.yaml`
- Create: `tests/fixtures/gitops-cluster/kubernetes/argo/configmap.yaml`
- Create: `tests/fixtures/gitops-cluster/.kube-linter.yaml`
- Create: `tests/fixtures/gitops-cluster/.gitleaks.toml`
- Create: `tests/fixtures/gitops-invalid-manifest/kubernetes/apps/bad/kustomization.yaml`
- Create: `tests/fixtures/gitops-invalid-manifest/kubernetes/apps/bad/service.yaml`
- Create: `tests/fixtures/gitops-lint-violation/kubernetes/apps/bad/deployment.yaml`
- Create: `tests/fixtures/gitops-planted-secret/aws-credentials.txt`

- [ ] **Step 1: Happy fixture — apps/web kustomization + workloads**

`tests/fixtures/gitops-cluster/kubernetes/apps/web/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

`tests/fixtures/gitops-cluster/kubernetes/apps/web/deployment.yaml` (kube-linter-clean: resource limits, non-root, read-only rootfs — so the happy kube-lint caller's permissive config and this clean manifest both yield 0):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: web
          image: nginx:1.27.3
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          livenessProbe:
            httpGet:
              path: /
              port: 8080
          readinessProbe:
            httpGet:
              path: /
              port: 8080
```

`tests/fixtures/gitops-cluster/kubernetes/apps/web/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
```

- [ ] **Step 2: Happy fixture — argo standalone manifest**

`tests/fixtures/gitops-cluster/kubernetes/argo/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-settings
data:
  timezone: UTC
```

- [ ] **Step 3: Happy fixture — permissive lint config + minimal gitleaks config**

`tests/fixtures/gitops-cluster/.kube-linter.yaml` (permissive — disables defaults so the happy kube-lint caller is deterministically 0):

```yaml
checks:
  doNotAutoAddDefaults: true
```

`tests/fixtures/gitops-cluster/.gitleaks.toml` (extends built-in rules; present so the Plan 2 renderer's `has_gitleaks_config` path has something to point at):

```toml
title = "gitops-cluster fixture gitleaks config"
[extend]
useDefault = true
```

- [ ] **Step 4: Failure fixture — invalid manifest (kubeconform -strict rejects)**

`tests/fixtures/gitops-invalid-manifest/kubernetes/apps/bad/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
```

`tests/fixtures/gitops-invalid-manifest/kubernetes/apps/bad/service.yaml` (the `bogusField` is an additional property → kubeconform `-strict` fails):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: bad
spec:
  bogusField: not-allowed
  ports:
    - port: 80
```

- [ ] **Step 5: Failure fixture — kube-linter violation**

`tests/fixtures/gitops-lint-violation/kubernetes/apps/bad/deployment.yaml` (no resource limits, runs as root, writable rootfs → trips multiple default checks; linted with the catalog baseline config, not a permissive one):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bad
  template:
    metadata:
      labels:
        app: bad
    spec:
      containers:
        - name: bad
          image: nginx:latest
```

- [ ] **Step 6: Failure fixture — planted secret (gitleaks default rule)**

`tests/fixtures/gitops-planted-secret/aws-credentials.txt` (a structurally-valid AWS access key id + secret — matches gitleaks' built-in `aws-access-token` rule):

```text
# Fixture for secret-scan failure-path integration test. NOT a real key.
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

> NOTE: This file will be flagged by the catalog's own `trivy-fs` integration scan and any repo-wide secret scan. Task 8 adds `tests/fixtures/gitops-planted-secret` to the existing `test-trivy-fs-happy` / `test-trivy-fs-failure` `paths_ignore` lists so the planted secret does not pollute the trivy-fs assertions. The secret-scan happy caller uses `no_git: true` against the *clean* `gitops-cluster` fixture, so it never sees this file.

- [ ] **Step 7: Validate fixtures parse**

Run: `yamllint tests/fixtures/gitops-cluster tests/fixtures/gitops-invalid-manifest tests/fixtures/gitops-lint-violation`
Expected: pass (the planted-secret `.txt` is not YAML; skip it).

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/gitops-cluster tests/fixtures/gitops-invalid-manifest tests/fixtures/gitops-lint-violation tests/fixtures/gitops-planted-secret
git commit -m "test(fixtures): add gitops-cluster happy + failure fixtures"
```

---

### Task 8: Integration wiring

`kube-lint` + `secret-scan` are count-based (findings_count output) → `integration.yml` happy + find-something pattern. `kube-validate` happy → `integration.yml`; its hard-fail path → `failure-paths-nightly.yml`.

**Files:**
- Modify: `.github/workflows/integration.yml`
- Modify: `.github/workflows/failure-paths-nightly.yml`

- [ ] **Step 1: Add GitOps happy + find-something callers to `integration.yml`**

In `.github/workflows/integration.yml`, after the `test-helm-publish` job (before the `semantic-release dry-run` job), add:

```yaml
  # ----- kube-validate happy path: valid fixture tree must succeed -----
  test-kube-validate-happy:
    uses: ./.github/workflows/kube-validate.yml
    secrets: inherit
    with:
      manifests_paths: |-
        tests/fixtures/gitops-cluster/kubernetes/apps
        tests/fixtures/gitops-cluster/kubernetes/argo
      sops: false

  # ----- kube-lint happy path: clean fixture + permissive config → 0 -----
  test-kube-lint-happy:
    uses: ./.github/workflows/kube-lint.yml
    secrets: inherit
    with:
      manifests_path: tests/fixtures/gitops-cluster/kubernetes/apps
      config_path: tests/fixtures/gitops-cluster/.kube-linter.yaml
      fail_on_findings: false
      upload_sarif: false

  assert-kube-lint-clean:
    needs: test-kube-lint-happy
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: Verify findings_count == 0
        env:
          COUNT: ${{ needs.test-kube-lint-happy.outputs.findings_count }}
        run: |
          if [[ "$COUNT" != "0" ]]; then
            echo "::error::Expected 0 kube-linter findings on clean fixture, got $COUNT"
            exit 1
          fi

  # ----- kube-lint find-something: violation fixture + baseline config → >0 -----
  test-kube-lint-findings:
    uses: ./.github/workflows/kube-lint.yml
    secrets: inherit
    with:
      manifests_path: tests/fixtures/gitops-lint-violation/kubernetes/apps
      fail_on_findings: false
      upload_sarif: false

  assert-kube-lint-finds:
    needs: test-kube-lint-findings
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: Verify findings_count > 0
        env:
          COUNT: ${{ needs.test-kube-lint-findings.outputs.findings_count }}
        run: |
          if [[ "$COUNT" == "0" ]]; then
            echo "::error::Expected kube-linter findings on violation fixture, got 0"
            exit 1
          fi
          echo "kube-lint correctly detected $COUNT finding(s)"

  # ----- secret-scan happy path: clean fixture, no-git mode → 0 -----
  test-secret-scan-happy:
    uses: ./.github/workflows/secret-scan.yml
    secrets: inherit
    with:
      no_git: true
      scan_path: tests/fixtures/gitops-cluster
      fail_on_findings: false
      upload_sarif: false

  assert-secret-scan-clean:
    needs: test-secret-scan-happy
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: Verify findings_count == 0
        env:
          COUNT: ${{ needs.test-secret-scan-happy.outputs.findings_count }}
        run: |
          if [[ "$COUNT" != "0" ]]; then
            echo "::error::Expected 0 secrets on clean fixture, got $COUNT"
            exit 1
          fi

  # ----- secret-scan find-something: planted secret, no-git mode → >0 -----
  test-secret-scan-findings:
    uses: ./.github/workflows/secret-scan.yml
    secrets: inherit
    with:
      no_git: true
      scan_path: tests/fixtures/gitops-planted-secret
      fail_on_findings: false
      upload_sarif: false

  assert-secret-scan-finds:
    needs: test-secret-scan-findings
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: Verify findings_count > 0
        env:
          COUNT: ${{ needs.test-secret-scan-findings.outputs.findings_count }}
        run: |
          if [[ "$COUNT" == "0" ]]; then
            echo "::error::Expected secret findings on planted-secret fixture, got 0"
            exit 1
          fi
          echo "secret-scan correctly detected $COUNT secret(s)"
```

- [ ] **Step 2: Keep the planted secret out of the trivy-fs assertions**

In `.github/workflows/integration.yml`, add `tests/fixtures/gitops-planted-secret` to BOTH trivy-fs callers' `paths_ignore`:

`test-trivy-fs-happy` `paths_ignore` becomes:

```yaml
      paths_ignore: |
        tests/fixtures/with-secret
        tests/fixtures/lint-test/helm-lint-fail
        tests/fixtures/gitops-planted-secret
```

`test-trivy-fs-failure` `paths_ignore` becomes:

```yaml
      paths_ignore: |
        tests/fixtures/lint-test/helm-lint-fail
        tests/fixtures/gitops-planted-secret
```

- [ ] **Step 3: Extend the integration `summary` needs**

In the `summary` job's `needs:` list in `integration.yml`, add:

```yaml
      - test-kube-validate-happy
      - test-kube-lint-happy
      - assert-kube-lint-clean
      - test-kube-lint-findings
      - assert-kube-lint-finds
      - test-secret-scan-happy
      - assert-secret-scan-clean
      - test-secret-scan-findings
      - assert-secret-scan-finds
```

- [ ] **Step 4: Add `kube-validate` hard-fail path to `failure-paths-nightly.yml`**

In `.github/workflows/failure-paths-nightly.yml`, after the `assert-helm-publish-fail` job (before `report-regressions`), add:

```yaml
  # ----- kube-validate: fail-path -----
  # Invalid manifest (additional property under a known schema) → kubeconform
  # -strict rejects → atom exits non-zero.
  test-kube-validate-fail:
    uses: ./.github/workflows/kube-validate.yml
    secrets: inherit
    with:
      manifests_paths: tests/fixtures/gitops-invalid-manifest/kubernetes/apps
      sops: false

  assert-kube-validate-fail:
    needs: test-kube-validate-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert validate job failed
        env:
          RESULT: ${{ needs.test-kube-validate-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected kube-validate to fail on invalid manifest, got: $RESULT"
            exit 1
          fi
          echo "kube-validate-fail: correctly observed failure"
```

- [ ] **Step 5: Extend the nightly `report-regressions` needs**

In the `report-regressions` job's `needs:` list in `failure-paths-nightly.yml`, add:

```yaml
      - assert-kube-validate-fail
```

(The bash gate counts `!= success` across all needs, so no other change is required. The hard-coded "All 11 assert-*" log strings are cosmetic; optionally update "11" → "12".)

- [ ] **Step 6: Validate**

Run: `actionlint && yamllint -s .github/workflows/integration.yml && yamllint -s .github/workflows/failure-paths-nightly.yml`
Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/integration.yml .github/workflows/failure-paths-nightly.yml
git commit -m "test(integration): wire gitops atoms into integration + nightly"
```

---

### Task 9: Static-validation sweep + Renovate sanity

**Files:**
- (Verification only; edit only if a check fails.)

- [ ] **Step 1: Full actionlint with the catalog's ignore flags**

Run the same invocation `validate.yml` uses, to confirm the new App-token atoms are covered by the existing global `-ignore` flags:

```bash
./actionlint \
  -ignore 'input "client-id" is not defined in action "actions/create-github-app-token@v3"' \
  -ignore 'missing input "app-id" which is required by action "actions/create-github-app-token@v3"'
```

Expected: clean. If a NEW actionlint message appears for the gitops atoms, add a matching `-ignore` to `.github/workflows/validate.yml` (Step 2); otherwise no edit.

- [ ] **Step 2: (Conditional) add ignore flag**

Only if Step 1 surfaced a new actionlint false-positive: add the corresponding `-ignore '<exact message>'` line to the `Run actionlint` step in `.github/workflows/validate.yml`, re-run Step 1 to confirm clean, then:

```bash
git add .github/workflows/validate.yml
git commit -m "ci(validate): ignore actionlint false-positive for gitops atoms"
```

- [ ] **Step 3: Renovate marker sanity**

Confirm each new pinned version carries a `# renovate:` comment (kustomize, kubeconform, sops, ksops, kube-linter, gitleaks) so Renovate keeps them current:

```bash
rg -n 'renovate:' actions/setup-kube-toolchain/action.yml actions/install-kube-linter/action.yml actions/install-gitleaks/action.yml
```

Expected: 6 markers total. No commit unless one is missing.

- [ ] **Step 4: Full bats run (no regressions)**

Run: `bats tests/shell/`
Expected: all pass, including the new `kube-validate.bats` and the unchanged existing suites.

---

### Task 10: Docs + PR

**Files:**
- Modify: `docs/operations.md`

- [ ] **Step 1: Document the new override vars + atoms**

In `docs/operations.md`, under the Per-Adopter Overrides / variables section (where `SK_TRIVY_VERSION` is documented), add entries for: `SK_KUSTOMIZE_VERSION`, `SK_KUBECONFORM_VERSION`, `SK_KUBE_LINTER_VERSION`, `SK_GITLEAKS_VERSION` (each: "version pin for the corresponding tool; empty → catalog composite default"). Add a short subsection describing the three new atoms (`kube-validate`, `kube-lint`, `secret-scan`) and that `secret-scan` is general-purpose (callable by any adopter, git-history-aware, with a `no_git` filesystem mode). Match the existing prose style; no emoji (use `✓ ✗ ▲ →` glyphs only where glyphs are needed).

- [ ] **Step 2: Validate + commit docs**

Run: `yamllint -s docs/` is not applicable (Markdown); just confirm Markdown renders. Then:

```bash
git add docs/operations.md
git commit -m "docs(operations): document gitops atoms + SK_* version overrides"
```

- [ ] **Step 3: Push the branch**

```bash
git push -u origin feat/gitops-atoms
```

- [ ] **Step 4: Two-stage review before opening the PR**

Per the catalog phase pattern, run the two-stage review on the diff (`git diff origin/main...HEAD`): (1) a spec-reviewer pass confirming the atoms match `docs/superpowers/specs/2026-05-30-gitops-support-design.md` (§1–§5 + §-test-strategy + acceptance criteria for the atom layer); (2) a code-quality-reviewer pass (bash safety under `set -euo pipefail`, errexit traps, SARIF guards, pinned SHAs, permissions = union of nested needs). Address blocking findings, re-run `bats` + `actionlint`.

- [ ] **Step 5: Open the PR**

```bash
gh pr create --title "feat(atoms): kube-validate, kube-lint, secret-scan + trivy-fs files_ignore" --body "$(cat <<'EOF'
## Summary
- Adds three reusable atoms: `kube-validate` (opinionated kubeconform over kustomize roots), `kube-lint` (kube-linter → SARIF), `secret-scan` (general gitleaks, git-history + no-git modes).
- Adds toolchain composites `setup-kube-toolchain` (kustomize + kubeconform + ksops/sops), `install-kube-linter`, `install-gitleaks`.
- Enhances `trivy-fs` with `files_ignore` (→ `--skip-files`).
- Adds GitOps fixtures + `kube-validate.sh` bats + integration (happy + find-something) and nightly (kube-validate hard-fail) wiring.

Implements PR 1 of the GitOps support phase (spec: `docs/superpowers/specs/2026-05-30-gitops-support-design.md`). PR 2 (detection + renderer + onboard) follows.

## Test plan
- [ ] `bats tests/shell/` green (incl. new `kube-validate.bats`, ≥90% coverage on `kube-validate.sh`)
- [ ] `actionlint` (with catalog ignore flags) + `yamllint -s .github/` clean
- [ ] `integration` workflow: `test-kube-validate-happy`, `assert-kube-lint-clean/finds`, `assert-secret-scan-clean/finds` all green
- [ ] `failure-paths-nightly` (manual dispatch): `assert-kube-validate-fail` green
- [ ] `trivy-fs` integration assertions unaffected by the planted-secret fixture
EOF
)"
```

(Follow the catalog PR style: no Claude attribution footer in body or commits.)

---

## Accepted limitations / notes

1. **ksops decryption (`sops: true`) is not exercised in catalog CI.** Committing a decryptable age private key to the catalog for CI would itself be a secret-leak (and trip the catalog's own scanners). The happy integration path runs `kube-validate` with `sops: false` against plaintext fixtures; the real ksops-decryption path is validated at adopter-onboard time (homelab-study / homelab-incus-oracle have the real `SOPS_AGE_KEY` + encrypted trees) in PR 2's onboard step. The atom's sops branch is covered statically (actionlint/yamllint) and by the `sops_age_key`-empty guard.
2. **`helm` is intentionally not installed** by `setup-kube-toolchain`. Both target repos pass `--enable-helm` but have zero `helmCharts:` kustomizations, so kustomize never shells out to helm. Add helm to the composite only when a future adopter introduces in-kustomize helm inflation.
3. **`kube-validate.sh` collects all failures then exits non-zero** (vs. the original's fail-fast). Friendlier output; still satisfies "fails the invalid tree." This is a deliberate improvement over `homelab-study/scripts/kubeconform.sh`, which also had two latent bugs (PIPESTATUS[0]-only check; pipe-subshell `exit`) that this script fixes.
4. **Tool version pins** (kustomize 5.5.0, kubeconform 0.6.7, sops 3.9.4, ksops 4.3.3, kube-linter v0.8.3, gitleaks 8.24.3) are best-known-good starting points; Renovate keeps them current via the `# renovate:` markers. kube-linter v0.8.3 matches homelab-study's proven version.

---

## Self-Review (run after writing; performed inline)

**1. Spec coverage** (against `2026-05-30-gitops-support-design.md`):
- §1 kube-validate (opinionated, inputs reproduce homelab-study) → Tasks 2+3. ✓
- §2 kube-lint (SARIF, config fallback to baseline) → Task 4. ✓
- §3 secret-scan (general, three git modes + built-in fallback) → Task 5 (+ added `no_git`/`scan_path` for deterministic fixture testing — additive, in the spirit of the general atom; flagged below). ✓
- §4 trivy-fs files_ignore → Task 6. ✓
- §5 composites (kustomize+kubeconform; sops+ksops) → Tasks 1, 4, 5. ✓
- Test strategy (bats on kube-validate.sh ≥90%; fixtures happy+failure; integration; static) → Tasks 2, 7, 8, 9. ✓
- Acceptance criteria for the atom layer (validate passes valid/fails invalid; kube-lint/secret-scan green/red on fixtures) → Task 8 asserts. ✓
- Detection / renderer / onboard (§6–§8, PR 2/4) → deliberately deferred to Plan 2. ✓

**2. Placeholder scan:** No TBD/"handle appropriately"/"similar to". All code blocks are complete. ✓

**3. Type consistency:** atom output name `findings_count` consistent across kube-lint/secret-scan and their assertions. Script env var names (`MANIFESTS_PATHS`, `KUSTOMIZE_ARGS`, …) match between `kube-validate.sh`, its bats, and `kube-validate.yml`. Composite input names (`kustomize_version`, `kubeconform_version`, `sops`, `version`) match their atom call sites. Fixture paths in Task 7 match the caller `with:` blocks in Task 8. ✓

**Deviation from spec, flagged:** `secret-scan` gains two inputs not in the spec's §3 table — `no_git` (boolean) + `scan_path` (string). Rationale: gitleaks `detect` scans the cwd git repo, which makes fixture-based integration testing non-deterministic (it would scan the catalog's own history). `--no-git --source <dir>` gives a deterministic filesystem scan and is a legitimate general feature. Additive, backwards-compatible (defaults preserve git-history behavior). Reflect this addition in the spec's §3 input list during the spec-reviewer pass.
