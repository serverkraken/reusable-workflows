# Phase 9b — Remove Caller Workflows + Goreleaser Fixture Fix (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cleanup nach erfolgreicher PR1 (Phase 9a). Löscht die 22 `caller-*.yml` Workflows, repariert die `tests/fixtures/cli-go-no-config` Goreleaser-Fixture so dass das Atom wirklich fehlschlägt (gegen modern-goreleaser-action Auto-Default), und entfernt das `if: false` Gate auf den goreleaser-fail Jobs in integration.yml.

**Architecture:** Reine Subtraktion auf der Self-CI-Seite (caller-*.yml weg) plus eine kleine Fixture-Reparatur. Branch-Protection wird ggf. nachjustiert wenn alte caller-Checks als required eingetragen sind (war zum Zeitpunkt von 9a-Start nicht der Fall — Verifikation siehe Task 1).

**Tech Stack:** GitHub Actions YAML, goreleaser CLI (lokal zur Fixture-Validierung), `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-05-27-phase-9-aggregate-caller-wrapper-design.md`

**Prerequisites:** PR1 von Phase 9a ist gemerged (siehe `2026-05-27-phase-9a-add-wrappers.md` Task 21). Bevor PR2 startet, muss main den Stand "integration.yml + self-ci.yml laufen, summary-Checks sind required, alle 22 caller-*.yml laufen parallel" haben.

---

## File Structure

**Delete:** alle 22 `.github/workflows/caller-*.yml`

**Modify:**
- `.github/workflows/integration.yml`: drei `if: false` Lines auf den goreleaser-fail Jobs entfernen, `assert-goreleaser-fail` zu `summary.needs` hinzufügen
- `tests/fixtures/cli-go-no-config/.goreleaser.yaml`: neue Datei mit deliberat broken YAML, sodass goreleaser-action ein Failure produziert auch wenn es Default-Config aus go.mod generiert

**Optionally Modify:** Branch-Protection auf main (nur falls alte caller-Checks dort gelandet sind — Verifikation in Task 1)

---

## Task 1: Worktree-Setup + Prerequisites-Check

**Files:** keine

- [ ] **Step 1: Verifiziere PR1 ist gemerged**

```bash
git fetch origin main
git log origin/main --oneline -10 | grep -E "phase 9|self-ci|aggregate" || echo "WARN: PR1 commits not visible in last 10"
```

Mindestens ein Commit von PR1 (`feat(self-ci): add aggregate summary wrappers (phase 9a)` o. ä.) sollte in den letzten 10 main-Commits sichtbar sein.

- [ ] **Step 2: Verifiziere PR1-Stand: beide Wrapper-Dateien existieren auf main**

```bash
git show origin/main:.github/workflows/self-ci.yml | head -5
git show origin/main:.github/workflows/integration.yml | grep -A 1 "summary:"
```

Beide müssen erfolgreich Inhalte zeigen.

- [ ] **Step 3: Branch-Protection-Status prüfen**

```bash
gh api repos/serverkraken/reusable-workflows/branches/main/protection \
  --jq '.required_status_checks'
```

Erwartet (nach Task 21 von 9a): `{"strict": true, "contexts": ["integration / summary", "self-ci / summary"]}`

Falls noch alte caller-*-Checks drin: notieren, dass sie in Task 6 entfernt werden.

- [ ] **Step 4: Worktree erstellen**

```bash
git worktree add /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/phase-9b chore/self-ci-remove-callers
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows/.worktrees/phase-9b
```

- [ ] **Step 5: Verifiziere goreleaser CLI lokal**

```bash
goreleaser --version
```

Brauchen wir in Task 2 für Fixture-Validierung. Falls nicht installiert: `brew install goreleaser`.

---

## Task 2: Goreleaser-Fixture reparieren

Fügt ein deliberat broken `.goreleaser.yaml` zur Fixture hinzu. Das stellt sicher dass goreleaser auch mit Auto-Default-Generierung fehlschlägt, weil eine explizit vorhandene aber broken Config-Datei Vorrang hat vor Auto-Generierung.

**Files:**
- Create: `tests/fixtures/cli-go-no-config/.goreleaser.yaml`

Hinweis: Die Fixture heißt weiterhin `cli-go-no-config` — das ist ein lokaler Misnomer (sie HAT jetzt eine Config), aber Umbenennung würde alle Pfad-Referenzen aktualisieren erfordern. YAGNI.

- [ ] **Step 1: .goreleaser.yaml erstellen mit deliberat broken Inhalt**

