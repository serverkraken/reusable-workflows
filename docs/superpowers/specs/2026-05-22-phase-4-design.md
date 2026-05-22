# Phase 4 — Test Coverage Expansion (Design Spec)

**Datum:** 2026-05-22
**Quelle:** `REVIEW-2026-05-22.md` § N Phase 4 (HIGH-11, MED-13, MED-14, MED-15) + § G.4 (onboard-drift action wrapper)
**Scope:** Schließt die verbleibenden Test-Coverage-Lücken aus dem Review nach Phasen 2a/2b/2c/3.
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger)
**Vorgänger:** Phase 2b (HIGH-6 + HIGH-7), Phase 3 (Doku-Drift)

---

## 1. Goal

Phase 4 schließt sechs Coverage-Lücken aus dem Katalog-Review — ausschließlich Test-Additionen, **kein Production-Workflow-Code wird verändert**:

- **HIGH-11**: Cargo-Workspace und pnpm-Workspace Detection in `onboard-detect-lib.sh` (zwei non-trivial awk/glob Parser-Pfade) haben heute weder Fixture noch Bats-Test.
- **MED-13**: Drei `*-fail` Caller (`docker-build-multi-fail`, `goreleaser-fail`, `helm-publish-fail`) sind `workflow_dispatch`-only. Sie laufen nie automatisch, fangen also keine Regressionen.
- **MED-14**: `cleanup-images.yml` hat nur einen Smoke-Test, keinen Failure-Path Caller.
- **MED-15**: `scripts/seed-onboarding-status.sh` (41 Zeilen `gh`-API + Zeilen-Upsert) hat null Bats-Coverage.
- **G.4-M3**: Das `onboard-drift` Composite-Action-Wrapper ist heute nur indirekt über `drift-check.yml` (scheduled, nicht im Integration-Run) abgedeckt. Der GHA-Wrapper-Layer (env-passthrough, GITHUB_OUTPUT-Capture, `$GITHUB_ACTION_PATH` Layout-Resolution) wird in CI nie exerciert.

MED-12 (golden_check für `containerfile-only` + `release-eligibility-mixed`) ist bereits mit PR #84 gelandet — `tests/shell/onboard-render.bats:182-183` hat die `golden_check`-Aufrufe.

## 2. Scope

### In Scope

| Concern | Findings | Outcome |
|---|---|---|
| **C-1** | HIGH-11 (cargo) | Fixture `tests/fixtures/onboard/cargo-workspace/` mit zwei Members + zwei neue Bats-Tests in `onboard-detect.bats` |
| **C-2** | HIGH-11 (pnpm) | Fixture `tests/fixtures/onboard/pnpm-workspace/` mit Glob-Expansion-Layout + zwei neue Bats-Tests in `onboard-detect.bats` |
| **C-3** | MED-15 | `tests/shell/seed-onboarding-status.bats` (neu) mit PATH-mocked `gh`. Drei Test-Cases: header-creation, append-only-new, regex-anchor |
| **C-4** | G.4-M3 | Fixture `tests/fixtures/onboard/drift-clean/` (pre-baked Lock + Files) + neuer Caller `tests/callers/onboard-drift-happy.yml` + path-filter Trigger |
| **C-5** | MED-13 | Drei `*-fail.yml` bekommen `pull_request: paths:` Trigger + `continue-on-error: true` + sibling `assert-X-fail` Job (Pattern aus Phase 2b § 4.3) |
| **C-6** | MED-14 | Neuer Caller `tests/callers/cleanup-images-fail.yml` mit selbem zwei-Job-Pattern wie C-5. Failure-Trigger: `runs_on: '[]'` |

### Out of Scope

