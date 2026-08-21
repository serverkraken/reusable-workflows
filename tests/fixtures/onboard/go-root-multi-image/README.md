# go-root-multi-image fixture

Golden fixture for the adopter manifest (`.github/onboard.yml`): a Go module
at the repo root with sub-directory Dockerfiles (`images/api`,
`images/worker`, plus `images/tools/Dockerfile` attached to the root
component), a chart (`charts/demo`) next to the code, and an e2e script.
Rendered by the self-CI job `onboard-preview-manifest-golden`
(`.github/workflows/self-ci.yml`) via `sk-workflows preview`, then diffed
against `expected/`. The bats harness (`tests/shell/`) cannot exercise this
fixture — the Bash engine refuses manifests by design (§ 11.4 of
`docs/operations.md`).

`expected/` lives inside this same directory tree, so the walkers **do**
reach it — it is not a dot-directory, and only dot-directories are pruned.
It stays benign for two separate reasons:

- The manifest's `components:` list is authoritative (§ 11.2), so the
  component walkers (`fallbackMarkerPaths`, `fallbackDockerfilePaths`) never
  run at all, and `unassignedSubdirDockerfileWarnings` is skipped for
  manifest repos.
- The one walker that does run over the whole tree, `firstNestedChart`,
  stops at the first `Chart.yaml` it finds in directory order — and
  `charts/` sorts before `expected/`, so it resolves `charts/demo` and
  returns. That chart is then dropped from the root component's release
  signals anyway, because `charts/demo` is its own component.

Nothing under `expected/` contains a `Chart.yaml`, so the sort order is
belt-and-braces rather than load-bearing — but keep new fixture directories
out of alphabetical range before `charts/` if they ever grow one.