```yaml
# Deliberately broken: this fixture exists to verify the goreleaser atom
# fails when given an unparseable config. The unknown top-level key
# `definitely_not_a_valid_key` and the `version: 99` (no such schema
# version exists) both trigger goreleaser config-validation failure.
version: 99
definitely_not_a_valid_key: true
builds:
  - id: cli
    binary: cli
    main: ./main.go
    targets:
      - this/is/not/a/valid/target
```

- [ ] **Step 2: Lokale Validierung dass goreleaser wirklich fehlschlägt**

```bash
cd tests/fixtures/cli-go-no-config
goreleaser check 2>&1 || echo "EXPECTED: goreleaser check failed (exit code $?)"
cd -
```

Erwartet: `goreleaser check` exitet non-zero mit einem Config-Parse oder Schema-Error.

Falls `goreleaser check` unerwartet success liefert: Inhalt anpassen bis ein stabiles Failure entsteht. Mögliche Anpassungen:
  - `version: 99` → `version: -1`
  - oder ein `release:` Block mit nicht-existierender Sub-Property einfügen
  - oder einen `before:` hook mit einem `hooks:` Sub-Key der kein gültiges Format hat

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/cli-go-no-config/.goreleaser.yaml
git commit -m "fix(fixtures): break cli-go-no-config goreleaser config for fail-path"
```

---

## Task 3: goreleaser-fail `if: false` Gate aus integration.yml entfernen

**Files:**
- Modify: `.github/workflows/integration.yml` (zwei `if: false   # PHASE-9B-ENABLES-AFTER-FIXTURE-FIX` Stellen)

- [ ] **Step 1: Marker im File finden**

```bash
grep -n "PHASE-9B-ENABLES-AFTER-FIXTURE-FIX" .github/workflows/integration.yml
```

Erwartet: 2 Treffer (einer auf test-goreleaser-fail, einer auf assert-goreleaser-fail).

Hinweis: assert-goreleaser-fail braucht NACH Entfernung des if: false ein `if: always()` (sonst läuft assert nicht wenn test fail-by-design).

- [ ] **Step 2: test-goreleaser-fail Block reparieren**

Suche im File:
```yaml
  test-goreleaser-fail:
    if: false   # PHASE-9B-ENABLES-AFTER-FIXTURE-FIX
    uses: ./.github/workflows/goreleaser.yml
```

Ersetzen mit:
```yaml
  test-goreleaser-fail:
    uses: ./.github/workflows/goreleaser.yml
```

- [ ] **Step 3: assert-goreleaser-fail Block reparieren**

Suche im File:
```yaml
  assert-goreleaser-fail:
    needs: test-goreleaser-fail
    # Phase 9b: replace `if: false` with `if: always()` (required so the assert
    # runs when test-goreleaser-fail fails-by-design once the fixture is fixed).
    if: false   # PHASE-9B-ENABLES-AFTER-FIXTURE-FIX
    runs-on: ubuntu-latest
```

Ersetzen mit:
```yaml
  assert-goreleaser-fail:
    needs: test-goreleaser-fail
    if: always()
    runs-on: ubuntu-latest
```

Die zwei Kommentar-Zeilen werden mit dem `if: false` zusammen entfernt — die Phase-9a-Anweisung an Phase 9b ist erfüllt, sobald `if: always()` an seiner Stelle steht.

- [ ] **Step 4: `assert-goreleaser-fail` zu `summary.needs` hinzufügen**

Im `summary:` Block der integration.yml, in der `needs:` Liste, die Zeile:
```yaml
      # assert-goreleaser-fail: deliberately excluded — gated with `if: false` in PR1, re-added in PR2
```
ersetzen mit:
```yaml
      - assert-goreleaser-fail
```

- [ ] **Step 5: actionlint**