- MED-12 — bereits gelandet (PR #84)
- MED-7 (relative-path bug in seed-onboarding-status.sh) — Bats-Test workaround per `cd`, structural fix später
- Failure-mode coverage für `onboard-drift` selbst — Script-Level (bats) bereits abgedeckt; Wrapper-Test ist Happy-Path-only um wrapper-spezifische GHA-Semantik (env, OUTPUT, ACTION_PATH) zu validieren
- `*-fail` für Lint/Test Atoms (`lint-go-fail`, `lint-rust-fail`, `test-go-cov-fail` etc.) — diese laufen bereits path-filter-getriggert; sie sind nicht in MED-13-Scope
- Performance-Optimierungen aus § F (Phase 5)
- Action-Version-Pin-Refresh, Renovate-Annotationen (Phase 6)

## 3. Background

### 3.1 Cargo-Workspace Detection (HIGH-11)

`scripts/lib/onboard-detect-lib.sh:109-131` parst:

```toml
[workspace]
members = ["pkg-a", "pkg-b"]
```

via awk, emittiert eine JSON-Components-Liste mit role-detection pro Member (`src/main.rs` → service, `src/lib.rs` → library). Diese Funktion läuft nur bei `Cargo.toml` mit `[workspace]`-Block — bisher existiert keine Fixture, die diesen Code-Pfad triggert. Die existierende `rust-cargo`-Fixture ist ein Single-Crate-Layout, kein Workspace.

### 3.2 pnpm-Workspace Detection (HIGH-11)

`scripts/lib/onboard-detect-lib.sh:132-152` parst `pnpm-workspace.yaml`:

```yaml
packages:
  - "apps/*"
  - "packages/*"
```

via Glob-Expansion zu konkreten Pfaden. Die existierende `node-package`-Fixture ist ein Single-Package, deckt diesen Pfad nicht ab.

### 3.3 Caller-Pattern im Repo

Happy-Path Caller (`*-happy.yml`) folgen einem etablierten Pattern:
```yaml
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/<atom>.yml'
      - 'tests/callers/<atom>-happy.yml'
      - 'tests/fixtures/<fixture>/**'
```

Damit triggern sie nur bei Änderungen am Atom oder am Test-Setup — kein CI-Burn bei jedem PR. Sie sind **nicht** in `integration.yml` referenziert, sondern self-firing.

Fail-Path Caller (`*-fail.yml`) folgten bisher diesem Pattern *nicht* — sie sind `workflow_dispatch`-only. Begründung in den existierenden Kommentaren: "we don't want to burn CI on every push for a guaranteed-failing run". Das Problem: ohne automatisches Triggern fängt der Test keine Regressionen.

**Lösung mit assert-Pattern:** Phase 2b § 4.3 hat das Muster etabliert. Ein `continue-on-error: true` Caller-Job feeds in einen sibling `assert-X-fail` Job (`if: always()`), der prüft `needs.X.result == 'failure'`. So bleibt der PR-Check grün, wenn das Atom korrekt failt.

### 3.4 seed-onboarding-status.sh Verhalten

Das Script (`scripts/seed-onboarding-status.sh`) liest `gh repo list serverkraken --json nameWithOwner` und appendiert Rows in `docs/onboarding-status.md`:
- Wenn `$DOC` fehlt: Header anlegen (`# Onboarding Status` + Tabelle)
- Für jeden Repo: prüfen, ob `^\| ${escaped_repo} \|` schon existiert → wenn nein, appenden
- Regex-Anker (`^\|` + Closing-Pipe) verhindert Substring-Match (`foo` nicht von `foo-extra` getroffen)

Drei testable Behaviors. `gh` und Filesystem sind die einzigen Side-Effects.

### 3.5 onboard-drift Action Wrapper

`actions/onboard-drift/action.yml` ist ein composite-action-Wrapper, der `scripts/onboard-drift.sh` aufruft:

```yaml
runs:
  using: composite
  steps:
    - id: drift
      shell: bash
      env:
        CATALOG_CURRENT_VERSION: ${{ inputs.current_version }}
      run: |
        catalog="$GITHUB_ACTION_PATH/../.."
        "$catalog/scripts/onboard-drift.sh" "${{ inputs.target_path }}" "$catalog" >> "$GITHUB_OUTPUT"
```

Der Wrapper-Layer hat drei Verantwortungen, die der Script-Level Bats-Test nicht abdeckt:
1. `env:` block injiziert `CATALOG_CURRENT_VERSION` korrekt für das Script
2. `$GITHUB_ACTION_PATH/../..` resolved zur Catalog-Root in einer realen GHA-Job-Umgebung (depends auf wie der Caller die Action `uses:`)
3. Multi-line Output-Capture (`>> "$GITHUB_OUTPUT"`) wird von der composite-action-Engine korrekt geparst und exposed als `steps.drift.outputs.status` etc.

Diese drei Verhaltensweisen werden nur im Integration-Test sichtbar — Script-Bats kann sie nicht testen.

### 3.6 cleanup-images Failure-Trigger-Wahl

`cleanup-images.yml` ist ein 100-Zeilen-Workflow mit:
- `runs_on` input (`type: string`, JSON-encoded array)
- `package_name` mit default `${{ github.event.repository.name }}`
- `gh api` Calls zu `/orgs/<owner>` und `/packages/container/<pkg>`

Failure-Trigger-Optionen:
- **`runs_on: '[]'`** — `fromJSON('[]')` ist valides JSON, `runs-on: []` rejected von GHA bei runner allocation. **Deterministisch, kein Netz, kein Token.** Gewählt.
- `runs_on: 'not-json'` — `fromJSON()` Expression-Error. Auch deterministisch, aber failt ein step weiter rechts (in `${{ fromJSON(...) }}` Evaluation) — weniger lesbar.
- Invalid `package_name` — gh API Verhalten ist nichttrivial (org vs user lookup), nicht-deterministisch je nach GHCR-State.
- Fehlendes `GH_TOKEN` — token kommt aus `secrets.GITHUB_TOKEN`, kann nicht weggenommen werden ohne dispatch-only-Caller-Anpassung.

Gewählt: `runs_on: '[]'` als saubererer Failure-Trigger.

## 4. Design per Concern

### 4.1 C-1 — cargo-workspace fixture + bats

#### Fixture-Layout

```
tests/fixtures/onboard/cargo-workspace/
├── Cargo.toml
├── pkg-a/
│   ├── Cargo.toml
│   └── src/main.rs
└── pkg-b/
    ├── Cargo.toml
    └── src/lib.rs
```

Inhalte:

`Cargo.toml`:
```toml
[workspace]
members = ["pkg-a", "pkg-b"]
resolver = "2"
```

`pkg-a/Cargo.toml`:
```toml
[package]
name = "pkg-a"
version = "0.1.0"
edition = "2021"
```

`pkg-a/src/main.rs`:
```rust
fn main() { println!("hello"); }
```

`pkg-b/Cargo.toml`:
```toml
[package]
name = "pkg-b"
version = "0.1.0"
edition = "2021"
```

`pkg-b/src/lib.rs`:
```rust
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

#### Bats Tests (in `tests/shell/onboard-detect.bats`)

```bats
@test "detects rust cargo-workspace with two members" {
  run "$DETECT" "$FIX/cargo-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=rust"* ]]
}

