# Tofu-Apply-Kern — Implementierungsplan (Phasen 1–2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Plan, den ein Mensch im PR liest, lässt sich anschließend per Dispatch als exakt dieser Plan anwenden — verschlüsselt übergeben, gegen vier Vorprüfungen abgesichert, mit State-Backup davor.

**Architecture:** Die gehärtete Tofu-Logik zieht in die Composite `actions/tofu-stack-exec`; `tofu-plan.yml` wird darauf umgebaut und lernt, den verschlüsselten Plan samt Metadaten als Artefakt abzulegen. `tofu-apply.yml` ist dispatch-only, holt das Artefakt aus dem benannten Lauf und wendet es an. Der Riegel ist die Dispatch-Aktion des Menschen, nicht ein GitHub-Feature.

**Tech Stack:** GitHub Actions (`workflow_call`), Bash, OpenTofu 1.12.6 (native Plan- und State-Verschlüsselung), AWS CLI v2 (State-Backup), bats.

**Spec:** `docs/superpowers/specs/2026-08-28-tofu-apply-destroy-design.md`, §§ 4–8

**Vorgänger:** `docs/superpowers/plans/2026-08-28-renovate-marker-guard.md` (Phase 0, erledigt — der Katalog steht auf OpenTofu 1.12.6, ohne das gibt es keine native Plan-Verschlüsselung mit `enforced`).

## Global Constraints

- **Arbeitsverzeichnis:** Worktree `.worktrees/tofu-apply-destroy`, Branch `feat/tofu-apply-destroy`. Alle Pfade relativ dazu.
- **Keine Third-Party-Setup-Actions.** Toolchains als gepinntes Binary mit Renovate-Marker. Der Marker-Wächter aus Phase 0 erzwingt, dass jeder neue Marker einen Manager hat — ein neuer Pin ohne passenden `matchString` lässt `validate` rot werden.
- **Fremde Actions auf SHA gepinnt**, Versionskommentar dahinter. Vorhandene Pins wiederverwenden: `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6`, `actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3`, `actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7`.
- **Jedes neue Atom braucht:** Kopfzeile `# Summary convention: docs/conventions/step-summary.md`, Stability-Surface-Kommentar, `permissions:` auf Workflow-Ebene, den `runs_on`-Wächter **als ersten Step jedes Jobs**, den Block „Resolve catalog ref" mit `# renovate-marker: catalog-major-ref`, eine Sektion in `docs/contracts.md`, einen Job in `self-ci.yml`, der vom `summary`-Aggregator erreichbar ist.
- **Verschlüsselung ist Pflicht, nicht Option.** Alle Atome dieses Plans bauen `TF_ENCRYPTION` mit `enforced = true` für `state` und `plan`. Der Nachweis ist das erfolgreiche Lesen unter erzwungener Konfiguration — **kein** Byte-Präfix-Test (`encrypted_metadata_alias` kann den Metadaten-Schlüssel umbenennen).
- **Alle Änderungen additiv.** `tofu-plan.yml` bekommt nur optionale Inputs mit Default. Minor-Bumps in `v4`.
- **Grenze der lokalen Prüfbarkeit:** Reusable Workflows lassen sich lokal nicht ausführen. Jeder Task endet mit den statischen Gates; der Beweis, dass ein Atom *läuft*, ist der Self-CI-Job auf dem PR. Wo ein Task nur per CI belegbar ist, steht das ausdrücklich dabei — nicht stillschweigend als „getestet" verbuchen.
- **Gates vor jedem Commit:**
  ```bash
  python3 tests/conventions/check-renovate-markers.py
  python3 tests/conventions/check-runs-on-guard.py
  python3 tests/conventions/check-contract-defaults.py
  python3 tests/conventions/check-reusable-permissions.py
  python3 tests/conventions/check-ref-fork-guard.py
  python3 tests/conventions/check-pin-scope-doc.py
  bash tests/conventions/check-step-summary.sh
  bash tests/conventions/check-contracts.sh
  bash tests/conventions/check-summary-coverage.sh
  bash tests/conventions/check-run-interpolation.sh
  yamllint .github/ actions/ tests/
  actionlint
  bats tests/shell/
  ```

---

# Phase 1 — Composite und Plan-Artefakt

Ergebnis der Phase: `tofu-plan.yml` läuft über die Composite und kann einen verschlüsselten Plan samt Metadaten als Artefakt hinterlegen. Bestehende Aufrufer merken davon nichts.

### Task 1: Composite `tofu-stack-exec`

Kapselt tf_vars-Parsing, Verschlüsselungskonfiguration, Backend-Init und den tofu-Aufruf. Composite-Steps laufen im selben Job und Runner — die Eigenschaft „die `TF_VAR_*` leben nur in einer Shell" bleibt erhalten, weil `$RUNNER_TEMP` dasselbe ist.

**Composite Actions können keine `secrets:` deklarieren.** Alles Geheime kommt per `with:` herein; das aufrufende Atom deklariert es als Secret.

**Files:**
- Create: `actions/tofu-stack-exec/action.yml`
- Modify: `docs/contracts.md` (neue Sektion `### actions/tofu-stack-exec`)

**Interfaces:**
- Consumes: `scripts/tf-vars-env.sh` (existiert, unverändert).
- Produces: eine Composite mit den Inputs `command`, `working_directory`, `backend_config`, `plan_file`, `lock`, `lock_timeout`, `tf_vars`, `encryption_passphrase`, `allow_unencrypted_fallback`, `backend_access_key`, `backend_secret_key` und den Outputs `has_changes`, `summary_line`, `exec_status`. Tasks 2 und 4 rufen sie auf.

- [ ] **Step 1: Composite anlegen**

