# Phase 6 — Remaining MED + LOW bugs (Design Spec)

**Datum:** 2026-05-23
**Quelle:** `REVIEW-2026-05-22.md` § C (MED), § D (LOW), § N Phase 6
**Scope:** Sweep der verbleibenden MED- und LOW-Items aus dem Catalog Review (19 Items in 2 PRs).
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger)
**Vorgänger:** Phase 5 (PR-L #101 + PR-M #102 merged)

---

## 1. Goal

Phase 6 erledigt den Long-Tail der Review-Items: kleine Bug-Fixes, Doku-Drift, Template-Cleanup, Hygiene. **Keine Architektur-Änderungen.** Alle Items haben file-lokale Auswirkung.

Aus den ursprünglichen 22 Items (10 MED + 12 LOW):
- **MED-10 dropped** — `find $p/cmd …` in `detect_role` ist bereits durch `[[ -d "$p/cmd" ]]` Guard defensiv geschützt; keine reale Failure-Mode.
- **MED-20 dropped** — Top-level dead templates wurden bereits gelöscht; nur `configs/*.tmpl` existieren noch.
- **MED-21 deferred** — Multi-Dockerfile-Prerelease ohne Trivy-Scan ist mehr als ein One-Liner: `docker-build-multi.yml` exponiert per Design KEINE Per-Image-Outputs ("Outputs: intentionally not exposed. Matrix cardinality makes per-image image_ref/digest/tag mapping ambiguous"). Atom-Contract-Change + Template-Scan-Plumbing braucht eigenen Spec.

Verbleibend: **19 Items in 2 PRs**.

## 2. Scope

### PR-N — Production Fixes (13 items)

| ID | Concern | File |
|---|---|---|
| MED-1 | setup-go cache-dependency-path im explicit-version Branch | `.github/workflows/lint-go.yml`, `.github/workflows/test-go.yml` |
| MED-4 | Helm-Version-Drift lint 3.16.3 vs publish 3.15.0 | `.github/workflows/helm-publish.yml` |
| MED-5 | go.work Single-Entry-Form parser | `scripts/lib/onboard-detect-lib.sh` + neue Fixture + Bats |
| MED-6 | install-trivy mktemp ohne trap | `actions/install-trivy/action.yml` |
| MED-7 | seed-onboarding-status.sh relativer DOC-Pfad | `scripts/seed-onboarding-status.sh` |
| MED-8 + LOW-4 | post-prerelease-comment SHORT_SHA fragil + Step ohne `id` | `actions/post-prerelease-comment/action.yml` |
| MED-9 | `declare -A seen` ohne `local` | `scripts/lib/onboard-detect-lib.sh` |
| LOW-1 | `pull_request.number != ''` String-Vergleich | `.github/workflows/docker-build.yml` |
| LOW-2 | Stale "6 rendered files" Kommentar | `.github/workflows/onboard.yml` |
| LOW-3 | cleanup-images fehlt `contents: read` | `.github/workflows/cleanup-images.yml` |
| LOW-5 | goreleaser fehlt `packages: write` | `.github/workflows/goreleaser.yml` |
| LOW-8 | onboard finalize-Job ohne explizites `contents: write` | `.github/workflows/onboard.yml` |

### PR-O — Docs / Templates / Fixture (6 items)

| ID | Concern | File |
|---|---|---|
| LOW-6 | cleanup.yml.tmpl unnötiges `secrets: inherit` | `docs/adopter-templates/skeletons/cleanup.yml.tmpl` |
| LOW-7 | setup-python-deps Header-Kommentar widerspricht Code | `actions/setup-python-deps/action.yml` |
| LOW-9 | Dead `simple` Fixture (nur `.gitkeep`) | `tests/fixtures/onboard/simple/` |
| LOW-10 | README setup-python-deps fehlt in Composite-Actions-Tabelle | `README.md` |
| LOW-11 | CONTRIBUTING.md `act`-Hinweis ohne Caveats | `CONTRIBUTING.md` |
| LOW-12 | Backlog stale Lint/Test Atoms Eintrag (verify presence) | `docs/superpowers/backlog.md` |

### Out of Scope

- **MED-21** — Multi-Dockerfile Prerelease Trivy Scan: braucht eigenen Spec für `docker-build-multi.yml` Output-Design + Template-Plumbing
- **MED-10, MED-20** — bereits durch früheren Code-Drift erledigt
- **PERF-3** — schon in Phase 5 als N/A markiert

## 3. Background

### 3.1 MED-1 — setup-go cache-dependency-path

`.github/workflows/lint-go.yml:55-66` und `.github/workflows/test-go.yml:50-61` haben zwei Branches für `actions/setup-go@v6`:

```yaml
- name: Setup Go (from go.mod)
  if: inputs.go_version == ''
  uses: actions/setup-go@v6
  with:
    go-version-file: ${{ inputs.working_directory }}/go.mod
    cache-dependency-path: ${{ inputs.working_directory }}/go.sum

- name: Setup Go (explicit version)
  if: inputs.go_version != ''
  uses: actions/setup-go@v6
  with:
    go-version: ${{ inputs.go_version }}
    # cache-dependency-path FEHLT
```

Im `from go.mod`-Branch ist `cache-dependency-path` korrekt gesetzt. Im `explicit version`-Branch fehlt es — bei `working_directory != '.'` (Monorepo-Subpfad) findet `setup-go` die go.sum nicht im erwarteten Pfad und cached jedes Mal frisch. Fix: identische `cache-dependency-path:` Zeile in beiden Branches.

### 3.2 MED-4 — Helm Version Drift

`lint-helm.yml:27` default `'v3.16.3'`, `helm-publish.yml:35` default `'v3.15.0'`. Adopter, die beide ohne Override-Input nutzen, lint mit 3.16.3 und publish mit 3.15.0 — Behaviour-Differenzen zwischen Minors können lint-grün/publish-rot erzeugen.

### 3.3 MED-5 — go.work Single-Entry-Form

`scripts/lib/onboard-detect-lib.sh:142`:
```bash
awk '/^use \(/{flag=1;next}/^\)/{flag=0}flag{gsub(/[()"\t ]/,"");print}' "$repo/go.work" | sed 's|^\./||'
```

Matcht NUR die multi-entry Form:
```go
use (
  ./api
  ./worker
)
```

Single-Entry Form (Go 1.21+ syntax):
```go
use ./tools/gen
```

…wird ignoriert. Die Funktion fällt in der Praxis durch Step-2 (Fallback monorepo durch ≥2 sub-marker) ab, was zufällig richtig oder falsch sein kann. Fix: zweiter awk-Branch für `/^use [^(]/`.

### 3.4 MED-6 — install-trivy mktemp Leak

`actions/install-trivy/action.yml:33`:
```bash
TMP=$(mktemp -d)
# kein trap
curl -sfL ... -o "$TMP/trivy.tar.gz"
tar -xzf "$TMP/trivy.tar.gz" -C "$TMP"
sudo install "$TMP/trivy" /usr/local/bin/trivy
```

Bei einem `curl`/`tar`-Fail mit `set -e` werden Temp-Dirs nicht aufgeräumt — füllt auf self-hosted Runnern langsam `/tmp`.

### 3.5 MED-7 — seed-onboarding-status relativer Pfad

`scripts/seed-onboarding-status.sh:10`:
```bash
DOC=docs/onboarding-status.md
```

Relative path: funktioniert nur wenn CWD = repo root. Aufruf aus einem Subdir → silent wrong paths.

### 3.6 MED-8 + LOW-4 — SHORT_SHA Fragilität

`actions/post-prerelease-comment/action.yml:42`:
```bash
SHORT_SHA=$(echo "$IMAGE_REF" | rev | cut -d- -f1 | rev | cut -c1-7)
```

Funktioniert bei `<name>:<tag>-<7chars-sha>` Format. Gibt Garbage bei:
- OCI-Digests (`sha256:abc…`)
- Full-length SHAs
- Non-prerelease Tags ohne `-` suffix

Plus: der "Compose body" Step hat kein explicit `id:` — Outputs wären über `steps.body.outputs.X` nicht referenzierbar.

### 3.7 MED-9 — declare -A ohne local

`scripts/lib/onboard-detect-lib.sh:230`:
```bash
  # De-duplicate while preserving order
  declare -A seen=()
```

Ohne `local` wird `seen` global. Bei mehrfachem Aufruf von `detect_components` (Loops, Test-Harness) sehen Aufrufe Stale-Entries.

### 3.8 LOW-1 — PR Number String-Vergleich

`.github/workflows/docker-build.yml:436`:
```yaml
if: inputs.prerelease && github.event.pull_request.number != ''
```

`github.event.pull_request.number` ist im non-PR-Context `null`, im PR-Context eine Zahl. `!=` mit `''` ist semantisch unklar — GHA's truthy/falsy Coercion macht das funktional richtig, aber Code-Reader müssen darüber nachdenken. Cleaner:
```yaml
if: inputs.prerelease && github.event_name == 'pull_request'
```

### 3.9 LOW-2 — Stale "6 rendered files"

`.github/workflows/onboard.yml:245`:
```bash
# Reset index, then explicitly add only the 6 rendered files.
```

Nach smarter-onboarding (#84): 7 rendered files (added Containerfile support). Kommentar stale.

### 3.10 LOW-3 — cleanup-images contents permission

`.github/workflows/cleanup-images.yml:27-28`:
```yaml
permissions:
  packages: write
```

Fehlt `contents: read`. Cross-Repo-Aufrufer mit strict intersection könnten den `actions/checkout`-Step verlieren. (Atom hat keinen checkout, aber: explicit > implicit, vermeidet Future-Drift.)

### 3.11 LOW-5 — goreleaser packages: write

`.github/workflows/goreleaser.yml:39-40`:
```yaml
permissions:
  contents: write
```

Fehlt `packages: write`. Wenn goreleaser eine `.goreleaser.yaml` mit `dockers:`-Block hat (GHCR-Push), failed der Push silent ohne `packages: write`.

### 3.12 LOW-8 — onboard finalize-Job

`.github/workflows/onboard.yml` finalize-Job. Inherit-Permission vom workflow-level reicht nicht für strict-intersection bei cross-repo. Explizit setzen.

### 3.13 LOW-6, LOW-7, LOW-9, LOW-10, LOW-11, LOW-12 — Docs/Templates/Fixture

Trivial. Siehe §4 für Details.

## 4. Design per Concern

### PR-N

#### 4.1 MED-1 — cache-dependency-path

Edit `.github/workflows/lint-go.yml` Setup Go (explicit version) Step (lines 62-65). Add one line:

```yaml
- name: Setup Go (explicit version)
  if: inputs.go_version != ''
  uses: actions/setup-go@v6
  with:
    go-version: ${{ inputs.go_version }}
    cache-dependency-path: ${{ inputs.working_directory }}/go.sum
```

Identisch in `.github/workflows/test-go.yml` (lines 58-61).

#### 4.2 MED-4 — helm version sync

Edit `.github/workflows/helm-publish.yml:35`. Change default from `'v3.15.0'` to `'v3.16.3'`. Add a `# renovate: datasource=github-releases depName=helm/helm` comment above to anchor for the renovate-manager.

Skip: do not also bump lint-helm because lint-helm is already at 3.16.3 and we want renovate to bump them together.

#### 4.3 MED-5 — go.work single-entry parser

Edit `scripts/lib/onboard-detect-lib.sh:139-142`. Replace the awk block:

```bash
  if [[ -f "$repo/go.work" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(awk '
      /^use \(/{flag=1; next}
      /^\)/{flag=0; next}
      flag {
        gsub(/[()"\t ]/, "");
        if ($0 != "") print
        next
      }
      /^use[[:space:]]+[^(]/ {
        sub(/^use[[:space:]]+/, "");
        gsub(/["\t ]/, "");
        print
      }
    ' "$repo/go.work" | sed 's|^\./||')
```

New `/^use[[:space:]]+[^(]/` branch matches single-entry form. `gsub(/["\t ]/,"")` strips quotes/whitespace.

**New fixture:** `tests/fixtures/onboard/go-work-single/`
```
tests/fixtures/onboard/go-work-single/
├── go.work          # go 1.22\n\nuse ./svc
├── go.mod           # module example.com/root\n\ngo 1.22
└── svc/
    ├── go.mod       # module example.com/root/svc\n\ngo 1.22
    └── main.go      # package main\n\nfunc main() {}
```

**New bats tests** in `tests/shell/onboard-detect.bats`:
```bats
@test "detects go workspace single-entry form" {
  run "$DETECT" "$FIX/go-work-single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
}

@test "go-work-single --profile-json emits the single member path" {
  run "$DETECT" --profile-json "$FIX/go-work-single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"svc"* ]]
}
```

#### 4.4 MED-6 — install-trivy trap

Edit `actions/install-trivy/action.yml:33`. After `TMP=$(mktemp -d)`:
```bash
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
```

#### 4.5 MED-7 — seed-onboarding-status anchor

Edit `scripts/seed-onboarding-status.sh:8-10`. Add SCRIPT_DIR/REPO_ROOT anchor:
```bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/docs/onboarding-status.md"
```

Existing bats test (`tests/shell/seed-onboarding-status.bats`) uses `cd "$WORK"` workaround — keep as-is; the script-side fix is additive and the workaround still works.

#### 4.6 MED-8 + LOW-4 — post-prerelease-comment

Edit `actions/post-prerelease-comment/action.yml`:

1. Add new optional input near other inputs:
```yaml
  commit_sha:
    description: 'Optional commit SHA; if unset, derived from image_ref tag (best-effort).'
    required: false
    type: string
    default: ''
```

2. Edit the "Compose body" step (around line 36): add `id: body`:
```yaml
- name: Compose body
  id: body
  shell: bash
  env:
    IMAGE_REF: ${{ inputs.image_ref }}
    TRIVY_STATUS: ${{ inputs.trivy_status }}
    COMMIT_SHA: ${{ inputs.commit_sha }}
  run: |
    if [[ -n "$COMMIT_SHA" ]]; then
      SHORT_SHA="${COMMIT_SHA:0:7}"
    else
      SHORT_SHA=$(echo "$IMAGE_REF" | rev | cut -d- -f1 | rev | cut -c1-7)
    fi
    BODY=$(cat <<EOF
    ...existing body construction...
    EOF
    )
```

The existing `COMMIT_SHA` env injection + the `${COMMIT_SHA:0:7}` derivation is byte-identical to the legacy `rev|cut` path when `commit_sha` input is empty (default). Existing callers see no change.

#### 4.7 MED-9 — local -A seen

Edit `scripts/lib/onboard-detect-lib.sh:230`. Change:
```bash
  declare -A seen=()
```
to:
```bash
  local -A seen=()
```

One-line fix.

#### 4.8 LOW-1 — event_name check

Edit `.github/workflows/docker-build.yml:436`. Change:
```yaml
if: inputs.prerelease && github.event.pull_request.number != ''
```
to:
```yaml
if: inputs.prerelease && github.event_name == 'pull_request'
```

#### 4.9 LOW-2 — comment fix

Edit `.github/workflows/onboard.yml:245`. Change `6 rendered files` to `7 rendered files`.

#### 4.10 LOW-3 — cleanup-images contents:read

Edit `.github/workflows/cleanup-images.yml:27-28`:
```yaml
permissions:
  contents: read
  packages: write
```

#### 4.11 LOW-5 — goreleaser packages:write

Edit `.github/workflows/goreleaser.yml:39-40`:
```yaml
permissions:
  contents: write
  packages: write
```

Comment: `# packages: write — required when .goreleaser.yaml has a dockers: block`.

#### 4.12 LOW-8 — onboard finalize permissions

Find the finalize-job in `onboard.yml` (around line 450+). Add explicit:
```yaml
  finalize:
    needs: [onboard]
    if: always()
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write   # if it operates on PRs; verify during implementation
```

(Exact set depends on what the finalize-job actually does — likely contents: write to push status updates, possibly pull-requests: write. Verify by reading the job's steps and matching min-required.)

### PR-O

#### 4.13 LOW-6 — drop secrets: inherit from cleanup.yml.tmpl

Edit `docs/adopter-templates/skeletons/cleanup.yml.tmpl:17`. Remove the `secrets: inherit` line. The cleanup atom uses only `${{ github.token }}` — no inherited secrets needed.

#### 4.14 LOW-7 — setup-python-deps header

Edit `actions/setup-python-deps/action.yml` header comment (around line 1-15). Read the actual code logic (probe order: `[tool.poetry]` block → `[tool.uv]` block → `requirements.txt` → bare `pip install -e .`) and rewrite the header comment to match. Use memory entry `troubleshooting_python_pm_detection` as reference.

#### 4.15 LOW-9 — delete simple fixture

```bash
rm -rf tests/fixtures/onboard/simple/
```

The directory contains only `.gitkeep`; no test references it.

#### 4.16 LOW-10 — README setup-python-deps row

Edit `README.md:96-103` (composite actions table). Add row:
```
| setup-python-deps    | Setup Python + install dependencies (poetry / uv / pip)        |
```

(Match existing table format — description matches the action's `description:` field.)

#### 4.17 LOW-11 — CONTRIBUTING.md act caveats

Edit `CONTRIBUTING.md:17` (act section). Add caveats:
```markdown
> `act` cannot exercise self-hosted-runner labels (defaults to ubuntu-latest images),
> cannot perform cosign keyless signing (no OIDC token in act's runner identity),
> and cannot push to GHCR without a manually-mounted token. For end-to-end
> validation of those paths, rely on the catalog's `integration.yml` self-CI.
```

#### 4.18 LOW-12 — backlog Lint/Test cleanup

Read `docs/superpowers/backlog.md` fully. If a "Lint & Test Atoms" section exists (review claimed it does at lines 1-14), remove it — that feature shipped in PR #47. If absent, skip this commit and note in PR-O body.

## 5. Interface Contracts

| File | Change-Class | Caller-Breaking? |
|---|---|---|
| `.github/workflows/lint-go.yml`, `test-go.yml` | Additive (`cache-dependency-path` line) | NO |
| `.github/workflows/helm-publish.yml` | Default-value bump (3.15.0 → 3.16.3) | NO (still overridable) |
| `.github/workflows/docker-build.yml`, `onboard.yml`, `cleanup-images.yml`, `goreleaser.yml` | Permission tightening / event-name check | NO |
| `scripts/lib/onboard-detect-lib.sh` | Additive parser branch + `local` keyword | NO |
| `scripts/seed-onboarding-status.sh` | Internal anchor fix | NO |
| `actions/install-trivy/action.yml` | Additive trap line | NO |
| `actions/post-prerelease-comment/action.yml` | Additive `commit_sha` input + step `id:` | NO (default `''` preserves existing path) |
| `docs/adopter-templates/skeletons/cleanup.yml.tmpl` | Remove dead `secrets: inherit` | NO (adopter re-renders) |
| `actions/setup-python-deps/action.yml` | Comment-only | NO |
| `README.md`, `CONTRIBUTING.md`, `docs/superpowers/backlog.md` | Docs-only | NO |
| `tests/fixtures/onboard/simple/` | Delete (dead) | NO |
| `tests/fixtures/onboard/go-work-single/` | NEW (MED-5 fixture) | NO |
| `tests/shell/onboard-detect.bats` | Additive (2 tests for MED-5) | NO |

**Version impact:** Mix of `fix:` (bug fixes) and `chore:`/`docs:` (docs, fixtures). Release-please default: patch bump for PR-N's `fix:` commits, no version impact for PR-O's `chore:`/`docs:` commits.

## 6. Test Strategy

| Surface | Verification |
|---|---|
| MED-1 | `validate.yml` actionlint+yamllint clean on touched files |
| MED-4 | `validate.yml` clean; integration's helm-related callers unchanged |
| MED-5 | 2 new bats tests + full `onboard-detect.bats` (57+2 = 59 tests; baseline before Phase 6 = 59 already from Phase 5 — so 59→61) |
| MED-6, MED-7, MED-9 | Existing bats suites unchanged in count, all green |
| MED-8 + LOW-4 | `actionlint actions/post-prerelease-comment/action.yml` green; existing default path preserved |
| LOW-1, LOW-2, LOW-3, LOW-5, LOW-8 | `validate.yml` clean |
| LOW-6, LOW-7, LOW-9, LOW-10, LOW-11, LOW-12 | Lint clean; markdown rendering check on README/CONTRIBUTING |

**Cross-cutting:** all existing bats (135 + 2 = 137 after MED-5 tests), all existing integration jobs unchanged.

## 7. PR Plan

### PR-N — `fix/phase-6-prod-fixes`

- **Worktree:** `.worktrees/phase-6-prod`
- **Files:** 9 distinct files (some touched 2x where two items share a file)
- **Commits (13):**
  1. `fix(lint-go,test-go): cache-dependency-path in explicit-version branch (MED-1)`
  2. `fix(helm-publish): bump helm default to v3.16.3 to match lint-helm (MED-4)`
  3. `fix(onboard-detect): handle go.work single-entry use form (MED-5)`
  4. `test(onboard-detect): go.work single-entry fixture and bats (MED-5)`
  5. `fix(install-trivy): trap mktemp tempdir on EXIT (MED-6)`
  6. `fix(seed-onboarding-status): anchor DOC to repo root via SCRIPT_DIR (MED-7)`
  7. `feat(post-prerelease-comment): add commit_sha input + step id (MED-8, LOW-4)`
  8. `fix(onboard-detect): local -A seen in detect_components (MED-9)`
  9. `fix(docker-build): use event_name instead of PR number string check (LOW-1)`
  10. `fix(onboard): update stale '6 rendered files' comment to 7 (LOW-2)`
  11. `fix(cleanup-images): declare explicit contents:read permission (LOW-3)`
  12. `fix(goreleaser): add packages:write for GHCR push (LOW-5)`
  13. `fix(onboard): explicit contents:write on finalize job (LOW-8)`

### PR-O — `chore/phase-6-docs-templates`

- **Worktree:** `.worktrees/phase-6-docs`
- **Files:** 6 distinct files
- **Commits (6):**
  1. `fix(cleanup.yml.tmpl): drop unnecessary secrets: inherit (LOW-6)`
  2. `docs(setup-python-deps): correct header comment to match code (LOW-7)`
  3. `chore(fixtures): remove dead simple fixture (LOW-9)`
  4. `docs(README): add setup-python-deps row to composite actions table (LOW-10)`
  5. `docs(CONTRIBUTING): add act caveats for self-hosted/cosign (LOW-11)`
  6. `chore(backlog): remove shipped Lint/Test Atoms entry (LOW-12)` (skip if not present after verification)

### Sequencing

PR-N und PR-O sind **file-disjoint** (PR-N touched `.github/workflows/*`, `scripts/*`, `actions/install-trivy/`, `actions/post-prerelease-comment/`, `tests/`; PR-O touched `docs/`, `actions/setup-python-deps/`, `README.md`, `CONTRIBUTING.md`).

**Empfehlung:** PR-N zuerst (mehr Substanz + neue Bats), PR-O als kleinerer Follow-up.

**PR-Body-Style:** kein Claude-Attribution-Footer.

## 8. Acceptance Criteria

- [ ] PR-N merged: 13 Commits gelandet; alle existierenden Bats grün; neue go-work-single Bats grün (+2 = 61 onboard-detect tests); `validate.yml` grün; `integration.yml` test-onboard-dry-run + test-vars-coercion grün
- [ ] PR-O merged: bis zu 6 Commits gelandet (LOW-12 möglicherweise skipped); `simple` Fixture-Dir absent; README composite-actions Tabelle inkl. setup-python-deps; cleanup.yml.tmpl rendered ohne `secrets: inherit`
- [ ] Version Bump: Patch (PR-N) + no-op (PR-O) per release-please default mapping
- [ ] Production-Verhalten aller Atome byte-identisch, abgesehen vom additiven `commit_sha` Input bei post-prerelease-comment

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Helm 3.15.0→3.16.3 Bump bricht Adopter-Charts | Low | Lint nutzt bereits 3.16.3; wenn ein Chart bei publish breaken würde, würde es bei lint schon broken sein. Renovate hält die zwei in sync. |
| `local -A seen` Syntax auf bash < 4.0 nicht unterstützt | Negligible | Runner-Image bash 5+; Homebrew bash 5+ lokal |
| `commit_sha` Input bricht existierende Caller | Negligible | Default `''` fällt byte-identisch in den existierenden Pfad; nur opt-in ändert Verhalten |
| `packages: write` an goreleaser bricht Consumer | Negligible | Additive — strict intersection für cross-repo nur RICHTUNG breiter, nicht enger |
| go.work single-entry Fixture matched nicht reale Adopter | Low | Fixture: `go 1.22\nuse ./svc` — minimale kanonische Go-single-entry Form |
| LOW-12 backlog Eintrag bereits weg → leere PR-O commit-Liste | Low | Pre-implementation verify; bei Absence einfach Commit überspringen, PR-O body Notice |
| onboard finalize-Job `pull-requests: write` falsch angesetzt | Medium | Implementer liest den Job vor Permission-Set; Permission ist min-required basierend auf Step-Inhalt |

## 10. Open Questions

Keine. Alle Entscheidungen aus Brainstorming fixiert:

1. ✓ Scope: 19 Items (MED-10, 20, 21 ausgeschlossen)
2. ✓ PR-Split: 2 PRs file-disjoint
3. ✓ MED-21 deferred zu separatem Spec
4. ✓ MED-8 Mechanism: additive `commit_sha` Input (kein retire-and-replace)
5. ✓ MED-4 Helm Bump: nur publish→3.16.3, Renovate als Sync-Anker