```bash
actionlint .github/workflows/integration.yml
```
Erwartet: keine Errors.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "feat(integration): re-enable goreleaser-fail jobs after fixture fix"
```

---

## Task 4: 22 caller-*.yml Dateien löschen

**Files:**
- Delete: alle 22 `.github/workflows/caller-*.yml`

- [ ] **Step 1: Liste der zu löschenden Files verifizieren**

```bash
ls .github/workflows/caller-*.yml
```

Erwartet: genau 22 Dateien. Falls weniger oder mehr: notieren und nur die im Plan dokumentierten 22 löschen.

Erwartete Liste (alphabetisch):
- caller-cleanup-images-fail.yml
- caller-docker-build-multi-fail.yml
- caller-docker-build-multi-happy.yml
- caller-goreleaser-fail.yml
- caller-goreleaser-happy.yml
- caller-helm-publish-fail.yml
- caller-helm-publish-happy.yml
- caller-lint-go-fail.yml
- caller-lint-go-happy.yml
- caller-lint-helm-fail.yml
- caller-lint-helm-happy.yml
- caller-lint-python-fail.yml
- caller-lint-python-happy.yml
- caller-lint-rust-fail.yml
- caller-lint-rust-happy.yml
- caller-onboard-drift-happy.yml
- caller-test-go-cov-fail.yml
- caller-test-go-happy.yml
- caller-test-python-cov-fail.yml
- caller-test-python-happy.yml
- caller-test-rust-cov-fail.yml
- caller-test-rust-happy.yml

- [ ] **Step 2: Löschen via git rm**

```bash
git rm .github/workflows/caller-*.yml
```

- [ ] **Step 3: Verifiziere dass nichts anderes mit "caller-" beginnt**

```bash
ls .github/workflows/caller-* 2>&1 | grep -v "No such" && echo "WARN: noch caller-* übrig"
```
Erwartet: kein Match (oder die WARN-Zeile zeigt nichts).

- [ ] **Step 4: Suche nach Referenzen auf caller-* in der gesamten Codebase**

```bash
rg "caller-" --type-add 'workflow:*.{yml,yaml}' -tworkflow -tmd .github docs scripts README.md CONTRIBUTING.md 2>/dev/null
```

Erwartet: ggf. ein paar Treffer in docs/ oder README — diese ggf. updaten oder als pre-existing-stale notieren. KEINE Treffer in `.github/workflows/` (außer in dieser Plan-Datei selbst, die ist nicht im Filter).

Wenn doc-Referenzen auftauchen: in einem separaten Commit (nicht in diesem PR) updaten, oder hier als Step ergänzen falls scope-passend.

- [ ] **Step 5: actionlint über `.github/workflows/` komplett**

```bash
actionlint .github/workflows/*.yml
```

Erwartet: keine neuen Errors. Falls actionlint sich über fehlende caller-* Files beschwert (z. B. wenn ein anderer Workflow `uses:` auf einen caller-* macht): das wäre ein dependency-Bug, nicht erwartet.

- [ ] **Step 6: Commit**

```bash
git commit -m "chore(self-ci): remove 22 obsolete caller-*.yml workflows"
```

---

## Task 5: PR2 verifizieren

**Files:** keine

- [ ] **Step 1: Branch pushen**

```bash
git push -u origin chore/self-ci-remove-callers
```

- [ ] **Step 2: PR öffnen (draft)**

```bash
gh pr create --draft --title "chore(self-ci): remove obsolete caller-*.yml + goreleaser fixture fix (phase 9b)" --body "$(cat <<'EOF'
## Summary
- Löscht 22 caller-*.yml Workflows; Logik lebt seit PR1 (#PR1-NR) in integration.yml + self-ci.yml
- Repariert tests/fixtures/cli-go-no-config/.goreleaser.yaml (broken YAML) damit goreleaser-fail-Path wirklich fehlschlägt gegen Auto-Default-Behavior
- Aktiviert goreleaser-fail Jobs in integration.yml (entfernt if: false Gate aus PR1)
- Fügt assert-goreleaser-fail zu summary.needs hinzu

## Test plan
- [ ] integration / summary grün (jetzt mit aktiviertem goreleaser-fail-Pair)
- [ ] self-ci / summary grün
- [ ] test-goreleaser-fail Job zeigt failure (designed-red), assert-goreleaser-fail zeigt success
- [ ] Keine caller-* Workflow-Suites mehr auf der PR-Page
- [ ] Top-Level-PR-Status-Badge grün

Spec: docs/superpowers/specs/2026-05-27-phase-9-aggregate-caller-wrapper-design.md
Plan: docs/superpowers/plans/2026-05-27-phase-9b-remove-callers.md
Follows: PR #PR1-NR (Phase 9a)
EOF
)"
```

PR1-NR vor dem Erstellen aus `gh pr list --state merged --limit 5` ermitteln und in den Body einsetzen.

- [ ] **Step 3: CI-Run abwarten**

```bash
gh pr checks --watch
```

- [ ] **Step 4: Verifiziere goreleaser-fail-Verhalten**

```bash
gh run list --workflow=integration.yml --limit 1 --json databaseId --jq '.[0].databaseId' \
  | xargs -I {} gh run view {} --json jobs \
  | jq -r '.jobs[] | select(.name | contains("goreleaser")) | "\(.conclusion)\t\(.name)"'
```

Erwartet:
```
failure  test-goreleaser-fail
success  assert-goreleaser-fail
success  test-goreleaser
```

Falls test-goreleaser-fail = success: Fixture funktioniert nicht wie geplant, Task 2 nochmal mit härterem broken-Inhalt.

- [ ] **Step 5: Workflow-Suite-Count auf der PR-Page**

```bash
gh pr view --json statusCheckRollup --jq '.statusCheckRollup | length'
```

Erwartet: deutlich weniger als vor PR1. Konkrete Zahl hängt von unabhängigen Workflows (validate, drift-check, etc.) ab — sollte aber 22 caller-* nicht mehr enthalten.

```bash
gh pr view --json statusCheckRollup --jq '.statusCheckRollup[] | .name' | grep -c "caller-" || echo "0"
```

Erwartet: `0`

- [ ] **Step 6: PR aus Draft holen sobald grün**

```bash
gh pr ready
```

---

## Task 6: Branch-Protection final aufräumen (falls nötig)

**Files:** keine (operativ via gh api)

- [ ] **Step 1: Prüfen ob alte caller-Checks in Required-Liste**

```bash
gh api repos/serverkraken/reusable-workflows/branches/main/protection \
  --jq '.required_status_checks.contexts[] | select(contains("caller-"))'
```

Erwartet: leere Ausgabe (war zum Phase-9a-Start nicht der Fall — siehe Task 1).

Falls Treffer: in Step 2 entfernen.

- [ ] **Step 2 (nur wenn Step 1 Treffer): caller-Checks aus Required-Liste entfernen**

```bash
# Aktuelle Liste lesen, caller-* filtern, neue Liste zurückschreiben
NEW_CONTEXTS=$(gh api repos/serverkraken/reusable-workflows/branches/main/protection \
  --jq '.required_status_checks.contexts | map(select(contains("caller-") | not))')

echo "Neue Required-Liste:"
echo "$NEW_CONTEXTS" | jq

# Mit Sicherheit überschreiben:
gh api -X PUT repos/serverkraken/reusable-workflows/branches/main/protection/required_status_checks \
  -F strict=true \
  -F "contexts=$(echo $NEW_CONTEXTS | jq -c '.')"
```

- [ ] **Step 3: Verifikation**

```bash
gh api repos/serverkraken/reusable-workflows/branches/main/protection \
  --jq '.required_status_checks'
```

Erwartet: nur `integration / summary` + `self-ci / summary` (+ ggf. validate / drift-check wenn die als unabhängige Required-Checks gewünscht sind, separate Entscheidung).

---

## Task 7: PR2 mergen + Memory aktualisieren

**Files:**
- Modify: `/Users/msoent/.claude/projects/-Users-msoent-SourceCode-serverkraken-reusable-workflows/memory/reference_phase9_aggregate_caller_wrapper.md`

- [ ] **Step 1: PR2 mergen**

```bash
gh pr merge --squash --auto
```

Oder UI-Merge nach Review.

- [ ] **Step 2: Memory aktualisieren — Status auf DONE**

Im Memory-File ergänzen am Anfang (vor "After PR #141..."):

```markdown
**DONE 2026-MM-DD** — Phase 9 abgeschlossen via PR-9A (#XXX) + PR-9B (#YYY).
- integration.yml: 8 Side-Effects-Atome + summary
- self-ci.yml: 8 Code-Inspection-Atome (inkl. onboard-drift composite + vars-coercion) + summary
- 22 caller-*.yml gelöscht
- goreleaser-Fixture repariert (broken .goreleaser.yaml in cli-go-no-config)
- Branch-protection: required_status_checks = ["integration / summary", "self-ci / summary"]
```

Plus eine Zeile in MEMORY.md ergänzen (oder die phase9-Zeile aktualisieren):

```markdown
- [Phase 9 — aggregate caller wrapper (DONE 2026-MM-DD)](reference_phase9_aggregate_caller_wrapper.md) — replaced 22 per-caller status checks with one summary per wrapper.
```

- [ ] **Step 3: Worktrees aufräumen**

```bash
cd /Users/msoent/SourceCode/serverkraken/reusable-workflows
git worktree remove .worktrees/phase-9a
git worktree remove .worktrees/phase-9b
```

Falls Branches schon weg sind (auto-deleted nach merge): `git worktree prune`.

---

## Done-Criteria PR2 / Phase 9 Gesamt

- [ ] Keine `caller-*.yml` mehr im Repo
- [ ] `tests/fixtures/cli-go-no-config/.goreleaser.yaml` existiert und broken
- [ ] integration.yml goreleaser-fail Jobs OHNE `if: false`, MIT `if: always()` auf assert
- [ ] integration.yml summary.needs enthält `assert-goreleaser-fail`
- [ ] CI grün: integration / summary + self-ci / summary
- [ ] Branch-Protection: nur Summary-Checks (+ ggf. independent-workflow-Checks) als required
- [ ] Memory aktualisiert auf DONE
- [ ] Worktrees aufgeräumt
- [ ] Auf einer Beispiel-PR nach Phase 9: Top-Level-PR-Status-Badge ist grün ohne dass Reviewer einzelne Checks aufdröseln muss
