# Tofu-Destroy, -Unlock und -Drift — Implementierungsplan (Phasen 3–5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Katalog kann eine Umgebung kontrolliert abräumen, einen liegengebliebenen State-Lock lösen und Infrastruktur-Drift melden — jeweils mit denselben Riegeln, die den Apply absichern.

**Architecture:** Alle drei Atome nutzen `actions/tofu-stack-exec` und den Rahmen aus `tofu-apply.yml`. Destroy ist zweistufig über zwei Dispatches: der erste erzeugt den Destroy-Plan und hält an, der zweite wendet ihn an. Drift ist der einzige lesende Neuzugang und lebt in der `observe`-Gruppe.

**Tech Stack:** GitHub Actions (`workflow_call`), Bash, OpenTofu 1.12.6, `gh` CLI (Issue-Verwaltung), bats.

**Spec:** `docs/superpowers/specs/2026-08-28-tofu-apply-destroy-design.md`, §§ 6.4–6.6

**Vorgänger:** `plans/2026-08-28-tofu-apply-core.md` (Phasen 1–2, erledigt). Ohne die Composite und `tofu-plan`s `emit_plan` gibt es hier nichts zu bauen.

## Global Constraints

- **Arbeitsverzeichnis:** Worktree `.worktrees/tofu-apply-destroy`, Branch `feat/tofu-apply-destroy`.
- **Der Rahmen wird wörtlich aus `.github/workflows/tofu-apply.yml` übernommen:** `runs_on`-Wächter als erster Step, Event-Riegel, Checkout mit `persist-credentials: false`, App-Token, `Resolve catalog ref` mit `# renovate-marker: catalog-major-ref`, Katalog-Checkout nach `.catalog`, Toolchain. Nicht neu erfinden — abschreiben und nur die abweichenden Teile ändern.
- **Jedes neue Atom braucht:** Kopfzeile `# Summary convention: docs/conventions/step-summary.md`, Stability-Surface-Kommentar, `permissions:` auf Workflow-Ebene, Sektion in `docs/contracts.md`, Zeile in der README-Atomtabelle, die Zahl in `check-pin-scope-doc.py` (README) um eins erhöht, einen Self-CI-Job vom `summary`-Aggregator erreichbar.
- **Schreibende Atome (destroy, unlock) gehören in die `mutate`-Gruppe**, `tofu-drift` in die `observe`-Gruppe — beide nach dem Muster `tofu-<art>-${{ github.repository }}-${{ inputs.concurrency_key || inputs.working_directory }}`, `cancel-in-progress: false`.
- **Locking ist bei destroy nicht abschaltbar.** Kein `lock`-Input, nur `lock_timeout`.
- **Gates vor jedem Commit:** dieselbe Liste wie in Plan 2 (alle `tests/conventions/check-*`, `actionlint`, `yamllint .github/ actions/ tests/`, `bats tests/shell/`).

---

### Task 1: `tofu-destroy.yml`

Zweistufig in einem Atom, gesteuert über die An- oder Abwesenheit von `plan_run_id`:

- **Erster Dispatch, ohne `plan_run_id`:** `plan -destroy`, Artefakt, Step-Summary mit der vollständigen Liste dessen, was verschwinden würde — dann **Stopp**. Es wird nichts zerstört.
- **Zweiter Dispatch, mit `plan_run_id` und `confirm`:** dieselben vier Vorprüfungen wie beim Apply, dann `apply` des gespeicherten Destroy-Plans.

**Files:**
- Create: `.github/workflows/tofu-destroy.yml`
- Modify: `docs/contracts.md`, `README.md`

**Interfaces:**
- Consumes: `actions/tofu-stack-exec` (`command: plan-destroy` bzw. `apply`), `scripts/tofu-apply-preflight.sh`.
- Produces: Artefakt `tofu-destroy-<normalisierter key>`, Outputs `destroyed`, `summary_line`, `destroy_status`, `plan_run_id_hint`.

- [ ] **Step 1: Das Atom anlegen**

