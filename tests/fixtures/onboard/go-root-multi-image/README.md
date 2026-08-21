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

`expected/` lives inside this same directory tree, so it is also visible to
`sk-workflows detect` when it walks the repo. This is benign: the manifest's
`components:` list is authoritative (§ 11.2), so detection never falls back
to scanning the file system for components, Dockerfiles, or chart
directories — the extra files under `expected/` are simply never looked at.
