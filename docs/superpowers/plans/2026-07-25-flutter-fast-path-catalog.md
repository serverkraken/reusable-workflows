# Flutter Fast Path — Catalog Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `v4.x` minor of the catalog that drops the useless emulator download from every Flutter job, turns the never-hitting SDK cache off by default, and makes the Flutter job timeouts parameterizable (30/45/45).

**Architecture:** All changes live in the shared composite `actions/setup-flutter-toolchain` and the three Flutter atoms that call it (`lint-flutter.yml`, `test-flutter.yml`, `release-flutter-android.yml`). Every new input has a default, so no adopter changes anywhere — `@v4` is a moving major tag. Spec: `serverkraken/actions-runner-image` → `docs/superpowers/specs/2026-07-25-flutter-sdk-bake-design.md` (§1–§3).

**Tech Stack:** GitHub Actions reusable workflows + composite actions (YAML), actionlint, yamllint.

## Global Constraints

- Composite inputs are **kebab-case** (`sdk-cache`); atom inputs are **snake_case** (`sdk_cache`) — match each file's existing convention.
- New composite input `sdk-cache` default `'false'` (string — composite inputs are strings).
- New atom inputs: `sdk_cache` (boolean, default `false`), `timeout_minutes` (number, defaults **30** lint / **45** test / **45** release).
- `android-actions/setup-android` gets `packages: 'platform-tools'` (today implicit default `'tools platform-tools'`).
- All new inputs `required: false` with defaults → this is a **minor** (`feat:` commit), adopters unchanged.
- yamllint config: 2-space indent, line-length max 200 (warning). Run linters after every YAML edit.
- Release order (cross-repo): **this catalog release must be live before (or with) the runner-image Flutter bake rollout** — with the bake but `cache: true` still active, `actions/cache` would keep uploading the 1.7 GB baked SDK on every job.
- Worktree: new branch `feat/flutter-fast-path` in a fresh worktree (`.worktrees/flutter-fast-path`), created via superpowers:using-git-worktrees. Base: `main`.

## Lint commands used throughout

```bash
# actionlint (pick whichever container runtime exists)
podman run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest
# or: docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest

# yamllint
pipx run yamllint .github/ actions/ tests/
```

Expected for both, before and after every task: exit code 0, no new findings (yamllint may print pre-existing line-length *warnings*; those are level: warning and not failures).

---

### Task 1: Composite — emulator out, SDK cache input (default off)

**Files:**
- Modify: `actions/setup-flutter-toolchain/action.yml`

**Interfaces:**
- Produces: composite input `sdk-cache` (string, default `'false'`) — Task 2 wires the atoms' `sdk_cache` boolean into it.

- [ ] **Step 1: Add the `sdk-cache` input**

In `actions/setup-flutter-toolchain/action.yml`, the `inputs:` block currently ends with:

```yaml
  working-directory:
    description: 'Path to the Flutter project root, relative to the runner workspace'
    default: '.'
```

Append directly after it (same indentation level):

```yaml
  sdk-cache:
    description: >-
      When "true", cache the Flutter SDK via actions/cache. Off by default:
      the SDK cache key embeds the resolved Flutter version, so it rotates
      with every Flutter stable release (~every 1-2 weeks) and almost never
      hits — while every job re-uploads a ~1.7 GB archive. On GitHub-hosted
      runners "true" is reasonable again.
    default: 'false'
```

- [ ] **Step 2: Pin setup-android to `platform-tools` only**

The step currently reads:

```yaml
    - name: Setup Android SDK
      uses: android-actions/setup-android@40fd30fb8d7440372e1316f5d1809ec01dcd3699 # v4
```

Replace with:

```yaml
    - name: Setup Android SDK
      uses: android-actions/setup-android@40fd30fb8d7440372e1316f5d1809ec01dcd3699 # v4
      with:
        # The action default 'tools platform-tools' drags in the emulator and
        # legacy sdk-tools via the deprecated 'tools' alias (~2 min per job,
        # useless for headless builds). platform-tools (adb) suffices; AGP
        # auto-installs platforms/build-tools during the Gradle build, and
        # the action still accepts the SDK licenses.
        packages: 'platform-tools'
```