```yaml
# actions/tofu-stack-exec/action.yml
name: tofu-stack-exec
description: |
  Fuehrt genau EINEN OpenTofu-Befehl gegen einen Stack aus: Backend-Init,
  tf_vars-Aufbereitung, Verschluesselungskonfiguration, Aufruf.

  Warum eine Composite: dieselbe geheertete Logik wird von tofu-plan,
  tofu-apply, tofu-destroy und tofu-drift gebraucht. Vierfach kopiert waere
  der naechste Sicherheitsfix vierfach zu machen -- und drei davon vergisst
  man.

  KEINE secrets: -- Composite Actions koennen keine deklarieren. Geheimes
  kommt per with: herein und wird vom aufrufenden Atom als Secret deklariert.

inputs:
  command:
    description: 'plan | plan-destroy | apply | unlock'
    required: true
  working_directory:
    description: 'OpenTofu stack directory.'
    required: true
  backend_config:
    description: 'Newline-separated -backend-config= arguments.'
    required: false
    default: ''
  plan_file:
    description: 'Pfad der tfplan (Ausgabe bei plan, Eingabe bei apply).'
    required: false
    default: 'tfplan'
  lock:
    description: 'State-Lock nehmen.'
    required: false
    default: 'true'
  lock_timeout:
    description: 'Wert fuer -lock-timeout.'
    required: false
    default: '60s'
  lock_id:
    description: 'Lock-ID fuer command=unlock.'
    required: false
    default: ''
  tf_vars:
    description: 'Newline-separated KEY=VALUE, wird zu TF_VAR_key.'
    required: false
    default: ''
  encryption_passphrase:
    description: >-
      Passphrase fuer die native Plan- und State-Verschluesselung. Pflicht,
      sobald ein Plan gespeichert oder ein State geschrieben wird.
    required: false
    default: ''
  allow_unencrypted_fallback:
    description: >-
      Einmalige Migration: erlaubt zusaetzlich das Lesen unverschluesselter
      Zustaende. NIEMALS dauerhaft an -- danach faellt der Schutz weg, ohne
      dass irgendetwas rot wird.
    required: false
    default: 'false'
  backend_access_key:
    description: 'S3-kompatibler Access Key.'
    required: false
    default: ''
  backend_secret_key:
    description: 'S3-kompatibler Secret Key.'
    required: false
    default: ''

outputs:
  has_changes:
    description: 'true|false bei plan/plan-destroy, sonst leer.'
    value: ${{ steps.run.outputs.has_changes }}
  summary_line:
    description: 'Die Zusammenfassungszeile des Laufs.'
    value: ${{ steps.run.outputs.summary_line }}
  exec_status:
    description: 'success|failed, leer wenn der Schritt nicht startete.'
    value: ${{ steps.run.outputs.exec_status }}

runs:
  using: composite
  steps:
    - name: Parse the tf_vars input
      shell: bash
      env:
        TF_VARS: ${{ inputs.tf_vars }}
        PARSER: ${{ github.action_path }}/../../scripts/tf-vars-env.sh
      run: |
        set -euo pipefail
        # ZUERST loeschen, BEDINGUNGSLOS. Auf dem self-hosted Pool ueberlebt
        # $RUNNER_TEMP den Job; ohne das koennte ein Lauf fuer ein ANDERES
        # Repo die Klartext-tf_vars des Vorgaengers sourcen. Die Frische ist
        # eine Eigenschaft des SCHREIBENS, nicht des geglueckten Aufraeumens.
        rm -f "$RUNNER_TEMP/tf-vars.env"
        if [[ -n "${TF_VARS:-}" ]]; then
          printf '%s\n' "$TF_VARS" | bash "$PARSER" "$RUNNER_TEMP/tf-vars.env"
        fi

    - name: Build the encryption configuration
      shell: bash
      env:
        PASSPHRASE: ${{ inputs.encryption_passphrase }}
        FALLBACK: ${{ inputs.allow_unencrypted_fallback }}
        COMMAND: ${{ inputs.command }}
      run: |
        set -euo pipefail
        rm -f "$RUNNER_TEMP/tofu-encryption.env"
        if [[ -z "${PASSPHRASE:-}" ]]; then
          if [[ "$COMMAND" != "plan" ]]; then
            echo "::error::command=${COMMAND} schreibt State oder liest einen gespeicherten Plan und verlangt eine encryption_passphrase" >&2
            exit 1
          fi
          echo "::notice::ohne encryption_passphrase: Plan wird NICHT verschluesselt gespeichert"
          exit 0
        fi
        umask 077
        # `enforced = true` ist der eigentliche Nachweis: OpenTofu lehnt danach
        # jeden unverschluesselten Zustand ab. Ein Byte-Praefix-Test auf
        # {"meta":{"key_provider taeugt -- encrypted_metadata_alias kann den
        # Schluessel umbenennen, und Klartext-JSON kann den Praefix faelschen.
        FALLBACK_BLOCK=""
        if [[ "$FALLBACK" == "true" ]]; then
          echo "::warning::allow_unencrypted_fallback ist AN — nur fuer die einmalige Migration, danach abschalten"
          FALLBACK_BLOCK='  fallback { method = method.unencrypted.legacy }'
          FALLBACK_METHOD='method "unencrypted" "legacy" {}'
        fi
        {
          echo "TF_ENCRYPTION<<TFENC"
          echo 'key_provider "pbkdf2" "catalog" {'
          echo "  passphrase = \"${PASSPHRASE}\""
          echo '}'
          echo 'method "aes_gcm" "catalog" {'
          echo '  keys = key_provider.pbkdf2.catalog'
          echo '}'
          [[ -n "${FALLBACK_METHOD:-}" ]] && echo "$FALLBACK_METHOD"
          echo 'state {'
          echo '  method   = method.aes_gcm.catalog'
          echo '  enforced = true'
          [[ -n "$FALLBACK_BLOCK" ]] && echo "$FALLBACK_BLOCK"
          echo '}'
          echo 'plan {'
          echo '  method   = method.aes_gcm.catalog'
          echo '  enforced = true'
          [[ -n "$FALLBACK_BLOCK" ]] && echo "$FALLBACK_BLOCK"
          echo '}'
          echo "TFENC"
        } > "$RUNNER_TEMP/tofu-encryption.env"

    - name: Initialize backend
      shell: bash
      env:
        DIR: ${{ inputs.working_directory }}
        BACKEND_CONFIG: ${{ inputs.backend_config }}
        AWS_ACCESS_KEY_ID: ${{ inputs.backend_access_key }}
        AWS_SECRET_ACCESS_KEY: ${{ inputs.backend_secret_key }}
      run: |
        set -euo pipefail
        # KEIN TF_VAR_* hier: `tofu init` wertet Input-Variablen nicht aus.
        # Was der Schritt nicht braucht, bekommt er nicht.
        if [[ -f "$RUNNER_TEMP/tofu-encryption.env" ]]; then
          set -a; . "$RUNNER_TEMP/tofu-encryption.env"; set +a
        fi
        ARGS=()
        while IFS= read -r line; do
          [[ -z "${line// /}" ]] && continue
          ARGS+=("-backend-config=$line")
        done <<< "$BACKEND_CONFIG"
        tofu -chdir="$DIR" init -input=false "${ARGS[@]+"${ARGS[@]}"}"

    - name: Run tofu
      id: run
      shell: bash
      env:
        DIR: ${{ inputs.working_directory }}
        COMMAND: ${{ inputs.command }}
        PLAN_FILE: ${{ inputs.plan_file }}
        LOCK: ${{ inputs.lock }}
        LOCK_TIMEOUT: ${{ inputs.lock_timeout }}
        LOCK_ID: ${{ inputs.lock_id }}
        AWS_ACCESS_KEY_ID: ${{ inputs.backend_access_key }}
        AWS_SECRET_ACCESS_KEY: ${{ inputs.backend_secret_key }}
      run: |
        set -uo pipefail
        # TF_VAR_* und TF_ENCRYPTION leben NUR in dieser Shell, nicht im Job.
        for f in tf-vars.env tofu-encryption.env; do
          if [[ -f "$RUNNER_TEMP/$f" ]]; then
            set -a
            # shellcheck disable=SC1090
            . "$RUNNER_TEMP/$f" || { echo "::error::$f liess sich nicht laden" >&2; exit 1; }
            set +a
          fi
        done
        LOCK_ARGS=(-lock-timeout="$LOCK_TIMEOUT")
        [[ "$LOCK" == "true" ]] || LOCK_ARGS+=(-lock=false)

        case "$COMMAND" in
          plan|plan-destroy)
            EXTRA=()
            [[ "$COMMAND" == "plan-destroy" ]] && EXTRA+=(-destroy)
            set +e
            # -detailed-exitcode: 0 = keine Aenderungen, 2 = Aenderungen,
            # 1 = Fehler. `set +e` ist Pflicht: GitHub startet run-Bloecke mit
            # `bash -e`, und der ERWARTETE Erfolgsfall ist rc=2.
            tofu -chdir="$DIR" plan -input=false -no-color -detailed-exitcode \
              "${LOCK_ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}" -out="$PLAN_FILE" \
              > plan.txt 2> plan.err
            rc=$?
            set -e
            cat plan.err >&2 || true
            case "$rc" in
              0) echo "has_changes=false" >> "$GITHUB_OUTPUT"; echo "exec_status=success" >> "$GITHUB_OUTPUT" ;;
              2) echo "has_changes=true"  >> "$GITHUB_OUTPUT"; echo "exec_status=success" >> "$GITHUB_OUTPUT" ;;
              *) echo "::error::tofu plan scheiterte (rc=$rc): $(tr -d '\n' < plan.err)" >&2
                 echo "exec_status=failed" >> "$GITHUB_OUTPUT"; exit 1 ;;
            esac
            LINE=$(grep -E '^Plan: |^No changes\.' plan.txt | tail -1 || true)
            echo "summary_line=${LINE:-unknown}" >> "$GITHUB_OUTPUT"
            ;;
          apply)
            set +e
            tofu -chdir="$DIR" apply -input=false -no-color "${LOCK_ARGS[@]}" "$PLAN_FILE" \
              > apply.txt 2> apply.err
            rc=$?
            set -e
            cat apply.err >&2 || true
            if [[ "$rc" -ne 0 ]]; then
              echo "::error::tofu apply scheiterte (rc=$rc): $(tr -d '\n' < apply.err)" >&2
              echo "exec_status=failed" >> "$GITHUB_OUTPUT"
              exit 1
            fi
            echo "exec_status=success" >> "$GITHUB_OUTPUT"
            LINE=$(grep -E '^Apply complete!' apply.txt | tail -1 || true)
            echo "summary_line=${LINE:-unknown}" >> "$GITHUB_OUTPUT"
            ;;
          unlock)
            if [[ -z "$LOCK_ID" ]]; then
              echo "::error::command=unlock verlangt lock_id" >&2
              exit 1
            fi
            tofu -chdir="$DIR" force-unlock -force "$LOCK_ID"
            echo "exec_status=success" >> "$GITHUB_OUTPUT"
            echo "summary_line=Lock ${LOCK_ID} geloest" >> "$GITHUB_OUTPUT"
            ;;
          *)
            echo "::error::unbekanntes command: ${COMMAND}" >&2
            exit 1
            ;;
        esac
```

