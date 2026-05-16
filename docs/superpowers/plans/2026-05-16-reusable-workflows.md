# Reusable Workflows Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement v1.0 of the `serverkraken/reusable-workflows` catalog — atomic reusable workflows (semantic-release, docker-build, trivy-image, trivy-fs, cleanup-images), an orchestrator, four composite actions, self-CI, and adopter templates — per the design spec at `docs/superpowers/specs/2026-05-16-reusable-workflows-design.md`.

**Architecture:** Each concern is an atomic `workflow_call` workflow in `.github/workflows/`. Reusable sub-steps (Trivy install, GHCR login, prerelease tag computation, PR comment posting) are composite actions in `actions/<name>/action.yml`. A thin orchestrator `release.yml` chains semantic-release → docker-build → trivy for the common release flow. Self-CI in this repo dog-foods every atom against fixtures in `tests/fixtures/` with happy + failure-path callers.

**Tech Stack:** GitHub Actions YAML; `googleapis/release-please-action@v4`; `docker/build-push-action@v7` + `docker/setup-buildx-action@v4`; `sigstore/cosign-installer@v3`; `actions/attest-build-provenance@v2`; `anchore/sbom-action@v0`; Trivy CLI (direct install); `actions/create-github-app-token@v2`; `peter-evans/find-comment@v3` + `peter-evans/create-or-update-comment@v4`; `actions/delete-package-versions@v5`; `rhysd/actionlint@v1`; `yamllint`; `bats-core` + `bashcov` for shell unit tests.

---

## File Structure

All paths are relative to repo root.

```
.github/
  renovate.json5                                   Task 1
  workflows/
    validate.yml                                    Task 7    self-CI: actionlint + yamllint
    cleanup-images.yml                              Task 8    atom (simplest, no deps)
    trivy-fs.yml                                    Task 9    atom
    trivy-image.yml                                 Task 10   atom
    docker-build.yml                                Task 11   atom (largest)
    semantic-release.yml                            Task 12   atom (GitHub App auth)
    release.yml                                     Task 13   orchestrator
    integration.yml                                 Task 15   self-CI: caller fixtures
    catalog-release.yml                             Task 16   this repo's own release
actions/
  install-trivy/action.yml                          Task 3    composite (pinned CLI)
  ghcr-login/action.yml                             Task 4    composite
  compute-prerelease-tag/action.yml                 Task 5    composite (with bats tests)
  post-prerelease-comment/action.yml                Task 6    composite
docs/
  adopter-templates/{ci,release,prerelease,cleanup}.yml  Task 17
  superpowers/plans/2026-05-16-reusable-workflows.md     this file
  superpowers/specs/2026-05-16-reusable-workflows-design.md  (exists)
tests/
  fixtures/
    minimal-go/{Dockerfile,main.go}                 Task 14
    with-secret/{.env-example,Dockerfile}           Task 14
    with-cve/Dockerfile                             Task 14
    minimal-release-please/{release-please-config.json,.release-please-manifest.json}  Task 14
  shell/compute-prerelease-tag.bats                 Task 5
.gitignore                                          existing; modify in Task 1
.yamllint.yml                                       Task 1
CONTRIBUTING.md                                     Task 1
LICENSE                                             Task 1
README.md                                           Task 1 (stub) + Task 18 (full)
release-please-config.json                          Task 2
.release-please-manifest.json                       Task 2
```

**Naming note:** The catalog's own self-release lives at `.github/workflows/catalog-release.yml`, not `release.yml`, because `release.yml` is reserved for the consumer-facing orchestrator (canonical adopter reference path). See spec §6.3.

**Commit convention:** Use `chore:` prefix for all bootstrap commits until the catalog is functionally complete. The first `feat:` commit triggers release-please to propose `v0.1.0`. This way the catalog doesn't accidentally release a half-built v0.1.0 during implementation.

---

## Task 1: Bootstrap files (README stub, LICENSE, CONTRIBUTING, .yamllint, Renovate, gitignore)

**Files:**
- Create: `README.md` (stub; full version in Task 18)
- Create: `LICENSE` (MIT — matches serverkraken convention)
- Create: `CONTRIBUTING.md`
- Create: `.yamllint.yml`
- Create: `.github/renovate.json5`
- Modify: `.gitignore` (add tooling artifacts)

- [ ] **Step 1: Write `README.md` stub**

```markdown
# serverkraken/reusable-workflows

Versioned, tested catalog of GitHub Actions reusable workflows for the `serverkraken` organisation.

**Status:** Bootstrapping (v0.1.0 in progress). Full documentation will be available once v0.1.0 is released.

See [the design spec](docs/superpowers/specs/2026-05-16-reusable-workflows-design.md) for the architecture and contract surface.

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 2: Write `LICENSE`** (MIT, year 2026, owner `serverkraken`)

```
MIT License

Copyright (c) 2026 serverkraken

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Write `CONTRIBUTING.md`**

```markdown
# Contributing

## Local validation

Before pushing a PR, run the static checks the CI will run:

\`\`\`bash
# Lint workflows
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest

# Lint YAML
pipx run yamllint .github/ actions/
\`\`\`

For the integration tests, use `act`:

\`\`\`bash
act pull_request -W .github/workflows/integration.yml --container-architecture linux/amd64
\`\`\`

## Commit messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org/). release-please reads the log to decide the next version:

- `feat: …` → minor bump (or major if `feat!:`)
- `fix: …` → patch bump
- `chore: …`, `docs: …`, `test: …`, `ci: …` → no version bump
- `feat!:` or `BREAKING CHANGE:` in body → major bump

## Backwards compatibility contract

The `inputs:` / `outputs:` / `secrets:` of every reusable workflow are the public API. Any change to those shapes — adding required inputs, removing inputs, renaming outputs — is a **breaking change** and requires `feat!:` or `BREAKING CHANGE:`.

Adding optional inputs (with safe defaults), adding outputs, or changing internal step ordering is **non-breaking**.
```

- [ ] **Step 4: Write `.yamllint.yml`**

```yaml
extends: default
rules:
  line-length: { max: 200, level: warning }
  comments:
    min-spaces-from-content: 1
  comments-indentation: disable
  truthy:
    allowed-values: ['true', 'false', 'on', 'off']
    check-keys: false
  document-start: disable
  indentation:
    spaces: 2
    indent-sequences: consistent
ignore: |
  tests/fixtures/
```

- [ ] **Step 5: Write `.github/renovate.json5`** (full config from spec §5.4 + customManagers from §4.3)

```json5
{
  $schema: 'https://docs.renovatebot.com/renovate-schema.json',
  extends: [
    'config:recommended',
    ':dependencyDashboard',
    ':semanticCommits',
    'group:allNonMajor',
  ],
  timezone: 'Europe/Berlin',
  schedule: ['before 6am on monday'],
  labels: ['dependencies'],
  ignorePaths: ['tests/fixtures/**'],
  packageRules: [
    {
      description: 'GitHub Actions — auto-merge minor+patch (gated by integration tests)',
      matchManagers: ['github-actions'],
      matchUpdateTypes: ['minor', 'patch'],
      automerge: true,
      automergeType: 'pr',
      groupName: 'GitHub Actions',
    },
    {
      description: 'Supply-chain actions move in lockstep',
      matchPackagePatterns: ['^sigstore/', '^actions/attest-', '^anchore/sbom-action'],
      groupName: 'Supply chain actions',
    },
    {
      description: 'Docker actions',
      matchPackagePatterns: ['^docker/'],
      groupName: 'Docker actions',
    },
    {
      description: 'Major updates always require review',
      matchUpdateTypes: ['major'],
      automerge: false,
      labels: ['dependencies', 'major'],
    },
  ],
  vulnerabilityAlerts: {
    labels: ['security'],
    automerge: true,
  },
  customManagers: [
    {
      customType: 'regex',
      fileMatch: ['^\\.github/workflows/.+\\.ya?ml$', '^actions/.+/action\\.ya?ml$'],
      matchStrings: [
        '#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)\\s*\\n\\s*TRIVY_VERSION:\\s*[\'\"]?(?<currentValue>\\S+?)[\'\"]?\\s*$',
      ],
      datasourceTemplate: 'github-releases',
      depNameTemplate: 'aquasecurity/trivy',
      extractVersionTemplate: '^v(?<version>.*)$',
    },
  ],
}
```

- [ ] **Step 6: Append to `.gitignore`**

```
# Tooling
*.tmp
.act/

# Coverage
coverage/
*.bashcov

# OS
.DS_Store
```

Run to verify the existing entries are preserved:
```bash
cat .gitignore
```
Expected output includes original lines (`CLAUDE.md`, `CLAUDE-*.md`, `.claude/`) plus the new lines.

- [ ] **Step 7: Validate yamllint and commit**

```bash
pipx run yamllint .yamllint.yml .github/renovate.json5
```
Expected: no output (silent success).

