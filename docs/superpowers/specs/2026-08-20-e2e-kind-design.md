# e2e-kind — Kubernetes e2e tests with kind on self-hosted runners

**Date:** 2026-08-20
**Status:** approved
**Origin:** mailstack's `e2e.yml` runs on `ubuntu-latest` because the inline
kind/Cilium flow failed on the on-prem ARC runners (run 32298575535). Goal:
run kind-based e2e suites on the self-hosted pool via a catalog atom, and
close the remaining gaps that keep mailstack from being fully catalog-served.

## Problem

mailstack's nightly e2e (kind cluster + Cilium CNI + full chart install +
mail-flow assertions) is the only mailstack job that cannot run through the
catalog. Two failure classes pushed it to GitHub-hosted runners:

1. **Tooling:** `curl -o /usr/local/bin/kind` fails as the runner user
   (exit 23, no write permission without sudo).
2. **Cilium never became ready** on the performance pool: pods stuck
   "Pending"/crash-looping until the 90s wait budget expired.

A feasibility spike (2026-08-20, local podman reproduction of the pod
topology + probe runs 32339273779/32339683469 on the real performance
runner) established:

- **The topology works.** Runner image v1.5.1 + `docker:dind` sidecar +
  kind v0.27.0 + Cilium 1.18.1 reach a Ready node in ~3 minutes total
  (toolchain 12s, `kind create` 82s, Cilium ready 66s after install).
- **Root cause of the Cilium failure:** Talos removes `CAP_SYS_MODULE`
  from the bounding set. A nested container (runner pod → dind → kind
  node → cilium pod) can never regain it, so Cilium's default capability
  list dies in `clean-cilium-state` with
  `runc: unable to apply caps: operation not permitted`.
  Fix: install Cilium with the same Talos-compatible capability values the
  host cluster itself uses (homelab-study
  `kube-system/cilium/helm-values.yaml`) — `SYS_MODULE` removed from
  `ciliumAgent` and `cleanCiliumState`.
- **Side findings:** `cilium install --wait --wait-duration N` returns
  after ~6s without waiting (observed on-prem and GH-hosted); only
  `cilium status --wait` is reliable. `kind create --wait` is wasted time
  when `disableDefaultCNI: true` (node cannot become Ready pre-CNI).
  Network is not a constraint (263 MB quay pull in 30s through the dind).

## Decisions (from brainstorming)