- [ ] **Step 2: Sektion in `docs/contracts.md` ergänzen**

Hinter `### actions/setup-tofu-toolchain` einfügen, im dortigen Tabellenformat, mit **exakt** den Defaults aus Step 1 — `check-contract-defaults.py` vergleicht sie Zeichen für Zeichen:

```markdown
### `actions/tofu-stack-exec`

| Kind   | Name | Type | Required | Default | Description |
|--------|------|------|----------|---------|-------------|
| input | `command` | string | yes | — | plan \| plan-destroy \| apply \| unlock |
| input | `working_directory` | string | yes | — | OpenTofu stack directory. |
| input | `backend_config` | string | no | `''` | Newline-separated -backend-config= arguments. |
| input | `plan_file` | string | no | `'tfplan'` | Pfad der tfplan (Ausgabe bei plan, Eingabe bei apply). |
| input | `lock` | string | no | `'true'` | State-Lock nehmen. |
| input | `lock_timeout` | string | no | `'60s'` | Wert fuer -lock-timeout. |
| input | `lock_id` | string | no | `''` | Lock-ID fuer command=unlock. |
| input | `tf_vars` | string | no | `''` | Newline-separated KEY=VALUE, wird zu TF_VAR_key. |
| input | `encryption_passphrase` | string | no | `''` | Passphrase fuer die native Plan- und State-Verschluesselung. |
| input | `allow_unencrypted_fallback` | string | no | `'false'` | Einmalige Migration; danach abschalten. |
| input | `backend_access_key` | string | no | `''` | S3-kompatibler Access Key. |
| input | `backend_secret_key` | string | no | `''` | S3-kompatibler Secret Key. |
| output | `has_changes` | string | — | — | true\|false bei plan/plan-destroy, sonst leer. |
| output | `summary_line` | string | — | — | Die Zusammenfassungszeile des Laufs. |
| output | `exec_status` | string | — | — | success\|failed, leer wenn der Schritt nicht startete. |
```

- [ ] **Step 3: Gates laufen lassen**

```bash
yamllint actions/
bash tests/conventions/check-contracts.sh; echo "contracts rc=$?"
python3 tests/conventions/check-contract-defaults.py; echo "defaults rc=$?"
```

Erwartet: alle rc=0. Meldet `check-contract-defaults.py` eine Abweichung, ist die Tabelle falsch abgeschrieben — **die Tabelle korrigieren, nicht den Check**.

- [ ] **Step 4: Commit**

```bash
git add actions/tofu-stack-exec/action.yml docs/contracts.md
git commit -m "feat: Composite tofu-stack-exec

Kapselt tf_vars-Parsing, Verschluesselungskonfiguration, Backend-Init und den
tofu-Aufruf. Vier Atome brauchen dieselbe gehaertete Logik; vierfach kopiert
waere der naechste Sicherheitsfix vierfach zu machen.

Die Verschluesselung wird mit enforced = true gebaut: OpenTofu lehnt danach
jeden unverschluesselten Zustand selbst ab. Das ersetzt einen Praefix-Test auf
die Metadaten, der sich mit encrypted_metadata_alias aushebeln liesse.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `tofu-plan.yml` umbauen und `emit_plan` ergänzen

Der Umbau ist für Aufrufer unsichtbar; die bestehenden Self-CI-Assertions (`assert-tofu-plan-changes`, `self-ci.yml:245`) sind das Sicherheitsnetz. Neu hinzu kommen drei optionale Inputs und das Artefakt.

**Files:**
- Modify: `.github/workflows/tofu-plan.yml`
- Modify: `docs/contracts.md` (Sektion `### tofu-plan.yml`)

**Interfaces:**
- Consumes: `actions/tofu-stack-exec` aus Task 1.
- Produces: Artefakt `tofu-plan-<report_slug|concurrency_key>` mit `tfplan` (verschlüsselt) und `plan-meta.json`. Task 4 liest genau dieses Artefakt.

- [ ] **Step 1: Die vier inline-Schritte durch die Composite ersetzen**