Note: `.github/renovate.json5` is JSON5, not YAML — yamllint will skip it via file extension matching, but explicitly listing it as an arg makes the check fail. Adjust by passing only the directory:
```bash
pipx run yamllint .yamllint.yml
```

```bash
git add README.md LICENSE CONTRIBUTING.md .yamllint.yml .github/renovate.json5 .gitignore
git commit -m "chore: bootstrap repo (README stub, LICENSE, CONTRIBUTING, yamllint, Renovate, gitignore)"
```

---

## Task 2: Catalog's own release-please config + manifest

**Files:**
- Create: `release-please-config.json`
- Create: `.release-please-manifest.json`

- [ ] **Step 1: Write `release-please-config.json`**

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "packages": {
    ".": {
      "release-type": "simple",
      "include-component-in-tag": false,
      "bump-minor-pre-major": true,
      "draft": false,
      "prerelease": false,
      "changelog-sections": [
        { "type": "feat", "section": "Features" },
        { "type": "fix", "section": "Bug Fixes" },
        { "type": "perf", "section": "Performance" },
        { "type": "refactor", "section": "Refactors" },
        { "type": "docs", "section": "Documentation", "hidden": false },
        { "type": "test", "section": "Tests", "hidden": true },
        { "type": "ci", "section": "CI", "hidden": true },
        { "type": "chore", "section": "Chores", "hidden": true }
      ]
    }
  }
}
```

`release-type: simple` is correct for this repo: there's no package manifest (no `package.json`, `Cargo.toml`, `pyproject.toml`) to version-bump. release-please will just create the GitHub release and tag.

- [ ] **Step 2: Write `.release-please-manifest.json`**

```json
{
  ".": "0.0.0"
}
```

Starting at `0.0.0` means the first version bump will produce `v0.1.0` (because `bump-minor-pre-major: true`).

- [ ] **Step 3: Commit**

```bash
git add release-please-config.json .release-please-manifest.json
git commit -m "chore: add release-please config and manifest"
```

---

## Task 3: Composite action — `install-trivy`

**Files:**
- Create: `actions/install-trivy/action.yml`

- [ ] **Step 1: Write the action**

```yaml
# actions/install-trivy/action.yml
name: install-trivy
description: |
  Install the Trivy CLI at a pinned version. Direct binary install — does NOT
  use aquasecurity/trivy-action (reliability issues per juke.gallery-rest).
  If `version` input is empty, falls back to the action's pinned default
  (which Renovate keeps current via the customManager regex).

inputs:
  version:
    description: 'Trivy version (without leading v). Empty → pinned default.'
    required: false
    default: ''

runs:
  using: composite
  steps:
    - name: Install Trivy CLI
      shell: bash
      env:
        # renovate: datasource=github-releases depName=aquasecurity/trivy
        DEFAULT_TRIVY_VERSION: '0.69.3'
        REQUESTED_TRIVY_VERSION: ${{ inputs.version }}
      run: |
        set -euo pipefail
        TRIVY_VERSION="${REQUESTED_TRIVY_VERSION:-$DEFAULT_TRIVY_VERSION}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64)  TRIVY_ARCH=64bit ;;
          aarch64) TRIVY_ARCH=ARM64 ;;
          arm64)   TRIVY_ARCH=ARM64 ;;
          *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d)
        cd "$TMP"
        curl -fsSL \
          "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" \
          -o trivy.tar.gz
        tar -xzf trivy.tar.gz trivy
        sudo install -m 0755 trivy /usr/local/bin/trivy
        trivy --version
```

The `# renovate:` comment on the line immediately before `DEFAULT_TRIVY_VERSION:` is parsed by the customManager block defined in `.github/renovate.json5` (Task 1). Task 7's `trivy-renovate-annotation-check` job verifies the regex still matches if anyone reformats the YAML.

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add actions/install-trivy/action.yml
git commit -m "chore: add install-trivy composite action"
```

---

## Task 4: Composite action — `ghcr-login`

**Files:**
- Create: `actions/ghcr-login/action.yml`

- [ ] **Step 1: Write the action**

```yaml
# actions/ghcr-login/action.yml
name: ghcr-login
description: |
  Login to GitHub Container Registry (ghcr.io) using the workflow's GITHUB_TOKEN
  by default. Wraps docker/login-action with sensible defaults.

inputs:
  username:
    description: 'GHCR username. Defaults to the workflow actor.'
    required: false
    default: ${{ github.actor }}
  token:
    description: 'GHCR token. Defaults to GITHUB_TOKEN.'
    required: false
    default: ${{ github.token }}

runs:
  using: composite
  steps:
    - name: Log in to GHCR
      uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: ${{ inputs.username }}
        password: ${{ inputs.token }}
```

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add actions/ghcr-login/action.yml
git commit -m "chore: add ghcr-login composite action"
```

---

## Task 5: Composite action — `compute-prerelease-tag` (with bats tests)

This is the only composite action with non-trivial shell, so bats unit tests apply per spec §7.3.

**Files:**
- Create: `actions/compute-prerelease-tag/action.yml`
- Create: `actions/compute-prerelease-tag/sanitize.sh` (extracted for testing)
- Create: `tests/shell/compute-prerelease-tag.bats`

- [ ] **Step 1: Write the failing bats tests FIRST**

```bash
# tests/shell/compute-prerelease-tag.bats
#!/usr/bin/env bats

setup() {
  SANITIZE_SH="$BATS_TEST_DIRNAME/../../actions/compute-prerelease-tag/sanitize.sh"
}

@test "simple lowercase branch" {
  run bash "$SANITIZE_SH" "feat-x" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feat-x-a1b2c3d$"
  echo "$output" | grep -q "^moving_tag=feat-x$"
}

@test "slash in branch name becomes dash" {
  run bash "$SANITIZE_SH" "feat/auth-fix" "a1b2c3d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feat-auth-fix-a1b2c3d$"
  echo "$output" | grep -q "^moving_tag=feat-auth-fix$"
}

@test "uppercase letters are lowercased" {
  run bash "$SANITIZE_SH" "Feature/Auth-Fix" "DEADBEE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tag_with_sha=feature-auth-fix-deadbee$"
}

@test "invalid OCI characters are stripped" {
  run bash "$SANITIZE_SH" "feat/foo@bar~baz" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo-bar-baz$"
}

@test "multiple consecutive dashes collapse to one" {
  run bash "$SANITIZE_SH" "feat//foo--bar" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo-bar$"
}

@test "leading/trailing dashes are stripped" {
  run bash "$SANITIZE_SH" "-feat-foo-" "abcdef0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^moving_tag=feat-foo$"
}

@test "empty branch name fails" {
  run bash "$SANITIZE_SH" "" "abcdef0"
  [ "$status" -ne 0 ]
}

@test "empty SHA fails" {
  run bash "$SANITIZE_SH" "feat-x" ""
  [ "$status" -ne 0 ]
}

@test "branch consisting only of invalid chars fails" {
  run bash "$SANITIZE_SH" "@@@" "abcdef0"
  [ "$status" -ne 0 ]
}

@test "very long branch name truncated to 64 chars in moving tag" {
  long_branch=$(printf 'a%.0s' {1..200})
  run bash "$SANITIZE_SH" "$long_branch" "abcdef0"
  [ "$status" -eq 0 ]
  moving=$(echo "$output" | grep '^moving_tag=' | cut -d= -f2)
  [ ${#moving} -le 64 ]
}
```

- [ ] **Step 2: Install bats and run tests to confirm they fail**

