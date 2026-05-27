# Step-Summary Convention

Every reusable workflow ("atom") in `.github/workflows/` writes a single, conformant Markdown block to `$GITHUB_STEP_SUMMARY` per run. This file is the authoritative spec for the schema. The CI gate in `tests/conventions/check-step-summary.sh` enforces presence; visual review enforces shape.

## Schema

```markdown
## <atom-name>

**Tool:** <toolname> <version>
[optional context lines: **Working dir:**, **Image:**, **Path:**, **Severities:** — atom-specific key-value lines]
**Result:** <glyph> <one-line status>

<atom-specific body — table or key-value list>
```

- **`<atom-name>`** is the workflow filename without `.yml` (e.g., `lint-go`, `docker-build-multi`). The CI gate matches `^## <atom-name>$` (with surrounding whitespace tolerated).
- **`**Tool:**`** lists the primary tool and version. For multi-tool atoms (e.g., `lint-go` runs `go vet` and `golangci-lint`), use `**Tools:**` with comma separation.
- **Context lines** (optional, between Tool and Result): atom-specific `**Key:** value` lines that contextualize the run — e.g., `**Working dir:**`, `**Image:**`, `**Path:**`, `**Severities:**`. Use backticks for paths/refs/versions.
- **`**Result:**`** uses exactly one glyph from the set below.
- **Body** content (after a blank line): table or extended key-value list — see "Per-Class Body" below.

### Result Glyphs

| Glyph | Meaning |
|---|---|
| `✓` | Success (all checks pass, build succeeded, etc.) |
| `✗` | Failure (at least one check failed, build broke, etc.) |
| `▲` | Warning / Partial (e.g., Trivy findings present with `fail_on_findings=false`; coverage below threshold with enforcement off) |

No emoji. Only the glyphs above.

## Per-Class Body

| Class | Required body |
|---|---|
| `lint-*` | Working dir; table `\| Check \| Status \|` with one row per tool |
| `test-*` | Working dir; test counts (run/pass/fail); coverage % + threshold; duration |
| `trivy-*` | Target (image ref or path); severity filter; findings count table by severity |
| `docker-build`, `docker-build-multi` | Tags; digest; platforms; sign/attest/SBOM status |
| `helm-publish` | Chart name; version; OCI ref; digest |
| `semantic-release` | Old → new version; bump type; release URL (or "no release" if idle) |
| `goreleaser` | Tag; artifact count; release URL |
| `cleanup-images` | Table `\| Rule \| Kept \| Deleted \|` |
| `onboard`, `onboard-sweep`, `drift-check` | Current body stays as-is; only the `## <atom>` header is prepended |

## Style Rules

- Inline code (backticks) for image refs, paths, version strings.
- Tables: pad pipes with spaces (`| key | value |`).
- No emoji. Only the glyphs from the Result-Glyphs table.
- No external links except to GHCR / GitHub-owned URLs (release pages, compare views).
- Append, never overwrite: always use `>>`, never `>`.
- Wrap every summary write in `|| true` so a write failure (e.g., 1 MB cap exceeded) never breaks the job.

## Step Conditions

| Class | Step condition | Why |
|---|---|---|
| `lint-*` | `if: always()` | Issue count must be visible even when a tool exits non-zero |
| `test-*` | `if: always()` | Coverage must be reported even when tests fail |
| `trivy-*` | `if: always()` | Findings must be visible before the gate-fail step aborts |
| `docker-build*` | normal (no `always()`) | Digest only exists after successful push |
| `helm-publish`, `semantic-release`, `goreleaser`, `cleanup-images` | normal | Values only exist after success |
| `onboard*`, `drift-check` | existing conditions stay | Existing step flow stays intact |

## Examples

### `lint-go` (success)

```markdown
## lint-go

**Tools:** go vet, golangci-lint v2.12.2
**Working dir:** `./services/api`
**Result:** ✓ passed

| Check | Status |
|---|---|
| go vet | ✓ |
| golangci-lint | ✓ |
```

### `test-python` (failure, coverage under threshold)

```markdown
## test-python

**Tool:** pytest 8.3.2
**Working dir:** `.`
**Result:** ✗ coverage 84% < threshold 90%

| Metric | Value |
|---|---|
| Tests run | 142 |
| Passed | 142 |
| Failed | 0 |
| Coverage | 84% |
| Threshold | 90% |
| Duration | 38s |
```

### `trivy-image` (findings, fail_on_findings=false)

```markdown
## trivy-image

**Tool:** Trivy 0.58.1
**Image:** `ghcr.io/serverkraken/foo:v1.2.3`
**Severities:** HIGH, CRITICAL
**Result:** ▲ 3 findings (gate disabled)

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| HIGH | 2 |
```

### `docker-build-multi` (happy)

```markdown
## docker-build-multi

**Tool:** Buildx v0.21.0 (distributed multi-arch)
**Result:** ✓ pushed

| Field | Value |
|---|---|
| Tags | `v1.2.3`, `latest` |
| Digest | `sha256:abc...` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Sign | ✓ cosign keyless |
| Attest | ✓ SLSA provenance |
| SBOM | ✓ SPDX-JSON |
```

## Adding a New Atom

When you add a workflow to `.github/workflows/` that is not in the Self-CI exemption list (`validate.yml`, `integration.yml`, `self-ci.yml`, `release.yml`, `catalog-release.yml`), you MUST:

1. Add a summary step matching this schema.
2. Add the file-header line at the top of your atom: `# Summary convention: docs/conventions/step-summary.md`
3. Run `bash tests/conventions/check-step-summary.sh` locally — exit 0 required.

If the gate rejects a legitimate writing pattern, extend the regex in the script and add a Bats case in `tests/shell/check-step-summary.bats`.
