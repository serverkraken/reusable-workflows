# Phase 2b — Test Coverage Expansion (Design Spec)

**Datum:** 2026-05-22
**Quelle:** `REVIEW-2026-05-22.md` HIGH-6, HIGH-7
**Scope:** `semantic-release.yml` dry-run input + integration tests for `semantic-release.yml` (happy) and `onboard.yml` (failure)
**Konsumiert von:** Implementation Plan (writing-plans next)
**Vorgänger:** Phase 2a (gemerged in 3.10.2), Phase 2c (gemerged separately)

---

## 1. Goal

Schließt zwei Coverage-Lücken aus dem Review:

- **HIGH-7**: `semantic-release.yml` ist als `workflow_call` deklariert, hat aber heute null Caller-Tests. Es ist das einzige Reusable Workflow im Katalog ohne jegliche Integration-Abdeckung (vgl. REVIEW § G.1).
- **HIGH-6**: `onboard.yml` (620 Zeilen, vier verschachtelte Jobs) hat heute nur einen Happy-Path Caller (`test-onboard-dry-run`). Keine Failure-Mode-Coverage trotz mehrerer realistischer Failure-Pfade (typo'd repo name, ambiguous language, etc.).

Beide Lücken werden geschlossen, ohne Production-Pfade zu verändern. Das wichtige Sub-Goal: `semantic-release.yml` muss real exerciert werden — kein Mock — aber ohne Tags zu pushen oder PRs zu öffnen.

## 2. Scope

### In Scope

| Concern | Findings | Outcome |
|---|---|---|
| **A. semantic-release dry-run support** | HIGH-7 (Teil 1) | Neuer `dry_run: boolean` Input in `semantic-release.yml`, der `skip-github-release` + `skip-github-pull-request` an die release-please-action durchreicht und den "move floating tags"-Step überspringt. |
| **B. semantic-release integration test** | HIGH-7 (Teil 2) | Neuer Job `test-semantic-release-dry-run` in `integration.yml`, der das Atom mit `dry_run: true` gegen die Katalog-eigenen release-please-Configs aufruft. |
| **C. onboard failure-caller** | HIGH-6 | Neue Jobs `test-onboard-failure` + `assert-onboard-failure` in `integration.yml`. Caller pointed at non-existent `target_repos`; Assertion verifiziert `needs.test-onboard-failure.result == 'failure'`. |

### Out of Scope

- Test-Fixture-Erweiterungen für onboard (cargo-workspace, pnpm-workspace HIGH-11) — eigener Plan (Phase 4)
- `*-fail` Caller automatisch laufen lassen (MED-13) — Phase 4
- `cleanup-images-fail` Caller (MED-14) — Phase 4
- `seed-onboarding-status.bats` (MED-15) — Phase 4
- `onboard-render.bats` golden_check für containerfile-only + release-eligibility-mixed (MED-12) — Phase 4
- `onboard-drift` Action-Wrapper-Test (M3) — Phase 4

## 3. Background

### 3.1 semantic-release.yml ist heute untestbar (HIGH-7)

`semantic-release.yml` callt `googleapis/release-please-action@v5`, das eine Wrapper-CLI für `release-please` ist. Bei Ausführung:
- Liest `release-please-config.json` + `.release-please-manifest.json`
- Analysiert Conventional Commits seit letztem Release
- Wenn ein Release fällig ist: öffnet/updated einen Release-PR
- Wenn ein Release-PR gerade gemerged wurde: erzeugt ein GitHub Release + Tag

Plus der Atom-Code (Step "Move floating major/minor tags") pusht `vN` und `vN.M` Tags via `git push --force` nach erfolgreichem Release.

Alle drei Mutationen (PR, Release, Tag-Push) sind echte Repo-Side-Effects. Auf jedem PR-CI-Run wäre das destruktiv. Das ist der Grund, warum das Atom heute nicht in `integration.yml` enthalten ist.

### 3.2 release-please-action v5 unterstützt `skip-*`-Flags

Verifiziert via `gh api repos/googleapis/release-please-action/contents/action.yml`:

```yaml
skip-github-release:
  description: 'if set to true, then do not try to tag releases'
  default: false
skip-github-pull-request:
  description: 'if set to true, then do not try to open pull requests'
  default: false
```

Beide Flags zusammen = die release-please-Logik läuft vollständig durch, aber **alle GitHub-API-Mutationen werden suppressed**. Das ist „real fidelity dry-run".

### 3.3 Bestehende `dry_run`-Konvention im Katalog

`onboard.yml` definiert bereits einen `dry_run: boolean = false` Input (sowohl `workflow_dispatch` als auch `workflow_call`). Bei `true` werden alle Side-Effects (Push, PR-Open, status-md-Update) übersprungen. Wird in `integration.yml` als `test-onboard-dry-run` mit `dry_run: true` verwendet. **`semantic-release.yml` mirror diese Konvention.**

### 3.4 onboard.yml Failure-Pfade (HIGH-6)

`scripts/onboard-detect.sh:84-88`:
```bash
if [[ -n "${TARGET_REPO:-}" ]]; then
  if ! default_branch=$(gh api "/repos/${TARGET_REPO}" -q '.default_branch' 2>/dev/null); then
    echo "::error::repo not accessible: $TARGET_REPO" >&2
    exit 1
  fi
```

Bei `target_repos` = non-existent owner/repo → `gh api` 404 → script exit 1 → onboard-Job kippt → der ganze Workflow-Call schlägt fehl. Klassischer Operator-Failure-Case (typo'd Repo-Name). Geeigneter Test-Trigger ohne Fixture-Setup.

## 4. Design per Concern

### 4.1 Concern A — semantic-release `dry_run` Input

#### A.1 Schema-Add in `.github/workflows/semantic-release.yml`

Im `inputs:`-Block neuen Input ergänzen (nach `release_please_manifest`, vor `outputs:`):

```yaml
      release_please_manifest:
        required: false
        type: string
        default: '.release-please-manifest.json'
      dry_run:
        description: |
          When true, run release-please without creating/updating a release PR,
          creating a GitHub release, or moving floating major/minor tags.
          Used by integration tests; production callers leave at false.
        required: false
        type: boolean
        default: false
    outputs:
```

#### A.2 Passthrough an release-please-action

Der `release`-Step bekommt zwei neue `with:`-Keys:

```yaml
      - uses: googleapis/release-please-action@v5
        id: release
        with:
          token: ${{ steps.app-token.outputs.token }}
          config-file: ${{ inputs.release_please_config }}
          manifest-file: ${{ inputs.release_please_manifest }}
          skip-github-release: ${{ inputs.dry_run }}
          skip-github-pull-request: ${{ inputs.dry_run }}
```

#### A.3 Tag-Push-Step überspringen

Der `Move floating major/minor tags`-Step bekommt die zusätzliche `!inputs.dry_run`-Bedingung:

```yaml
      - name: Move floating major/minor tags
        id: float
        if: |
          !inputs.dry_run &&
          steps.release.outputs.release_created == 'true' &&
          !contains(steps.release.outputs.tag_name, '-')
```

#### A.4 Job-Summary

Der `Job summary`-Step bleibt unverändert. Bei `dry_run=true` ist `steps.release.outputs.release_created` per definition `false` (skip-github-release verhindert das), daher feuert die `if:`-Bedingung des Summary-Steps natürlich nicht. Kein expliziter Eingriff nötig.

#### A.5 Outputs

`release_created`, `tag_name`, `major_tag`, `minor_tag` werden im Dry-Run-Mode entweder leer sein oder den theoretisch berechneten Wert enthalten — abhängig davon, was release-please-action bei `skip-*=true` als Output zurückgibt. **Wir asserten nicht auf diese Outputs in 2b** (für Caller im Production-Pfad bleiben die Outputs definiert). Sollte release-please bei skip-mode kein `release_created` setzen, sind die nested-Jobs in `release.yml` (`docker-build`, `trivy-image`) durch das `if: needs.semantic-release.outputs.release_created == 'true'` ohnehin korrekt geguarded.

### 4.2 Concern B — semantic-release integration test

Neuer Job in `integration.yml` (eingeordnet nach `test-cleanup-images`, vor `test-onboard-dry-run`):

```yaml
  # ----- semantic-release dry-run: exercise the atom against the catalog's
  #       own release-please configs WITHOUT mutating remote state.
  #       skip-github-release + skip-github-pull-request flags on the
  #       release-please-action prevent PR/release/tag mutations. The
  #       atom-level !dry_run guard on the "Move floating major/minor tags"
  #       step prevents the git push --force --tags. So this job exercises
  #       app-token mint, checkout, release-please logic, and output wiring
  #       without any production side-effects.
  test-semantic-release-dry-run:
    uses: ./.github/workflows/semantic-release.yml
    secrets: inherit
    with:
      dry_run: true
```

Keine `with: release_please_config: …` / `release_please_manifest: …` — die Defaults zeigen auf die Katalog-eigenen Files an Repo-Root. Das ist Absicht: wir testen das Atom gegen reale, produktive Configs (kein Fixture-Sandbox-Risiko, dass das Fixture sich vom Production-Schema unterscheidet).

Keine Assertion-Job: das grün-Laufen IST der Test. Wenn `semantic-release.yml` jemals regressiert (z.B. App-Token-Mint bricht durch Action-Major-Bump, ein Schritt timeoutet, etc.), schlägt dieser Job fehl.

### 4.3 Concern C — onboard failure-caller

Zwei neue Jobs in `integration.yml` (eingeordnet nach `test-onboard-dry-run`, vor `test-vars-coercion`):

```yaml
  # ----- onboard failure path: target_repos points at a non-existent repo,
  #       script must fail fast at the gh api lookup. Tests the operator-typo
  #       case that's the most common failure mode in production dispatch.
  test-onboard-failure:
    uses: ./.github/workflows/onboard.yml
    with:
      target_repos: serverkraken/phase-2b-nonexistent-fixture
      language: auto
      dry_run: true
      pin_version: v3
    secrets: inherit
    continue-on-error: true

  assert-onboard-failure:
    needs: test-onboard-failure
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify onboard failed for non-existent repo
        env:
          RESULT: ${{ needs.test-onboard-failure.result }}
        run: |
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::Expected onboard to fail for non-existent target_repos, got result=$RESULT"
            exit 1
          fi
          echo "onboard correctly failed for non-existent repo"
```

`continue-on-error: true` auf dem reusable-workflow-Caller-Job ist von GHA unterstützt (workflow_call-Jobs respektieren das Field genauso wie normale Jobs).

`if: always()` auf dem assert-Job ist nötig: ohne diesen Wert würde GHA den assert-Job skippen sobald sein `needs:`-Dependency `failure` reportet.

`pin_version: v3` (statt v1) — die Default wurde in Phase 2a (PR #92) auf v3 gehoben. Hier explizit gesetzt für Klarheit und Insulation gegen Future-Default-Änderungen.

`dry_run: true` ist hier ein Defensiv-Mechanismus: selbst wenn das non-existent-repo-Detection irgendwie nicht greift, würde der dry-run-Pfad keinen PR im (nicht-existierenden) Target-Repo öffnen wollen.

### 4.4 Repo-Name-Disclaimer

`serverkraken/phase-2b-nonexistent-fixture` ist absichtlich gewählt:
- Klar als Test-Marker erkennbar
- Niemals als echtes Repo angelegt (kein Risk dass jemand es versehentlich erstellt → Test silent grün)
- Per Naming-Convention klar als Phase-2b-Artefakt erkennbar

## 5. Interface Contracts

| File | Change-Class | Caller-Breaking? |
|---|---|---|
| `semantic-release.yml` | Additive Input (`dry_run`, default `false`) | NEIN — alle existierenden Caller (catalog-release.yml, release.yml) bekommen Default `false` = bisheriges Verhalten |
| `integration.yml` | Additive Jobs | NEIN — bestehende Jobs unverändert |
| `onboard.yml` | UNVERÄNDERT | — |

Commit-Class: `feat(semantic-release): add dry_run input` (PR-H), `test(integration): add onboard failure-path coverage` (PR-I). PR-H löst einen Minor-Bump aus (additive Feature), PR-I ist non-versioning (`test:` ist neutral im default release-please mapping).

## 6. Test Strategy

Drei neue Test-Surfaces:
- **PR-H/Concern B**: `test-semantic-release-dry-run` Job muss grün laufen — semantic-release-Atom-Exec-Path validiert.
- **PR-I/Concern C**: `test-onboard-failure` Job muss `failure` reporten (continue-on-error catches), `assert-onboard-failure` Job validiert das.
- Existing: alle anderen Integration-Tests bleiben unverändert.

Plus passive Verification durch CI:
- `actionlint`/`yamllint` clean auf beiden geänderten files
- `validate.yml` (catalog self-CI) grün

## 7. PR Plan

**PR-H — `feat/semantic-release-dry-run`**
- **Worktree:** `.worktrees/semantic-release-dry-run`
- **Files:** `.github/workflows/semantic-release.yml` (Schema-Add), `.github/workflows/integration.yml` (neuer Job)
- **Commits:** 2 (eines fürs Atom, eines fürs integration-test) — saubere Trennung von Atom-Change und Test-Add
  - `feat(semantic-release): add dry_run input for integration tests`
  - `test(integration): add semantic-release dry-run coverage`

**PR-I — `test/onboard-failure-caller`**
- **Worktree:** `.worktrees/onboard-failure-caller`
- **Files:** `.github/workflows/integration.yml` (neue 2 Jobs)
- **Commits:** 1
  - `test(integration): add onboard failure-path coverage`

**Reihenfolge:** PR-H zuerst (Atom-Change ist konzeptuell upstream), dann PR-I rebase + merge.

**File-Overlap-Risk:** beide PRs editieren `integration.yml`. Beim zweiten Merge: wahrscheinlich Append-Conflict (beide hängen Jobs am Ende des Files an). Strategie wie Phase 1 mit `onboard-detect.bats`-Conflict: manuell resolven, force-push, re-merge.

PR-Body-Style: kein Claude-Attribution-Footer (Memory: `feedback_pr_style`).

## 8. Acceptance Criteria

- [ ] PR-H merged: `semantic-release.yml` hat `dry_run` Input. `test-semantic-release-dry-run` Job in `integration.yml` läuft grün.
- [ ] PR-I merged: `test-onboard-failure` + `assert-onboard-failure` Jobs in `integration.yml`. `test-onboard-failure` reportet `failure`, `assert-onboard-failure` reportet `success` (catches the expected failure).
- [ ] `actionlint`/`yamllint` clean auf allen geänderten files.
- [ ] Bestehende Production-Workflows unverändert: `catalog-release.yml` und `release.yml` (die `semantic-release.yml` callen) bekommen weiterhin Default `dry_run: false` und verhalten sich byte-identisch.
- [ ] `release-please` PR (nach merge): Patch-Bump für PR-I (`test:`), Minor-Bump für PR-H (`feat:`), oder als kombinierter Minor-Bump wenn beide gemeinsam.

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `release-please-action@v5` setzt im skip-mode keinen `tag_name` Output → `release_created` ist leer → nested `if: needs.semantic-release.outputs.release_created == 'true'` Guards in `release.yml` halten korrekt | Low | Spec § A.5 dokumentiert das; production-pfad weiterhin korrekt geguarded; integration-test assertet nicht auf Outputs |
| `continue-on-error: true` auf reusable-workflow-Caller-Job nicht von GHA unterstützt | Low | Plan dokumentiert Fallback: wenn nicht unterstützt, dann den failure in einem eigenen wrapper-Job (via `gh workflow run` + polling) provozieren. Aber: Field IST von GHA für composite und workflow_call Jobs unterstützt seit 2022, sollte funktionieren |
| `serverkraken/phase-2b-nonexistent-fixture` Repo wird versehentlich angelegt → Test silent grün | Very Low | Disclaimer im Comment + im PR-Body |
| skip-github-pull-request + offener Release-PR im catalog → release-please-action versucht den PR nicht zu updaten, was er normalerweise täte → keine sichtbare Auswirkung, da skip-mode | Negligible | Erwartetes Verhalten; Comment im integration.yml-Job dokumentiert das |

## 10. Open Questions

Keine. Alle Entscheidungspunkte aus dem Brainstorming sind fixiert:

1. ✓ Mocking-Strategie: dry_run Input (statt no-op-only oder both)
2. ✓ 2 separate PRs (semantic-release Atom-Change + onboard test-only)
3. ✓ semantic-release-Test gegen Katalog-Configs (keine Fixture-Sandbox)
4. ✓ onboard-Failure-Trigger: non-existent target_repos (statt invalid language)