- [ ] **Step 3: Wire the cache input**

In the `Setup Flutter` step, change one line:

```yaml
        cache: true
```

to:

```yaml
        cache: ${{ inputs.sdk-cache }}
```

- [ ] **Step 4: Run the linters**

Run both lint commands from the header. Expected: exit 0, no new findings.

- [ ] **Step 5: Commit**

```bash
git add actions/setup-flutter-toolchain/action.yml
git commit -m "feat(flutter): drop emulator download, make SDK cache opt-in (default off)"
```

---

### Task 2: Atoms — `timeout_minutes` + `sdk_cache` passthrough

**Files:**
- Modify: `.github/workflows/lint-flutter.yml` (inputs block ~line 38-42, `timeout-minutes` line 61, composite call ~line 96-103)
- Modify: `.github/workflows/test-flutter.yml` (inputs block, `timeout-minutes` line 64, composite call)
- Modify: `.github/workflows/release-flutter-android.yml` (inputs block ~line 53-57, `timeout-minutes` line 118, composite call ~line 157-164)

**Interfaces:**
- Consumes: composite input `sdk-cache` from Task 1.
- Produces: workflow_call inputs `sdk_cache` (boolean, default false) and `timeout_minutes` (number, defaults 30/45/45) on all three atoms — documented by Task 3.

The three edits are structurally identical; every file is shown in full below (do not infer).

- [ ] **Step 1: `lint-flutter.yml`**

(a) The `inputs:` block currently ends with:

```yaml
      use_build_runner:
        description: 'When true, runs dart run build_runner build after pub get.'
        required: false
        type: boolean
        default: true
```

Append directly after it:

```yaml
      sdk_cache:
        description: 'Cache the Flutter SDK via actions/cache. Off by default; see setup-flutter-toolchain.'
        required: false
        type: boolean
        default: false
      timeout_minutes:
        description: 'Job timeout in minutes.'
        required: false
        type: number
        default: 30
```

(b) Change line 61:

```yaml
    timeout-minutes: 20
```

to:

```yaml
    timeout-minutes: ${{ inputs.timeout_minutes }}
```

(c) The `Setup Flutter toolchain` step's `with:` block currently ends with:

```yaml
          working-directory: ${{ inputs.working_directory }}
```

Append after it (same indentation):

```yaml
          sdk-cache: ${{ inputs.sdk_cache }}
```

- [ ] **Step 2: `test-flutter.yml`**

(a) Append after the `use_build_runner` input block (identical shape to lint, but note test-flutter also has `coverage_threshold` after `use_build_runner` — append after **`coverage_threshold`**, keeping the inputs together):

```yaml
      sdk_cache:
        description: 'Cache the Flutter SDK via actions/cache. Off by default; see setup-flutter-toolchain.'
        required: false
        type: boolean
        default: false
      timeout_minutes:
        description: 'Job timeout in minutes.'
        required: false
        type: number
        default: 45
```

(b) Change line 64:

```yaml
    timeout-minutes: 30
```

to:

```yaml
    timeout-minutes: ${{ inputs.timeout_minutes }}
```

(c) Append to the `Setup Flutter toolchain` step's `with:` block:

```yaml
          sdk-cache: ${{ inputs.sdk_cache }}
```

- [ ] **Step 3: `release-flutter-android.yml`**

(a) Append after the `artefact_name_prefix` input block (the last input, ~line 83-87):

```yaml
      sdk_cache:
        description: 'Cache the Flutter SDK via actions/cache. Off by default; see setup-flutter-toolchain.'
        required: false
        type: boolean
        default: false
      timeout_minutes:
        description: 'Job timeout in minutes.'
        required: false
        type: number
        default: 45
```

(b) Change line 118:

```yaml
    timeout-minutes: 30
```

to:

```yaml
    timeout-minutes: ${{ inputs.timeout_minutes }}
```

(c) Append to the `Setup Flutter toolchain` step's `with:` block:

```yaml
          sdk-cache: ${{ inputs.sdk_cache }}
```

- [ ] **Step 4: Run the linters**