Abweichungen vom `tofu-apply.yml`-Rahmen, alles andere wörtlich übernehmen:

```yaml
      # Destroy laeuft NUR aus einem manuellen Dispatch. Kein push, kein
      # schedule, kein pull_request — es gibt keinen Automatismus, bei dem
      # das Abraeumen einer Umgebung die richtige Antwort waere.
      - name: Refuse to run outside a manual dispatch
        working-directory: ${{ github.workspace }}
        env:
          EVENT: ${{ github.event_name }}
        run: |
          set -euo pipefail
          if [[ "$EVENT" != "workflow_dispatch" ]]; then
            echo "::error::tofu-destroy darf nur aus einem manuellen workflow_dispatch laufen, nicht unter '${EVENT}'" >&2
            exit 1
          fi

      # Der Ref-Riegel ist beim Destroy schaerfer als beim Apply: ein Destroy
      # von einem beliebigen Feature-Branch aus waere ein Weg, die Reviews zu
      # umgehen, die auf dem Default-Branch haengen.
      - name: Refuse to run from a ref outside the allowlist
        working-directory: ${{ github.workspace }}
        env:
          ALLOWED: ${{ inputs.allowed_refs }}
          REF: ${{ github.ref }}
        run: |
          set -euo pipefail
          ok=0
          while IFS= read -r allowed; do
            [[ -z "${allowed// /}" ]] && continue
            [[ "$REF" == "$allowed" ]] && ok=1
          done <<< "$ALLOWED"
          if [[ "$ok" != "1" ]]; then
            echo "::error::tofu-destroy laeuft nur von: ${ALLOWED//$'\n'/, } — dieser Lauf kommt von ${REF}" >&2
            exit 1
          fi
```

Die Bestätigung, nur im zweiten Dispatch verlangt:

```yaml
      - name: Verify the typed confirmation
        if: inputs.plan_run_id != ''
        env:
          CONFIRM: ${{ inputs.confirm }}
          KEY: ${{ inputs.concurrency_key || inputs.working_directory }}
        run: |
          set -euo pipefail
          # `working_directory` allein waere zu schwach: das hiesse meist
          # "tippe tofu". Repo UND State-Identitaet zusammen sind eine Huerde,
          # die man nicht versehentlich nimmt.
          expected="DESTROY ${GITHUB_REPOSITORY} ${KEY}"
          if [[ "$CONFIRM" != "$expected" ]]; then
            echo "::error::confirm stimmt nicht. Erwartet wird woertlich:" >&2
            echo "::error::  ${expected}" >&2
            exit 1
          fi
          echo "Bestaetigung akzeptiert"
```

Die Verzweigung der beiden Stufen:

```yaml
      - name: Plan the destruction
        if: inputs.plan_run_id == ''
        id: plan
        uses: ./.catalog/actions/tofu-stack-exec
        with:
          command: plan-destroy
          working_directory: ${{ inputs.working_directory }}
          backend_config: ${{ inputs.backend_config }}
          lock_timeout: ${{ inputs.lock_timeout }}
          tf_vars: ${{ secrets.tf_vars }}
          encryption_passphrase: ${{ secrets.tf_encryption_passphrase }}
          backend_access_key: ${{ secrets.backend_access_key }}
          backend_secret_key: ${{ secrets.backend_secret_key }}

      - name: Stop and explain the second dispatch
        if: inputs.plan_run_id == ''
        env:
          KEY: ${{ inputs.concurrency_key || inputs.working_directory }}
          LINE: ${{ steps.plan.outputs.summary_line }}
        run: |
          set -euo pipefail
          # Bewusst KEIN Fehler: die erste Stufe ist erfolgreich, wenn sie
          # angehalten hat. Ein rotes Ergebnis waere die falsche Aussage.
          {
            echo "### Nichts wurde zerstoert"
            echo ""
            echo "Der Destroy-Plan liegt als Artefakt bereit: \`${LINE}\`"
            echo ""
            echo "Zum Ausfuehren diesen Workflow erneut starten, mit:"
            echo ""
            echo '```'
            echo "plan_run_id: ${GITHUB_RUN_ID}"
            echo "confirm:     DESTROY ${GITHUB_REPOSITORY} ${KEY}"
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
```

Die zweite Stufe (Artefakt holen, Vorprüfung, State-Backup, `apply`) wird aus `tofu-apply.yml` übernommen, mit `if: inputs.plan_run_id != ''` an jedem Schritt und dem Artefaktpräfix `tofu-destroy-`.

**Kein `tofu destroy -auto-approve`.** Es wird immer der gespeicherte Plan angewandt — sonst führte der zweite Dispatch einen anderen Vorgang aus als den freigegebenen.

- [ ] **Step 2: Inputs, Outputs, Secrets**

Wie `tofu-apply.yml`, mit diesen Abweichungen: `plan_run_id` ist **nicht** Pflicht (leer = erste Stufe), neu sind `confirm` (`''`) und `allowed_refs` (Default `refs/heads/main`). Outputs: `destroyed`, `summary_line`, `destroy_status`.

- [ ] **Step 3: Gates und Commit**

```bash
actionlint && yamllint .github/ && bash tests/conventions/check-contracts.sh \
  && python3 tests/conventions/check-contract-defaults.py \
  && python3 tests/conventions/check-pin-scope-doc.py \
  && python3 tests/conventions/check-runs-on-guard.py
```

```bash
git add .github/workflows/tofu-destroy.yml docs/contracts.md README.md
git commit -m "feat: tofu-destroy raeumt eine Umgebung in zwei Schritten ab"
```

---

### Task 2: `tofu-unlock.yml`

**Files:**
- Create: `.github/workflows/tofu-unlock.yml`
- Modify: `docs/contracts.md`, `README.md`

**Interfaces:**
- Consumes: `actions/tofu-stack-exec` (`command: unlock`).
- Produces: Output `unlocked`.

- [ ] **Step 1: Das Atom anlegen**

Rahmen wie oben, dispatch-only, `mutate`-Gruppe. Der einzige eigene Schritt ist die Bestätigung — und sie ist strenger als beim Destroy, weil ein `force-unlock` zur falschen Zeit zwei gleichzeitige Schreiber erzeugt:

```yaml
      - name: Verify the typed confirmation
        env:
          CONFIRM: ${{ inputs.confirm }}
          KEY: ${{ inputs.concurrency_key || inputs.working_directory }}
          LOCK_ID: ${{ inputs.lock_id }}
        run: |
          set -euo pipefail
          # Die Lock-ID gehoert in die Bestaetigung, nicht nur in einen Input:
          # sie ist der einzige Beleg, dass jemand nachgesehen hat, WELCHEN
          # Lock er loest. Ein force-unlock waehrend eines laufenden Applys
          # erzeugt zwei gleichzeitige Schreiber auf denselben State.
          expected="UNLOCK ${GITHUB_REPOSITORY} ${KEY} ${LOCK_ID}"
          if [[ "$CONFIRM" != "$expected" ]]; then
            echo "::error::confirm stimmt nicht. Erwartet wird woertlich:" >&2
            echo "::error::  ${expected}" >&2
            exit 1
          fi
```

Die Step-Summary verweist auf das Runbook:

```yaml
            echo "**Vor dem naechsten Lauf pruefen:** haelt wirklich niemand mehr"
            echo "diesen Lock? Runbook: docs/operations.md, Abschnitt „State-Lock geloest\"."
