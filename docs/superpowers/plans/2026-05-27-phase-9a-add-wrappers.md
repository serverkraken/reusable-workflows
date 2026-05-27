# Phase 9a — Add Aggregate Wrappers (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Erweitert `.github/workflows/integration.yml` um die 4 fehlenden Side-Effects-Atome (docker-build-multi, goreleaser, helm-publish, cleanup-images-fail) + Summary-Job. Erstellt neues `.github/workflows/self-ci.yml` als Aggregator-Wrapper für alle Code-Inspection-Atome (lint-*, test-*, vars-coercion, onboard-drift) + Summary-Job. Lässt alle 22 `caller-*.yml` Dateien UNVERÄNDERT — sie laufen parallel zur Doppel-Validierung.

**Architecture:** Tier-Split nach Side-Effects vs Code-Inspection. Jeder Wrapper hat eine eigene concurrency-group, einen permissions-Block als Union der nested-call-Bedarfe, und einen `summary`-Job der mit `if: always()` läuft und via `toJson(needs)` + jq aggregiert. Designed-red `test-X-fail` Jobs sind NICHT in `summary.needs` — nur ihre `assert-X-fail` Geschwister sind drin, sodass Summary grün bleibt obwohl test-X-fail per Design rot ist.

**Tech Stack:** GitHub Actions YAML, actionlint (lokale Validierung), `gh` CLI (PR-Erstellung + CI-Monitoring), bash für summary-job-Logik.

**Spec:** `docs/superpowers/specs/2026-05-27-phase-9-aggregate-caller-wrapper-design.md`

**Discovery aus Audit (verändert Spec leicht):**
- Branch-Protection auf `main` hat heute KEINE `required_status_checks` konfiguriert. Phase 9 etabliert die zwei Summary-Checks als erste Required-Checks überhaupt — kein Risiko von Merge-Block durch Removal von checks-die-es-nicht-gibt.
- `caller-onboard-drift-happy.yml` ist KEIN workflow_call-caller, sondern ein plain `runs-on: ubuntu-latest` Job mit composite-action `./actions/onboard-drift`. Wandert 1:1 als Job in self-ci.yml.
- `caller-lint-python-happy.yml` + `caller-test-python-happy.yml` haben je 3 parallele Jobs (poetry/uv/pip). Alle 6 werden in self-ci.yml übernommen.
- `caller-lint-helm-fail.yml` + `caller-lint-rust-fail.yml` haben ein fehlendes Echo am Ende ihrer assert-jobs (gegenüber den anderen fail-callern). Werden im Wrapper konsistent gemacht (alle bekommen die success-echo).

---

## File Structure

**Modify:** `.github/workflows/integration.yml` (heute 245 Zeilen, danach ~500 Zeilen)
- Entfernen: `test-vars-coercion` Job (wandert nach self-ci.yml)
- Hinzufügen: cleanup-images-fail (+ assert), docker-build-multi happy + fail (+ assert), goreleaser happy + fail (+ assert, fail-Job mit `if: false` Gate für PR1), helm-publish happy + fail (+ assert), `summary` Job

**Create:** `.github/workflows/self-ci.yml` (~450 Zeilen)
- Header (name, on, concurrency, permissions)
- 8 lint-* Jobs (4 Sprachen × happy/fail; python-happy hat 3 Sub-Jobs)
- 6 test-* Jobs (3 Sprachen × happy/cov-fail; python-happy hat 3 Sub-Jobs)
- 4 assert-* Jobs (für die fail-Varianten von lint-go/helm/python/rust)
- 3 assert-* Jobs (für die cov-fail-Varianten von test-go/python/rust)
- vars-coercion Job
- onboard-drift Job (special: composite-action)
- `summary` Job

**Unverändert:** Alle 22 `.github/workflows/caller-*.yml` — werden erst in Phase 9b gelöscht.

---

## Task 1: Worktree-Setup

**Files:** keine

- [ ] **Step 1: Erstelle Phase-9a-Worktree**

```bash
git worktree add /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/phase-9a feat/self-ci-aggregate-wrappers
```

Wenn der Worktree-Pfad bereits existiert: `git worktree remove` + neu anlegen, oder einen anderen Pfad wählen. Wenn die Branch bereits existiert: anderen Namen wählen.