| # | Question | Decision |
|---|----------|----------|
| 1 | Workflow scope | Generic: provision toolchain, run a consumer-owned e2e script, diagnose + clean up. Not Helm-specific. |
| 2 | Runner pool | Existing `performance` pool as default `runs_on`; a dedicated pool only if real contention shows up later. |
| 3 | Binary provisioning | Both: bake kind/kubectl/cilium-cli into `actions-runner-image` AND a catalog composite action with presence-check → download fallback. |
| 4 | Cluster lifecycle | Stays in the consumer script (mailstack's `run.sh` keeps working unchanged locally via its podman path). The workflow is a thin shell. |

## Goals

- New catalog atom `e2e-kind.yml` (workflow_call) that any repo with a
  kind-based e2e script can adopt; mailstack is the first consumer.
- New composite action `actions/setup-kind-toolchain` (presence-check,
  job-private install fallback, works on `ubuntu-latest` too).
- Bake kind, kubectl, cilium-cli into `actions-runner-image` so the
  presence check hits on self-hosted runners.
- Guaranteed cleanup: a failed/aborted e2e run must never leak a kind
  cluster into the next job on the long-lived runner pod.
- mailstack adoption: `e2e.yml` calls the atom; `run.sh` gets the Talos
  capability values and the wait fixes; e2e returns to self-hosted.

## Non-Goals

- No workflow-managed cluster lifecycle (inputs like `kind_config`,
  `cni: cilium|kindnet`). Can be added additively later without breaking
  the thin-shell contract.
- No pre-pulled Cilium/kindest container images in the image or dind.
  The dind layer cache of the long-lived pod amortizes the ~30s pull;
  only the first run after pod rotation pays it.
- No dedicated e2e runner pool (revisit only on measured contention).
- `test-helm.yml` (helm-unittest) and the onboarding `extra-files`
  Chart.yaml sync gap are separate packages with their own cycles.

## Design

### 1. `e2e-kind.yml` (reusable workflow)

Stability surface (`inputs`):

| Input | Type | Default | Purpose |
|---|---|---|---|
| `runs_on` | string (JSON array) | `'["self-hosted","Linux","X64","performance"]'` | pool selection; `'["ubuntu-latest"]'` override supported |
| `script` | string, **required** | — | consumer e2e script path, e.g. `test/e2e/run.sh` |
| `working_directory` | string | `'.'` | monorepo support |
| `timeout_minutes` | number | `45` | job timeout |
| `kind_version` | string | `''` | empty → action's pinned default |
| `kubectl_version` | string | `''` | empty → action's pinned default |
| `cilium_cli_version` | string | `''` | empty → action's pinned default |
| `helm_version` | string | `'v3.16.3'` | renovate-tracked input default (house style, as in `lint-helm.yml`); installed via `azure/setup-helm` (resolves the image's toolcache bake) |

No outputs. `permissions: contents: read, packages: read`.
`GITHUB_TOKEN` is passed to the script env (consumers use it to let the
kind node pull private ghcr images).

Job steps:

1. Checkout (`persist-credentials: false`).
2. `actions/setup-kind-toolchain` (kind, kubectl, cilium-cli).
3. `azure/setup-helm` with `helm_version`.
4. Run the consumer script from `working_directory`.
5. `if: failure()` — diagnostics: for **every** cluster in
   `kind get clusters`: `kind export logs`, plus `kubectl get events` and
   describes of non-Running pods; upload as artifact (retention 5 days).
6. `if: always()` — cleanup: delete **every** cluster from
   `kind get clusters` (not a single known name — leaked clusters from
   aborted runs must not poison the next job). The `kindest/node` image
   stays in the dind cache deliberately (~50s saved per subsequent run).

Because cleanup enumerates `kind get clusters`, there is no
`cluster_name` input.

The file header documents the consumer-facing operational notes:

- Cilium on this pool needs the Talos capability values (no
  `SYS_MODULE`); point at homelab-study's helm-values as the reference.
- Only `cilium status --wait` is reliable; `cilium install --wait` is not.
- Skip `kind create ... --wait` when `disableDefaultCNI: true`.

### 2. `actions/setup-kind-toolchain` (composite action)

Pattern: `setup-kube-toolchain` / `install-trivy` — direct pinned binary
installs, never third-party setup actions.

- Inputs: `kind_version`, `kubectl_version`, `cilium_cli_version`;
  empty → pinned default `ARG`-style env in the action, each tracked by a
  renovate comment (`kubernetes-sigs/kind`, `kubernetes/kubernetes`,
  `cilium/cilium-cli`).
- Per tool: if the binary is on PATH **and** its version matches the
  requested one → skip (the image bake serves it, 0s). Otherwise download
  to `$RUNNER_TEMP/bin` and prepend to `GITHUB_PATH` — job-private, no
  sudo, shadows a stale bake, works unchanged on `ubuntu-latest`.
- Arch detection via `uname -m` (amd64/arm64), as in
  `setup-kube-toolchain`.

### 3. Image bake (`actions-runner-image`)

- kind, kubectl, cilium-cli into `/usr/local/bin` — deliberately **not**
  the toolcache: no `setup-*` action looks for them there; the pattern is
  the gh CLI. README's toolcache layout table is not affected.
- Three `ARG`s with one renovate customManager each in `renovate.json`.
- `tests/smoke.sh`: assert each binary exists and `--version` answers.
- Version drift between image bake and action default is harmless by
  design — the action shadows once per job. The `TOOLCACHE_MISS` hook
  never sees these tools (not toolcache) — no report noise.
- Release as `feat:` → minor.

### 4. mailstack adoption (completes package 1)

- `e2e.yml` → `uses: serverkraken/reusable-workflows/.github/workflows/e2e-kind.yml@v4`
  with `script: test/e2e/run.sh`; the four inline install steps go away.
- `run.sh`: Cilium install gets the Talos capability sets
  (`securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}`,
  `cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}`), drops
  `kind create --wait 120s`, and moves the whole wait budget into
  `cilium status --wait` (≥240s). The same script path then works locally
  (podman) and on-prem.
- Acceptance: a dispatch of the converted `e2e.yml` on a mailstack branch
  is green on `["self-hosted","Linux","X64","performance"]`.

## Testing

Catalog self-CI (repo rule: ≥1 happy-path + ≥1 failure-path caller per
atom):

- `tests/fixtures/kind-smoke/e2e.sh`: 1-node kind cluster **without**
  Cilium (keeps the integration run ~2 min), asserts `kubectl get nodes`,
  deletes its own cluster.
- Happy-path caller in `tests/callers/` → runs in `integration.yml` on
  every PR.
- Failure-path caller → `failure-paths-nightly.yml`: fixture script
  creates a cluster then exits 1; asserts (a) the job fails, (b) the
  diagnostics artifact exists, (c) **no cluster is left behind**
  (`kind get clusters` empty in a follow-up step) — leak behavior is the
  real risk on long-lived runners.
- Static: actionlint + yamllint as everywhere. The action's bash stays
  small (presence-check one-liners); if it grows, extract to `scripts/`
  + bats per the repo's ratchet rule.

Image repo: `smoke.sh` assertions, hadolint stays green.

## Versioning

New workflow + new action = `feat:` (minor on the v4 line). No existing
contract changes, no major.

## Risks & Mitigations

- **Disk pressure in the dind** from kindest/node + workload images on
  long-lived pods: diagnostics step prints `docker system df`; if it
  becomes a problem, add an opt-in prune input later (additive).
- **Contention on the 2-slot performance pool** (e2e vs Flutter/Docker
  builds): accepted per decision 2; mailstack's e2e is nightly + tag-only.
  Revisit with a dedicated pool if queueing shows up in the runner
  dashboards.
- **cilium-cli behavior drift** (`install --wait` bug): the atom never
  relies on it; consumer guidance says `cilium status --wait`.
