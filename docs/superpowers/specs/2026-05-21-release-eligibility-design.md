# Release-Eligibility + Sign/Attest/SBOM Overrides — Design

**Date:** 2026-05-21
**Status:** Approved, pending implementation plan

## Problem

Two related gaps in the catalog's adopter-rendered workflows:

1. **No way to mark a Dockerfile as prerelease-only.** Today `onboard-detect` inventories every `Dockerfile` and `Dockerfile.*` it finds, and the rendered `release.yml` builds and pushes ALL of them on every release-please-driven release. Adopters with `Dockerfile.dev` (development variant), `Dockerfile.debug`, or similar non-production variants get them shipped to GHCR alongside the real production image. skytrack-ui + blupod-ui are concrete cases.

2. **`Containerfile` (Podman/OCI synonym) is not detected at all.** `inventory_dockerfiles`'s `find` pattern matches only `Dockerfile`/`Dockerfile.*`. Adopters using Podman lose all docker-build automation silently.

3. **No adopter-side toggle for sign/attest/sbom.** Catalog `release.yml` orchestrator exposes these inputs (added in PR #67, v3.4.0), but the adopter-rendered `release.yml.tmpl` doesn't wire them through. Adopters who need to turn off cosign signing or SLSA provenance attestation (runner without cosign prereqs, org policy, etc.) have no opt-out short of hand-editing the rendered file.

## Solution

Three coupled changes, shipped together:

1. **Per-Dockerfile `release_eligible` flag**, driven by convention + per-file annotation override. Filtered into `release.yml`'s docker-build call; `prerelease.yml` keeps the full unfiltered list (since prerelease is manual-trigger by design).

2. **Containerfile detection.** `Containerfile` + `Containerfile.*` treated equivalently to `Dockerfile` patterns in `inventory_dockerfiles` and `derive_image_name`. Same release-eligibility convention applies.

3. **`SK_SIGN`, `SK_ATTEST`, `SK_SBOM` repository-variable overrides**, plumbed through both `release.yml.tmpl` and `prerelease.yml.tmpl` into the docker-build / docker-build-multi atom inputs. Default `true` (mirror atom defaults). Override-wins via the same `fromJSON()`-wrap pattern PR #80 established.

## Release-Eligibility — Convention + Override

**Default classification:**

| File matches | `release_eligible` |
|---|---|
| `Dockerfile` (exact) | `true` |
| `Containerfile` (exact) | `true` |
| `Dockerfile.*` (any extension) | `false` |
| `Containerfile.*` (any extension) | `false` |

**Override** via a header comment in the Dockerfile itself, extending the existing `# onboard:image=<name>` pattern:

```dockerfile
# Dockerfile.worker
# onboard:release=true
FROM alpine:3.19
...
```

`# onboard:release=true` forces release-eligible. `# onboard:release=false` opts the file out (useful for the unusual case of a `Dockerfile` that shouldn't ship). Only the first 5 lines of the file are scanned, matching the existing override mechanism.

**Schema extension** to `inventory_dockerfiles` output — each entry gains a `release_eligible` boolean field:

```json
[
  {"path": "Dockerfile",      "image_name": "...", "image_name_source": "derived", "release_eligible": true},
  {"path": "Dockerfile.dev",  "image_name": "...", "image_name_source": "derived", "release_eligible": false},
  {"path": "Dockerfile.worker","image_name": "...", "image_name_source": "derived", "release_eligible": true}
]
```

## Containerfile Detection

Extend `inventory_dockerfiles`' `find` pattern:

```bash
find "$p" -maxdepth 1 -type f \( \
  -name 'Dockerfile' -o -name 'Dockerfile.*' \
  -o -name 'Containerfile' -o -name 'Containerfile.*' \
\)
```

`derive_image_name` gains parallel match arms for `Containerfile` and `Containerfile.*` so suffix-derivation behaves identically (`Containerfile.api` → `$REPO-api`).

A Component that has *both* `Dockerfile` and `Containerfile` gets two separate image builds — both default-release-eligible, both with their own derived `image_name`. Rare in practice; trusts adopter intent if they actually committed both.

## Sign/Attest/SBOM Vars

New repository variables, mirroring the catalog atom-input shape:

| Variable | Atom Input | Template Default | Type |
|---|---|---|---|
| `SK_SIGN` | `sign` | `'true'` | boolean |
| `SK_ATTEST` | `attest` | `'true'` | boolean |
| `SK_SBOM` | `sbom` | `'true'` | boolean |

Wired into both `release.yml.tmpl` (docker-build + docker-build-multi calls) and `prerelease.yml.tmpl` (same two calls). All three use the established `fromJSON()` wrap pattern from PR #80:

```yaml
  docker-build{{ $suffix }}:
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@{{ $pin }}
    with:
      ...
      sign: {{`${{ fromJSON(vars.SK_SIGN || 'true') }}`}}
      attest: {{`${{ fromJSON(vars.SK_ATTEST || 'true') }}`}}
      sbom: {{`${{ fromJSON(vars.SK_SBOM || 'true') }}`}}
    secrets: inherit
```

The three knobs are independent. Adopter who needs only `attest: false` (e.g. avoiding the `Artifact Metadata` API path) sets just `SK_ATTEST = "false"`.

## Architecture — Template Rendering

### `release.yml.tmpl` per-component flow

1. Filter `$c.dockerfiles` to release-eligible only — `$releaseDfs`.
2. Branch on `len($releaseDfs)`:
   - `0` → omit docker-build job entirely (no image to ship on release).
   - `1` → emit single `docker-build.yml` call with the one eligible Dockerfile.
   - `>1` → emit `docker-build-multi.yml` call with the JSON array of eligible Dockerfiles.

All three branches embed the SK_SIGN/SK_ATTEST/SK_SBOM expressions where applicable.

### `prerelease.yml.tmpl` per-component flow

Unchanged filtering — emits ALL dockerfiles (build + scan jobs as today). Adds the same three SK_* expressions for sign/attest/sbom passthrough.

### Drift-check interaction

Both changes preserve the drift-clean property:

- **release_eligible flag**: deterministic at render time from profile data + Dockerfile contents. Two adopters with identical structure render identical YAML.
- **SK_SIGN/SK_ATTEST/SK_SBOM expressions**: literal strings in YAML, resolved only at CI run time. Identical across adopters.

`onboard.lock.json` SHAs match what re-rendering would produce. Existing reproducibility test in `tests/shell/onboard-drift.bats` continues to pass without modification.

## Testing

Four layers:

1. **Detection bats (`tests/shell/onboard-detect.bats`):**
   - `read_release_override` reads `true` and `false` correctly; empty when annotation absent; ignored beyond line 5.
   - `inventory_dockerfiles` classifies `Dockerfile` true, `Dockerfile.*` false by default.
   - Header override flips both directions.
   - `Containerfile` + `Containerfile.foo` detected with parallel behavior.
   - Component with only non-release-eligible Dockerfiles emits a `no_release_eligible` warning.

2. **Render bats (`tests/shell/onboard-render.bats`):**
   - Inline test: profile with `release_eligible: true/false` mix → rendered `release.yml` only contains eligible ones in the `images:` JSON.
   - Inline test: profile with all non-release-eligible → no docker-build job in release.yml.
   - Inline test: SK_SIGN/SK_ATTEST/SK_SBOM expressions present on both single-call and multi-call branches in `release.yml`, and in `prerelease.yml`. `grep -cF` enforces multi-occurrence count where applicable.
   - Containerfile-only fixture renders correctly.

3. **Golden fixtures:**
   - Regenerate all existing fixture goldens (filter changes the docker-build emit).
   - New fixture `release-eligibility-mixed`: contains `Dockerfile`, `Dockerfile.dev`, `Dockerfile.worker` (latter with `# onboard:release=true` header). Expected release.yml has Dockerfile + Dockerfile.worker; prerelease.yml has all three.
   - New fixture `containerfile-only`: `Containerfile` only, verifies pattern parity.

4. **Default-sync bats extension:** three new tests asserting `SK_SIGN`/`SK_ATTEST`/`SK_SBOM` template defaults match the atom-side `default: true` on `docker-build.yml` and `docker-build-multi.yml`.

No new integration smoke caller. The existing `test-vars-coercion` already exercises the boolean fromJSON path via `cgo_enabled`.

## Migration

Sequencing after merge:

1. Catalog auto-releases v3.10.0 (feat → minor bump).

2. Re-onboard all four adopters via `gh workflow run onboard.yml -f target_repos=...`. Per-adopter behavior diff:
   - **blupod-ui**: had `Dockerfile` + `Dockerfile.dev`. After: release.yml builds only `Dockerfile`; prerelease.yml keeps both. **Behavior change** — `Dockerfile.dev` no longer ships on release.
   - **flow**: no Dockerfiles, goreleaser-only. Unchanged.
   - **skytrack**: `Dockerfile` only. Unchanged.
   - **skytrack-ui**: identical to blupod-ui. **Behavior change**.

3. Onboard-PRs land. Drift-check reports all four clean.

4. Adopters who actively want `SK_SIGN=false` etc. set the variable post-merge — no re-render needed (vars resolve at CI run time).

## Open Questions / Known Limits

1. **Adopters with only non-release-eligible Dockerfiles silently get no docker-build job on release.** Mitigation: detect-side warning emitted into the onboard run's step-summary. If the warning is missed, the first attempted release shows "no docker-build job" in the workflow run, prompting investigation. Acceptable failure mode given the rarity (no adopter today).

2. **`Dockerfile` + `# onboard:release=false` is honored** (override wins over default). Trusts adopter intent for the unusual case of a dev-only `Dockerfile`.

3. **`Containerfile` + `Dockerfile` in the same component produces two parallel image builds.** Both default release-eligible, separate `image_name` derivation. Acceptable but rare.

### Out of scope (future PRs if needed)

- **Per-component sign/attest/sbom overrides.** Today all three vars apply globally per-adopter. A monorepo wanting "production component signs, internal-tools component doesn't" would need per-component variable scoping, which GitHub Actions doesn't natively support. Not in current demand.

- **`.catalog/images.yaml` file-based override.** Considered during brainstorming; rejected in favor of Dockerfile-header annotation for consistency with the existing `# onboard:image=` pattern. If a third use case emerges that doesn't fit the header model, we'd revisit.

- **GitHub Variable for "release-eligible Dockerfile list."** Considered; rejected because the list is structurally per-file rather than per-repo, and the Dockerfile-header annotation puts the decision next to the Dockerfile itself — easier to maintain.