@test "cargo-workspace --profile-json emits both component paths" {
  run "$DETECT" --profile-json "$FIX/cargo-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pkg-a"* ]]
  [[ "$output" == *"pkg-b"* ]]
}
```

Die Tests halten sich an die existierende Bats-Konvention im File (Substring-Matches auf `$output`, keine exakten JSON-Diffs).

### 4.2 C-2 — pnpm-workspace fixture + bats

#### Fixture-Layout

```
tests/fixtures/onboard/pnpm-workspace/
├── package.json
├── pnpm-workspace.yaml
├── apps/
│   ├── web/package.json
│   └── api/package.json
└── packages/
    └── shared/package.json
```

`package.json` (root):
```json
{ "name": "monorepo-root", "private": true, "version": "0.0.0" }
```

`pnpm-workspace.yaml`:
```yaml
packages:
  - "apps/*"
  - "packages/*"
```

Jedes `<dir>/package.json`:
```json
{ "name": "<basename>", "version": "0.0.0" }
```

#### Bats Tests

```bats
@test "detects node pnpm-workspace" {
  run "$DETECT" "$FIX/pnpm-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=node"* ]]
}

@test "pnpm-workspace --profile-json includes all members" {
  run "$DETECT" --profile-json "$FIX/pnpm-workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps/web"* ]]
  [[ "$output" == *"apps/api"* ]]
  [[ "$output" == *"packages/shared"* ]]
}
```

Hinweis: node ist im Katalog nicht als release-eligible Sprache implementiert. `emit_unsupported_language_warnings` wird feuern — das wird vom existierenden `node-package` Test bereits asserted. Hier nur Detection-Coverage.

### 4.3 C-3 — seed-onboarding-status bats

#### File-Layout

```bats
#!/usr/bin/env bats
# tests/shell/seed-onboarding-status.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/seed-onboarding-status.sh"
  WORK=$(mktemp -d)
  cd "$WORK"
  mkdir -p docs

  # Mock gh on PATH
  BIN="$WORK/bin"
  mkdir -p "$BIN"
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Mock: emit predefined repo list when asked
if [[ "$1" == "repo" && "$2" == "list" ]]; then
  printf 'serverkraken/alpha\nserverkraken/beta\nserverkraken/foo\n'