```bash
brew install bats-core 2>&1 || true  # idempotent
bats tests/shell/compute-prerelease-tag.bats
```
Expected: all 10 tests fail with `cannot find sanitize.sh` (file doesn't exist yet).

- [ ] **Step 3: Write `sanitize.sh` minimal implementation**

```bash
# actions/compute-prerelease-tag/sanitize.sh
#!/usr/bin/env bash
set -euo pipefail

BRANCH="${1:-}"
SHORT_SHA="${2:-}"

if [[ -z "$BRANCH" ]] || [[ -z "$SHORT_SHA" ]]; then
  echo "usage: $0 <branch> <short-sha>" >&2
  exit 1
fi

# Lowercase, replace non-alphanumeric with dashes, collapse, trim
sanitized=$(echo "$BRANCH" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g' \
  | sed 's/--*/-/g' \
  | sed 's/^-//;s/-$//')

# OCI tag spec: ≤128 chars, but we cap moving tag at 64 for readability
moving_tag="${sanitized:0:64}"
moving_tag="${moving_tag%-}"   # don't end on dash if truncated mid-word

if [[ -z "$moving_tag" ]]; then
  echo "branch '$BRANCH' produced empty tag after sanitization" >&2
  exit 1
fi

tag_with_sha="${moving_tag}-${SHORT_SHA}"

echo "tag_with_sha=${tag_with_sha}"
echo "moving_tag=${moving_tag}"
```

```bash
chmod +x actions/compute-prerelease-tag/sanitize.sh
```

- [ ] **Step 4: Run tests, verify all pass**

```bash
bats tests/shell/compute-prerelease-tag.bats
```
Expected:
```
 ✓ simple lowercase branch
 ✓ slash in branch name becomes dash
 ✓ uppercase letters are lowercased
 ✓ invalid OCI characters are stripped
 ✓ multiple consecutive dashes collapse to one
 ✓ leading/trailing dashes are stripped
 ✓ empty branch name fails
 ✓ empty SHA fails
 ✓ branch consisting only of invalid chars fails
 ✓ very long branch name truncated to 64 chars in moving tag

10 tests, 0 failures
```

- [ ] **Step 5: Write the composite action wrapper**

```yaml
# actions/compute-prerelease-tag/action.yml
name: compute-prerelease-tag
description: |
  Compute OCI-valid prerelease tags from a branch name and short SHA.
  Outputs two tags: moving_tag (e.g. 'feat-auth-fix') and tag_with_sha
  (e.g. 'feat-auth-fix-a1b2c3d'). Branch name is lowercased, non-alphanumeric
  characters are replaced with dashes, consecutive dashes collapsed,
  leading/trailing dashes stripped, moving_tag capped at 64 chars.

inputs:
  branch:
    description: 'Branch name (e.g. github.head_ref or github.ref_name).'
    required: true
  short_sha:
    description: 'Short commit SHA.'
    required: true

outputs:
  tag_with_sha:
    description: 'Unique-per-commit tag: <sanitized-branch>-<short-sha>'
    value: ${{ steps.compute.outputs.tag_with_sha }}
  moving_tag:
    description: 'Moving tag (without SHA), points to latest build of branch'
    value: ${{ steps.compute.outputs.moving_tag }}

runs:
  using: composite
  steps:
    - name: Sanitize and emit
      id: compute
      shell: bash
      env:
        BRANCH: ${{ inputs.branch }}
        SHORT_SHA: ${{ inputs.short_sha }}
      run: |
        bash "${GITHUB_ACTION_PATH}/sanitize.sh" "$BRANCH" "$SHORT_SHA" \
          | tee -a "$GITHUB_OUTPUT"
```

- [ ] **Step 6: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add actions/compute-prerelease-tag/ tests/shell/compute-prerelease-tag.bats
git commit -m "chore: add compute-prerelease-tag composite action with bats tests"
```

---

## Task 6: Composite action — `post-prerelease-comment`

**Files:**
- Create: `actions/post-prerelease-comment/action.yml`

- [ ] **Step 1: Write the action**

```yaml
# actions/post-prerelease-comment/action.yml
name: post-prerelease-comment
description: |
  Idempotently post or update a PR comment with a Docker pull command for a
  prerelease image. Detects an existing comment by a stable header marker.

inputs:
  image_ref:
    description: 'Full image reference, e.g. ghcr.io/serverkraken/foo:feat-x-a1b2c3d'
    required: true
  pr_number:
    description: 'PR number to post the comment on.'
    required: true
  trivy_status:
    description: 'Optional Trivy result line (e.g. "✅ no HIGH/CRITICAL").'
    required: false
    default: ''
  github_token:
    description: 'Token with pull-requests:write permission.'
    required: false
    default: ${{ github.token }}

runs:
  using: composite
  steps:
    - name: Find existing comment
      id: find
      uses: peter-evans/find-comment@v3
      with:
        issue-number: ${{ inputs.pr_number }}
        comment-author: 'github-actions[bot]'
        body-includes: '<!-- prerelease-image-comment -->'
        token: ${{ inputs.github_token }}

    - name: Compose body
      id: body
      shell: bash
      env:
        IMAGE_REF: ${{ inputs.image_ref }}
        TRIVY_STATUS: ${{ inputs.trivy_status }}
      run: |
        SHORT_SHA=$(echo "$IMAGE_REF" | rev | cut -d- -f1 | rev | cut -c1-7)
        BODY=$(cat <<EOF
        <!-- prerelease-image-comment -->
        🐳 **Prerelease image ready**

        \`\`\`
        docker pull $IMAGE_REF
        \`\`\`

        Built from \`$SHORT_SHA\`
        EOF
        )
        if [[ -n "$TRIVY_STATUS" ]]; then
          BODY="$BODY · trivy: $TRIVY_STATUS"
        fi
        {
          echo 'body<<DELIM'
          echo "$BODY"
          echo 'DELIM'
        } >> "$GITHUB_OUTPUT"

    - name: Create or update comment
      uses: peter-evans/create-or-update-comment@v4
      with:
        comment-id: ${{ steps.find.outputs.comment-id }}
        issue-number: ${{ inputs.pr_number }}
        body: ${{ steps.body.outputs.body }}
        edit-mode: replace
        token: ${{ inputs.github_token }}
```

The `<!-- prerelease-image-comment -->` HTML marker is invisible to readers but stable for the `find-comment` action to match against, enabling idempotency.

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add actions/post-prerelease-comment/action.yml
git commit -m "chore: add post-prerelease-comment composite action"
```

---

## Task 7: `validate.yml` self-CI workflow

**Files:**
- Create: `.github/workflows/validate.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/validate.yml
name: validate
on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: validate-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run actionlint
        uses: rhysd/actionlint@v1
        with:
          color: 'true'

  yamllint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Install yamllint
        run: pipx install yamllint
      - name: Run yamllint
        run: yamllint .github/ actions/ tests/

  renovate-config-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Validate renovate.json5
        uses: suzuki-shunsuke/renovate-config-validator-action@v1
        with:
          config: .github/renovate.json5

  trivy-renovate-annotation-check:
    # Verify the customManagers regex actually matches the # renovate: comment
    # in install-trivy/action.yml. Catches regression where someone reformats
    # the comment in a way that breaks the parser.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Check that Renovate would detect TRIVY_VERSION
        run: |
          set -e
          PATTERN='# renovate: datasource=github-releases depName=aquasecurity/trivy'
          grep -A1 "$PATTERN" actions/install-trivy/action.yml \
            | grep -E "default: '[0-9]+\.[0-9]+\.[0-9]+'" \
            || { echo "::error::Renovate annotation broken in install-trivy"; exit 1; }
```

`ubuntu-latest` here (not self-hosted): static checks don't need the self-hosted pool and avoid bootstrapping self-hosted before the catalog itself can release.

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no errors.

- [ ] **Step 3: Commit + push (this is the first workflow that should run on push)**

```bash
git add .github/workflows/validate.yml
git commit -m "chore: add validate workflow (actionlint + yamllint + renovate config + trivy-annotation guard)"
git push origin main
```

- [ ] **Step 4: Watch the validate workflow run**

```bash
gh run watch
```
Expected: all four jobs pass green within ~30 seconds.

If a job fails, fix the underlying file and recommit before continuing to Task 8.

---

## Task 8: Atom — `cleanup-images.yml`

Simplest atom — no upstream dependencies on other atoms. Good first atom to validate the reusable-workflow contract.

**Files:**
- Create: `.github/workflows/cleanup-images.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/cleanup-images.yml
name: cleanup-images
on:
  workflow_call:
    inputs:
      package_name:
        description: 'GHCR package name. Defaults to the calling repo name.'
        required: false
        type: string
        default: ''
      keep_stable_versions:
        description: 'Min count of v* (semver) versions to keep.'
        required: false
        type: number
        default: 10
      prerelease_age_days:
        description: 'Delete non-semver tags older than N days.'
        required: false
        type: number
        default: 14
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'

permissions:
  packages: write

concurrency:
  group: cleanup-${{ github.repository }}
  cancel-in-progress: false

jobs:
  cleanup:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    steps:
      - name: Resolve package name
        id: pkg
        env:
          INPUT_NAME: ${{ inputs.package_name }}
          DEFAULT_NAME: ${{ github.event.repository.name }}
        run: |
          NAME="${INPUT_NAME:-$DEFAULT_NAME}"
          echo "name=$NAME" >> "$GITHUB_OUTPUT"

      - name: Delete old prerelease/non-semver tags
        uses: actions/delete-package-versions@v5
        with:
          package-name: ${{ steps.pkg.outputs.name }}
          package-type: container
          delete-only-pre-release-versions: true
          # The action operates on package versions; non-semver tagged versions
          # are treated as prereleases by this flag's semantics.
          min-versions-to-keep: 0

      - name: Prune oldest stable versions over keep threshold
        uses: actions/delete-package-versions@v5
        with:
          package-name: ${{ steps.pkg.outputs.name }}
          package-type: container
          min-versions-to-keep: ${{ inputs.keep_stable_versions }}
          delete-only-untagged-versions: false

      - name: Summary
        run: |
          {
            echo "## 🧹 Cleanup complete"
            echo ""
            echo "**Package:** \`${{ steps.pkg.outputs.name }}\`"
            echo "**Kept stable versions:** ${{ inputs.keep_stable_versions }}"
            echo "**Pre-release retention:** ${{ inputs.prerelease_age_days }} days"
          } >> "$GITHUB_STEP_SUMMARY"
```

**Note on `prerelease_age_days`:** The `actions/delete-package-versions@v5` action doesn't support age-based filtering directly. The current implementation deletes ALL prerelease versions, ignoring `prerelease_age_days`. Document this as a known limitation; v1.x can swap in a custom script using `gh api /orgs/.../packages/...` when age-based retention becomes a real need.

Update the docstring on the input to reflect:

```yaml
      prerelease_age_days:
        description: |
          (Not yet enforced — see workflow comments.) Intent: delete non-semver
          tags older than N days. Current behavior: ALL non-semver tags are
          deleted on each run.
```

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/cleanup-images.yml
git commit -m "chore(cleanup-images): add atom workflow for GHCR retention"
```

---

## Task 9: Atom — `trivy-fs.yml`

**Files:**
- Create: `.github/workflows/trivy-fs.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/trivy-fs.yml
name: trivy-fs
on:
  workflow_call:
    inputs:
      scanners:
        description: 'Trivy scanners (vuln,secret,misconfig).'
        required: false
        type: string
        default: 'vuln,secret,misconfig'
      severity:
        description: 'Severity levels to fail on.'
        required: false
        type: string
        default: 'HIGH,CRITICAL'
      paths_ignore:
        description: 'Newline-separated paths to skip.'
        required: false
        type: string
        default: ''
      upload_sarif:
        description: 'Upload SARIF to GitHub code-scanning. Auto-skipped on forks.'
        required: false
        type: boolean
        default: true
      trivy_version:
        description: 'Override Trivy version (defaults to install-trivy default).'
        required: false
        type: string
        default: ''
      fail_on_findings:
        description: 'Exit non-zero when severity-matching findings exist.'
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
        description: 'Number of findings at requested severity.'
        value: ${{ jobs.scan.outputs.findings_count }}

permissions:
  contents: read
  security-events: write

concurrency:
  group: trivy-fs-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  scan:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    outputs:
      findings_count: ${{ steps.count.outputs.findings_count }}
    steps:
      - uses: actions/checkout@v6
      - name: Checkout catalog for composite actions
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.workflow_sha }}
          path: .catalog

      - name: Install Trivy
        uses: ./.catalog/actions/install-trivy
        with:
          version: ${{ inputs.trivy_version }}

      - name: Build ignore-paths args
        id: ignore
        env:
          PATHS: ${{ inputs.paths_ignore }}
        run: |
          if [[ -z "$PATHS" ]]; then
            echo "args=" >> "$GITHUB_OUTPUT"
          else
            ARGS=""
            while IFS= read -r line; do
              [[ -z "$line" ]] && continue
              ARGS="$ARGS --skip-dirs $line"
            done <<< "$PATHS"
            echo "args=$ARGS" >> "$GITHUB_OUTPUT"
          fi

      - name: Run Trivy filesystem scan
        env:
          SCANNERS: ${{ inputs.scanners }}
          SEVERITY: ${{ inputs.severity }}
          IGNORE_ARGS: ${{ steps.ignore.outputs.args }}
        run: |
          set -e
          # Run twice: once for SARIF output, once for JSON to count findings.
          trivy fs \
            --scanners "$SCANNERS" \
            --severity "$SEVERITY" \
            --exit-code 0 \
            --ignore-unfixed \
            --format sarif \
            --output trivy-fs.sarif \
            $IGNORE_ARGS .
          trivy fs \
            --scanners "$SCANNERS" \
            --severity "$SEVERITY" \
            --exit-code 0 \
            --ignore-unfixed \
            --format json \
            --output trivy-fs.json \
            $IGNORE_ARGS .

      - name: Count findings
        id: count
        run: |
          COUNT=$(jq '[.Results[]? | (.Vulnerabilities // []) + (.Secrets // []) + (.Misconfigurations // []) | length] | add // 0' trivy-fs.json)
          echo "findings_count=$COUNT" >> "$GITHUB_OUTPUT"
          echo "Found $COUNT severity-matching findings"

      - name: Upload SARIF to code-scanning
        if: inputs.upload_sarif && github.event.pull_request.head.repo.full_name == github.repository
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: trivy-fs.sarif
          category: trivy-fs

      - name: Upload SARIF as artifact
        uses: actions/upload-artifact@v4
        with:
          name: trivy-fs-sarif
          path: trivy-fs.sarif
          if-no-files-found: error
          retention-days: 7

      - name: Job summary
        if: always()
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
        run: |
          {
            echo "## 🛡️ Trivy filesystem scan"
            echo ""
            echo "**Scanners:** \`${{ inputs.scanners }}\`"
            echo "**Severity:** \`${{ inputs.severity }}\`"
            echo "**Findings:** **$COUNT**"
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Fail on findings
        if: inputs.fail_on_findings && steps.count.outputs.findings_count != '0'
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
        run: |
          echo "::error::Trivy found $COUNT severity-matching findings"
          exit 1
```

**Why `actions/checkout` twice**: composite-action references from inside a reusable workflow resolve against the **caller's** checkout, not the catalog's. The workaround is to explicitly check out the catalog into `.catalog/` and reference actions from there. `github.workflow_sha` resolves to the exact commit the caller pinned (via `@v1`, `@v1.2`, etc.), so the catalog version stays in sync.

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/trivy-fs.yml
git commit -m "chore(trivy-fs): add filesystem scan atom"
```

---

## Task 10: Atom — `trivy-image.yml`

**Files:**
- Create: `.github/workflows/trivy-image.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/trivy-image.yml
name: trivy-image
on:
  workflow_call:
    inputs:
      image_ref:
        description: 'Full image reference, e.g. ghcr.io/serverkraken/foo:v1.2.3'
        required: true
        type: string
      scanners:
        required: false
        type: string
        default: 'vuln,secret,misconfig'
      severity:
        required: false
        type: string
        default: 'HIGH,CRITICAL'
      ignore_unfixed:
        required: false
        type: boolean
        default: true
      fail_on_findings:
        required: false
        type: boolean
        default: true
      paths_ignore:
        required: false
        type: string
        default: ''
      upload_sarif:
        required: false
        type: boolean
        default: true
      trivy_version:
        required: false
        type: string
        default: ''
      runs_on:
        required: false
        type: string
        default: '["self-hosted","Linux"]'
    outputs:
      findings_count:
        value: ${{ jobs.scan.outputs.findings_count }}

permissions:
  contents: read
  security-events: write
  packages: read    # to pull the image from GHCR

concurrency:
  group: trivy-image-${{ inputs.image_ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  scan:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    outputs:
      findings_count: ${{ steps.count.outputs.findings_count }}
    steps:
      - uses: actions/checkout@v6
      - name: Checkout catalog for composite actions
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.workflow_sha }}
          path: .catalog
      - name: Install Trivy
        uses: ./.catalog/actions/install-trivy
        with:
          version: ${{ inputs.trivy_version }}
      - name: Log in to GHCR
        uses: ./.catalog/actions/ghcr-login

      - name: Run Trivy image scan
        env:
          IMAGE: ${{ inputs.image_ref }}
          SCANNERS: ${{ inputs.scanners }}
          SEVERITY: ${{ inputs.severity }}
          IGNORE_UNFIXED: ${{ inputs.ignore_unfixed }}
        run: |
          set -e
          UNFIXED_FLAG=""
          [[ "$IGNORE_UNFIXED" == "true" ]] && UNFIXED_FLAG="--ignore-unfixed"
          trivy image \
            --scanners "$SCANNERS" \
            --severity "$SEVERITY" \
            --exit-code 0 \
            $UNFIXED_FLAG \
            --format sarif \
            --output trivy-image.sarif \
            "$IMAGE"
          trivy image \
            --scanners "$SCANNERS" \
            --severity "$SEVERITY" \
            --exit-code 0 \
            $UNFIXED_FLAG \
            --format json \
            --output trivy-image.json \
            "$IMAGE"

      - name: Count findings
        id: count
        run: |
          COUNT=$(jq '[.Results[]? | (.Vulnerabilities // []) + (.Secrets // []) + (.Misconfigurations // []) | length] | add // 0' trivy-image.json)
          echo "findings_count=$COUNT" >> "$GITHUB_OUTPUT"

      - name: Upload SARIF to code-scanning
        if: inputs.upload_sarif && github.event.pull_request.head.repo.full_name == github.repository
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: trivy-image.sarif
          category: trivy-image

      - name: Upload SARIF as artifact
        uses: actions/upload-artifact@v4
        with:
          name: trivy-image-sarif
          path: trivy-image.sarif
          if-no-files-found: error
          retention-days: 7

      - name: Job summary
        if: always()
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
        run: |
          {
            echo "## 🛡️ Trivy image scan"
            echo ""
            echo "**Image:** \`${{ inputs.image_ref }}\`"
            echo "**Scanners:** \`${{ inputs.scanners }}\`"
            echo "**Severity:** \`${{ inputs.severity }}\`"
            echo "**Findings:** **$COUNT**"
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Fail on findings
        if: inputs.fail_on_findings && steps.count.outputs.findings_count != '0'
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
        run: |
          echo "::error::Trivy found $COUNT severity-matching findings in $IMAGE"
          exit 1
```

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/trivy-image.yml
git commit -m "chore(trivy-image): add image scan atom"
```

---

## Task 11: Atom — `docker-build.yml` (the meaty one)

**Files:**
- Create: `.github/workflows/docker-build.yml`

This is the most complex atom: multi-arch matrix, Cosign signing, SLSA attestation, SBOM, prerelease tagging, PR comment.

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/docker-build.yml
name: docker-build
on:
  workflow_call:
    inputs:
      tag:
        description: 'Image tag. Empty → auto-compute (prerelease only).'
        required: false
        type: string
        default: ''
      prerelease:
        description: 'Prerelease build (no :latest, auto-compute tag if empty).'
        required: false
        type: boolean
        default: false
      image_name:
        description: 'Image name. Default: caller repo (owner/repo).'
        required: false
        type: string
        default: ''
      dockerfile:
        required: false
        type: string
        default: './Dockerfile'
      context:
        required: false
        type: string
        default: '.'
      platforms:
        required: false
        type: string
        default: 'linux/amd64,linux/arm64'
      build_args:
        required: false
        type: string
        default: ''
      sign:
        required: false
        type: boolean
        default: true
      attest:
        required: false
        type: boolean
        default: true
      sbom:
        required: false
        type: boolean
        default: true
      runs_on_amd64:
        required: false
        type: string
        default: '["self-hosted","Linux","X64","performance"]'
      runs_on_arm64:
        required: false
        type: string
        default: '["self-hosted","Linux","ARM64"]'
      runs_on_merge:
        required: false
        type: string
        default: '["self-hosted","Linux","low-performance"]'
    outputs:
      image_ref:
        description: 'Pushed image reference with tag.'
        value: ${{ jobs.merge.outputs.image_ref }}
      digest:
        description: 'Manifest list digest (sha256:...).'
        value: ${{ jobs.merge.outputs.digest }}
      tag:
        description: 'Final tag (auto-computed if input was empty).'
        value: ${{ jobs.version.outputs.tag }}

permissions:
  contents: read
  packages: write
  id-token: write
  attestations: write
  pull-requests: write

concurrency:
  group: docker-build-${{ inputs.tag || github.ref }}
  cancel-in-progress: ${{ inputs.prerelease }}

jobs:
  version:
    runs-on: ${{ fromJSON(inputs.runs_on_merge) }}
    outputs:
      tag: ${{ steps.resolve.outputs.tag }}
      moving_tag: ${{ steps.resolve.outputs.moving_tag }}
      image_name: ${{ steps.resolve.outputs.image_name }}
    steps:
      - uses: actions/checkout@v6
      - name: Checkout catalog for composite actions
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.workflow_sha }}
          path: .catalog

      - name: Compute prerelease tag (if needed)
        id: prerelease_tag
        if: inputs.prerelease && inputs.tag == ''
        uses: ./.catalog/actions/compute-prerelease-tag
        with:
          branch: ${{ github.head_ref || github.ref_name }}
          short_sha: ${{ github.event.pull_request.head.sha != '' && github.event.pull_request.head.sha || github.sha }}

      - name: Resolve effective tag and image name
        id: resolve
        env:
          INPUT_TAG: ${{ inputs.tag }}
          INPUT_IMAGE: ${{ inputs.image_name }}
          DEFAULT_IMAGE: ${{ github.repository }}
          PRE_TAG: ${{ steps.prerelease_tag.outputs.tag_with_sha }}
          PRE_MOVING: ${{ steps.prerelease_tag.outputs.moving_tag }}
          IS_PRE: ${{ inputs.prerelease }}
        run: |
          TAG="${INPUT_TAG:-}"
          if [[ -z "$TAG" ]] && [[ "$IS_PRE" == "true" ]]; then
            TAG="$PRE_TAG"
          fi
          if [[ -z "$TAG" ]]; then
            echo "::error::tag input is empty and prerelease=false; cannot resolve tag"
            exit 1
          fi
          IMG="${INPUT_IMAGE:-$DEFAULT_IMAGE}"
          {
            echo "tag=$TAG"
            echo "moving_tag=$PRE_MOVING"
            echo "image_name=$IMG"
          } >> "$GITHUB_OUTPUT"

  build:
    needs: version
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: linux/amd64
            arch: amd64
            runs_on_input: runs_on_amd64
          - platform: linux/arm64
            arch: arm64
            runs_on_input: runs_on_arm64
    runs-on: ${{ fromJSON(matrix.runs_on_input == 'runs_on_amd64' && inputs.runs_on_amd64 || inputs.runs_on_arm64) }}
    steps:
      - uses: actions/checkout@v6
      - name: Checkout catalog for composite actions
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.workflow_sha }}
          path: .catalog
      - name: Log in to GHCR
        uses: ./.catalog/actions/ghcr-login

      - uses: docker/setup-buildx-action@v4

      - name: Build and push by digest
        id: build
        uses: docker/build-push-action@v7
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.dockerfile }}
          platforms: ${{ matrix.platform }}
          build-args: ${{ inputs.build_args }}
          outputs: type=image,name=ghcr.io/${{ needs.version.outputs.image_name }},push-by-digest=true,name-canonical=true,push=true
          cache-from: type=gha,scope=build-${{ matrix.arch }}
          cache-to: type=gha,mode=max,scope=build-${{ matrix.arch }}

      - name: Export digest
        run: |
          mkdir -p /tmp/digests
          digest="${{ steps.build.outputs.digest }}"
          touch "/tmp/digests/${digest#sha256:}"

      - uses: actions/upload-artifact@v4
        with:
          name: digests-${{ matrix.arch }}
          path: /tmp/digests/*
          if-no-files-found: error
          retention-days: 1

  merge:
    needs: [version, build]
    runs-on: ${{ fromJSON(inputs.runs_on_merge) }}
    outputs:
      image_ref: ${{ steps.compose.outputs.image_ref }}
      digest: ${{ steps.merge_step.outputs.digest }}
    steps:
      - uses: actions/checkout@v6
      - name: Checkout catalog for composite actions
        uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.workflow_sha }}
          path: .catalog
      - name: Log in to GHCR
        uses: ./.catalog/actions/ghcr-login

      - uses: actions/download-artifact@v4
        with:
          path: /tmp/digests
          pattern: digests-*
          merge-multiple: true

      - uses: docker/setup-buildx-action@v4

      - name: Compose tag list
        id: tags
        env:
          IMG: ghcr.io/${{ needs.version.outputs.image_name }}
          TAG: ${{ needs.version.outputs.tag }}
          MOVING: ${{ needs.version.outputs.moving_tag }}
          IS_PRE: ${{ inputs.prerelease }}
        run: |
          ARGS="-t $IMG:$TAG"
          if [[ "$IS_PRE" != "true" ]]; then
            ARGS="$ARGS -t $IMG:latest"
          fi
          if [[ -n "$MOVING" ]]; then
            ARGS="$ARGS -t $IMG:$MOVING"
          fi
          echo "tag_args=$ARGS" >> "$GITHUB_OUTPUT"

      - name: Create manifest list and capture digest
        id: merge_step
        working-directory: /tmp/digests
        env:
          IMG: ghcr.io/${{ needs.version.outputs.image_name }}
          TAG_ARGS: ${{ steps.tags.outputs.tag_args }}
        run: |
          docker buildx imagetools create $TAG_ARGS \
            $(printf "$IMG@sha256:%s " *)
          DIGEST=$(docker buildx imagetools inspect "$IMG:${{ needs.version.outputs.tag }}" --format '{{.Manifest.Digest}}')
          echo "digest=$DIGEST" >> "$GITHUB_OUTPUT"

      - name: Compose image_ref output
        id: compose
        run: |
          echo "image_ref=ghcr.io/${{ needs.version.outputs.image_name }}:${{ needs.version.outputs.tag }}" >> "$GITHUB_OUTPUT"

      - name: Install Cosign
        if: inputs.sign
        uses: sigstore/cosign-installer@v3

      - name: Sign image
        if: inputs.sign
        env:
          IMG: ghcr.io/${{ needs.version.outputs.image_name }}
          DIGEST: ${{ steps.merge_step.outputs.digest }}
        run: cosign sign --yes "$IMG@$DIGEST"

      - name: Attest build provenance
        if: inputs.attest
        uses: actions/attest-build-provenance@v2
        with:
          subject-name: ghcr.io/${{ needs.version.outputs.image_name }}
          subject-digest: ${{ steps.merge_step.outputs.digest }}
          push-to-registry: true

      - name: Generate SBOM
        if: inputs.sbom
        uses: anchore/sbom-action@v0
        with:
          image: ghcr.io/${{ needs.version.outputs.image_name }}:${{ needs.version.outputs.tag }}
          format: spdx-json
          output-file: sbom.spdx.json
          upload-artifact: false   # we'll upload ourselves below

      - name: Upload SBOM artifact
        if: inputs.sbom
        uses: actions/upload-artifact@v4
        with:
          name: sbom-spdx
          path: sbom.spdx.json
          if-no-files-found: error
          retention-days: 30

      - name: Job summary
        run: |
          {
            echo "## 🐳 Multi-arch image published"
            echo ""
            echo "**Image:** \`ghcr.io/${{ needs.version.outputs.image_name }}:${{ needs.version.outputs.tag }}\`"
            echo "**Digest:** \`${{ steps.merge_step.outputs.digest }}\`"
            echo "**Platforms:** \`${{ inputs.platforms }}\`"
            echo "**Signed:** ${{ inputs.sign }}"
            echo "**Attested:** ${{ inputs.attest }}"
            echo "**SBOM:** ${{ inputs.sbom }}"
          } >> "$GITHUB_STEP_SUMMARY"

  post-comment:
    # Only run for prerelease builds initiated from a PR context.
    if: inputs.prerelease && github.event.pull_request.number != ''
    needs: [version, merge]
    runs-on: ${{ fromJSON(inputs.runs_on_merge) }}
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ github.workflow_sha }}
          path: .catalog
      - name: Post PR comment
        uses: ./.catalog/actions/post-prerelease-comment
        with:
          image_ref: ghcr.io/${{ needs.version.outputs.image_name }}:${{ needs.version.outputs.tag }}
          pr_number: ${{ github.event.pull_request.number }}
```

**The matrix `runs-on` selector** uses a ternary expression because matrix values can't directly reference different inputs based on `matrix.runs_on_input`. The string-based key + ternary lookup is the GitHub-Actions-idiomatic workaround.

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no errors. If actionlint complains about the matrix `runs-on` ternary, fix the expression syntax until clean.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/docker-build.yml
git commit -m "chore(docker-build): add multi-arch atom with cosign, attestation, SBOM, prerelease tagging"
```

---

## Task 12: Atom — `semantic-release.yml` (GitHub App auth + floating tags)

**Files:**
- Create: `.github/workflows/semantic-release.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/semantic-release.yml
name: semantic-release
on:
  workflow_call:
    inputs:
      runs_on:
        required: false
        type: string
        default: '["self-hosted","Linux","low-performance"]'
      release_please_config:
        required: false
        type: string
        default: 'release-please-config.json'
      release_please_manifest:
        required: false
        type: string
        default: '.release-please-manifest.json'
    outputs:
      release_created:
        value: ${{ jobs.release.outputs.release_created }}
      tag_name:
        value: ${{ jobs.release.outputs.tag_name }}
      major_tag:
        value: ${{ jobs.release.outputs.major_tag }}
      minor_tag:
        value: ${{ jobs.release.outputs.minor_tag }}
    secrets:
      release_please_app_id:
        required: true
        description: 'GitHub App ID for the release-please bot.'
      release_please_app_private_key:
        required: true
        description: 'PEM-formatted private key for the release-please bot.'

permissions:
  contents: write
  pull-requests: write
  issues: write

concurrency:
  group: semantic-release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  release:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    outputs:
      release_created: ${{ steps.release.outputs.release_created }}
      tag_name: ${{ steps.release.outputs.tag_name }}
      major_tag: ${{ steps.float.outputs.major_tag }}
      minor_tag: ${{ steps.float.outputs.minor_tag }}
    steps:
      - name: Mint GitHub App installation token
        uses: actions/create-github-app-token@v2
        id: app-token
        with:
          app-id: ${{ secrets.release_please_app_id }}
          private-key: ${{ secrets.release_please_app_private_key }}

      - uses: actions/checkout@v6
        with:
          token: ${{ steps.app-token.outputs.token }}
          fetch-depth: 0

      - uses: googleapis/release-please-action@v4
        id: release
        with:
          token: ${{ steps.app-token.outputs.token }}
          config-file: ${{ inputs.release_please_config }}
          manifest-file: ${{ inputs.release_please_manifest }}

      - name: Move floating major/minor tags
        id: float
        if: |
          steps.release.outputs.release_created == 'true' &&
          !contains(steps.release.outputs.tag_name, '-')
        env:
          NEW_TAG: ${{ steps.release.outputs.tag_name }}
        run: |
          set -euo pipefail
          # Lightweight tags carry no tagger info, so git user.name/email
          # config is intentionally omitted here. The push is authenticated
          # by the checkout's App token (set in the earlier checkout step).
          VERSION="${NEW_TAG#v}"
          IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
          MAJOR_TAG="v$MAJOR"
          MINOR_TAG="v$MAJOR.$MINOR"
          git tag -f "$MAJOR_TAG"
          git tag -f "$MINOR_TAG"
          git push origin "$MAJOR_TAG" "$MINOR_TAG" --force
          {
            echo "major_tag=$MAJOR_TAG"
            echo "minor_tag=$MINOR_TAG"
          } >> "$GITHUB_OUTPUT"

      - name: Job summary
        if: steps.release.outputs.release_created == 'true'
        env:
          TAG: ${{ steps.release.outputs.tag_name }}
          MAJ: ${{ steps.float.outputs.major_tag }}
          MIN: ${{ steps.float.outputs.minor_tag }}
        run: |
          {
            echo "## 🎉 Released $TAG"
            echo ""
            if [[ -n "${MAJ:-}" ]]; then
              echo "**Floating tags updated:** \`$MAJ\` · \`$MIN\`"
            fi
          } >> "$GITHUB_STEP_SUMMARY"
```

**Lightweight tags carry no tagger info**, so the `git config user.*` lines that appear in many examples (including the spec §4.1 sketch) are vestigial and intentionally omitted here. The `git push` is authenticated by the App token already configured on the `actions/checkout` step earlier in this job. If we ever need annotated tags (e.g., signed tags), revisit and resolve the bot's noreply email at that time via `gh api /users/serverkraken-release-bot[bot] -q .id`.

- [ ] **Step 2: actionlint passes**

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/semantic-release.yml
git commit -m "chore(semantic-release): add release-please atom with GitHub App auth and floating major/minor tags"
```

---

## Task 13: Orchestrator — `release.yml`

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write the orchestrator**

```yaml
# .github/workflows/release.yml
# Opinionated end-to-end release pipeline. Most consumers should call this
# rather than wiring the atoms directly.
name: release
on:
  workflow_call:
    inputs:
      build_image:
        required: false
        type: boolean
        default: true
      run_trivy:
        required: false
        type: boolean
        default: true
      dockerfile:
        required: false
        type: string
        default: './Dockerfile'
      context:
        required: false
        type: string
        default: '.'
      platforms:
        required: false
        type: string
        default: 'linux/amd64,linux/arm64'
      trivy_severity:
        required: false
        type: string
        default: 'HIGH,CRITICAL'
    secrets:
      release_please_app_id:
        required: true
      release_please_app_private_key:
        required: true

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  semantic-release:
    uses: ./.github/workflows/semantic-release.yml
    secrets: inherit

  docker-build:
    needs: semantic-release
    if: needs.semantic-release.outputs.release_created == 'true' && inputs.build_image
    uses: ./.github/workflows/docker-build.yml
    with:
      tag: ${{ needs.semantic-release.outputs.tag_name }}
      prerelease: false
      dockerfile: ${{ inputs.dockerfile }}
      context: ${{ inputs.context }}
      platforms: ${{ inputs.platforms }}

  trivy-image:
    needs: [semantic-release, docker-build]
    if: needs.semantic-release.outputs.release_created == 'true' && inputs.build_image && inputs.run_trivy
    uses: ./.github/workflows/trivy-image.yml
    with:
      image_ref: ${{ needs.docker-build.outputs.image_ref }}
      severity: ${{ inputs.trivy_severity }}
```

- [ ] **Step 2: actionlint passes**

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "chore(release): add orchestrator chaining semantic-release → docker-build → trivy"
```

---

## Task 14: Fixtures

**Files:**
- Create: `tests/fixtures/minimal-go/Dockerfile`
- Create: `tests/fixtures/minimal-go/main.go`
- Create: `tests/fixtures/with-secret/.env-example`
- Create: `tests/fixtures/with-secret/Dockerfile`
- Create: `tests/fixtures/with-cve/Dockerfile`
- Create: `tests/fixtures/minimal-release-please/release-please-config.json`
- Create: `tests/fixtures/minimal-release-please/.release-please-manifest.json`

- [ ] **Step 1: minimal-go fixture**

```go
// tests/fixtures/minimal-go/main.go
package main

import "fmt"

func main() { fmt.Println("hello from minimal-go fixture") }
```

```dockerfile
# tests/fixtures/minimal-go/Dockerfile
FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY main.go .
RUN go build -o /out/app main.go

FROM alpine:3.20
COPY --from=builder /out/app /usr/local/bin/app
ENTRYPOINT ["/usr/local/bin/app"]
```

- [ ] **Step 2: with-secret fixture** — contains a fake AWS key for Trivy's secret scanner to detect

```
# tests/fixtures/with-secret/.env-example
# Intentionally contains a TEST AWS access key to trigger trivy secret scan.
# This is NOT a real key; it's the documented example pattern.
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

```dockerfile
# tests/fixtures/with-secret/Dockerfile
# Used by trivy-fs failure-path test: scanner should find the AWS key.
FROM alpine:3.20
COPY .env-example /app/.env
CMD ["true"]
```

- [ ] **Step 3: with-cve fixture** — uses an intentionally-old base image known to contain HIGH/CRITICAL CVEs

```dockerfile
# tests/fixtures/with-cve/Dockerfile
# Intentionally OLD base image with known HIGH/CRITICAL CVEs.
# Renovate ignores tests/fixtures/** (see .github/renovate.json5),
# so this version pin stays put.
FROM alpine:3.15
CMD ["true"]
```

- [ ] **Step 4: minimal-release-please fixture**

```json
// tests/fixtures/minimal-release-please/release-please-config.json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "packages": {
    ".": {
      "release-type": "simple",
      "bump-minor-pre-major": true
    }
  }
}
```

```json
// tests/fixtures/minimal-release-please/.release-please-manifest.json
{ ".": "0.0.0" }
```

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/
git commit -m "chore(tests): add fixtures for caller-workflow integration tests"
```

---

## Task 15: Self-CI — `integration.yml` (caller workflows for each atom)

**Files:**
- Create: `.github/workflows/integration.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/integration.yml
# Self-CI: exercises every atom against fixtures. Each atom gets at least
# one happy-path caller and (where applicable) one failure-path caller
# with a downstream assertion job that verifies failure occurred.
name: integration
on:
  pull_request:

concurrency:
  group: integration-${{ github.ref }}
  cancel-in-progress: true

jobs:
  # ----- docker-build happy path -----
  test-docker-build:
    uses: ./.github/workflows/docker-build.yml
    with:
      tag: ''
      prerelease: true
      context: tests/fixtures/minimal-go
      dockerfile: tests/fixtures/minimal-go/Dockerfile
      image_name: ${{ github.repository }}/test-fixture
      sign: false           # Cosign requires OIDC, only on main releases
      attest: false
      sbom: true            # exercise SBOM path; produces an artifact

  # ----- trivy-image happy path (no findings against clean fixture) -----
  test-trivy-image-happy:
    needs: test-docker-build
    uses: ./.github/workflows/trivy-image.yml
    with:
      image_ref: ${{ needs.test-docker-build.outputs.image_ref }}
      fail_on_findings: false   # clean fixture; assert later that count == 0

  assert-trivy-image-clean:
    needs: test-trivy-image-happy
    runs-on: ubuntu-latest
    steps:
      - name: Verify findings_count == 0
        env:
          COUNT: ${{ needs.test-trivy-image-happy.outputs.findings_count }}
        run: |
          if [[ "$COUNT" != "0" ]]; then
            echo "::error::Expected 0 findings on clean fixture, got $COUNT"
            exit 1
          fi

  # ----- trivy-fs happy path -----
  test-trivy-fs-happy:
    uses: ./.github/workflows/trivy-fs.yml
    with:
      paths_ignore: 'tests/fixtures/with-secret'
      fail_on_findings: false

  # ----- trivy-fs failure path: must fail on the secret fixture -----
  test-trivy-fs-failure:
    uses: ./.github/workflows/trivy-fs.yml
    with:
      paths_ignore: ''         # do NOT ignore; with-secret/.env-example should trip
      upload_sarif: false
      fail_on_findings: true
    continue-on-error: true

  assert-trivy-fs-fails:
    needs: test-trivy-fs-failure
    runs-on: ubuntu-latest
    steps:
      - name: Assert failure path failed
        run: |
          # If we get here AND the upstream job didn't fail, that's a bug.
          # GitHub Actions exposes upstream result via `needs.<job>.result`.
          if [[ "${{ needs.test-trivy-fs-failure.result }}" != "failure" ]]; then
            echo "::error::trivy-fs failure-path expected to fail on with-secret fixture but result was ${{ needs.test-trivy-fs-failure.result }}"
            exit 1
          fi
          echo "✅ failure-path correctly failed"

  # ----- cleanup-images smoke: just verify the workflow accepts inputs -----
  # We don't actually delete anything; the workflow runs with min-versions-to-keep
  # > our test fixture count, so it's a no-op.
  test-cleanup-images:
    uses: ./.github/workflows/cleanup-images.yml
    with:
      package_name: ${{ github.event.repository.name }}/test-fixture
      keep_stable_versions: 1000   # effectively prevents any deletion
      prerelease_age_days: 365
      runs_on: '["ubuntu-latest"]'
```

**Note:** `semantic-release.yml` is NOT exercised by `integration.yml` (no PR-time test) — the only meaningful test for it is the catalog's own self-release in Task 16. Tagging is destructive and should run on real release events only.

- [ ] **Step 2: actionlint passes**

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

- [ ] **Step 3: Commit + push**

```bash
git add .github/workflows/integration.yml
git commit -m "chore(self-ci): add integration workflow exercising each atom against fixtures"
git push origin main
```

(Note: pushing main directly because branch protection allows admin override and the catalog has no other contributors yet. Once Task 16 lands and release-please opens its first PR, the PR-merge flow takes over.)

- [ ] **Step 4: Open a test PR to verify integration.yml runs**

```bash
git checkout -b test/verify-integration
git commit --allow-empty -m "test: trigger integration workflow"
git push -u origin test/verify-integration
gh pr create --title "test: verify integration workflow" --body "verifies all atoms pass against fixtures" --base main
gh pr checks
```

Expected: all jobs in `integration.yml` pass (or `assert-trivy-fs-fails` confirms the expected failure of `test-trivy-fs-failure`).

If integration fails:
- Read the failed job logs via `gh run view --log-failed`
- Fix the atom (NOT the test) — the assertion in the test is correct by design
- Commit the fix to the test branch
- Push, wait for re-run

Once all green, close the test PR without merging (or merge as `test:` commit — no version impact):
```bash
gh pr close test/verify-integration --delete-branch
git checkout main
```

---

## Task 16: Catalog's self-release — `catalog-release.yml`

**Files:**
- Create: `.github/workflows/catalog-release.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/catalog-release.yml
# Self-release for this repository (NOT a reusable workflow). Calls the
# semantic-release atom we publish. If the atom is broken, this repo can't
# release — strong correction signal ("dogfooding").
name: catalog-release
on:
  push:
    branches: [main]

concurrency:
  group: catalog-release-main
  cancel-in-progress: false

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  release:
    uses: ./.github/workflows/semantic-release.yml
    secrets: inherit
```

- [ ] **Step 2: actionlint passes**

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/catalog-release.yml
git commit -m "chore(catalog-release): add self-release workflow that dog-foods semantic-release.yml"
```

- [ ] **Step 4: Push and watch first release-please PR**

```bash
git push origin main
gh run watch
```

Expected: `catalog-release.yml` runs `semantic-release.yml`. Since all commits so far are `chore:`, release-please should determine **no release needed** and exit green without opening a PR. Verify:

```bash
gh run view --log | grep -i 'release_created'
```
Expected: `release_created=false`.

If release-please errors out (auth, config), fix the issue before continuing. Common failures:
- 401 from API → check `RELEASE_PLEASE_APP_ID` and `RELEASE_PLEASE_APP_PRIVATE_KEY` org secrets
- "manifest not found" → ensure `.release-please-manifest.json` is at repo root
- "package not found" → check `release-please-config.json` syntax

---

## Task 17: Adopter templates

**Files:**
- Create: `docs/adopter-templates/release.yml`
- Create: `docs/adopter-templates/ci.yml`
- Create: `docs/adopter-templates/prerelease.yml`
- Create: `docs/adopter-templates/cleanup.yml`

- [ ] **Step 1: Template — `release.yml`**

```yaml
# docs/adopter-templates/release.yml
# Drop into <consumer-repo>/.github/workflows/release.yml
name: release
on:
  push:
    branches: [main]

jobs:
  release:
    uses: serverkraken/reusable-workflows/.github/workflows/release.yml@v1
    secrets: inherit
    # Optional inputs (uncomment to override defaults):
    # with:
    #   build_image: true
    #   run_trivy: true
    #   dockerfile: ./Dockerfile
    #   context: .
    #   platforms: linux/amd64,linux/arm64
    #   trivy_severity: HIGH,CRITICAL
```

- [ ] **Step 2: Template — `ci.yml`**

```yaml
# docs/adopter-templates/ci.yml
# Drop into <consumer-repo>/.github/workflows/ci.yml
name: ci
on:
  pull_request:

jobs:
  secscan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@v1
    # Optional:
    # with:
    #   scanners: vuln,secret,misconfig
    #   severity: HIGH,CRITICAL
    #   paths_ignore: |
    #     tests/fixtures/
    #     docs/examples/
```

- [ ] **Step 3: Template — `prerelease.yml`**

```yaml
# docs/adopter-templates/prerelease.yml
# Drop into <consumer-repo>/.github/workflows/prerelease.yml
# Trigger from UI (branch dropdown) or CLI:
#   gh workflow run prerelease.yml --ref feat/foo
name: prerelease
on:
  workflow_dispatch: {}

jobs:
  build:
    uses: serverkraken/reusable-workflows/.github/workflows/docker-build.yml@v1
    with:
      prerelease: true   # auto-computes tag from branch + short SHA
  scan:
    needs: build
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-image.yml@v1
    with:
      image_ref: ${{ needs.build.outputs.image_ref }}
```

- [ ] **Step 4: Template — `cleanup.yml`**

```yaml
# docs/adopter-templates/cleanup.yml
# Drop into <consumer-repo>/.github/workflows/cleanup.yml
name: cleanup
on:
  schedule: [{ cron: '0 3 * * 0' }]   # Sundays at 03:00 UTC
  workflow_dispatch: {}

jobs:
  cleanup:
    uses: serverkraken/reusable-workflows/.github/workflows/cleanup-images.yml@v1
    # Optional:
    # with:
    #   keep_stable_versions: 10
    #   prerelease_age_days: 14
```

- [ ] **Step 5: Commit**

```bash
git add docs/adopter-templates/
git commit -m "docs: add adopter workflow templates"
```

---

## Task 18: Full README — adopter onboarding

**Files:**
- Modify: `README.md` (replace the stub from Task 1)

- [ ] **Step 1: Write the full README**

````markdown
# serverkraken/reusable-workflows

Versioned, tested catalog of GitHub Actions reusable workflows for the `serverkraken` organisation. Stop copying CI workflows between repos — reference them with a one-line `uses:`.

## Quick start (adopters)

**Prerequisites** (one-time per repo):

1. `release-please-config.json` in repo root (see [release-please docs](https://github.com/googleapis/release-please) for `release-type` per language).
2. `.release-please-manifest.json` in repo root with initial version, e.g. `{ ".": "0.0.0" }`.
3. The `serverkraken-release-bot` GitHub App must be installed on the repo (org-wide install handles this automatically).

**Then** copy templates from [`docs/adopter-templates/`](docs/adopter-templates/) into `.github/workflows/` of your repo:

| Template          | Trigger              | Purpose                                              |
|-------------------|----------------------|------------------------------------------------------|
| `release.yml`     | push → main          | Full release pipeline (release-please → image build → trivy) |
| `ci.yml`          | pull_request         | PR-time security scan (trivy-fs)                     |
| `prerelease.yml`  | workflow_dispatch    | Manual image build from a feature branch             |
| `cleanup.yml`     | weekly cron          | GHCR retention                                       |

That's the complete onboarding. No per-repo secret setup — `secrets: inherit` reaches the org-level App secrets.

## What it does

### `release.yml` (orchestrator)

End-to-end release pipeline:
1. release-please reads Conventional Commits and opens/updates a release PR.
2. Merging the release PR → tag `vX.Y.Z` + GitHub Release.
3. Floating tags `vX` and `vX.Y` are force-moved to the same commit (so consumers can pin `@v1` and float on minor/patch).
4. Multi-arch image built (linux/amd64 + linux/arm64) on native self-hosted runners.
5. Image is **signed** (Cosign keyless via OIDC) and **attested** (SLSA build provenance, pushed to registry alongside image).
6. SBOM (SPDX-JSON) attached to the GitHub Release.
7. Trivy scans the published image (vuln + secret + misconfig); release fails if HIGH/CRITICAL findings.

### `ci.yml` (PR-time security gate)

`trivy-fs` scans the source tree on every PR for vulnerabilities, embedded secrets, and Dockerfile/YAML misconfigurations. SARIF uploaded to the Code Scanning tab.

### `prerelease.yml` (feature-branch image)

Manual trigger to build a Docker image from any branch. Tag format: `<sanitized-branch>-<short-sha>` (e.g. `feat-auth-fix-a1b2c3d`) plus a moving `<sanitized-branch>` tag. Reviewers can `docker pull` to test. Trivy runs on the resulting image. A PR comment is posted/updated with the pull command.

### `cleanup.yml` (GHCR retention)

Weekly cron prunes old image versions: keeps the latest N stable `v*.*.*` versions; deletes prerelease/non-semver tags.

## Versioning

This catalog uses [Semantic Versioning](https://semver.org/) driven by [release-please](https://github.com/googleapis/release-please).

| Pin                                                          | Behavior                                |
|--------------------------------------------------------------|-----------------------------------------|
| `@v1`                                                        | Always latest 1.x.y                     |
| `@v1.2`                                                      | Always latest 1.2.x                     |
| `@v1.2.3`                                                    | Immutable, never changes                |

**Breaking changes** (any input/output/secret shape change) bump the major version. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Workflow contracts

The complete input/output/secret schema of every reusable workflow is documented in the [design spec](docs/superpowers/specs/2026-05-16-reusable-workflows-design.md) §4.

## Atomic workflows (advanced)

Most consumers should use `release.yml` (the orchestrator). For non-standard flows, the atoms are also reusable:

```yaml
# Example: PR-time security scan only
jobs:
  scan:
    uses: serverkraken/reusable-workflows/.github/workflows/trivy-fs.yml@v1
```

| Atom                      | Purpose                                            |
|---------------------------|----------------------------------------------------|
| `semantic-release.yml`    | release-please + floating major/minor tags         |
| `docker-build.yml`        | multi-arch build + cosign + attestation + SBOM     |
| `trivy-image.yml`         | image vuln/secret/misconfig scan                   |
| `trivy-fs.yml`            | filesystem vuln/secret/misconfig scan              |
| `cleanup-images.yml`      | GHCR retention                                     |

## Composite actions

Reusable sub-steps used internally by the atoms. Available for advanced consumers:

| Action                                 | Purpose                                    |
|----------------------------------------|--------------------------------------------|
| `actions/install-trivy`                | Pinned Trivy CLI install (direct binary)   |
| `actions/ghcr-login`                   | GHCR login wrapper                         |
| `actions/compute-prerelease-tag`       | OCI-valid tag from branch + short SHA      |
| `actions/post-prerelease-comment`      | Idempotent PR comment with pull command    |

## Operations

See the [spec §9](docs/superpowers/specs/2026-05-16-reusable-workflows-design.md#9-operational-setup-org-level-one-time) for the GitHub App setup, Actions access policy, and private-key rotation runbook.

## License

[MIT](LICENSE).
````

- [ ] **Step 2: Verify markdown renders correctly**

```bash
pipx run mdformat --check README.md 2>&1 || true   # mdformat is optional; just sanity-checks
```

- [ ] **Step 3: Final commit — flip from `chore` to `feat` to trigger first release**

```bash
git add README.md
git commit -m "feat: v0.1.0 — initial reusable workflows catalog

Atomic workflows: semantic-release, docker-build (with cosign +
attestation + SBOM), trivy-image, trivy-fs (vuln + secret + misconfig),
cleanup-images. Orchestrator (release.yml) chains them. Composite
actions for install-trivy, ghcr-login, compute-prerelease-tag,
post-prerelease-comment. Self-CI via integration.yml with happy and
failure-path callers. release-please-driven versioning with floating
vX / vX.Y tags. GitHub App auth (serverkraken-release-bot) so adopters
need no per-repo secret setup."
git push origin main
```

- [ ] **Step 4: Watch release-please open the first release PR**

```bash
gh run watch
gh pr list
```

Expected: a release PR titled `chore(main): release 0.1.0` appears, listing all the conventional commits.

- [ ] **Step 5: Review the release PR, then merge**

```bash
gh pr view <PR-number>
gh pr merge <PR-number> --merge
gh run watch
```

After merge, release-please's second run creates the `v0.1.0` tag, GitHub Release, and (via the floating-tag step) `v0` and `v0.1` tags.

Verify:
```bash
git fetch --tags
git tag --list | sort -V
```
Expected output:
```
v0
v0.1
v0.1.0
```

---

## Done

After Task 18, v0.1.0 is published. The catalog is now usable by adopters.

**Next-spec candidates** (not in this plan):
- `lint-go.yml` / `test-go.yml`
- `lint-python.yml` / `test-python.yml`
- `lint-rust.yml` / `test-rust.yml`
- Migration plan for the ~6 repos currently on hand-rolled bash semantic-release.
