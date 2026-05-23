# Phase 5 — Performance (Design Spec)

**Datum:** 2026-05-22
**Quelle:** `REVIEW-2026-05-22.md` § F (PERF-1 through PERF-5) + § C (MED-11)
**Scope:** Five perf items split into two file-disjoint PRs. No public-contract breakage.
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger)
**Vorgänger:** Phase 4 (HIGH-11, MED-13–15 in #99 + #100)

---

## 1. Goal

Phase 5 schließt fünf Performance-Items aus dem Katalog-Review:

- **PERF-1**: 21 Workflows haben heute **keinen** `timeout-minutes:`. GHA-Default ist 360min (6h). Ein hängender Job kann maximal 6 Stunden Runner-Slots binden.
- **PERF-2**: Vier Stellen bauen JSON-Arrays via `jq-in-loop` (O(n) Prozess-Spawns für O(n)-Elemente, effektiv O(n²) bei großen Inputs).
- **PERF-3**: `detect_legacy_ci` spawned 4 separate `grep`-Prozesse pro Workflow-File. Bei einem Adopter mit 8 Legacy-Workflows: 32 grep-Spawns. Eine combined-alternation Regex tut's auch.
- **PERF-4/MED-11**: `actions/onboard-detect/action.yml` ruft `scripts/onboard-detect.sh` **zweimal** (einmal für Legacy key=value, einmal für `--profile-json`). Beide Aufrufe machen einen `gh api /repos/<owner>/<repo>` Roundtrip für `default_branch`.
- **PERF-5**: `read_image_override` benutzt `head | grep | sed` (3 Prozesse pro Dockerfile). Single awk ersetzt das.

Alle fünf Items sind reine Performance-Verbesserungen — keine Verhaltensänderung am Public Contract.

## 2. Scope

### In Scope

| Concern | Findings | PR | Outcome |
|---|---|---|---|
| **C-1** | PERF-1 | PR-L | `timeout-minutes:` auf jedem Job in allen 21 Workflows, Werte aus § F Tabelle |
| **C-2** | PERF-2 | PR-M | 4 jq-in-loop Stellen auf bash-array + slurp Pattern refactored |
| **C-3** | PERF-3 | PR-M | `detect_legacy_ci` 4 greps zu 1 alternation Regex |
| **C-4** | PERF-4 / MED-11 | PR-M | `onboard-detect.sh` bekommt `--emit-both` Mode; Action ruft Script 1× statt 2× |
| **C-5** | PERF-5 | PR-M | `read_image_override` head\|grep\|sed → single awk |

### Out of Scope

- **PERF-6** (`validate.yml` trivy-renovate-annotation-check konsolidieren) — Phase 6 oder 7
- **PERF-7** (docker-build dreifacher Catalog-Checkout) — Architektur-Entscheidung mit eigener Plan-Datei nötig
- **OPT-4** (compute-prerelease-tag + ghcr-login inline statt cross-repo-checkout) — Architektur-Entscheidung
- **Legacy key=value Mode retirement** — würde Major-Bump erzwingen; nicht kosteneffizient für nur PERF-4

## 3. Background

### 3.1 timeout-minutes Default-Verhalten (PERF-1)

GHA-Default für `jobs.<id>.timeout-minutes:` ist **360** (6h). Wenn ein Job in einem Reusable Workflow hängt (deadlocked Tests, hängender Trivy-Scan, unresponsive goreleaser tool), blockiert er bis zu 6 Stunden Runner-Slots im selfhosted Pool.

`timeout-minutes` ist nur auf **Job-Ebene** gültig — kein workflow-level Key. Daher muss jeder Job in jeder Workflow-Datei den Key bekommen.

§ F des Reviews schlägt diese Tabelle vor:

| Workflow-Typ | Minuten |
|---|---|
| lint-* | 15 |
| test-* | 30 |
| docker-build (pro Job) | 60 |
| trivy-* | 20 |
| semantic-release, goreleaser | 15 |
| helm-publish | 10 |
| onboard, drift-check | 30 |

### 3.2 jq-in-loop O(n²) Pattern (PERF-2)

Aktuelles Pattern an 4 Stellen:

```bash
arr='[]'
for x in "${items[@]}"; do
  arr=$(echo "$arr" | jq --arg p "$x" '. + [...]')
done
```

Jede Iteration:
1. Spawnt einen `jq`-Prozess (~10-50ms je nach System)
2. Liest das gesamte bisherige Array
3. Hängt ein Element an
4. Schreibt das resultierende Array

Bei einem 10-Komponenten-Monorepo: 10 Spawns. Beim 50-Workflow Legacy-Scan: 50 Spawns. CPU-Cost addiert sich linear; mit zusätzlich quadratischem read+rewrite des wachsenden Arrays.

Bessere Variante:
```bash
entries=()
for x in "${items[@]}"; do
  entries+=("$(jq -nc --arg p "$x" '{path: $p, ...}')")
done
arr=$(printf '%s\n' "${entries[@]}" | jq -s '.')
```

N+1 Spawns statt N². Jeder Inner-Spawn produziert nur ein einzelnes JSON-Objekt; das final `jq -s` slurped die Zeilen in einen Array. Output bit-identisch (`jq -c -S` für canonical sort/compact, falls die Lock-Hashes davon abhängen).

Die 4 Stellen heute:

| Datei | Zeile | Funktion | Was wird gebaut |
|---|---|---|---|
| `scripts/lib/onboard-detect-lib.sh` | 246 | `detect_components` | Components-Array `[{path, languages, primary_language, ...}, ...]` |
| `scripts/lib/onboard-detect-lib.sh` | 374 | `inventory_dockerfiles` | Dockerfiles-Array `[{path, image_name, image_name_source, release_eligible}, ...]` |
| `scripts/lib/onboard-detect-lib.sh` | 573 | `detect_legacy_ci` | Legacy-Workflows-Array `[{path, summary, replaced_by}, ...]` |
| `scripts/onboard-render.sh` | 137 | (inline files_json builder) | Lock-Files-Object `{path1: "sha256:...", path2: "sha256:..."}` |

### 3.3 detect_legacy_ci Mehrfach-Grep (PERF-3)

Aktuell (`scripts/lib/onboard-detect-lib.sh:494-504`):
```bash
detect_legacy_ci() {
  local repo="$1" file="$2"
  grep -qE 'serverkraken/reusable-workflows/' "$file" && return 0
  grep -qE 'aquasecurity/trivy-action' "$file" && return 0
  grep -qE 'cargo (build|test|clippy)' "$file" && return 0
  grep -qE 'helm (lint|publish)' "$file" && return 0
  return 1
}
```

Jeder Aufruf spawned bis zu 4 grep-Prozesse. Bei 8 Workflow-Files im Adopter-Repo: bis zu 32 Spawns. Combined:

```bash
detect_legacy_ci() {
  grep -qE 'serverkraken/reusable-workflows/|aquasecurity/trivy-action|cargo (build|test|clippy)|helm (lint|publish)' "$2"
}
```

1 Spawn. Logik-äquivalent (alternation == any-match).

### 3.4 onboard-detect Doppel-Invocation (PERF-4 / MED-11)

Aktuell (`actions/onboard-detect/action.yml:55-58`):
```bash
"$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" \
  "$REPO_PATH" "$LANG_OVERRIDE" >> "$GITHUB_OUTPUT"
profile=$("$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --profile-json "$REPO_PATH")
delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
{ echo "profile_json<<${delim}"; echo "$profile"; echo "${delim}"; } >> "$GITHUB_OUTPUT"
```

Beide Script-Invocations:
- Laden `onboard-detect-lib.sh`
- Probieren Sprach-Detection auf dem Working Tree
- Wenn `$TARGET_REPO` gesetzt: machen einen `gh api /repos/<owner>/<repo>` Roundtrip für `default_branch` + `gh release list -L 1` für `current_version`

Effektiv: **2 Detection-Pässe + 2 gh-API-Roundtrip-Sets pro Action-Call.**

### 3.5 read_image_override Mehr-Pipe (PERF-5)

Aktuell (`scripts/lib/onboard-detect-lib.sh:340-350`-Region):
```bash
head -5 "$f" | grep -E '^# onboard:image=' | sed -E 's/^# onboard:image=//'
```

3 Prozesse pro Dockerfile. Bei einem Repo mit 5 Dockerfiles: 15 Spawns nur für Override-Reads.

Single awk:
```bash
awk '/^# onboard:image=/{sub(/^# onboard:image=/,""); print; exit} NR>5{exit}' "$f"
```

1 Spawn. Early-exit nach Line 5 (gleiche Semantik wie `head -5`).

## 4. Design per Concern

### 4.1 C-1 — timeout-minutes auf alle Workflows (PR-L)

Jedes der 21 Files in `.github/workflows/` bekommt `timeout-minutes:` auf jedem Job. Wert aus dieser Tabelle (entspricht § F):

| Datei | Job(s) | timeout-minutes |
|---|---|---|
| `lint-go.yml` | `lint` | 15 |
| `lint-python.yml` | `lint` | 15 |
| `lint-rust.yml` | `lint` | 15 |
| `lint-helm.yml` | `lint` | 15 |
| `test-go.yml` | `test` | 30 |
| `test-python.yml` | `test` | 30 |
| `test-rust.yml` | `test` | 30 |
| `docker-build.yml` | `version`, `build` (matrix), `merge`, `post-comment` | 60 (alle Jobs) |
| `docker-build-multi.yml` | `parse`, `version`, `build` (matrix), `merge` | 60 (alle Jobs) |
| `trivy-fs.yml` | `scan` | 20 |
| `trivy-image.yml` | `scan` | 20 |
| `semantic-release.yml` | `release` | 15 |
| `goreleaser.yml` | `release` | 15 |
| `helm-publish.yml` | `publish` | 10 |
| `cleanup-images.yml` | `cleanup` | 15 |
| `onboard.yml` | `parse-inputs`, `onboard` (matrix), `finalize` | 30 (alle Jobs) |
| `drift-check.yml` | `enumerate`, `check` (matrix), `summarize` | 30 (alle Jobs) |
| `release.yml` | `semantic-release` + downstream wrapper jobs | 60 (match docker-build ceiling) |
| `validate.yml` | `actionlint`, `yamllint`, `renovate-config-check`, `trivy-renovate-annotation-check`, `shell-tests` | 30 (alle Jobs) |
| `integration.yml` | alle Caller-Jobs + alle assert-* Jobs | 30 (alle Jobs) |
| `catalog-release.yml` | `release` | 30 |

**Placement convention:** `timeout-minutes:` direkt nach `runs-on:` für jeden Job, mirror der existierenden `permissions:`/`concurrency:`-Position im Katalog.

**Beispiel:**
```yaml
jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 15
    steps:
      ...
```

Keine Sondertreatment für Matrix-Jobs — GHA wendet `timeout-minutes:` pro Matrix-Element an.

### 4.2 C-2 — jq-in-loop Refactor (PR-M)

**Pattern (uniform an allen 4 Stellen):**

Vorher:
```bash
arr='[]'
for x in "${items[@]}"; do
  arr=$(echo "$arr" | jq --arg ... '. + [{...}]')
done
echo "$arr"
```

Nachher:
```bash
entries=()
for x in "${items[@]}"; do
  entries+=("$(jq -nc --arg ... '{...}')")
done
if [[ ${#entries[@]} -eq 0 ]]; then
  echo '[]'
else
  printf '%s\n' "${entries[@]}" | jq -cs '.'
fi
```

Die `[[ -eq 0 ]]`-Klausel: bei leerem Array vermeiden wir den `jq -s`-Spawn ganz (gibt `[]` zurück, bit-identisch zum ursprünglichen Start-Wert).

**Vier konkrete Stellen:**

#### 4.2.1 `scripts/lib/onboard-detect-lib.sh:237-265` — detect_components

```bash
# Vorher (lines 237-265):
arr='[]'
for p in "${unique[@]}"; do
  ...
  arr=$(echo "$arr" | jq \
    --arg path "$p" \
    --argjson languages "$langs" \
    ...
    '. + [{path: $path, languages: $languages, ...}]')
done
echo "$arr"

# Nachher:
entries=()
for p in "${unique[@]}"; do
  ...
  entries+=("$(jq -nc \
    --arg path "$p" \
    --argjson languages "$langs" \
    ... \
    '{path: $path, languages: $languages, ...}')")
done
if [[ ${#entries[@]} -eq 0 ]]; then
  echo '[]'
else
  printf '%s\n' "${entries[@]}" | jq -cs '.'
fi
```

#### 4.2.2 `scripts/lib/onboard-detect-lib.sh:365-385` — inventory_dockerfiles

Gleiches Pattern. Loop iteriert über `${files[@]}` (Dockerfile-Namen).

#### 4.2.3 `scripts/lib/onboard-detect-lib.sh:570-590` — detect_legacy_ci (innerhalb des find-Loops)

Gleiches Pattern. Loop iteriert über gefundene Workflow-Files.

#### 4.2.4 `scripts/onboard-render.sh:130-145` — files_json builder

Vorher:
```bash
files_json='{}'
for f in "${RENDERED[@]}"; do
  ...
  files_json=$(echo "$files_json" | jq --arg k "$f" --arg v "sha256:$sha" '. + {($k): $v}')
done
```

Nachher (etwas anders weil Object, nicht Array):
```bash
files_entries=()
for f in "${RENDERED[@]}"; do
  ...
  files_entries+=("$(jq -nc --arg k "$f" --arg v "sha256:$sha" '{($k): $v}')")
done
if [[ ${#files_entries[@]} -eq 0 ]]; then
  files_json='{}'
else
  files_json=$(printf '%s\n' "${files_entries[@]}" | jq -cs 'add')
fi
```

`jq -cs 'add'` slurped die Object-Entries und merged sie zu einem flachen Object.

**Output-Equivalenz:** alle 4 Refactors produzieren bit-identische JSON gegenüber dem Original (`jq -c` für compact, Reihenfolge der Properties bleibt durch die Loop-Iteration). Bats-Tests in `onboard-detect.bats` und `onboard-render.bats` (golden_check) validieren das.

### 4.3 C-3 — detect_legacy_ci combined regex (PR-M)

Edit in `scripts/lib/onboard-detect-lib.sh:494-504`. Ersetze die 4-grep-Sequenz durch:

```bash
detect_legacy_ci() {
  grep -qE 'serverkraken/reusable-workflows/|aquasecurity/trivy-action|cargo (build|test|clippy)|helm (lint|publish)' "$2"
}
```

Funktional identisch — alternation ist `OR`. Exit-code 0 wenn irgendein Pattern matched, sonst 1. Same return semantics wie heute.

**Bats coverage:** `tests/shell/onboard-detect.bats` hat 3 existierende `detect_legacy_ci` Tests (laut Review § G.3) — die müssen weiter grün laufen.

### 4.4 C-4 — `--emit-both` Mode (PR-M)

#### Script change — `scripts/onboard-detect.sh`

Neue Mode-Detection: drittes argv-Pattern.

```bash
# Heute (vereinfacht):
if [[ "$1" == "--profile-json" ]]; then
  shift
  profile_json_mode=1
fi
REPO_PATH="$1"

# Mit Phase 5:
emit_both=0
if [[ "$1" == "--emit-both" ]]; then
  shift
  emit_both=1
elif [[ "$1" == "--profile-json" ]]; then
  shift
  profile_json_mode=1
fi
REPO_PATH="$1"
```

Im `--emit-both` Pfad:
1. Detection-Logik 1× durchlaufen (gleicher Code wie heute, aber Werte werden NICHT direkt emittiert).
2. Erst die Legacy-key=value-Zeilen ausgeben.
3. Dann die `profile_json=<<DELIM` ... `<<DELIM` Multiline-Block-Form (kompatibel mit `>> "$GITHUB_OUTPUT"`).

```bash
if (( emit_both )); then
  echo "language=$language"
  echo "release_type=$release_type"
  echo "current_version=$current_version"
  echo "default_branch=$default_branch"
  delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
  echo "profile_json<<${delim}"
  echo "$profile_json"
  echo "${delim}"
fi
```

Die existierenden Modi (default `<repo>` und `--profile-json <repo>`) bleiben **unverändert**.

#### Action change — `actions/onboard-detect/action.yml`

Vorher (zwei Invocations):
```yaml
run: |
  set -euo pipefail
  "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" \
    "$REPO_PATH" "$LANG_OVERRIDE" >> "$GITHUB_OUTPUT"
  profile=$("$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --profile-json "$REPO_PATH")
  delim="EOF_$(head -c 16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)"
  { echo "profile_json<<${delim}"; echo "$profile"; echo "${delim}"; } >> "$GITHUB_OUTPUT"
```

Nachher (eine Invocation):
```yaml
run: |
  set -euo pipefail
  "$GITHUB_ACTION_PATH/../../scripts/onboard-detect.sh" --emit-both \
    "$REPO_PATH" "$LANG_OVERRIDE" >> "$GITHUB_OUTPUT"
```

Die Delimiter-Generierung wandert vom Action-Inline-Script ins Script selbst (gleicher `head -c 16 /dev/urandom | base64`-Pattern). Keine Doppellogik mehr.

**Action-Outputs UNVERÄNDERT:** alle 5 Output-Keys (`language`, `release_type`, `current_version`, `default_branch`, `profile_json`) werden weiterhin mit denselben Werten emittiert. Keine Consumer-Migration nötig.

**Bats coverage:** 2 neue Tests in `tests/shell/onboard-detect.bats`:
```bats
@test "--emit-both emits legacy key=value lines AND profile_json block" {
  run "$DETECT" --emit-both "$FIX/go-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=go"* ]]
  [[ "$output" == *"release_type=go"* ]]
  [[ "$output" == *"profile_json<<"* ]]
}

@test "--emit-both profile_json block is GITHUB_OUTPUT compatible" {
  run "$DETECT" --emit-both "$FIX/go-repo"
  [ "$status" -eq 0 ]
  # Extract the profile_json block content between the delimiter markers
  block=$(echo "$output" | awk '/^profile_json<<EOF_/{flag=1; delim=$0; sub(/^profile_json<</,"",delim); next} $0==delim{flag=0} flag')
  echo "$block" | jq -e '.languages | type == "array"'
}
```

### 4.5 C-5 — read_image_override single awk (PR-M)

Edit in `scripts/lib/onboard-detect-lib.sh:340-350`-Region.

Vorher:
```bash
read_image_override() {
  head -5 "$1" | grep -E '^# onboard:image=' | sed -E 's/^# onboard:image=//'
}
```

Nachher:
```bash
read_image_override() {
  awk '/^# onboard:image=/{sub(/^# onboard:image=/,""); print; exit} NR>5{exit}' "$1"
}
```

Same input-output contract. Early-exit auf Line 5 = identisch zum `head -5`-Limit.

**Bats coverage:** 1 existierender Test (`read_image_override`-Tests in `onboard-detect.bats`) validiert.

## 5. Interface Contracts

| File | Change-Class | Caller-Breaking? |
|---|---|---|
| `.github/workflows/*.yml` (21 files) | Additive (`timeout-minutes:` per job) | NEIN — tightening from implicit 360min default |
| `scripts/onboard-detect.sh` | Additive `--emit-both` mode (zusätzlich zu den 2 existierenden) | NEIN — existierende Modi byte-identisch |
| `scripts/lib/onboard-detect-lib.sh` | Internal-only perf refactor in 4 Funktionen | NEIN — Output bit-identisch (bats guards) |
| `scripts/onboard-render.sh` | Internal-only perf refactor in 1 Stelle | NEIN — Lock-JSON byte-identisch |
| `actions/onboard-detect/action.yml` | Single script call statt zwei | NEIN — gleicher Outputs-Set |
| `tests/shell/onboard-detect.bats` | Additiv (2 neue Tests) | NEIN |

**Commit-Klasse:** Alle Commits `perf:` oder `refactor:` (release-please default mapping → Patch-Bump oder no-op). Die 2 neuen Bats-Tests sind `test:` (neutral).

## 6. Test Strategy

| Surface | Verification |
|---|---|
| C-1 (timeouts) | `validate.yml` PR-Check grün (actionlint + yamllint). Keine Runtime-Tests — GHA aktiviert `timeout-minutes` nur bei wirklich hängenden Jobs |
| C-2 (jq-loops) | `bats tests/shell/onboard-detect.bats` + `onboard-render.bats` (inkl. golden_check) grün — Output-Drift wird sofort sichtbar |
| C-3 (combined grep) | `bats tests/shell/onboard-detect.bats` grün — 3 existierende `detect_legacy_ci` Tests |
| C-4 (--emit-both) | 2 neue Bats-Tests + integration: `test-onboard-dry-run` Job in `integration.yml` exerciert die Action end-to-end |
| C-5 (single awk) | `bats tests/shell/onboard-detect.bats` grün — existierender `read_image_override` Test |

**Regression-safety:** Phase 4's cargo+pnpm Fixtures und `seed-onboarding-status.bats` decken die jq-Pfade. Bats-Suite ist heute 135 Tests, wächst auf 137 nach Phase 5 (`--emit-both` × 2).

## 7. PR Plan

### PR-L — `perf/workflow-timeouts`

- **Worktree:** `.worktrees/phase-5-timeouts`
- **Files:** alle 21 Workflow-Dateien in `.github/workflows/`
- **Commits (1):** mechanisches single-commit. Keine Wert in 21 Commits-Aufteilung.
  - `perf(workflows): add timeout-minutes to every job`

### PR-M — `perf/onboard-scripts`

- **Worktree:** `.worktrees/phase-5-scripts`
- **Files:**
  - `scripts/onboard-detect.sh` (`--emit-both` mode)
  - `scripts/lib/onboard-detect-lib.sh` (4 refactor spots: detect_components, inventory_dockerfiles, detect_legacy_ci, read_image_override)
  - `scripts/onboard-render.sh` (files_json refactor)
  - `actions/onboard-detect/action.yml` (single invocation)
  - `tests/shell/onboard-detect.bats` (2 new tests)
- **Commits (6):**
  - `perf(onboard-detect): combine 4 legacy_ci grep calls into single alternation`
  - `perf(onboard-detect): replace head|grep|sed in read_image_override with single awk`
  - `perf(onboard-detect): slurp-pattern for detect_components + inventory_dockerfiles + detect_legacy_ci array builders`
  - `perf(onboard-render): slurp-pattern for files_json builder`
  - `feat(onboard-detect): add --emit-both mode for action 1×-call`
  - `test(onboard-detect): cover --emit-both mode`

### Sequencing

PR-L und PR-M sind **file-disjoint** (PR-L editiert nur `.github/workflows/*`; PR-M editiert nur `scripts/*`, `actions/*`, `tests/shell/*`). Beide können parallel entwickelt werden.

**Empfehlung:** PR-L zuerst (mechanisch, low-risk, baut Confidence). Dann PR-M (echte perf-Delta, nuancierter).

**PR-Body-Style:** kein Claude-Attribution-Footer (Memory: `feedback_pr_style`).

## 8. Acceptance Criteria

- [ ] PR-L merged: alle 21 Workflows haben `timeout-minutes:` auf jedem Job per § F Tabelle; `validate.yml` (actionlint+yamllint) grün; keine Runtime-Regression in `integration.yml` (alle existierenden Jobs laufen innerhalb ihres neuen Limits)
- [ ] PR-M merged: bats Suite 137 Tests grün (135 + 2 für `--emit-both`); `integration.yml`'s `test-onboard-dry-run` Job grün (validiert 1×-call Pfad end-to-end); production Verhalten aller Consumer unverändert
- [ ] Kein Version-Bump über Patch hinaus (alle Commits `perf:`/`refactor:`/`feat:`/`test:`)
- [ ] Existing Integration-Tests bleiben unverändert grün (test-onboard-dry-run, test-semantic-release-dry-run, etc.)

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Ein realer Production-Job hits das neue `timeout-minutes` Limit | Low | Werte gewählt basierend auf § F (beobachtete Run-Zeiten); jeder Job kann individuell hochgesetzt werden in Follow-up |
| jq-loop Refactor produziert non-canonical JSON (key-order shift) | Medium | `jq -c` für compact-form; bats golden_check in `onboard-render.bats` würde Lock-Drift sofort fangen |
| `--emit-both` GITHUB_OUTPUT Multiline-Delimiter kollidiert mit Payload | Negligible | Random Delimiter (16 chars base64) — gleiche Entropie-Quelle wie heute; gleicher Pattern, gleiches Risiko |
| Combined regex in `detect_legacy_ci` matches falsche Patterns | Low | Existierende 3 bats-Tests validieren gegen dieselben Fixtures; jeder unerwartete match wäre offensichtlich |
| Empty-Array-Edge-Case bei slurp-Pattern (printf gibt newline aus → jq -s sieht `[""]`) | Medium | Explizite `${#entries[@]} -eq 0` Check vor printf — Spec § 4.2 zeigt das Pattern |
| PR-L's 21-file Change yaml-formatting drift | Low | yamllint config toleriert; jede `timeout-minutes: <N>` ist eine kurze Zeile; line-length-Limit ist 200 |
| `--emit-both` Mode wird in `gh release list` Empty-Case different als heute | Negligible | Detection-Logik bleibt unverändert; nur der Emission-Pfad ist neu |

## 10. Open Questions

Keine. Alle Entscheidungspunkte aus Brainstorming fixiert:

1. ✓ Scope: 5 Perf-Items
2. ✓ Timeout-Werte: per-workflow tuned per § F Tabelle
3. ✓ PERF-4: `--emit-both` Flag (kein Legacy-Retire)
4. ✓ PR-Split: 2 PRs file-disjoint (PR-L workflows, PR-M scripts)