fi
EOF
  chmod +x "$BIN/gh"
  PATH="$BIN:$PATH"
}

teardown() {
  rm -rf "$WORK"
}
```

#### Test Cases

```bats
@test "creates onboarding-status.md with header when missing" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ -f docs/onboarding-status.md ]]
  grep -q "# Onboarding Status" docs/onboarding-status.md
  grep -q "| Repository |" docs/onboarding-status.md
}

@test "appends only new repos, preserves existing rows" {
  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/alpha | ✓ | v3.0.0 | #1 | #2 | onboarded |
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Existing row untouched
  grep -q "| serverkraken/alpha | ✓ | v3.0.0 |" docs/onboarding-status.md
  # New rows appended
  grep -q "| serverkraken/beta |" docs/onboarding-status.md
  grep -q "| serverkraken/foo |" docs/onboarding-status.md
}

@test "regex anchor avoids substring false-match" {
  # gh returns "serverkraken/foo"; existing row is "serverkraken/foo-extra"
  cat > docs/onboarding-status.md <<'EOF'
# Onboarding Status

| Repository | Onboarded | Catalog Version | Add PR | Cleanup PR | Status |
|---|---|---|---|---|---|
| serverkraken/foo-extra | — | — | — | — | not onboarded |
EOF
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # foo should now appear as a new row (anchor prevents the foo-extra row from masking it)
  grep -cE '^\| serverkraken/foo \|' docs/onboarding-status.md | grep -q '^1$'
}
```

`gh` mock ist absichtlich minimal: schreibt nur stdout, kein exit-handling, kein quoting. Das deckt den einzigen `gh`-Code-Pfad ab.

### 4.4 C-4 — onboard-drift action-wrapper test

#### Fixture-Bau

`tests/fixtures/onboard/drift-clean/` wird einmal manuell erzeugt durch:

```bash
# Anweisung im Plan (nicht im Test-Code) — fixture wird committed
mkdir -p tests/fixtures/onboard/drift-clean
profile=$(scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/go-repo)
echo "$profile" > /tmp/profile.json
scripts/onboard-render.sh "$PWD" tests/fixtures/onboard/drift-clean /tmp/profile.json v3
rm /tmp/profile.json
```

Ergebnis: `.github/onboard.lock.json` + alle gerenderten Files unter `.github/workflows/` etc. mit Hashes, die mit dem Lock matchen.

Plus ein 5-zeiliges `tests/fixtures/onboard/drift-clean/README.md`:
```markdown
# drift-clean fixture

Pre-rendered v3 onboarding output used by `tests/callers/onboard-drift-happy.yml`
to verify the `actions/onboard-drift` composite-action wrapper.

When the catalog cuts a new major (v4+), regenerate via:

    rm -rf tests/fixtures/onboard/drift-clean
    profile=$(scripts/onboard-detect.sh --profile-json tests/fixtures/onboard/go-repo)
    echo "$profile" > /tmp/profile.json
    mkdir -p tests/fixtures/onboard/drift-clean
    scripts/onboard-render.sh "$PWD" tests/fixtures/onboard/drift-clean /tmp/profile.json vN