In `tofu-plan.yml` entfallen die Schritte „Parse the tf_vars secret", „Initialize backend" und „Run tofu plan". An ihre Stelle tritt:

```yaml
      - name: Plan the stack
        if: steps.fork.outputs.is_fork == 'false'
        id: plan
        uses: ./.catalog/actions/tofu-stack-exec
        with:
          command: plan
          working_directory: ${{ inputs.working_directory }}
          backend_config: ${{ inputs.backend_config }}
          lock: ${{ inputs.lock }}
          lock_timeout: ${{ inputs.lock_timeout }}
          tf_vars: ${{ secrets.tf_vars }}
          encryption_passphrase: ${{ secrets.tf_encryption_passphrase }}
          backend_access_key: ${{ secrets.backend_access_key }}
          backend_secret_key: ${{ secrets.backend_secret_key }}
```

Die Job-Outputs bleiben unverändert benannt; `plan_status` wird jetzt aus `exec_status` gespeist:

```yaml
    outputs:
      has_changes: ${{ steps.plan.outputs.has_changes }}
      summary_line: ${{ steps.plan.outputs.summary_line }}
      plan_status: ${{ steps.plan.outputs.exec_status }}
```

- [ ] **Step 2: Die drei neuen Inputs und das neue Secret ergänzen**

```yaml
      emit_plan:
        description: >-
          Den gespeicherten Plan als Artefakt hinterlegen, damit tofu-apply ihn
          spaeter anwenden kann. Verlangt das Secret tf_encryption_passphrase —
          ohne Verschluesselung wird der Upload VERWEIGERT, weil die tfplan
          sensitive-Werte im Klartext traegt.
        required: false
        type: boolean
        default: false
      plan_retention_days:
        description: 'Retention des Plan-Artefakts in Tagen.'
        required: false
        type: number
        default: 3
      concurrency_key:
        description: >-
          Identitaet des States fuers Scheduling. Default ist
          working_directory; ein Pfad ist aber keine belastbare
          State-Identitaet (Umbenennen aendert die Gruppe, zwei Verzeichnisse
          koennen denselben Backend-Key benutzen).
        required: false
        type: string
        default: ''
```

```yaml
      tf_encryption_passphrase:
        required: false
        description: 'Passphrase fuer die native Plan- und State-Verschluesselung. Pflicht bei emit_plan.'
```

- [ ] **Step 3: Concurrency-Gruppe auf `observe` umstellen**

```yaml
concurrency:
  # Getrennt von der mutate-Gruppe (apply/destroy/unlock): ein lesender Plan
  # soll nicht hinter einem schreibenden Lauf warten muessen. Beide Gruppen
  # tragen bewusst KEIN github.ref -- mit ref liefen PR-Plan und Apply in
  # verschiedenen Gruppen, und die Serialisierung waere verfehlt.
  group: tofu-observe-${{ github.repository }}-${{ inputs.concurrency_key || inputs.working_directory }}
  cancel-in-progress: false
```

- [ ] **Step 4: Den falschen Rat im Kopfkommentar korrigieren**

Der Abschnitt VERTRAUENSGRENZE rät heute, den aufrufenden Job an ein geschütztes `environment` zu hängen. Das ist **nicht umsetzbar** — ein Job mit `jobs.<id>.uses:` darf kein `environment:` tragen (erlaubt sind `uses`, `with`, `secrets`, `needs`, `if`, `permissions`, `concurrency`, `strategy`). Ersetzen durch:

```
#     - den Plan nur mit LESENDEN Backend-Credentials laufen lassen und das
#       Schreiben tofu-apply.yml ueberlassen, das per workflow_dispatch
#       ausgeloest wird — die Dispatch-Aktion eines Menschen ist der Riegel; oder
#     - kurzlebige, NUR LESENDE Credentials uebergeben, deren Diebstahl
#       nichts wert ist.
#
#   NICHT moeglich ist der frueher hier empfohlene Weg, den aufrufenden Job an
#   ein geschuetztes `environment` zu haengen: ein Job, der per `uses:` einen
#   reusable workflow aufruft, darf kein `environment:` tragen. Und Required
#   Reviewers stehen auf dem Team-Plan in privaten Repos ohnehin nicht zur
#   Verfuegung — GitHub antwortet mit HTTP 422 und legt das Environment
#   trotzdem an, ohne Protection Rules.
```

- [ ] **Step 5: Artefakt-Schritte ergänzen, hinter „Run tofu plan", vor der Summary**

```yaml
      - name: Verify the plan is encrypted before uploading it
        if: >-
          steps.fork.outputs.is_fork == 'false' && inputs.emit_plan
          && steps.plan.outputs.exec_status == 'success'
        env:
          DIR: ${{ inputs.working_directory }}
          PASSPHRASE: ${{ secrets.tf_encryption_passphrase }}
        run: |
          set -euo pipefail
          if [[ -z "${PASSPHRASE:-}" ]]; then
            echo "::error::emit_plan verlangt das Secret tf_encryption_passphrase — ohne Verschluesselung traegt die tfplan sensitive-Werte im Klartext" >&2
            exit 1
          fi
          # Der Nachweis ist, dass ein Lesen OHNE Schluessel scheitert. Ein
          # Test auf den Metadaten-Praefix waere faelschbar.
          #
          # `show tfplan`, NICHT `show "$DIR/tfplan"`: -chdir aendert das
          # Arbeitsverzeichnis von tofu, der Pfad ist also bereits relativ
          # dazu. Mit $DIR davor suchte tofu in $DIR/$DIR — der Aufruf
          # schluege fehl, und der Riegel meldete faelschlich "verschluesselt".
          if env -u TF_ENCRYPTION tofu -chdir="$DIR" show tfplan >/dev/null 2>&1; then
            echo "::error::die tfplan liess sich OHNE Schluessel lesen — sie ist nicht verschluesselt, Upload verweigert" >&2
            exit 1
          fi
          echo "Plan ist verschluesselt (Lesen ohne Schluessel schlaegt fehl)"

      - name: Write plan metadata
        if: >-
          steps.fork.outputs.is_fork == 'false' && inputs.emit_plan
          && steps.plan.outputs.exec_status == 'success'
        env:
          DIR: ${{ inputs.working_directory }}
          KEY: ${{ inputs.concurrency_key || inputs.working_directory }}
          CATALOG_SHA: ${{ steps.catalog-ref.outputs.ref }}
        run: |
          set -euo pipefail
          # Diese Datei ist der Vertrag zwischen Plan- und Apply-Lauf.
          # tofu-apply prueft jedes Feld, bevor es tofu ueberhaupt startet.
          cat > plan-meta.json <<META
          {
            "working_directory": "${DIR}",
            "concurrency_key": "${KEY}",
            "catalog_ref": "${CATALOG_SHA}",
            "tofu_version": "$(tofu version | head -1 | awk '{print $2}')",
            "adopter_sha": "${GITHUB_SHA}",
            "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "run_id": "${GITHUB_RUN_ID}"
          }
          META
          cat plan-meta.json

      - name: Upload the encrypted plan
        if: >-
          steps.fork.outputs.is_fork == 'false' && inputs.emit_plan
          && steps.plan.outputs.exec_status == 'success'
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: tofu-plan-${{ inputs.report_slug || inputs.concurrency_key || inputs.working_directory }}
          path: |
            ${{ inputs.working_directory }}/tfplan
            plan-meta.json
          if-no-files-found: error
          retention-days: ${{ inputs.plan_retention_days }}
```