```

- [ ] **Step 2: Gates und Commit** — wie Task 1.

---

### Task 3: `tofu-drift.yml`

**Files:**
- Create: `.github/workflows/tofu-drift.yml`
- Modify: `docs/contracts.md`, `README.md`

**Interfaces:**
- Consumes: `actions/tofu-stack-exec` (`command: plan`, ohne `-out`).
- Produces: Outputs `has_changes`, `summary_line`, `issue_number`.

- [ ] **Step 1: Das Atom anlegen**

**Kein eigener `schedule:`** — ein Cron im Katalog liefe im Katalog, nicht beim Adopter. Der Zeitplan gehört in den Wrapper; das gehört als Kommentar in den Kopf.

`permissions:` braucht `issues: write` und **kein** `pull-requests: write`.

- [ ] **Step 2: Rollendes Issue, mit Auto-Close**

Nach dem erprobten Muster aus `drift-check.yml:360-385` (Liste statt Such-API, weil die Suche nachhängt) — **erweitert um den Rückweg**, den `drift-check.yml` hat und der hier sonst fehlte:

```yaml
      - name: Upsert or close the rolling drift issue
        env:
          GH_TOKEN: ${{ github.token }}
          HAS_CHANGES: ${{ steps.plan.outputs.has_changes }}
          LABEL: ${{ inputs.issue_label }}
          KEY: ${{ inputs.concurrency_key || inputs.working_directory }}
        run: |
          set -euo pipefail
          title="OpenTofu-Drift: ${KEY}"
          existing=$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --limit 100 \
            --json number,title -q ".[] | select(.title == \\"${title}\\") | .number" | head -1)

          if [[ "$HAS_CHANGES" == "true" ]]; then
            if [[ -n "$existing" ]]; then
              gh issue edit "$existing" --repo "$GITHUB_REPOSITORY" --body-file drift-body.md
              echo "issue_number=${existing}" >> "$GITHUB_OUTPUT"
            else
              num=$(gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" \
                --label "$LABEL" --body-file drift-body.md | grep -oE '[0-9]+$')
              echo "issue_number=${num}" >> "$GITHUB_OUTPUT"
            fi
          elif [[ -n "$existing" ]]; then
            # Der Rueckweg. Ohne ihn bliebe ein Issue offen, dessen Drift
            # laengst behoben ist — und ein Issue, das immer offen steht,
            # liest irgendwann niemand mehr.
            gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" \
              --body "Drift ist verschwunden (Lauf ${GITHUB_RUN_ID}). Automatisch geschlossen."
            gh issue close "$existing" --repo "$GITHUB_REPOSITORY"
            echo "issue_number=" >> "$GITHUB_OUTPUT"
          fi
```

- [ ] **Step 3: `fail_on_drift`**

Default `false`: ein Drift-Bericht ist eine Meldung, kein kaputter Build. Wer es hart will, schaltet es ein.

- [ ] **Step 4: Gates und Commit.**

---

### Task 4: Template-Block und Goldens

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl`
- Modify: `tests/shell/golden/**` (neu erzeugt)

- [ ] **Step 1: Auskommentierten `tofu-plan`-Block ergänzen**

Hinter dem `tofu-validate`-Block im `{{- if index .profile "iac" }}`-Zweig. **Auskommentiert**, weil ein gerenderter `tofu-plan` ohne konfiguriertes Remote-Backend nicht scheitert, sondern gegen leeren lokalen State plant und **grün meldet, ohne etwas zu prüfen**:

```gotemplate
{{`
  # tofu-plan: einkommentieren, sobald ein Remote-Backend konfiguriert ist.
  #
  # OHNE Backend scheitert dieser Job NICHT — er plant gegen einen leeren
  # lokalen State und meldet gruen, ohne irgendetwas zu pruefen. Das ist
  # schlimmer als kein Check.
  #
  # emit_plan: true legt den (verschluesselten) Plan als Artefakt ab; danach
  # kann tofu-apply.yml ihn per Dispatch mit dieser Run-ID anwenden.
  #
  # tofu-plan:
  #   uses: serverkraken/reusable-workflows/.github/workflows/tofu-plan.yml@`}}{{ $pin }}{{`
  #   permissions:
  #     contents: read
  #     pull-requests: write
  #   with:
  #     working_directory: tofu
  #     emit_plan: true
  #   secrets: inherit
`}}
```

- [ ] **Step 2: Goldens neu erzeugen**

```bash
bash tests/conventions/check-rendered-goldens.sh
```

Schlägt fehl, solange die Goldens den neuen Block nicht enthalten. Die Goldens nach dem im Repo etablierten Weg neu erzeugen (siehe `tests/shell/onboard-render.bats`), dann erneut prüfen. Erwartet: rc=0, und im Diff steht **nur** der auskommentierte Block bei Repos mit `iac`-Signal — Repos ohne dieses Signal müssen byte-identisch bleiben.

- [ ] **Step 3: Commit.**

---

### Task 5: Runbook, Self-CI und Nightly

**Files:**
- Modify: `docs/operations.md` (neuer Abschnitt), `.github/workflows/self-ci.yml`, `.github/workflows/failure-paths-nightly.yml`

- [ ] **Step 1: Runbook-Abschnitt „OpenTofu: Apply, Destroy, Zwischenfälle"**

Drei Unterabschnitte, alle drei aus konkreten Fehlermeldungen heraus geschrieben:

1. **`errored.tfstate` liegt vor.** Der Apply hat Ressourcen geändert, konnte den State aber nicht zurückschreiben. **Nicht** erneut applien. Reihenfolge: Datei sichern → State-Backup-Artefakt des Laufs herunterladen → prüfen, welcher der beiden Stände aktueller ist → gezielt zurückspielen → erst dann neu planen.
2. **State-Lock gelöst.** Vor jedem `tofu-unlock`: den Lauf finden, der den Lock hält (die Lock-Meldung nennt ihn), prüfen ob er wirklich tot ist, erst dann unlocken. Ein `force-unlock` während eines laufenden Applys erzeugt zwei Schreiber.
3. **Migration eines Klartext-States.** Der Fehlertext lautet wörtlich `failed to write backup file: encountered unencrypted payload without unencrypted method configured`. Einmalig `allow_unencrypted_fallback: true`, danach abschalten.

- [ ] **Step 2: Self-CI-Abdeckung**

`tofu-destroy` gegen die Fixture, nach dem destruktiven Muster aus `failure-paths-nightly.yml` ab Zeile 631: erste Stufe (Plan, muss anhalten und **nichts** zerstören), dann zweite Stufe mit korrekter Bestätigung, dann Assertion. `tofu-drift` gegen die Fixture ohne State → `has_changes=true`.

- [ ] **Step 3: Nightly-Fehlerpfade**

`confirm` falsch → Abbruch **vor** jedem tofu-Aufruf; `allowed_refs` verletzt → Abbruch. Beide Assertions verlangen wie in Plan 2 einen zweiten Beweis, dass das Gate gegriffen hat.

- [ ] **Step 4: Gates und Commit.**

---

## Selbst-Review

**Spec-Abdeckung.** § 6.4 → Task 1. § 6.5 → Task 2. § 6.6 → Task 3. § 8 (Template) → Task 4. Runbook → Task 5; `tofu-apply.yml` verweist bereits auf `docs/operations.md`, dieser Verweis geht bis dahin ins Leere.

**Bewusst nicht drin.** Der Absatz für gegatete Zwei-Job-Atome in `docs/conventions/step-summary.md` aus der Spec ist gegenstandslos: nach dem Wegfall des Environment-Gates ist jedes Atom einjobbig.

**Was erst die CI zeigt.** Ob `gh issue create` mit `issues: write` aus einem *aufgerufenen* reusable workflow im Adopter-Repo funktioniert — die Self-CI prüft es nur im Katalog-Repo selbst. Und ob der Destroy-Self-CI-Test wirklich zerstört: die Fixture nutzt lokalen State, der zwischen zwei Jobs nicht überlebt, also muss die zweite Stufe im selben Job oder gegen einen persistierten State laufen. **Beim Umsetzen zuerst klären** — wenn es nicht sauber geht, den Destroy-Test ehrlich als `# summary-exempt` markieren, statt einen Test zu bauen, der nichts beweist.