Restore this README after regeneration.
```

#### Caller-Workflow

`tests/callers/onboard-drift-happy.yml`:

```yaml
# tests/callers/onboard-drift-happy.yml
# Happy-path caller for the onboard-drift composite action. Exercises the
# GHA wrapper layer (env passthrough, GITHUB_OUTPUT capture, GITHUB_ACTION_PATH
# resolution) against the pre-rendered drift-clean fixture. The script-level
# behaviour is already covered by tests/shell/onboard-drift.bats.
name: caller-onboard-drift-happy
on:
  workflow_dispatch:
  pull_request:
    paths:
      - 'actions/onboard-drift/**'
      - 'scripts/onboard-drift.sh'
      - 'scripts/lib/hash-lib.sh'
      - 'tests/callers/onboard-drift-happy.yml'
      - 'tests/fixtures/onboard/drift-clean/**'

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - id: drift
        uses: ./actions/onboard-drift
        with:
          target_path: tests/fixtures/onboard/drift-clean
          current_version: v3
      - name: Assert clean status
        env:
          STATUS: ${{ steps.drift.outputs.status }}
        run: |
          if [[ "$STATUS" != "clean" ]]; then
            echo "::error::expected status=clean, got status=$STATUS"
            exit 1
          fi
          echo "onboard-drift wrapper returned status=clean"
```

Nicht in `integration.yml` referenziert — self-firing via path filter wie alle anderen `*-happy.yml`.

### 4.5 C-5 — *-fail callers auto-run

Drei Files bekommen identische Struktur-Änderungen. Beispiel für `docker-build-multi-fail.yml`:

**Vorher:**
```yaml
on:
  workflow_dispatch:

jobs:
  test-docker-build-multi-fail:
    uses: ./.github/workflows/docker-build-multi.yml
    secrets: inherit
    with: { ... }
```

**Nachher:**
```yaml
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/docker-build-multi.yml'
      - 'tests/callers/docker-build-multi-fail.yml'
      - 'tests/fixtures/multi-image/**'

jobs:
  test-docker-build-multi-fail:
    uses: ./.github/workflows/docker-build-multi.yml
    secrets: inherit
    continue-on-error: true
    with: { ... }

  assert-docker-build-multi-fail:
    needs: test-docker-build-multi-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-docker-build-multi-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected docker-build-multi to fail, got result=$RESULT"
            exit 1
          fi
          echo "docker-build-multi correctly failed for empty images array"