- [ ] **Step 2: In Worktree wechseln**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/phase-9a
```

Alle weiteren Tasks laufen in diesem Verzeichnis.

- [ ] **Step 3: Verifiziere actionlint ist verfügbar**

```bash
actionlint --version
```
Erwartet: Versions-String (z. B. `1.7.12`). Falls nicht installiert: `brew install actionlint`.

---

## Task 2: vars-coercion Job aus integration.yml entfernen

Der Job wandert nach self-ci.yml (Task 17) — wir entfernen ihn hier vorbereitend.

**Files:**
- Modify: `.github/workflows/integration.yml:222-245`

- [ ] **Step 1: Block-Markierung im Editor prüfen**

```bash
sed -n '220,246p' .github/workflows/integration.yml
```

Erwartet: Block beginnt mit `# ----- vars coercion:` Kommentar (Zeile ~223), endet bei `cgo_enabled:` Zeile.

- [ ] **Step 2: Block entfernen**

Lösche die Zeilen vom Kommentar-Header `# ----- vars coercion: verify type=number + type=boolean inputs accept` bis inklusive `cgo_enabled: ${{ fromJSON(vars.NONEXISTENT_BOOL_FOR_COERCION_TEST || 'false') }}`. Das sind heute Zeilen 222-245.

- [ ] **Step 3: actionlint lokal**

```bash
actionlint .github/workflows/integration.yml
```
Erwartet: keine Ausgabe (oder nur Warnungen die schon vorher da waren).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "refactor(integration): remove vars-coercion (moves to self-ci.yml)"
```

---

## Task 3: cleanup-images-fail Job zu integration.yml

Übernimmt `caller-cleanup-images-fail.yml` als Job-Pair (test + assert).

**Files:**
- Modify: `.github/workflows/integration.yml` (nach dem `test-cleanup-images` Block einfügen, ~Zeile 197)

- [ ] **Step 1: Block einfügen**

Direkt nach dem `test-cleanup-images:` Job (heute Zeilen 188-197) einfügen, vor dem `# ----- semantic-release dry-run` Kommentar:

```yaml
  # ----- cleanup-images failure path: empty runs_on array forces atom-level
  #       validation failure (matrix evaluation requires non-empty input). -----
  test-cleanup-images-fail:
    uses: ./.github/workflows/cleanup-images.yml
    secrets: inherit
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
            echo "::error::expected cleanup-images to fail for empty runs_on, got result=$RESULT"
            exit 1
          fi
          echo "cleanup-images correctly failed for empty runs_on"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/integration.yml
```
Erwartet: keine neuen Errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "feat(integration): absorb cleanup-images-fail caller"
```

---

## Task 4: docker-build-multi Jobs zu integration.yml

Übernimmt `caller-docker-build-multi-happy.yml` + `caller-docker-build-multi-fail.yml` (Pair + assert).

**Files:**
- Modify: `.github/workflows/integration.yml` (nach den cleanup-images-fail Jobs aus Task 3)

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-cleanup-images-fail:` (Task 3 Ende) einfügen:

```yaml
  # ----- docker-build-multi happy path: matrix build of 2 images from
  #       the multi-image fixture, manifest stitched, push by digest. -----
  test-docker-build-multi:
    uses: ./.github/workflows/docker-build-multi.yml
    secrets: inherit
    with:
      tag: ''
      prerelease: true
      context: tests/fixtures/multi-image
      images: >-
        [
          {"dockerfile": "tests/fixtures/multi-image/Dockerfile",
           "image_name": "serverkraken/reusable-workflows/test-multi-api"},
          {"dockerfile": "tests/fixtures/multi-image/Dockerfile.worker",
           "image_name": "serverkraken/reusable-workflows/test-multi-worker"}
        ]
      sign: true
      attest: true
      sbom: true

  # ----- docker-build-multi failure path: empty images array must
  #       fail at input validation, before any runner work begins. -----
  test-docker-build-multi-fail:
    uses: ./.github/workflows/docker-build-multi.yml
    secrets: inherit
    with:
      tag: ''
      prerelease: true
      context: tests/fixtures/multi-image
      images: '[]'
      sign: false
      attest: false
      sbom: false

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
            echo "::error::expected docker-build-multi to fail for empty images array, got result=$RESULT"
            exit 1
          fi
          echo "docker-build-multi correctly failed for empty images array"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/integration.yml
```
Erwartet: keine neuen Errors. Falls Warnung zu `release_please_app_client_id`/`release_please_app_private_key` Secret-Referenz im Atom auftaucht, ist das pre-existing (siehe Memory `actionlint-stale-data-on-create-github-app-token-v3`).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "feat(integration): absorb docker-build-multi happy + fail callers"
```

---

## Task 5: goreleaser Jobs zu integration.yml

Übernimmt `caller-goreleaser-happy.yml` + `caller-goreleaser-fail.yml`. **fail-Job bekommt `if: false` Gate** — Atom liefert heute fixture-bedingt success statt failure (Memory `phase9-aggregate-caller-wrapper`). Phase 9b repariert die Fixture und entfernt das Gate.

**Files:**
- Modify: `.github/workflows/integration.yml` (nach den docker-build-multi Jobs aus Task 4)

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-docker-build-multi-fail:` (Task 4 Ende):