Run both lint commands from the header. Expected: exit 0. (actionlint validates that `timeout-minutes` accepts the `${{ inputs.timeout_minutes }}` expression — if it flags it, that is a real error; do not suppress.)

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/lint-flutter.yml .github/workflows/test-flutter.yml .github/workflows/release-flutter-android.yml
git commit -m "feat(flutter): parameterize job timeouts (30/45/45) and SDK cache"
```

---

### Task 3: Document the flutter contracts

**Files:**
- Modify: `docs/contracts.md`

The flutter atoms are entirely absent from `docs/contracts.md` today (verified 2026-07-25). Add complete sections — a partial table would be worse than none. Insert the three atom sections alphabetically among the existing `### \`<name>.yml\`` headings under **## Atomic Workflows**, and the composite under **## Composite Actions** (alphabetical there too).

- [ ] **Step 1: Add `lint-flutter.yml` section**

```markdown
### `lint-flutter.yml`

Runs `dart format --set-exit-if-changed` + `flutter analyze`.

| Kind    | Name                | Type    | Required | Default                                         | Description |
|---------|---------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`           | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory` | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `java_version`      | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`   | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`   | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`  | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `sdk_cache`         | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (since v4; off — key rotates per Flutter release) |
| input   | `timeout_minutes`   | number  | no       | `30`                                            | Job timeout (since v4) |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |

---
```

- [ ] **Step 2: Add `test-flutter.yml` section**

```markdown
### `test-flutter.yml`

Runs `flutter test --coverage` and enforces a line-coverage threshold.

| Kind    | Name                 | Type    | Required | Default                                         | Description |
|---------|----------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`            | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory`  | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `java_version`       | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`    | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`    | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`   | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `coverage_threshold` | number  | no       | `80`                                            | Minimum line coverage percentage (0-100) |
| input   | `sdk_cache`          | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (since v4; off — key rotates per Flutter release) |
| input   | `timeout_minutes`    | number  | no       | `45`                                            | Job timeout (since v4) |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |

---
```

- [ ] **Step 3: Add `release-flutter-android.yml` section**

```markdown
### `release-flutter-android.yml`

Builds a signed Android APK and/or AAB and attaches it to a GitHub Release.

| Kind    | Name                       | Type    | Required | Default                                         | Description |
|---------|----------------------------|---------|----------|-------------------------------------------------|-------------|
| input   | `runs_on`                  | string  | no       | `'["self-hosted","Linux","X64","performance"]'` | JSON-encoded runner labels |
| input   | `working_directory`        | string  | no       | `'.'`                                           | Flutter project root, relative to repo root |
| input   | `version`                  | string  | no       | `''`                                            | Semver (leading v optional). Empty only with `create_release=true` → derives `<latest-tag>-rc.<run_number>` |
| input   | `create_release`           | boolean | no       | `false`                                         | Create the Release at the resolved tag before upload (manual/ad-hoc builds) |
| input   | `java_version`             | string  | no       | `'17'`                                          | Java major version |
| input   | `flutter_channel`          | string  | no       | `'stable'`                                      | Flutter release channel |
| input   | `flutter_version`          | string  | no       | `''`                                            | Specific Flutter version (empty = latest on channel) |
| input   | `use_build_runner`         | boolean | no       | `true`                                          | Run `dart run build_runner build` after pub get |
| input   | `build_apk`                | boolean | no       | `true`                                          | Build a release APK |
| input   | `build_aab`                | boolean | no       | `false`                                         | Build a release AAB |
| input   | `flavor`                   | string  | no       | `''`                                            | Build flavor (empty = no `--flavor`) |
| input   | `prerelease`               | boolean | no       | `false`                                         | Mark the GitHub Release as prerelease |
| input   | `dart_define_secret_names` | string  | no       | `''`                                            | Comma-separated secret names forwarded as `--dart-define=NAME=$VALUE` |
| input   | `artefact_name_prefix`     | string  | no       | `''`                                            | Prefix for renamed artefacts (empty = repo name) |
| input   | `sdk_cache`                | boolean | no       | `false`                                         | Cache the Flutter SDK via actions/cache (since v4; off — key rotates per Flutter release) |
| input   | `timeout_minutes`          | number  | no       | `45`                                            | Job timeout (since v4) |
| secret  | `release_please_app_client_id`   | — | **yes** | — | App Client ID for the catalog-checkout token |
| secret  | `release_please_app_private_key` | — | **yes** | — | App private key for the catalog-checkout token |
| secret  | `ANDROID_KEYSTORE_BASE64`        | — | **yes** | — | Base64-encoded release keystore |
| secret  | `ANDROID_STORE_PASSWORD`         | — | **yes** | — | Keystore store password |
| secret  | `ANDROID_KEY_ALIAS`              | — | **yes** | — | Key alias inside the keystore |
| secret  | `ANDROID_KEY_PASSWORD`           | — | **yes** | — | Key password |

---
```