```

#### Path-Filter Triggers pro Caller

| File | paths |
|---|---|
| `docker-build-multi-fail.yml` | `docker-build-multi.yml`, this file, `tests/fixtures/multi-image/**` |
| `goreleaser-fail.yml` | `goreleaser.yml`, this file, `tests/fixtures/cli-go-no-config/**` |
| `helm-publish-fail.yml` | `helm-publish.yml`, this file, `tests/fixtures/helm-broken/**` |

Header-Kommentar in jedem File wird auf zwei Zeilen reduziert; die langen "dispatch-only because we don't want to burn CI" Comments werden ersetzt durch:
```yaml
# Failure-path caller for <atom>.yml. Auto-fires on path-filtered PRs;
# the assert-<atom>-fail sibling job verifies the atom failed as expected.
```

### 4.6 C-6 — cleanup-images-fail caller

Neuer File `tests/callers/cleanup-images-fail.yml`:

```yaml
# tests/callers/cleanup-images-fail.yml
# Failure-path caller for cleanup-images.yml. Passes runs_on as an empty
# JSON array; fromJSON yields [], which GHA rejects at runner allocation.
# The assert-cleanup-images-fail sibling job verifies the atom failed.
name: caller-cleanup-images-fail
on:
  workflow_dispatch:
  pull_request:
    paths:
      - '.github/workflows/cleanup-images.yml'
      - 'tests/callers/cleanup-images-fail.yml'

jobs:
  test-cleanup-images-fail:
    uses: ./.github/workflows/cleanup-images.yml
    secrets: inherit
    continue-on-error: true
    with:
      runs_on: '[]'

  assert-cleanup-images-fail:
    needs: test-cleanup-images-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-cleanup-images-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected cleanup-images to fail for runs_on='[]', got result=$RESULT"
            exit 1
          fi
          echo "cleanup-images correctly failed for empty runs_on"
```

## 5. Interface Contracts

| File | Change-Class | Caller-Breaking? |
|---|---|---|
| `.github/workflows/{docker-build-multi,goreleaser,helm-publish,cleanup-images}.yml` | UNVERÄNDERT | — |
| `actions/onboard-drift/action.yml` | UNVERÄNDERT | — |
| `scripts/seed-onboarding-status.sh` | UNVERÄNDERT | — |
| `tests/callers/{docker-build-multi,goreleaser,helm-publish}-fail.yml` | Trigger + assert job hinzugefügt | NEIN (caller files sind nicht Teil eines public contract) |
| `tests/callers/cleanup-images-fail.yml` | NEU | NEIN |
| `tests/callers/onboard-drift-happy.yml` | NEU | NEIN |
| `tests/fixtures/onboard/{cargo-workspace,pnpm-workspace,drift-clean}/` | NEU | NEIN |
| `tests/shell/onboard-detect.bats` | Additiv | NEIN |
| `tests/shell/seed-onboarding-status.bats` | NEU | NEIN |

**Commit-Klasse:** Alle Commits `test:` (release-please default mapping: kein Version-Bump). PR-J und PR-K sind beide patch-bump-neutral.

## 6. Test Strategy

| Surface | Verification |
|---|---|
| C-1, C-2 | `bats tests/shell/onboard-detect.bats` lokal grün; neue Tests erscheinen im Output. CI: `validate.yml`'s bats-step grün. |
| C-3 | `bats tests/shell/seed-onboarding-status.bats` grün; alle 3 Cases pass mit PATH-mocked gh. |
| C-4 | PR-Check `caller-onboard-drift-happy / drift` grün auf PR-J. |
| C-5 | PR-Checks `caller-{docker-build-multi,goreleaser,helm-publish}-fail / assert-X-fail` grün auf PR-K. |
| C-6 | PR-Check `caller-cleanup-images-fail / assert-cleanup-images-fail` grün auf PR-K. |
| Beide | `actionlint`/`yamllint` (via `validate.yml`) clean. |

**Keine Production-Pfad-Asserts.** Die Atome werden in dieser Phase nicht verändert; Existing Integration-Tests müssen unverändert grün bleiben (Regression-Boundary).

## 7. PR Plan

### PR-J — `test/onboard-coverage-phase-4`

- **Worktree:** `.worktrees/phase-4-onboard`
- **Files:**
  - `tests/fixtures/onboard/cargo-workspace/` (neu, 5 files)
  - `tests/fixtures/onboard/pnpm-workspace/` (neu, 6 files)
  - `tests/fixtures/onboard/drift-clean/` (neu, generiert + README)
  - `tests/shell/onboard-detect.bats` (additiv, 4 neue Tests)
  - `tests/shell/seed-onboarding-status.bats` (neu)
  - `tests/callers/onboard-drift-happy.yml` (neu)
- **Commits (5):**
  - `test(onboard): cargo-workspace fixture and detect tests`
  - `test(onboard): pnpm-workspace fixture and detect tests`
  - `test(onboard): bats coverage for seed-onboarding-status.sh`
  - `test(onboard): drift-clean fixture for action-wrapper test`
  - `test(onboard): onboard-drift composite-action caller workflow`

### PR-K — `test/atom-failure-coverage-phase-4`

- **Worktree:** `.worktrees/phase-4-atom-fail`
- **Files:**
  - `tests/callers/docker-build-multi-fail.yml` (edit: trigger + assert job + header-comment)
  - `tests/callers/goreleaser-fail.yml` (edit: same)
  - `tests/callers/helm-publish-fail.yml` (edit: same)
  - `tests/callers/cleanup-images-fail.yml` (neu)
- **Commits (4):**
  - `test(docker-build-multi): auto-trigger failure caller with assert job`
  - `test(goreleaser): auto-trigger failure caller with assert job`
  - `test(helm-publish): auto-trigger failure caller with assert job`
  - `test(cleanup-images): add failure-path caller`

### Sequenz

PR-J und PR-K sind **datei-disjoint** (PR-J editiert nur `tests/fixtures/onboard/*`, `tests/shell/*`, `tests/callers/onboard-drift-happy.yml`; PR-K editiert nur die 4 atom-failure-caller files). Beide können parallel entwickelt und in beliebiger Reihenfolge gemerged werden.

**Empfehlung:** PR-J zuerst (größere strukturelle Adds), PR-K als kleinerer Follow-up.

**PR-Body-Style:** kein Claude-Attribution-Footer (Memory: `feedback_pr_style`).

## 8. Acceptance Criteria

- [ ] PR-J merged: alle 5 Commits gelandet; `bats tests/shell/onboard-detect.bats` + `bats tests/shell/seed-onboarding-status.bats` grün; `caller-onboard-drift-happy / drift` PR-Check grün
- [ ] PR-K merged: alle 4 Commits gelandet; die 4 fail-Caller triggern auf PR via `pull_request: paths:` und reporten grün über ihre assert-Jobs
- [ ] `validate.yml` (self-CI) grün auf beiden PRs
- [ ] Production-Verhalten von `docker-build-multi`, `goreleaser`, `helm-publish`, `cleanup-images`, `onboard-drift` unverändert — pure Test-Additionen, byte-identisches Atom-Behaviour für existierende Caller
- [ ] Kein Version-Bump: release-please PR nach Merge ist patch-only oder no-op (test:-only commits per default mapping)
- [ ] Existing Integration-Tests in `integration.yml` (test-onboard-dry-run, test-onboard-failure, test-semantic-release-dry-run, test-cleanup-images, test-vars-coercion etc.) bleiben unverändert grün

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `drift-clean` fixture wird stale am nächsten Major-Bump (v3→v4) → wrapper-Test reportet `behind` statt `clean` → assert failt | Certain (bei jedem Major) | README im fixture-dir dokumentiert die ein-Zeilen-Refresh-Prozedur; gleicher Coupling-Cost wie bats `golden_check` Tests |
| `runs_on: '[]'` löst nicht den erwarteten GHA-Fehler aus (z.B. silent-skip statt failure) | Low | Fallback: `runs_on: 'not-json'` → `fromJSON()` Expression-Error im Job-Header. Wenn auch das nicht greift: `package_name` mit Unicode-Edge-Case |
| `continue-on-error: true` auf workflow_call-Caller-Job nicht respektiert | Very Low | Phase 2b (`test-onboard-failure` in integration.yml) hat dasselbe Pattern erfolgreich eingesetzt — gleiche GHA-Semantik |
| Bats-Mock-`gh` schreibt zu naive output (z.B. kein `\n` zwischen repos) und seed-script's `read` loop liest's falsch | Low | Mock benutzt `printf '...\n'` explizit; Bats-Tests prüfen exakte Zeilenzahl-Asserts |
| pnpm-workspace Glob-Expansion-Order nicht-deterministisch zwischen macOS/Linux | Low | Bats-Asserts nutzen Substring-Matches (`[[ output == *"apps/web"* ]]`), nicht Reihenfolge |
| Cargo-Workspace fixture löst zusätzlich unsupported-language warnings für nicht-rust files aus | Negligible | Fixture enthält nur Cargo.toml + .rs files — keine Mixed-Language Pfade |
| Beide PRs gleichzeitig in release-please-Queue → Patch-Bump-Konflikt | Low | Disjoint files = kein Merge-Conflict; release-please ist tolerant für concurrent test:-only PRs |

## 10. Open Questions

Keine. Alle Entscheidungen aus Brainstorming fixiert:

1. ✓ Scope: 6 Concerns (HIGH-11, MED-13, MED-14, MED-15, G.4-M3 onboard-drift wrapper, MED-12 already done)
2. ✓ PR-Split: 2 PRs by domain (PR-J onboard, PR-K atom-failure)
3. ✓ MED-13 Mechanism: self-contained assert job in each caller file (Phase 2b pattern)
4. ✓ Drift-Fixture: pre-baked (Option A)
5. ✓ Cleanup-images failure trigger: `runs_on: '[]'`
6. ✓ seed-onboarding-status MED-7 (relative path) bleibt out-of-scope; bats-Test arbeitet via `cd`