Der Aufräumschritt am Jobende bleibt unverändert — er läuft nach dem Upload und entfernt die lokale tfplan.

- [ ] **Step 6: `docs/contracts.md` nachziehen**

Die Sektion `### tofu-plan.yml` um `emit_plan` (`false`), `plan_retention_days` (`3`), `concurrency_key` (`''`) und das Secret `tf_encryption_passphrase` erweitern. Defaults zeichengenau.

- [ ] **Step 7: Gates laufen lassen**

```bash
actionlint
yamllint .github/ actions/
python3 tests/conventions/check-contract-defaults.py; echo "defaults rc=$?"
python3 tests/conventions/check-runs-on-guard.py; echo "runs-on rc=$?"
bash tests/conventions/check-step-summary.sh; echo "summary rc=$?"
bash tests/conventions/check-contracts.sh; echo "contracts rc=$?"
```

Erwartet: alle rc=0.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/tofu-plan.yml docs/contracts.md
git commit -m "feat: tofu-plan laeuft ueber tofu-stack-exec und kann den Plan hinterlegen

Die inline-Schritte fuer tf_vars, Backend-Init und den tofu-Aufruf wandern in
die Composite. Neu und optional: emit_plan legt den Plan samt plan-meta.json
als Artefakt ab, damit tofu-apply spaeter exakt diesen Plan anwenden kann.

Der Upload wird verweigert, wenn sich die tfplan ohne Schluessel lesen laesst
-- der Nachweis ist das fehlschlagende Lesen, nicht ein faelschbarer
Metadaten-Praefix.

Die Concurrency-Gruppe wechselt auf tofu-observe-<repo>-<key>, damit lesende
Plaene nicht hinter schreibenden Laeufen warten. Sichtbare Verhaltensaenderung,
gehoert ins CHANGELOG.

Der Rat im Kopfkommentar, den aufrufenden Job an ein geschuetztes environment
zu haengen, war falsch: ein Job mit uses: darf kein environment: tragen, und
Required Reviewers gibt es auf dem Team-Plan privat ohnehin nicht (HTTP 422).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Phase 2 — `tofu-apply.yml`

Ergebnis der Phase: Ein Plan aus einem PR-Lauf lässt sich per Dispatch anwenden, mit vier Vorprüfungen und einem State-Backup davor.

### Task 3: Fixture mit persistentem, verschlüsseltem State

`tofu-plan-local` reicht nicht: Apply braucht einen State, der über den Lauf hinaus existiert, und die Verschlüsselung muss aktiv sein.

**Files:**
- Create: `tests/fixtures/tofu-apply-local/main.tf`, `tests/fixtures/tofu-apply-local/versions.tf`

**Interfaces:**
- Produces: einen Stack mit `null_resource`, lokalem Backend und ohne Provider-Credentials, den Task 5 in der Self-CI benutzt.

- [ ] **Step 1: Fixture anlegen**

```hcl
# tests/fixtures/tofu-apply-local/main.tf
# Ein null_resource ohne externe Abhaengigkeit: der Apply-Pfad laesst sich
# damit offline und ohne Credentials durchspielen. Der Trigger ist konstant,
# ein zweiter Apply meldet daher "No changes" -- genau das braucht die
# Assertion fuer den Stale-Plan-Test.
resource "null_resource" "applied" {
  triggers = {
    fixture = "tofu-apply-local"
  }
}
```

```hcl
# tests/fixtures/tofu-apply-local/versions.tf
# Kein backend-Block: lokaler State. Die Verschluesselung kommt zur Laufzeit
# ueber TF_ENCRYPTION aus der Composite, nicht aus dieser Datei -- so testet
# die Fixture denselben Weg, den ein Adopter geht.
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
```

- [ ] **Step 2: Lokal gegenprüfen, dass die Fixture formatiert und gültig ist**

```bash
tofu fmt -check -recursive -diff tests/fixtures/tofu-apply-local; echo "fmt rc=$?"
TMP=$(mktemp -d); cp -R tests/fixtures/tofu-apply-local/. "$TMP/"
( cd "$TMP" && tofu init -backend=false -input=false -no-color >/dev/null 2>&1 && tofu validate -no-color )
echo "validate rc=$?"; rm -rf "$TMP"
```

Erwartet: `fmt rc=0`, `validate rc=0`.

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/tofu-apply-local
git commit -m "test: Fixture mit persistentem State fuer den Apply-Pfad

tofu-plan-local hat keinen State ueber den Lauf hinaus; Apply und der
Stale-Plan-Test brauchen einen. null-Provider, lokales Backend, keine
Credentials -- laeuft offline.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `tofu-apply.yml`

Das Atom holt den Plan aus dem benannten Lauf, prüft vier Dinge, sichert den State und wendet an.

**Files:**
- Create: `.github/workflows/tofu-apply.yml`
- Modify: `docs/contracts.md`, `README.md` (Atom-Tabelle und die Zahl in `check-pin-scope-doc.py`)

**Interfaces:**
- Consumes: das Artefakt aus Task 2 (`tfplan`, `plan-meta.json`), die Composite aus Task 1.
- Produces: Outputs `applied`, `summary_line`, `apply_status`, `outputs_json`. Plan 3 (destroy) übernimmt die Vorprüfungs-Logik unverändert.

- [ ] **Step 1: Das Atom anlegen**

Der Rahmen (Kopfkommentar, `runs_on`-Wächter als erster Step, Checkout mit `persist-credentials: false`, App-Token, Katalog-Checkout nach `.catalog`, Toolchain) wird wörtlich aus `tofu-plan.yml` übernommen — mit **einem** Unterschied: der Katalog-Ref kommt aus dem Artefakt, nicht aus dem `v4`-Marker. Der Rest des Jobs:

```yaml
      - name: Refuse to run outside a manual dispatch
        env:
          EVENT: ${{ github.event_name }}
        run: |
          set -euo pipefail
          # Der Riegel dieses Atoms ist die bewusste Dispatch-Aktion eines
          # Menschen. Unter pull_request liefe es automatisch — genau das,
          # was es nicht darf.
          case "$EVENT" in
            workflow_dispatch|repository_dispatch) ;;
            *) echo "::error::tofu-apply darf nur aus einem manuellen Dispatch laufen, nicht unter '${EVENT}'" >&2
               exit 1 ;;
          esac

      - name: Download the plan from the referenced run
        env:
          GH_TOKEN: ${{ github.token }}
          RUN_ID: ${{ inputs.plan_run_id }}
          NAME: tofu-plan-${{ inputs.report_slug || inputs.concurrency_key || inputs.working_directory }}
        run: |
          set -euo pipefail
          gh run download "$RUN_ID" --name "$NAME" --dir plan-artifact
          test -f plan-artifact/plan-meta.json || { echo "::error::plan-meta.json fehlt im Artefakt" >&2; exit 1; }
          test -f plan-artifact/tfplan || { echo "::error::tfplan fehlt im Artefakt" >&2; exit 1; }

      - name: Preflight — four checks before tofu starts
        id: preflight
        env:
          DIR: ${{ inputs.working_directory }}
          KEY: ${{ inputs.concurrency_key || inputs.working_directory }}
          MAX_AGE: ${{ inputs.max_plan_age_minutes }}
          CATALOG_SHA: ${{ steps.catalog-ref.outputs.ref }}
        run: |
          set -euo pipefail
          meta=plan-artifact/plan-meta.json
          get() { python3 -c "import json,sys;print(json.load(open('$meta'))['$1'])"; }

          # 1. Stack — ein Plan fuer einen anderen Stack darf nie angewandt werden.
          [[ "$(get working_directory)" == "$DIR" ]] || {
            echo "::error::Plan gehoert zu '$(get working_directory)', angefordert wurde '${DIR}'" >&2; exit 1; }

          # 2. State-Identitaet.
          [[ "$(get concurrency_key)" == "$KEY" ]] || {
            echo "::error::Plan gehoert zu State '$(get concurrency_key)', angefordert wurde '${KEY}'" >&2; exit 1; }

          # 3. Katalog-Revision. Adopter pinnen den beweglichen v4: laeuft der
          #    Apply Stunden nach dem Plan, kann v4 weitergerueckt sein — der
          #    Apply liefe dann mit anderem Katalog-Code als der Plan.
          [[ "$(get catalog_ref)" == "$CATALOG_SHA" ]] || {
            echo "::error::Plan entstand mit Katalog-Ref '$(get catalog_ref)', dieser Lauf nutzt '${CATALOG_SHA}'" >&2
            echo "::error::neu planen statt einen Plan fremder Katalogversion anzuwenden" >&2; exit 1; }

          # 4. Alter. "Saved plan is stale" faengt State-Aenderungen ab, aber
          #    NICHT Ressourcen, die ausserhalb des States veraendert wurden.
          created=$(get created_at)
          age=$(( ( $(date -u +%s) - $(date -u -d "$created" +%s 2>/dev/null || python3 -c "
          import datetime,sys;print(int(datetime.datetime.strptime('$created','%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))") ) / 60 ))
          if (( age > MAX_AGE )); then
            echo "::error::Plan ist ${age} Minuten alt, erlaubt sind ${MAX_AGE} — neu planen" >&2; exit 1
          fi
          echo "age_minutes=${age}" >> "$GITHUB_OUTPUT"
          echo "Vorpruefungen bestanden (Plan ist ${age} Minuten alt)"

      - name: Back up the raw state object
        if: inputs.state_bucket != ''
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.backend_access_key }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.backend_secret_key }}
          BUCKET: ${{ inputs.state_bucket }}
          KEY_PATH: ${{ inputs.state_key }}
          PREFIX: ${{ inputs.state_workspace_key_prefix }}
          WORKSPACE: ${{ inputs.state_workspace }}
          ENDPOINT: ${{ inputs.state_endpoint }}
        run: |
          set -euo pipefail
          # Bei einem Nicht-Default-Workspace lautet der Objektpfad
          # <prefix>/<workspace>/<key> — ein naives bucket+key sicherte das
          # falsche Objekt.
          if [[ "$WORKSPACE" == "default" ]]; then OBJ="$KEY_PATH"; else OBJ="${PREFIX}/${WORKSPACE}/${KEY_PATH}"; fi
          ARGS=(); [[ -n "$ENDPOINT" ]] && ARGS+=(--endpoint-url "$ENDPOINT")
          # Das Objekt ist Chiffrat (enforced = true in der Composite), das
          # Artefakt daher kein Leck. Faellt der Download aus, ist das ein
          # Fehler und kein Achselzucken: ohne Backup gibt es keinen
          # Wiederherstellungspunkt, und Garage kann keine Versionierung.
          aws "${ARGS[@]+"${ARGS[@]}"}" s3 cp "s3://${BUCKET}/${OBJ}" state-backup.enc
          if grep -qa '"serial"' state-backup.enc; then
            echo "::error::das State-Objekt ist unverschluesselt — Backup wird NICHT hochgeladen" >&2
            rm -f state-backup.enc
            exit 1
          fi
          echo "State-Backup bereit ($(wc -c < state-backup.enc) Bytes, Chiffrat)"

      - name: Upload the state backup
        if: inputs.state_bucket != ''
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: tofu-state-backup-${{ inputs.concurrency_key || inputs.working_directory }}-${{ github.run_id }}
          path: state-backup.enc
          if-no-files-found: error
          retention-days: ${{ inputs.plan_retention_days }}

      - name: Apply the saved plan
        id: apply
        uses: ./.catalog/actions/tofu-stack-exec
        with:
          command: apply
          working_directory: ${{ inputs.working_directory }}
          backend_config: ${{ inputs.backend_config }}
          plan_file: ${{ github.workspace }}/plan-artifact/tfplan
          lock_timeout: ${{ inputs.lock_timeout }}
          tf_vars: ${{ secrets.tf_vars }}
          encryption_passphrase: ${{ secrets.tf_encryption_passphrase }}
          backend_access_key: ${{ secrets.backend_access_key }}
          backend_secret_key: ${{ secrets.backend_secret_key }}

      - name: Export allow-listed outputs
        if: inputs.outputs_allowlist != ''
        id: outputs
        env:
          DIR: ${{ inputs.working_directory }}
          ALLOW: ${{ inputs.outputs_allowlist }}
        run: |
          set -euo pipefail
          tofu -chdir="$DIR" output -json > outputs-raw.json
          # sensitive wird hart entfernt UND nur die Allowlist exportiert:
          # auf das sensitive-Flag allein ist kein Verlass, ein Provider oder
          # ein Adopter kann es falsch setzen.
          python3 - <<'PY' > outputs.json
          import json, os
          raw = json.load(open("outputs-raw.json"))
          allow = {n.strip() for n in os.environ["ALLOW"].splitlines() if n.strip()}
          print(json.dumps({k: v["value"] for k, v in raw.items()
                            if k in allow and not v.get("sensitive", False)}))
          PY
          echo "outputs_json=$(cat outputs.json)" >> "$GITHUB_OUTPUT"
          rm -f outputs-raw.json outputs.json

      - name: Preserve errored.tfstate for the incident path
        if: always()
        env:
          DIR: ${{ inputs.working_directory }}
        run: |
          # NICHT loeschen: schlaegt der Apply nach bereits geaenderten
          # Ressourcen beim Zurueckschreiben fehl, ist diese Datei womoeglich
          # die einzige aktuelle State-Kopie.
          if [[ -f "$DIR/errored.tfstate" ]]; then
            echo "::error::errored.tfstate liegt vor — der State wurde NICHT zurueckgeschrieben. Runbook: docs/operations.md"
            cp "$DIR/errored.tfstate" errored.tfstate
          fi
```