- [ ] **Step 4: Add `actions/setup-flutter-toolchain` under Composite Actions**

```markdown
### `actions/setup-flutter-toolchain`

Shared by the lint-flutter, test-flutter, and release-flutter-android atoms:
setup-java → setup-android (`platform-tools` only) → subosito/flutter-action
→ `flutter pub get` → optional build_runner.

| Kind  | Name                | Type   | Required | Default     | Description |
|-------|---------------------|--------|----------|-------------|-------------|
| input | `java-version`      | string | no       | `'17'`      | Java major version |
| input | `java-distribution` | string | no       | `'temurin'` | Distribution slug for actions/setup-java |
| input | `flutter-channel`   | string | no       | `'stable'`  | Flutter release channel |
| input | `flutter-version`   | string | no       | `''`        | Specific Flutter version (empty = latest on channel) |
| input | `use-build-runner`  | string | no       | `'true'`    | Run build_runner after pub get |
| input | `working-directory` | string | no       | `'.'`       | Flutter project root |
| input | `sdk-cache`         | string | no       | `'false'`   | Cache the Flutter SDK via actions/cache (off: key rotates per Flutter stable) |
```

- [ ] **Step 5: Commit**

```bash
git add docs/contracts.md
git commit -m "docs(contracts): document the flutter atoms and setup-flutter-toolchain"
```

---

### Task 4: PR + verification via self-CI

**Files:** none (branch push + PR).

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feat/flutter-fast-path
gh pr create \
  --title "feat(flutter): fast path — emulator out, SDK cache opt-in, timeouts 30/45/45" \
  --body "Catalog half of the Flutter fast path (spec: actions-runner-image docs/superpowers/specs/2026-07-25-flutter-sdk-bake-design.md).

- setup-flutter-toolchain: setup-android \`packages: 'platform-tools'\` (no emulator, ~2 min saved per job); \`cache: true\` → input \`sdk-cache\` default **'false'** (the key rotates with every Flutter stable, and every save pushes 1.7 GB to the Pi-backed cache server — both 0.38.0 and 0.39.0 strassenfuchs release builds were misses).
- atoms: new \`timeout_minutes\` (30/45/45; today 20/30/30 — the 30 killed a finished release build in the cache-save post step) and \`sdk_cache\` passthrough.
- contracts.md: flutter atoms + composite documented (were missing entirely).

No adopter changes — all new inputs have defaults.

**Release order:** this must be released before (or with) the runner-image Flutter-bake rollout, otherwise the baked SDK still gets re-uploaded by actions/cache on every job."
```

- [ ] **Step 2: Watch the PR checks**

Expected green, in particular `self-ci / summary` — its `lint-flutter-happy` and `test-flutter-happy` jobs run the **changed** composite against `tests/fixtures/flutter-app` (self-CI resolves the catalog ref to the PR SHA).

- [ ] **Step 3: Verify the behavior change in the self-CI logs**

In the `lint-flutter-happy` job log:
- `Setup Android SDK` step: **no** `Downloading emulator-…` lines, duration well under 1 min.
- `Setup Flutter` step: **no** `actions/cache` restore for `flutter-linux-…` (cache input false).

- [ ] **Step 4: Hand over**

Merge + release (release-please → catalog-release moves `v4`) are Soenne's. After the release: the next strassenfuchs PR shows the ~2 min drop; the runner-image plan (`actions-runner-image/docs/superpowers/plans/2026-07-25-flutter-sdk-bake.md`) delivers the remaining ~5 min.
