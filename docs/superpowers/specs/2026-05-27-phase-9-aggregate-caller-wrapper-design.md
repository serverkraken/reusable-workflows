# Phase 9 — Aggregate Caller Wrapper (Design Spec)

**Datum:** 2026-05-27
**Quelle:** Memory `phase9-aggregate-caller-wrapper` (decided 2026-05-27 nach v4.2.1 Hotfix)
**Scope:** Tier-Split-Konsolidierung der 22 `caller-*.yml` Workflows in zwei aggregierende Self-CI-Wrapper mit Summary-Jobs.
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger)
**Vorgänger:** Phase 8 (PR #139, v4.2.0) + v4.2.1 Hotfix (PR #141, PR #142)

---

## 1. Goal

Die PR-Page eines Catalog-PRs zeigt heute ~22 Top-Level-Workflow-Suites (eine pro `caller-*.yml`), davon ~9 absichtlich rot (Failure-Path-Caller, die per Design fehlschlagen, damit das `assert-X-fail` Sibling-Job die Failure-Erwartung verifizieren kann). Der menschliche Reviewer kann auf einen Blick nicht unterscheiden zwischen "designed-red" und "real-red" und muss in jeden Check hineinklicken.

Phase 9 reduziert das auf **zwei Top-Level-Workflow-Suites** (`integration` und `self-ci`), jeweils mit einem `summary`-Job der gegen designed-red Sibling-Jobs immun ist. Branch-Protection verlangt nur noch zwei Required-Checks: `integration / summary` + `self-ci / summary`. Der Top-Level-PR-Status-Badge wird grün auch wenn intern designed-red-Jobs laufen, weil Summary nur die `assert-*` + happy-Jobs in `needs:` aufnimmt, nicht die `test-X-fail`-Jobs.

**Was sich NICHT reduziert:** die Gesamtzahl der Sub-Jobs bleibt ungefähr gleich (heute über 22 Workflows verteilt, morgen in 2 Workflows konzentriert). Reduziert wird die Anzahl unabhängiger Workflow-Suites am Top-Level der PR-Page und die Anzahl Required-Checks in Branch-Protection — beides sind die Vektoren, an denen "designed-red" heute visuell durchschlägt.

## 2. Scope

### Wrapper-Tier-Split

Regel hinter dem Boundary: **produziert das Atom Side-Effects (push, sign, release, GitHub-API write)? → integration.yml. Inspiziert es nur Code (lint, test, drift-check)? → self-ci.yml.**

#### `integration.yml` (bleibt, wird erweitert)

| Atom                        | Variant                          | Status                  |
|-----------------------------|----------------------------------|-------------------------|
| docker-build                | happy + CVE                      | existiert               |
| trivy-image                 | happy + CVE-finds-vulns          | existiert               |
| trivy-fs                    | happy + secret-find              | existiert               |
| cleanup-images              | happy                            | existiert               |
| cleanup-images              | fail                             | **neu (aus caller)**    |
| semantic-release            | dry-run                          | existiert               |
| onboard                     | dry-run                          | existiert               |
| docker-build-multi          | happy + fail                     | **neu (aus caller)**    |
| goreleaser                  | happy + fail (Fixture-Fix in PR2)| **neu (aus caller)**    |
| helm-publish                | happy + fail                     | **neu (aus caller)**    |
| `summary`                   | needs[*] aggregation             | **neu**                 |

Geschätzte ~18 Top-Level Jobs, ~500 Zeilen Datei.

#### `self-ci.yml` (neue Datei)

| Atom                        | Variant                          | Quelle                  |
|-----------------------------|----------------------------------|-------------------------|
| lint-go                     | happy + fail                     | caller-lint-go-{h,f}    |
| lint-helm                   | happy + fail                     | caller-lint-helm-{h,f}  |
| lint-python                 | happy + fail                     | caller-lint-python-{h,f}|
| lint-rust                   | happy + fail                     | caller-lint-rust-{h,f}  |
| test-go                     | happy + cov-fail                 | caller-test-go-{h,cf}   |
| test-python                 | happy + cov-fail                 | caller-test-python-{h,cf}|
| test-rust                   | happy + cov-fail                 | caller-test-rust-{h,cf} |
| vars-coercion               | (aus integration.yml verschoben) | integration.yml today   |
| onboard-drift               | happy                            | caller-onboard-drift-h  |
| `summary`                   | needs[*] aggregation             | **neu**                 |

Geschätzte ~15 Top-Level Jobs, ~450 Zeilen Datei.

### Caller-`*.yml` Fate

Alle 22 `caller-*.yml` Dateien werden in PR2 ersatzlos gelöscht. Ihr Inhalt lebt ab dann nur noch als Job-Block im jeweiligen Wrapper. Begründung: Single-Source-of-Truth pro Atom-Caller, kein Dead-Code, kein doppelter Wartungsort. Wer ein Atom ad-hoc triggern will, nutzt `workflow_dispatch` direkt auf dem Atom (z. B. `lint-go.yml`).

### Out of Scope

- **Composite-Action für Summary-Pattern.** Inline-bash + `toJson(needs)` reicht. Wenn beide `summary`-Job-Definitionen wirklich identisch werden, kann später in `actions/aggregate-summary/action.yml` extrahiert werden — YAGNI für jetzt.
- **Path-basierte Change-Detection.** Beide Wrapper laufen always-run auf `pull_request:` (konsistent zu heutigem integration.yml). `[skip ci]` bleibt der Escape-Hatch für Doc-only-Commits. Falls Runner-Kosten nachweislich problematisch werden, kann später dorny/paths-filter nachgerüstet werden.
- **Matrix-Driven Caller-Fan-Out.** GHA erlaubt keine matrix-Expressions in `jobs.<id>.uses:` (Workflow-Pfad muss static-resolvable sein). Selbst innerhalb eines Atoms ist Matrix unbrauchbar, weil ein matrix-Job-Result über alle Entries kollabiert und Downstream-Asserts sich nicht auf einzelne Entries beziehen können. → expliziter Fan-out pro Variante, wie integration.yml es heute macht.
- **Reduktion der Two-Job-Pattern-Sub-Jobs.** GHAs Spec-Limit (kein `continue-on-error` auf `uses:` Jobs) ist hart. Designed-red `test-X-fail` Jobs bleiben sichtbar — sie werden nur aus dem Summary ausgeschlossen, damit der Top-Level-Status grün ist.
- **Goreleaser-fail Fixture-Fix als separater PR.** Wird in PR2 mitgenommen, weil das Atom in derselben PR nach integration.yml zieht.
- **ARC-Pool-Konfigurationsänderungen** für leichtere Lint-Jobs (separate Concern, evtl. Phase 10).

## 3. Architecture

### 3.1 Summary-Job-Pattern (identisch in beiden Wrappern)

```yaml
summary:
  name: summary
  needs:
    - <happy-job-1>
    - <happy-job-2>
    - <assert-X-fail-job-1>
    - <assert-Y-fail-job-2>
    # NICHT in needs: test-X-fail, test-Y-fail (designed-red)
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
          echo "$failed" | sed 's/^/  - /'
          exit 1
        fi
        echo "All required children passed (count=$(echo "$NEEDS_JSON" | jq 'keys | length'))."
```

**Designaspekte:**

- `if: always()` ist notwendig, damit Summary auch bei Children-Failure läuft (Standardverhalten: ein needs-Child mit `failure` blockiert das needs-Folge-Job).
- `toJson(needs)` enumeriert alle needs-Children dynamisch. Ohne das müsste jeder Child-Name als `${{ needs.X.result }}` einzeln ge-templated werden — fehleranfällig bei Wachstum.
- `jq`-Pipeline filtert auf `result != "success"`. `result` kann sein: `success`, `failure`, `cancelled`, `skipped`. Cancelled und skipped sind ebenfalls Fail-Signale für den Aggregat-Status — keine Sonderbehandlung.
- `set -euo pipefail` für defensive Fehlerpropagierung im Bash-Block.
- `timeout-minutes: 5` — der Job tut nichts Externes, sollte in <30s fertig sein.

### 3.2 Two-Job-Pattern bleibt erhalten

Für Failure-Path-Caller (z. B. lint-go-fail):

```yaml
test-lint-go-fail:
  # Designed-red: das Atom MUSS fehlschlagen, weil die Fixture broken ist.
  # NICHT in summary.needs aufgenommen — sein Failure ist Erfolg.
  uses: ./.github/workflows/lint-go.yml
  secrets: inherit
  with:
    working_directory: tests/fixtures/lint-test/go-lint-fail

assert-lint-go-fail:
  # Verifiziert, dass test-lint-go-fail wirklich fehlgeschlagen ist.
  # IST in summary.needs aufgenommen.
  needs: test-lint-go-fail
  if: always()
  runs-on: ubuntu-latest
  steps:
    - name: Assert lint job failed
      env:
        RESULT: ${{ needs.test-lint-go-fail.result }}
      run: |
        if [[ "$RESULT" != "failure" ]]; then
          echo "::error::Expected lint-go failure, got: $RESULT"
          exit 1
        fi
        echo "lint-go correctly failed on broken fixture."
```

**Begründung:** GHAs Spec verbietet `continue-on-error` auf `jobs.<id>.uses:`. Das Two-Job-Pattern ist der bekannte Workaround (s. Memory `continue-on-error-not-supported-on-workflow-call-jobs`). Phase 9 ändert daran nichts — es macht das Pattern lediglich an der PR-Page-Oberfläche unsichtbar via Summary.

### 3.3 Concurrency

Beide Wrapper bekommen je eine eigene concurrency-group:

```yaml
# integration.yml (existiert heute)
concurrency:
  group: integration-${{ github.ref }}
  cancel-in-progress: true

# self-ci.yml (neu)
concurrency:
  group: self-ci-${{ github.ref }}
  cancel-in-progress: true
```

Separate Gruppen: ein Lint-Re-Push (cancelt nur `self-ci`) killt nicht laufende heavy-Jobs in `integration` (sign+attest mid-flight, ~10 min). Heutige caller-*.yml hatten implizite eigene Gruppen — Phase 9 konsolidiert sie atom-übergreifend zu zwei.

### 3.4 Permissions

Top-Level-Block pro Wrapper als Union der nested-call-Bedarfe (per Memory `chained-reusable-permissions`):

- **integration.yml**: behält heutige Liste (contents:write, packages:write, id-token:write, security-events:write, pull-requests:write, issues:write, actions:read) plus ggf. zusätzliche Bedarfe von goreleaser/helm-publish/docker-build-multi/cleanup-fail. Audit während PR1.
- **self-ci.yml**: minimal. `contents: read` für Checkout. `packages: read` falls test-* Atome GHCR-Bilder pullen müssen (zu verifizieren). KEIN write — self-ci.yml soll keine Side-Effects produzieren können.

### 3.5 Triggers

```yaml
# beide Wrapper
on:
  pull_request:
```

Kein `paths:`, kein `workflow_dispatch:`. Always-run wie heutiges integration.yml. Atome bleiben separat per `workflow_dispatch` auf ihrer eigenen Datei triggerbar — wir verlieren nichts.

## 4. Migration Plan

### PR1 — `feat(self-ci): add aggregate summary wrappers`

**Branch:** `feat/self-ci-aggregate-wrappers` (eigener Worktree)

**Diff-Umfang:** ca. 800 Zeilen +, 50 Zeilen − (kein caller-* gelöscht, nur additiv + 1 vars-coercion Block verschoben)

**Schritte (für Implementation-Plan):**

1. **integration.yml** — vars-coercion Job entfernen (wandert nach self-ci.yml)
2. **integration.yml** — docker-build-multi happy+fail Jobs hinzufügen (aus caller-docker-build-multi-*.yml übernehmen, working_directory/secrets/with korrekt mappen)
3. **integration.yml** — cleanup-images-fail Job hinzufügen (aus caller-cleanup-images-fail.yml)
4. **integration.yml** — goreleaser happy+fail Jobs hinzufügen (aus caller-goreleaser-*.yml übernehmen). NOTE: der fail-Job zeigt heute fixture-bedingt `success` statt `failure` (Atom-Fixture `tests/fixtures/cli-go-no-config/` enthält kein `.goreleaser.yaml`, aber moderne goreleaser-action generiert eine Default-Config aus `go.mod`). PR1 nimmt den Job in `summary.needs` aufgrund seines `assert-goreleaser-fail` Sibling-Jobs auf, der heute red-by-broken-fixture sein wird — daher MUSS PR1 entweder (a) den goreleaser-fail Block hinter ein `if: false` Flag setzen (in PR2 wieder aktiviert), oder (b) die Fixture-Reparatur in PR1 vorziehen. **Entscheidung im Implementation-Plan.**
5. **integration.yml** — helm-publish happy+fail Jobs hinzufügen (aus caller-helm-publish-*.yml)
6. **integration.yml** — `summary`-Job mit needs auf alle happy + assert-*-fail Jobs (NICHT test-*-fail) hinzufügen
7. **integration.yml** — permissions-Block auditieren und ggf. erweitern für die neu hinzugefügten Atome
8. **self-ci.yml** — neue Datei erstellen mit: pull_request-Trigger, concurrency-group `self-ci-${{ github.ref }}`, minimal-permissions
9. **self-ci.yml** — 8 lint-* Jobs (4 Atome × happy + fail) inkl. assert-*-fail Siblings
10. **self-ci.yml** — 6 test-* Jobs (3 Atome × happy + cov-fail) inkl. assert-*-cov-fail Siblings
11. **self-ci.yml** — vars-coercion Job (aus integration.yml übernehmen)
12. **self-ci.yml** — onboard-drift happy Job
13. **self-ci.yml** — `summary`-Job mit needs auf alle happy + assert-* Jobs
14. **caller-*.yml** — UNVERÄNDERT lassen (laufen parallel zur Validierung)

**Out-of-Band vor Merge von PR1:**
- `gh api -X PUT repos/serverkraken/reusable-workflows/branches/main/protection/required_status_checks` mit erweiterter Liste (alte per-caller-Checks + `integration / summary` + `self-ci / summary`)
- Verifikation via `gh api repos/.../branches/main/protection`

**Akzeptanzkriterien PR1:**
- Alle alten `caller-*` Checks weiterhin grün
- Beide neuen `summary`-Checks grün
- Designed-red Sibling-Jobs (`test-X-fail`) sind sichtbar rot, aber ihr Sibling `assert-X-fail` ist grün und der Top-Level-Summary ist grün

### PR2 — `chore(self-ci): remove obsolete caller-*.yml + goreleaser fixture fix`

**Branch:** `chore/self-ci-remove-callers` (eigener Worktree)

**Diff-Umfang:** ca. 22 Dateien gelöscht, ~5 Zeilen Fixture-Änderung, ~3 Zeilen Job-Definition-Update.

**Schritte (für Implementation-Plan):**

1. Alle 22 `caller-*.yml` Dateien löschen
2. `tests/fixtures/cli-go-no-config/.goreleaser.yaml` erstellen mit deliberat broken YAML (z. B. unbekannter Top-Level-Key, ungültiger Builds-Block — getestet mit lokalem `goreleaser check` damit der Fail-Modus stabil ist gegen goreleaser-action Auto-Defaults)
3. integration.yml goreleaser-fail Job — `if: false` Flag (falls in PR1 gesetzt) entfernen, sodass der Job wieder läuft und im Summary aufgenommen wird (working_directory bleibt `tests/fixtures/cli-go-no-config`)
4. Verifikation: PR2-CI-Run zeigt nur noch `integration / summary` + `self-ci / summary` als grüne Top-Level-Suites (und ggf. die seit-eh-vorhandenen drift-check / validate / etc., die NICHT Teil von Phase 9 sind)

**Out-of-Band vor Merge von PR2:**
- `gh api -X PUT .../required_status_checks` mit reduzierter Liste — alle per-caller-Checks entfernen, nur noch `integration / summary` + `self-ci / summary` (plus eventuell vorhandene unabhängige Checks wie `validate`, `drift-check`)

**Akzeptanzkriterien PR2:**
- Repo enthält keine `caller-*.yml` mehr
- `tests/fixtures/cli-go-no-config/` enthält neue Fixture, oder ist umbenannt zu `cli-go-bad-config/` (PR-Plan entscheidet)
- goreleaser-fail Job ist im aktuellen Run rot (test-*-fail) + sein assert-*-fail grün
- Branch-Protection-Required-Checks-Liste enthält nur noch die zwei Summary-Checks (plus unabhängige Workflows wie validate)

## 5. Rollback

### PR1
Rein additiv (kein caller-*.yml gelöscht, nur ein vars-coercion-Block von einer Datei in eine andere verschoben). Revert via `git revert <PR1-merge-commit>`. Branch-Protection-Update rückgängig: `gh api -X PUT` mit alter Required-Checks-Liste.

### PR2
Revert holt 22 caller-*.yml zurück und undoes goreleaser-Fixture-Änderung. Branch-Protection muss manuell zurück. Vars-coercion ist davon nicht betroffen (wurde in PR1 verschoben).

**Rollback-Skript für Branch-Protection** (zu erstellen in `scripts/phase9/restore-branch-protection.sh`, oder inline im Plan dokumentiert):

```bash
gh api -X PUT repos/serverkraken/reusable-workflows/branches/main/protection \
  -F required_status_checks.strict=true \
  -F required_status_checks.contexts[]="<alter-check-name-1>" \
  -F required_status_checks.contexts[]="<alter-check-name-2>" \
  ...
```

Vor PR1 die heutige `required_status_checks.contexts`-Liste sichern (z. B. in `docs/superpowers/specs/2026-05-27-branch-protection-snapshot.txt`).

## 6. Testing

### PR1 Validation
- **Doppelte Validierung** ist der Hauptmechanismus: alle 22 caller-* laufen weiter UND beide neuen Summaries laufen. Wenn das Verhalten der absorbierten Jobs in den Wrappern vom Verhalten in den caller-* abweicht (z. B. permissions falsch, secrets nicht inherited, working_directory falsch), wird das sofort sichtbar als asymmetrisches Pass/Fail zwischen alter und neuer Quelle.
- Vor PR1-Merge: PR1-Branch lokal pushen, CI laufen lassen, Asymmetrie-Audit:
  ```bash
  gh run view <run-id> --json jobs --jq '.jobs[] | select(.conclusion != "success") | .name'
  ```
  Falls Asymmetrien (etwa `caller-lint-go-happy: success`, `self-ci / lint-go-happy: failure`), Job-Definition korrigieren.

### PR2 Validation
- Nach Merge von PR1 + Branch-Protection-Erweiterung: nur noch die zwei Summary-Checks sind required.
- PR2 löscht caller-* — der CI-Run zeigt KEINE caller-* Checks mehr.
- Goreleaser-fail Job muss test-*-fail = `failure`, assert-*-fail = `success`, Summary = `success` zeigen.

### Manuelle Branch-Protection-Verifikation
Vor Merge jedes PRs:
```bash
gh api repos/serverkraken/reusable-workflows/branches/main/protection \
  --jq '.required_status_checks.contexts | sort'
```
Output muss erwarteten Required-Checks-Stand vor Merge zeigen.

## 7. Risiken

| Risiko | Wahrscheinlichkeit | Impact | Mitigation |
|--------|--------------------|--------|------------|
| Vergessenes Branch-Protection-Update vor PR2-Merge | mittel | hoch (alle Merges blockiert) | Plan dokumentiert die Operation explizit als Pre-Merge-Gate; gh-api-Snippet in PR2-Beschreibung kopieren |
| Permissions-Drift: neuer Job in integration.yml braucht write-Permission die nicht im top-level Block steht | mittel | mittel (Job fails-to-start mit klarer Fehlermeldung) | Schritt 7 in PR1 (Permissions-Audit) ist explizit; PR1 doppelt-validiert gegen caller-* zeigt sofort, ob der Job startet |
| Asymmetrie zwischen Wrapper-Job-Verhalten und caller-* Job-Verhalten | niedrig | niedrig (sofort sichtbar in PR1-Run) | Doppelte Validierung in PR1 ist der Mechanismus dagegen |
| Goreleaser-Fixture-Fix funktioniert nicht wie erwartet | niedrig | niedrig (fail-Job zeigt success in PR2 → CI rot bis korrigiert) | Fixture-Änderung lokal mit goreleaser CLI testen vor PR2-Push |
| ARC-Runner-Pool-Auslastung durch always-run der bisher path-gefilterten Lint-Atome | niedrig | niedrig | Lint-Atome sind 1–2 min; parallel; Pool autoskaliert; Beobachtung in den ersten 5 PRs nach PR2-Merge |
| `toJson(needs)` Output zu groß für GHA-Env-Var-Limit (>1 MB) bei vielen needs | sehr niedrig | niedrig | Maximal ~25 needs-Children pro Wrapper; jeder Eintrag ist ~100 Bytes serialized; Total <5 KB |

## 8. Out-of-Scope Side-Notes (vor PR1-Start klären)

- **`docs/operations.md` Working-Tree-Modifikation:** Beim Session-Start (2026-05-27) ist `docs/operations.md` modifiziert ohne Commit. Gehört NICHT zu Phase 9. Vor PR1-Worktree-Erstellung: entweder committen (separater Doc-Fix-Commit auf main), stashen oder verwerfen. Soenne entscheidet.
- **Sechs stale Worktrees:** `.worktrees/{docker-multi-perms, exclude-catalog, go-atoms-fix, go-cgo-toggle, sweep-pr-guard, v4.2.1-fixes}` — alle für gemergte PRs. Phase 9 braucht zwei NEUE Worktrees. Cleanup der alten via `git worktree remove <path>` vor Start ist sinnvoll, blockiert aber Phase 9 nicht.

## 9. Erfolgs-Kriterien (Gesamtphase)

Phase 9 ist fertig wenn:

1. `integration.yml` enthält alle Side-Effects-Atome inkl. Summary-Job
2. `self-ci.yml` existiert und enthält alle Code-Inspection-Atome inkl. Summary-Job
3. Kein `caller-*.yml` mehr im Repo
4. `tests/fixtures/cli-go-no-config/` ist repariert (oder umbenannt) sodass goreleaser-fail wirklich fehlschlägt
5. Branch-Protection Required-Checks für `main` enthält nur `integration / summary` + `self-ci / summary` (plus eventuell vorhandene independent-workflow-Checks)
6. Auf einer Beispiel-PR (z. B. nächste Hotfix-PR nach Phase 9): Top-Level-Status-Badge ist grün, ohne dass Reviewer in einzelne Checks hineinklicken muss
7. Memory `phase9-aggregate-caller-wrapper` ist auf "DONE YYYY-MM-DD" aktualisiert

---

**Nächster Schritt:** `writing-plans` Skill für Implementation-Plan-Erstellung. Plan wird zwei Teil-Pläne enthalten: `2026-05-27-phase-9a-add-wrappers.md` (PR1) und `2026-05-27-phase-9b-remove-callers.md` (PR2).