- [ ] **Step 2: Die Inputs, Outputs und Secrets deklarieren**

Inputs: `plan_run_id` (string, Pflicht), `working_directory` (`'tofu'`), `concurrency_key` (`''`), `max_plan_age_minutes` (number, `120`), `backend_config` (`''`), `lock_timeout` (`'60s'`), `report_slug` (`''`), `outputs_allowlist` (`''`), `plan_retention_days` (number, `3`), `state_bucket` (`''`), `state_key` (`''`), `state_workspace_key_prefix` (`'env:'`), `state_workspace` (`'default'`), `state_endpoint` (`''`), `runs_on` (`'["self-hosted","Linux"]'`).

Outputs: `applied`, `summary_line`, `apply_status`, `outputs_json`.

Secrets: `release_please_app_client_id` (Pflicht), `release_please_app_private_key` (Pflicht), `tf_encryption_passphrase` (Pflicht), `backend_access_key`, `backend_secret_key`, `tf_vars`.

`permissions:` auf Workflow-Ebene: `contents: read`, `actions: read` (für `gh run download`). **Kein** `pull-requests: write` — das Atom läuft nie auf PRs.

Concurrency:

```yaml
concurrency:
  group: tofu-mutate-${{ github.repository }}-${{ inputs.concurrency_key || inputs.working_directory }}
  cancel-in-progress: false
```

- [ ] **Step 3: Step-Summary nach Schema**

```yaml
      - name: Summary
        if: always()
        env:
          DIR: ${{ inputs.working_directory }}
          STATUS: ${{ steps.apply.outputs.exec_status }}
          LINE: ${{ steps.apply.outputs.summary_line }}
          AGE: ${{ steps.preflight.outputs.age_minutes }}
          RUN_ID: ${{ inputs.plan_run_id }}
        run: |
          tofu_version=$(tofu version 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)
          if [[ "${STATUS:-}" == "success" ]]; then result="✓ angewandt"
          elif [[ -z "${STATUS:-}" ]]; then result="✗ Apply lief nicht durch"
          else result="✗ Apply fehlgeschlagen"; fi
          {
            echo "## tofu-apply"
            echo ""
            echo "**Tool:** OpenTofu ${tofu_version}"
            echo "**Phase:** apply"
            echo "**Working dir:** \`${DIR}\`"
            echo "**Plan aus Lauf:** ${RUN_ID} (${AGE:-?} Minuten alt)"
            echo "**Result:** ${result}"
            echo ""
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Apply | ${STATUS:-nicht gelaufen} |"
            echo "| Summary | ${LINE:-unknown} |"
          } >> "$GITHUB_STEP_SUMMARY" || true
```

- [ ] **Step 4: `docs/contracts.md` und README nachziehen**

Neue Sektion `### tofu-apply.yml` mit allen Inputs, Outputs und Secrets aus Step 2, Defaults zeichengenau. In der README-Atomtabelle eine Zeile ergänzen. `check-pin-scope-doc.py` zählt die Katalog-Checkouts — die dokumentierte Zahl in der README um eins erhöhen.

- [ ] **Step 5: Gates laufen lassen**

```bash
actionlint
yamllint .github/ actions/ tests/
python3 tests/conventions/check-runs-on-guard.py; echo "runs-on rc=$?"
python3 tests/conventions/check-reusable-permissions.py; echo "permissions rc=$?"
python3 tests/conventions/check-contract-defaults.py; echo "defaults rc=$?"
python3 tests/conventions/check-pin-scope-doc.py; echo "pin-scope rc=$?"
python3 tests/conventions/check-ref-fork-guard.py; echo "fork-guard rc=$?"
bash tests/conventions/check-step-summary.sh; echo "summary rc=$?"
bash tests/conventions/check-contracts.sh; echo "contracts rc=$?"
bash tests/conventions/check-run-interpolation.sh; echo "interpolation rc=$?"
```

Erwartet: alle rc=0. `check-run-interpolation.sh` ist hier besonders wichtig — es verbietet aufrufergesteuerte Ausdrücke direkt im `run`-Körper; alle Werte gehen über `env:`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/tofu-apply.yml docs/contracts.md README.md
git commit -m "feat: tofu-apply wendet einen freigegebenen Plan an

Dispatch-only. Das Atom holt den verschluesselten Plan aus dem benannten Lauf
und prueft vier Dinge, bevor tofu ueberhaupt startet: Stack, State-Identitaet,
Katalog-Revision und Planalter.

Die Katalog-Pruefung ist kein Zierrat: Adopter pinnen den beweglichen v4, und
laeuft der Apply Stunden nach dem Plan, kann v4 weitergerueckt sein -- der
Apply liefe mit anderem Katalog-Code als der Plan.

Vor dem Apply wird das rohe State-Objekt gesichert. Es ist Chiffrat, weil die
Composite mit enforced = true arbeitet; ein unverschluesseltes Objekt bricht
den Lauf ab, statt im Artefakt zu landen. Noetig, weil Garage keine
Bucket-Versionierung kann.

errored.tfstate wird gesichert, nicht geloescht: es kann die einzige aktuelle
State-Kopie sein.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Self-CI-Integration

Der Beweis, dass die Kette läuft. **Nur hier** entscheidet sich, ob die Atome funktionieren — lokal ist das nicht prüfbar.

**Files:**
- Modify: `.github/workflows/self-ci.yml`

**Interfaces:**
- Consumes: alles aus den Tasks 1–4.
- Produces: die Jobs `tofu-plan-emit`, `tofu-apply-happy`, `assert-tofu-apply`, alle vom `summary`-Aggregator erreichbar.

- [ ] **Step 1: Plan-Lauf mit Artefakt**

```yaml
  # ----- tofu-plan mit Artefakt: Grundlage fuer den Apply-Test -----
  tofu-plan-emit:
    uses: ./.github/workflows/tofu-plan.yml
    permissions:
      contents: read
      pull-requests: write
    with:
      working_directory: tests/fixtures/tofu-apply-local
      lock: false
      comment_on_pr: false
      emit_plan: true
      concurrency_key: selfci-apply
      runs_on: '["ubuntu-latest"]'
    secrets: inherit
```

Das Secret `tf_encryption_passphrase` muss im Katalog-Repo existieren, sonst verweigert der Upload-Riegel. **Vor dem ersten Lauf setzen:**

```bash
gh secret set TF_ENCRYPTION_PASSPHRASE --repo serverkraken/reusable-workflows --body "$(openssl rand -base64 32)"
```

- [ ] **Step 2: Apply gegen genau diesen Lauf**

```yaml
  tofu-apply-happy:
    needs: [tofu-plan-emit]
    uses: ./.github/workflows/tofu-apply.yml
    permissions:
      contents: read
      actions: read
    with:
      working_directory: tests/fixtures/tofu-apply-local
      concurrency_key: selfci-apply
      plan_run_id: ${{ github.run_id }}
      runs_on: '["ubuntu-latest"]'
    secrets: inherit
```