```yaml
  # ----- goreleaser happy path: snapshot build against the cli-go fixture
  #       with a valid .goreleaser.yaml. No artifacts published. -----
  test-goreleaser:
    uses: ./.github/workflows/goreleaser.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/cli-go-with-goreleaser
      snapshot: true

  # ----- goreleaser failure path: fixture has no .goreleaser.yaml. Modern
  #       goreleaser-action auto-generates a default from go.mod, so this
  #       caller currently observes success. Gated with `if: false` in
  #       Phase 9a — Phase 9b adds a deliberately broken .goreleaser.yaml
  #       to the fixture (or renames the fixture) and removes the gate. -----
  test-goreleaser-fail:
    if: false   # PHASE-9B-ENABLES-AFTER-FIXTURE-FIX
    uses: ./.github/workflows/goreleaser.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/cli-go-no-config
      snapshot: true

  assert-goreleaser-fail:
    if: false   # PHASE-9B-ENABLES-AFTER-FIXTURE-FIX
    needs: test-goreleaser-fail
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-goreleaser-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected goreleaser to fail for missing config, got result=$RESULT"
            exit 1
          fi
          echo "goreleaser correctly failed for missing .goreleaser.yaml"
```

**Begründung des `if: false` ohne `if: always()`:** der assert-Job hängt an test-goreleaser-fail; wenn beide via `if: false` skipped sind, ist der needs-Graph konsistent (skipped → skipped). Summary-Job (Task 7) wird `assert-goreleaser-fail` in seinen needs aufnehmen — `skipped` ist für summary's filter ein non-success-Status und würde den Summary fehlschlagen lassen. Lösung: assert-goreleaser-fail wird in PR1 NICHT in `summary.needs` aufgenommen; Task 7 fügt es explizit AUS und Task X in 9b fügt es WIEDER hinzu.

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/integration.yml
```
Erwartet: keine neuen Errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "feat(integration): absorb goreleaser happy + fail (fail gated until 9b)"
```

---

## Task 6: helm-publish Jobs zu integration.yml

Übernimmt `caller-helm-publish-happy.yml` + `caller-helm-publish-fail.yml`.