Hinweis: `github.run_id` funktioniert hier, weil Plan und Apply im **selben** Lauf stecken — der Self-CI-Test bildet damit den Artefakt-Transport ab, nicht den Zeitverzug. Das Altern des Plans wird in Task 6 (Nightly) separat geprüft.

- [ ] **Step 3: Assertion**

```yaml
  assert-tofu-apply:
    needs: [tofu-apply-happy]
    runs-on: ubuntu-latest
    steps:
      - name: apply_status muss success sein
        env:
          STATUS: ${{ needs.tofu-apply-happy.outputs.apply_status }}
          LINE: ${{ needs.tofu-apply-happy.outputs.summary_line }}
        run: |
          set -euo pipefail
          if [[ "$STATUS" != "success" ]]; then
            echo "::error::erwartet apply_status=success, bekam '${STATUS}'" >&2
            exit 1
          fi
          if [[ "$LINE" != *"Apply complete"* ]]; then
            echo "::error::summary_line sollte 'Apply complete' enthalten, war: '${LINE}'" >&2
            exit 1
          fi
          echo "tofu-apply meldete: ${LINE}"
```

- [ ] **Step 4: Beide Assert-Jobs an den Aggregator hängen**

In der `needs:`-Liste des `summary`-Jobs ergänzen: `- assert-tofu-apply`. `check-summary-coverage.sh` verlangt, dass jeder Job erreichbar ist — ein `summary-exempt`-Marker an einem trotzdem erreichbaren Job schlägt ebenfalls fehl.

- [ ] **Step 5: Gates und Commit**

```bash
actionlint
bash tests/conventions/check-summary-coverage.sh; echo "coverage rc=$?"
```

```bash
git add .github/workflows/self-ci.yml
git commit -m "test: Self-CI deckt den Apply-Pfad ab

tofu-plan legt in der Fixture einen verschluesselten Plan ab, tofu-apply holt
ihn aus demselben Lauf und wendet ihn an. Damit ist der Artefakt-Transport
inklusive Entschluesselung und Vorpruefungen abgedeckt.

Nicht abgedeckt und bewusst so: dass ein Mensch den Dispatch ausloest. Das ist
Konfiguration im Adopter-Repo, kein Verhalten des Atoms.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Fehlerpfade im Nightly

**Files:**
- Modify: `.github/workflows/failure-paths-nightly.yml`

**Interfaces:**
- Consumes: die Atome aus Phase 1 und 2.
- Produces: Jobs, die belegen, dass jede Vorprüfung greift.

- [ ] **Step 1: Drei Fehlerpfade ergänzen**

Nach dem Muster des Blocks „cleanup-images DESTRUKTIV" (`failure-paths-nightly.yml`, ab Zeile 631): Job mit `continue-on-error: true` aufrufen, danach ein Assert-Job, der `result == 'failure'` verlangt.

| Job | Aufbau | Erwartung |
|---|---|---|
| `test-tofu-apply-wrong-stack` | `tofu-apply` mit `working_directory: tests/fixtures/tofu-plan-local`, aber `plan_run_id` eines Plans für `tofu-apply-local` | Vorprüfung 1 bricht ab |
| `test-tofu-apply-stale` | `tofu-apply` mit `max_plan_age_minutes: 0` | Vorprüfung 4 bricht ab |
| `test-tofu-plan-emit-without-key` | `tofu-plan` mit `emit_plan: true`, aber ohne `tf_encryption_passphrase` (per `secrets:` einzeln übergeben statt `inherit`) | Der Upload-Riegel bricht ab |

- [ ] **Step 2: Assertions schreiben**

Je Job dasselbe Muster, mit dem konkreten Grund im Text:

```yaml
  assert-tofu-apply-wrong-stack:
    needs: test-tofu-apply-wrong-stack
    if: always()
    runs-on: ubuntu-latest
    steps:
      - env:
          RESULT: ${{ needs.test-tofu-apply-wrong-stack.result }}
        run: |
          set -euo pipefail
          # Ein Erfolg waere hier der Fehler: das Atom haette einen Plan
          # fuer einen anderen Stack angewandt.
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::erwartet failure (Plan gehoert zu anderem Stack), bekam '${RESULT}'" >&2
            exit 1
          fi
          echo "Vorpruefung 'Stack' greift"
```

- [ ] **Step 3: Gates und Commit**

```bash
actionlint
bash tests/conventions/check-summary-coverage.sh; echo "coverage rc=$?"
```

```bash
git add .github/workflows/failure-paths-nightly.yml
git commit -m "test: Fehlerpfade fuer die Apply-Vorpruefungen

Drei Faelle im Nightly: Plan fuer einen anderen Stack, abgelaufener Plan, und
emit_plan ohne Verschluesselungsschluessel. Alle drei muessen abbrechen --
ein gruener Lauf waere hier der Fehler.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Selbst-Review

**Spec-Abdeckung.** § 6.1 (Composite) → Task 1. § 6.2 (`tofu-plan`-Änderungen) → Task 2. § 6.3 (`tofu-apply` samt vier Vorprüfungen) → Task 4. § 6.7 (Concurrency) → Tasks 2 und 4. § 7.1 (Verschlüsselung als Voraussetzung, Nachweis über `enforced`) → Task 1 Step 1 und Task 2 Step 5. § 7.2 (State-Backup mit `workspace_key_prefix`) → Task 4 Step 1. § 8 (Sicherheitsgrenzen, `errored.tfstate`, Outputs-Allowlist) → Task 4. § 10 (Fixtures, Tests) → Tasks 3, 5, 6.

**Nicht in diesem Plan**, gehört nach Plan 3: `tofu-destroy.yml`, `tofu-unlock.yml`, `tofu-drift.yml`, der auskommentierte Template-Block, das Runbook in `docs/operations.md` (Task 4 verweist bereits darauf) und der Absatz für gegatete Zwei-Job-Atome in `docs/conventions/step-summary.md` — letzterer ist nach dem Wegfall des Environment-Gates ohnehin gegenstandslos geworden; `tofu-apply` ist einjobbig.

**Zwei Dinge, die erst die CI zeigen kann.** Erstens: ob `gh run download` das Artefakt eines *anderen* Laufs im selben Repo mit `actions: read` holen darf — der Self-CI-Test in Task 5 nutzt denselben Lauf und beweist das nicht. Zweitens: ob `date -u -d` auf dem self-hosted Pool existiert; der Fallback auf Python in Task 4 Step 1 ist genau dafür da, aber ungeprüft. Beides gehört beim ersten echten Adopter-Lauf angesehen.

**Migrationsfalle, bewusst so gelöst.** `enforced = true` verweigert das Lesen eines heute unverschlüsselten States. Der erste Lauf eines Adopters mit vorhandenem Klartext-State braucht `allow_unencrypted_fallback: true` — genau einmal. Der Input trägt eine `::warning::`, weil ein dauerhaft gesetztes Flag den Schutz aufhebt, ohne dass irgendetwas rot wird.