**Files:**
- Modify: `.github/workflows/integration.yml` (nach den goreleaser Jobs aus Task 5)

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-goreleaser-fail:` (Task 5 Ende):

```yaml
  # ----- helm-publish happy path: dry-run publish of the helm-only fixture
  #       to a test OCI registry path. No actual push (dry_run: true). -----
  test-helm-publish:
    uses: ./.github/workflows/helm-publish.yml
    secrets: inherit
    with:
      chart_path: tests/fixtures/helm-only
      oci_registry: ghcr.io/serverkraken/test
      dry_run: true

  # ----- helm-publish failure path: fixture has a broken Chart.yaml. Atom
  #       must fail at helm lint / package step before any push attempt. -----
  test-helm-publish-fail:
    uses: ./.github/workflows/helm-publish.yml
    secrets: inherit
    with:
      chart_path: tests/fixtures/helm-broken
      oci_registry: ghcr.io/serverkraken/test
      dry_run: true

  assert-helm-publish-fail:
    needs: test-helm-publish-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify atom failed as expected
        env:
          RESULT: ${{ needs.test-helm-publish-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected helm-publish to fail for broken Chart.yaml, got result=$RESULT"
            exit 1
          fi
          echo "helm-publish correctly failed for broken Chart.yaml"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/integration.yml
```
Erwartet: keine neuen Errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "feat(integration): absorb helm-publish happy + fail callers"
```

---

## Task 7: Summary-Job zu integration.yml

Aggregat-Job der mit `if: always()` läuft und via `toJson(needs)` + jq überprüft, dass alle aufgenommenen Children `success` sind. **Aufgenommen werden:** alle happy-Jobs + alle `assert-*-fail` Jobs. **NICHT aufgenommen:** `test-*-fail` (designed-red) und die in Task 5 mit `if: false` gegateten goreleaser-fail-Jobs.

**Files:**
- Modify: `.github/workflows/integration.yml` (am Ende der jobs-Liste)

- [ ] **Step 1: Summary-Job ans Datei-Ende anhängen**

Direkt nach `assert-helm-publish-fail:` (Task 6 Ende), als letzter Job in der Datei:

```yaml
  # ----- Summary: aggregates ALL must-pass children into a single status.
  #       Branch-protection will require ONLY this check. Designed-red
  #       `test-*-fail` jobs are NOT in needs — only their assert-* siblings.
  #       goreleaser-fail siblings are excluded until Phase 9b unlocks them. -----
  summary:
    name: summary
    needs:
      - test-docker-build
      - assert-attestation-verifies
      - test-trivy-image-happy
      - assert-trivy-image-clean
      - test-trivy-fs-happy
      - test-trivy-fs-failure
      - assert-trivy-fs-finds-secrets
      - test-docker-build-cve
      - test-trivy-image-cve
      - assert-trivy-image-cve-finds-vulns
      - test-cleanup-images
      - assert-cleanup-images-fail
      - test-semantic-release-dry-run
      - test-onboard-dry-run
      - test-docker-build-multi
      - assert-docker-build-multi-fail
      - test-goreleaser
      # assert-goreleaser-fail: deliberately excluded — gated with `if: false` in PR1, re-added in PR2
      - test-helm-publish
      - assert-helm-publish-fail
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Aggregate child statuses
        env:
          NEEDS_JSON: ${{ toJson(needs) }}
        run: |
          set -euo pipefail
          failed=$(echo "$NEEDS_JSON" | jq -r '
            to_entries
            | map(select(.value.result != "success"))
            | .[].key
          ')
          if [[ -n "$failed" ]]; then
            echo "::error::Failing summary children:"
            while IFS= read -r line; do
              echo "  - $line"
            done <<< "$failed"
            exit 1
          fi
          echo "All required children passed (count=$(echo "$NEEDS_JSON" | jq 'keys | length'))."
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/integration.yml
```
Erwartet: keine Errors. Falls actionlint sich über `toJson(needs)` beschwert: das ist gültige GHA-Syntax, ggf. via `-shellcheck=` Filter ausschließen (existiert hier vermutlich nicht, weil das Bash-Block valide ist).

- [ ] **Step 3: Lokales Trockenrennen der jq-Pipeline**

```bash
echo '{"job-a":{"result":"success"},"job-b":{"result":"failure"}}' \
  | jq -r 'to_entries | map(select(.value.result != "success")) | .[].key'
```
Erwartet: `job-b`

Das verifiziert, dass die jq-Pipeline syntaktisch und semantisch korrekt ist, bevor sie auf den GHA-Runner geht.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "feat(integration): add summary aggregator job"
```

---

## Task 8: Permissions-Audit für integration.yml

Das heutige top-level `permissions:` Block deckt docker-build/trivy-*/semantic-release/onboard ab. Die neuen Atome (docker-build-multi, goreleaser, helm-publish) brauchen alle Permissions die das aktuelle Block schon hat (verifiziert via Atom-Headers im Audit). Trotzdem: einmal überfliegen, ob ein neuer Bedarf reingerutscht ist.

**Files:**
- Modify: `.github/workflows/integration.yml:17-24` (top-level `permissions:` block)

- [ ] **Step 1: Audit der neuen Atom-Permissions**

```bash
grep -A 10 "^permissions:" .github/workflows/docker-build-multi.yml .github/workflows/goreleaser.yml .github/workflows/helm-publish.yml
```

Erwartet:
- docker-build-multi: contents:read, packages:write, id-token:write, pull-requests:write
- goreleaser: contents:write, packages:write
- helm-publish: contents:read, packages:write

Alle bereits durch das integration.yml top-level Block abgedeckt (contents:write ist Superset von contents:read).

- [ ] **Step 2: integration.yml top-level Block prüfen**

Der heutige Block (Zeilen ~17-24):
```yaml
permissions:
  contents: write
  packages: write
  id-token: write
  security-events: write
  pull-requests: write
  issues: write
  actions: read
```

Wenn Schritt 1 keinen neuen Permission-Bedarf gezeigt hat, **keine Änderung** in diesem Task. Falls doch (z. B. wenn ein Atom-File aktualisiert wurde seit dem Audit-Sweep): Permission ergänzen.

- [ ] **Step 3: Kein Commit nötig falls keine Änderung**

Wenn Step 2 zu keiner Modifikation geführt hat: nichts zu committen.

Wenn doch:
```bash
git add .github/workflows/integration.yml
git commit -m "chore(integration): extend permissions for absorbed atoms"
```

---

## Task 9: self-ci.yml Skelett erstellen

Neue Datei mit Header (name, on, concurrency, permissions, leerer jobs-Block). Folge-Tasks füllen Jobs ein.

**Files:**
- Create: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Datei mit Skelett erstellen**

```yaml
# .github/workflows/self-ci.yml
# Aggregate self-CI wrapper: exercises every code-inspection atom (lint-*,
# test-*, vars-coercion, onboard-drift) against catalog fixtures. Each atom
# gets at least one happy-path job and (where applicable) a failure-path
# job with an assert-* sibling that uses if: always() to verify failure
# occurred. The summary job aggregates all must-pass children into a single
# status — designed-red `test-*-fail` jobs are EXCLUDED from summary needs,
# only their assert-* siblings are included.
#
# Sibling workflow: integration.yml (side-effects atoms: docker-build,
# trivy-*, semantic-release, onboard, goreleaser, helm-publish, etc.).
name: self-ci

on:
  pull_request:

# All atoms here are code-inspection only. No write permissions needed.
# packages:read is in case a test-* atom pulls a GHCR-hosted toolchain image.
permissions:
  contents: read
  packages: read

concurrency:
  group: self-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  # Jobs filled in Tasks 10-19.
  placeholder:
    if: false
    runs-on: ubuntu-latest
    steps:
      - run: echo "placeholder — replaced by Tasks 10-19"
```

Der `placeholder` Job verhindert dass actionlint einen "no jobs" Error wirft. Wird in Task 19 (Summary) endgültig entfernt.

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```
Erwartet: keine Errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): create wrapper skeleton (header + placeholder)"
```

---

## Task 10: lint-go Jobs zu self-ci.yml

Übernimmt `caller-lint-go-happy.yml` + `caller-lint-go-fail.yml`. Job-Names werden mit `-go` Suffix versehen, damit Cross-Atom-Namespacing klar bleibt (statt heutigem generischem `lint` / `assert-failed`).

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Vor dem `placeholder:` Job (in der jobs-Liste):

```yaml
  # ----- lint-go: happy + fail -----
  lint-go-happy:
    uses: ./.github/workflows/lint-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-happy

  test-lint-go-fail:
    uses: ./.github/workflows/lint-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-lint-fail

  assert-lint-go-fail:
    needs: test-lint-go-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.test-lint-go-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
          echo "lint-go-fail: correctly observed failure"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```
Erwartet: keine Errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb lint-go happy + fail callers"
```

---

## Task 11: lint-helm Jobs zu self-ci.yml

Übernimmt `caller-lint-helm-happy.yml` + `caller-lint-helm-fail.yml`. **Normalisierung:** fehlende success-echo im assert-Job (heute in caller-lint-helm-fail) wird hier ergänzt für Konsistenz mit den anderen lints.

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-lint-go-fail:` (Task 10 Ende):

```yaml
  # ----- lint-helm: happy + fail -----
  lint-helm-happy:
    uses: ./.github/workflows/lint-helm.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures
      charts_dir: helm-only

  test-lint-helm-fail:
    uses: ./.github/workflows/lint-helm.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test
      charts_dir: helm-lint-fail

  assert-lint-helm-fail:
    needs: test-lint-helm-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.test-lint-helm-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
          echo "lint-helm-fail: correctly observed failure"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb lint-helm happy + fail callers"
```

---

## Task 12: lint-python Jobs zu self-ci.yml

**Special:** lint-python-happy hat 3 parallele Sub-Jobs (poetry/uv/pip), je eigene Fixture. Alle 3 werden übernommen.

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-lint-helm-fail:` (Task 11 Ende):

```yaml
  # ----- lint-python: 3 happy paths (poetry/uv/pip) + fail -----
  lint-python-poetry-happy:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-poetry-happy

  lint-python-uv-happy:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-uv-happy

  lint-python-pip-happy:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-pip-happy

  test-lint-python-fail:
    uses: ./.github/workflows/lint-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-lint-fail

  assert-lint-python-fail:
    needs: test-lint-python-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.test-lint-python-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
          echo "lint-python-fail: correctly observed failure"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb lint-python (3 happy + fail) callers"
```

---

## Task 13: lint-rust Jobs zu self-ci.yml

Übernimmt `caller-lint-rust-happy.yml` + `caller-lint-rust-fail.yml`. Normalisierung: success-echo im assert ergänzt (analog zu Task 11).

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-lint-python-fail:` (Task 12 Ende):

```yaml
  # ----- lint-rust: happy + fail -----
  lint-rust-happy:
    uses: ./.github/workflows/lint-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-happy

  test-lint-rust-fail:
    uses: ./.github/workflows/lint-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-lint-fail

  assert-lint-rust-fail:
    needs: test-lint-rust-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert lint job failed
        env:
          RESULT: ${{ needs.test-lint-rust-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected lint job to fail, got: $RESULT"
            exit 1
          fi
          echo "lint-rust-fail: correctly observed failure"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb lint-rust happy + fail callers"
```

---

## Task 14: test-go Jobs zu self-ci.yml

Übernimmt `caller-test-go-happy.yml` + `caller-test-go-cov-fail.yml`.

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-lint-rust-fail:` (Task 13 Ende):

```yaml
  # ----- test-go: happy + cov-fail -----
  test-go-happy:
    uses: ./.github/workflows/test-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-happy
      coverage_threshold: 90

  test-test-go-cov-fail:
    uses: ./.github/workflows/test-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/go-cov-fail
      coverage_threshold: 90

  assert-test-go-cov-fail:
    needs: test-test-go-cov-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert test job failed
        env:
          RESULT: ${{ needs.test-test-go-cov-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected test job to fail (coverage gate), got: $RESULT"
            exit 1
          fi
          echo "test-go-cov-fail: correctly observed failure"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb test-go happy + cov-fail callers"
```

---

## Task 15: test-python Jobs zu self-ci.yml

3 happy + 1 cov-fail (analog zu lint-python in Task 12).

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-test-go-cov-fail:` (Task 14 Ende):

```yaml
  # ----- test-python: 3 happy paths (poetry/uv/pip) + cov-fail -----
  test-python-poetry-happy:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-poetry-happy
      coverage_threshold: 90

  test-python-uv-happy:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-uv-happy
      coverage_threshold: 90

  test-python-pip-happy:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-pip-happy
      coverage_threshold: 90

  test-test-python-cov-fail:
    uses: ./.github/workflows/test-python.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/python-cov-fail
      coverage_threshold: 90

  assert-test-python-cov-fail:
    needs: test-test-python-cov-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert test job failed
        env:
          RESULT: ${{ needs.test-test-python-cov-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected test job to fail (coverage gate), got: $RESULT"
            exit 1
          fi
          echo "test-python-cov-fail: correctly observed failure"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb test-python (3 happy + cov-fail) callers"
```

---

## Task 16: test-rust Jobs zu self-ci.yml

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-test-python-cov-fail:` (Task 15 Ende):

```yaml
  # ----- test-rust: happy + cov-fail -----
  test-rust-happy:
    uses: ./.github/workflows/test-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-happy
      coverage_threshold: 90

  test-test-rust-cov-fail:
    uses: ./.github/workflows/test-rust.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/lint-test/rust-cov-fail
      coverage_threshold: 90

  assert-test-rust-cov-fail:
    needs: test-test-rust-cov-fail
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Assert test job failed
        env:
          RESULT: ${{ needs.test-test-rust-cov-fail.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::expected test job to fail (coverage gate), got: $RESULT"
            exit 1
          fi
          echo "test-rust-cov-fail: correctly observed failure"
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb test-rust happy + cov-fail callers"
```

---

## Task 17: vars-coercion Job zu self-ci.yml

Übernimmt den Job-Block der in Task 2 aus integration.yml entfernt wurde. Originaler Kontext-Kommentar bleibt erhalten.

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `assert-test-rust-cov-fail:` (Task 16 Ende):

```yaml
  # ----- vars coercion: verify type=number + type=boolean inputs accept
  #       string-valued GHA expressions WRAPPED IN fromJSON(), which is
  #       what the SK_* override pattern emits in adopter ci.yml. The
  #       proof is structural: GHA's pre-flight schema check silently
  #       drops `uses:` jobs whose `with:` block assigns an unwrappable
  #       string expression to a typed input (empirically confirmed on
  #       PR #80 before the fromJSON wrap was introduced). So a passing
  #       `test-vars-coercion / test` job here IS the proof — if coercion
  #       were broken, this job wouldn't appear in the run at all.
  #
  #       The vars.NONEXISTENT_*_FOR_COERCION_TEST references intentionally
  #       point at variables that don't exist — the || fallback always
  #       fires, evaluating to a literal string ('70', 'false') which
  #       fromJSON() then coerces into the typed value the atom expects.
  test-vars-coercion:
    uses: ./.github/workflows/test-go.yml
    secrets: inherit
    with:
      working_directory: tests/fixtures/minimal-go
      go_version: '1.22'
      coverage_threshold: ${{ fromJSON(vars.NONEXISTENT_NUMBER_FOR_COERCION_TEST || '70') }}
      cgo_enabled: ${{ fromJSON(vars.NONEXISTENT_BOOL_FOR_COERCION_TEST || 'false') }}
```

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb vars-coercion job from integration.yml"
```

---

## Task 18: onboard-drift Job zu self-ci.yml

**Special:** caller-onboard-drift-happy.yml ist KEIN workflow_call — der "Atom-Caller" ist ein plain Job mit composite-action `./actions/onboard-drift`. Übernehme den Job 1:1 inkl. der inline-step für die Assertion.

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Block einfügen**

Direkt nach `test-vars-coercion:` (Task 17 Ende):

```yaml
  # ----- onboard-drift: exercises the composite action ./actions/onboard-drift
  #       against a known-clean fixture. Special-case: not a workflow_call
  #       caller — this is a plain runs-on job with an inline assertion
  #       step (the assert is not a sibling job). -----
  onboard-drift-happy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
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

- [ ] **Step 2: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): absorb onboard-drift happy caller"
```

---

## Task 19: Summary-Job zu self-ci.yml + placeholder entfernen

Analog zu Task 7 (integration.yml summary), aber mit den self-ci needs. **Aufgenommen:** alle happy-Jobs + alle `assert-*-fail` Jobs + `test-vars-coercion` + `onboard-drift-happy`. **NICHT aufgenommen:** alle `test-*-fail`/`test-test-*-cov-fail` (designed-red Children).

**Files:**
- Modify: `.github/workflows/self-ci.yml`

- [ ] **Step 1: Summary-Job ans Datei-Ende anhängen**

Direkt nach `onboard-drift-happy:` (Task 18 Ende):

```yaml
  # ----- Summary: aggregates ALL must-pass children into a single status.
  #       Branch-protection will require ONLY this check. Designed-red
  #       `test-*-fail` jobs are NOT in needs — only their assert-* siblings.
  summary:
    name: summary
    needs:
      - lint-go-happy
      - assert-lint-go-fail
      - lint-helm-happy
      - assert-lint-helm-fail
      - lint-python-poetry-happy
      - lint-python-uv-happy
      - lint-python-pip-happy
      - assert-lint-python-fail
      - lint-rust-happy
      - assert-lint-rust-fail
      - test-go-happy
      - assert-test-go-cov-fail
      - test-python-poetry-happy
      - test-python-uv-happy
      - test-python-pip-happy
      - assert-test-python-cov-fail
      - test-rust-happy
      - assert-test-rust-cov-fail
      - test-vars-coercion
      - onboard-drift-happy
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Aggregate child statuses
        env:
          NEEDS_JSON: ${{ toJson(needs) }}
        run: |
          set -euo pipefail
          failed=$(echo "$NEEDS_JSON" | jq -r '
            to_entries
            | map(select(.value.result != "success"))
            | .[].key
          ')
          if [[ -n "$failed" ]]; then
            echo "::error::Failing summary children:"
            while IFS= read -r line; do
              echo "  - $line"
            done <<< "$failed"
            exit 1
          fi
          echo "All required children passed (count=$(echo "$NEEDS_JSON" | jq 'keys | length'))."
```

- [ ] **Step 2: placeholder-Job entfernen**

Lösche den `placeholder:` Job-Block der in Task 9 als actionlint-Anker eingefügt wurde:
```yaml
  placeholder:
    if: false
    runs-on: ubuntu-latest
    steps:
      - run: echo "placeholder — replaced by Tasks 10-19"
```

- [ ] **Step 3: actionlint**

```bash
actionlint .github/workflows/self-ci.yml
```
Erwartet: keine Errors.

- [ ] **Step 4: Job-Count Verifikation**

```bash
grep -cE "^  [a-z][a-z-]+:$" .github/workflows/self-ci.yml
```
Erwartet: 28 Jobs (27 worker + 1 summary). Aufschlüsselung der 27 worker:
- lint-go: 3 (happy + test-fail + assert)
- lint-helm: 3
- lint-python: 5 (3 happy + test-fail + assert)
- lint-rust: 3
- test-go: 3 (happy + test-cov-fail + assert)
- test-python: 5 (3 happy + test-cov-fail + assert)
- test-rust: 3
- test-vars-coercion: 1
- onboard-drift-happy: 1
Wenn anders: prüfen ob ein Job fehlt oder doppelt da ist.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/self-ci.yml
git commit -m "feat(self-ci): add summary aggregator + remove placeholder"
```

---

## Task 20: PR1 verifizieren

Push, CI laufen lassen, Doppel-Validierung prüfen.

**Files:** keine

- [ ] **Step 1: Branch pushen**

```bash
git push -u origin feat/self-ci-aggregate-wrappers
```

- [ ] **Step 2: PR öffnen (draft)**

```bash
gh pr create --draft --title "feat(self-ci): add aggregate summary wrappers (phase 9a)" --body "$(cat <<'EOF'
## Summary
- Erweitert integration.yml um docker-build-multi, goreleaser (fail gated), helm-publish, cleanup-images-fail + summary-Job
- Erstellt neues self-ci.yml als Aggregator für lint-*, test-*, vars-coercion, onboard-drift + summary-Job
- Verschiebt vars-coercion Job aus integration.yml nach self-ci.yml
- ALLE 22 caller-*.yml bleiben unverändert (Doppel-Validierung). Cleanup in Phase 9b.

## Test plan
- [ ] Alle alten caller-* Checks grün (keine Regression im Atom-Verhalten)
- [ ] integration / summary grün
- [ ] self-ci / summary grün
- [ ] Designed-red Jobs (test-lint-*-fail, test-test-*-cov-fail, test-docker-build-multi-fail, test-cleanup-images-fail, test-helm-publish-fail) sichtbar rot, aber ihre assert-* Siblings grün
- [ ] goreleaser-fail-Job zeigt skipped (durch if: false, wird in 9b enabled)

Spec: docs/superpowers/specs/2026-05-27-phase-9-aggregate-caller-wrapper-design.md
Plan: docs/superpowers/plans/2026-05-27-phase-9a-add-wrappers.md
EOF
)"
```

- [ ] **Step 3: CI-Run abwarten und auswerten**

```bash
gh pr checks --watch
```

- [ ] **Step 4: Asymmetrie-Audit**

Vergleiche pro Atom: stimmt das Verhalten zwischen altem caller-* und neuem Wrapper-Job überein?

```bash
gh run list --workflow=self-ci.yml --limit 1 --json databaseId --jq '.[0].databaseId' \
  | xargs -I {} gh run view {} --json jobs \
  | jq -r '.jobs[] | "\(.conclusion // "running")\t\(.name)"' | sort
```

Vergleiche mit der entsprechenden alten caller-* Auflistung:

```bash
for name in caller-lint-go-happy caller-lint-go-fail; do
  gh run list --workflow=$name.yml --limit 1 --json conclusion,name \
    --jq '.[] | "\(.conclusion)\t\(.name)"'
done
```

Falls Asymmetrie (z. B. caller-lint-go-happy=success aber self-ci / lint-go-happy=failure): Job-Block in self-ci.yml korrigieren und nochmal pushen.

- [ ] **Step 5: PR aus Draft holen sobald grün**

```bash
gh pr ready
```

- [ ] **Step 6: Auf Soenne-Review warten**

PR1 ist additiv (kein File gelöscht); Revert ist sicher. Branch-Protection NICHT in diesem PR ändern — passiert nach Merge in Task 21.

---

## Task 21: Branch-Protection (post-merge)

**Nach Merge von PR1**: required_status_checks auf `main` setzen.

**Discovery:** Branch-Protection hatte vor PR1 KEINE required_status_checks. Phase 9 etabliert sie erstmals.

**Files:** keine (operativ via gh api)

- [ ] **Step 1: PR1 mergen**

```bash
gh pr merge --squash --auto
```

Oder UI-Merge nach Review.

- [ ] **Step 2: required_status_checks setzen**

```bash
gh api -X PATCH repos/serverkraken/reusable-workflows/branches/main/protection \
  -f required_status_checks.strict=true \
  -F required_status_checks.contexts[]="integration / summary" \
  -F required_status_checks.contexts[]="self-ci / summary"
```

Hinweis: PATCH (nicht PUT) damit andere Branch-Protection-Settings (linear_history etc.) erhalten bleiben. `-f` (string), `-F` (typed bzw. array).

Falls die Branch-Protection-API erfordert dass `required_status_checks` als komplettes Objekt gesetzt wird:
```bash
gh api -X PUT repos/serverkraken/reusable-workflows/branches/main/protection/required_status_checks \
  -F strict=true \
  -F contexts[]="integration / summary" \
  -F contexts[]="self-ci / summary"
```

- [ ] **Step 3: Verifikation**

```bash
gh api repos/serverkraken/reusable-workflows/branches/main/protection \
  --jq '.required_status_checks'
```

Erwartet:
```json
{
  "strict": true,
  "contexts": ["integration / summary", "self-ci / summary"]
}
```

- [ ] **Step 4: Spec/Plan-Annotation**

Edit `docs/superpowers/plans/2026-05-27-phase-9a-add-wrappers.md` (in main): Task 21 als done markieren mit Datum/Commit-Hash.

---

## Done-Criteria PR1

- [ ] integration.yml hat 4 neue Atom-Pairs (docker-build-multi, goreleaser mit `if: false`, helm-publish, cleanup-images-fail) + summary
- [ ] self-ci.yml existiert mit allen lint-/test-/drift-/vars-coercion-Jobs + summary
- [ ] vars-coercion ist NICHT mehr in integration.yml
- [ ] Alle 22 caller-*.yml UNVERÄNDERT
- [ ] CI grün: alle alten caller-Checks + integration/summary + self-ci/summary
- [ ] Branch-Protection setzt erstmals required_status_checks auf die zwei Summary-Checks
