# IaC- und Shell-Atome — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Katalog bekommt ein Shell-Lint-Atom und drei IaC-Bausteine, und `serverkraken/homelab-hetzner` wird onboarded, sodass seine beiden INTERIM-Inline-Jobs verschwinden.

**Architecture:** Vier Phasen, jede für sich releasebar. Jedes Atom folgt dem Katalog-Skelett: `runs_on`-Wächter → Checkout → App-Token → Katalog-Checkout nach `.catalog` → Composite Action für die Toolchain → Arbeit → Step-Summary → Gate. Risikobehaftete Bash-Logik wird in `scripts/*.sh` bzw. `scripts/*.py` ausgelagert und mit **bats** geprüft, nie inline gelassen.

**Tech Stack:** GitHub Actions (`workflow_call`), Bash, Python 3 (stdlib), Go (Detektor), bats, shellcheck, shfmt, OpenTofu, tflint.

**Spec:** `docs/superpowers/specs/2026-08-27-iac-shell-atoms-design.md`
(flow: `specs/2026-08-27-iac-shell-atoms-design`)

## Global Constraints

- **Arbeitsverzeichnis:** Worktree `.worktrees/iac-shell-atoms`, Branch `feat/iac-shell-atoms`. Alle Pfade unten sind relativ dazu.
- **Keine Third-Party-Setup-Actions.** Toolchains werden als gepinntes Binary direkt installiert, mit Renovate-Marker. Verboten: `opentofu/setup-opentofu`, `hashicorp/setup-terraform`, `terraform-linters/setup-tflint`.
- **Fremde Actions auf SHA gepinnt**, mit Versionskommentar. Bestehende Pins wiederverwenden: `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6`, `actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3`, `github/codeql-action/upload-sarif@7211b7c8077ea37d8641b6271f6a365a22a5fbfa # v4`, `actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7`.
- **Jedes neue `workflow_call`-Atom braucht:** Kopfzeile `# Summary convention: docs/conventions/step-summary.md`, einen Stability-Surface-Kommentar, `permissions:` auf Workflow-Ebene, den `runs_on`-Wächter wörtlich aus `kube-lint.yml`, den Block „Resolve catalog ref" mit `# renovate-marker: catalog-major-ref`, eine Sektion in `docs/contracts.md`, sowie einen Job in `.github/workflows/self-ci.yml`, der vom `summary`-Aggregator aus erreichbar ist.
- **Step-Summary-Schema:** `## <atom-name>` / `**Tool:**` / optionale Kontextzeilen / `**Result:**` mit genau einem Glyph aus `✓ ✗ ▲` / Body. Keine Emoji. Schreiben immer mit `>>` und `|| true`.
- **Alle Änderungen additiv** — Minor-Bumps in `v4`, kein Major.
- **Conventional Commits** auf Deutsch im Body, Präfix englisch (`feat:`, `fix:`, `docs:`, `test:`).
- **Gates, die vor jedem Commit grün sein müssen:**
  ```bash
  bash tests/conventions/check-step-summary.sh
  bash tests/conventions/check-contracts.sh
  bash tests/conventions/check-summary-coverage.sh
  python3 tests/conventions/check-contract-defaults.py
  python3 tests/conventions/check-runs-on-guard.py
  python3 tests/conventions/check-reusable-permissions.py
  python3 tests/conventions/check-pin-scope-doc.py
  python3 tests/conventions/check-ref-fork-guard.py
  bats tests/shell/
  ```

---

# Phase 1 — `lint-shell`

Ergebnis der Phase: Adopter können `lint-shell.yml@v4` aufrufen; `homelab-hetzner` kann seinen `shellcheck`-Interim-Job ersetzen.

### Task 1: SARIF-Konverter für shellcheck

shellcheck kann kein SARIF. `-f json1` liefert ein Objekt mit `comments`; daraus wird SARIF 2.1.0. Präzedenz im Repo: `scripts/merge-sarif-runs.py`, getestet über `tests/shell/merge-sarif-runs.bats`.

**Files:**
- Create: `scripts/shellcheck-to-sarif.py`
- Test: `tests/shell/shellcheck-to-sarif.bats`

**Interfaces:**
- Consumes: nichts
- Produces: CLI `python3 scripts/shellcheck-to-sarif.py --tool-version <v> < json1.json > out.sarif`. Exit 0 bei Erfolg, 1 bei ungültiger Eingabe. Task 3 ruft es so auf.

- [ ] **Step 1: Write the failing test**

`tests/shell/shellcheck-to-sarif.bats`:

```bash
#!/usr/bin/env bats

# scripts/shellcheck-to-sarif.py wandelt `shellcheck -f json1` in SARIF 2.1.0,
# weil shellcheck selbst kein SARIF kann und der Katalog kein weiteres fremdes
# Binary einschleppen soll.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/shellcheck-to-sarif.py"
  cd "$BATS_TEST_TMPDIR" || exit 1
}

@test "leere Fundliste ergibt gueltiges SARIF mit null Results" {
  echo '{"comments":[]}' > in.json
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == "2.1.0"'
  echo "$output" | jq -e '.runs | length == 1'
  echo "$output" | jq -e '.runs[0].results | length == 0'
  echo "$output" | jq -e '.runs[0].tool.driver.name == "ShellCheck"'
  echo "$output" | jq -e '.runs[0].tool.driver.version == "0.10.0"'
}

@test "ein Fund wird zu einem Result mit Regel-ID, Ort und Level" {
  cat > in.json <<'JSON'
{"comments":[{"file":"scripts/a.sh","line":3,"endLine":3,"column":5,"endColumn":9,
  "level":"warning","code":2086,"message":"Double quote to prevent globbing."}]}
JSON
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.runs[0].results[0].ruleId == "SC2086"'
  echo "$output" | jq -e '.runs[0].results[0].level == "warning"'
  echo "$output" | jq -e '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri == "scripts/a.sh"'
  echo "$output" | jq -e '.runs[0].results[0].locations[0].physicalLocation.region.startLine == 3'
  echo "$output" | jq -e '.runs[0].results[0].locations[0].physicalLocation.region.startColumn == 5'
  echo "$output" | jq -e '.runs[0].tool.driver.rules[0].helpUri == "https://www.shellcheck.net/wiki/SC2086"'
}

# SARIF kennt error/warning/note. shellchecks `info` und `style` haben dort
# keine Entsprechung und muessen auf `note` fallen — sonst lehnt die
# CodeQL-Action den Upload ab.
@test "info und style werden auf note abgebildet" {
  cat > in.json <<'JSON'
{"comments":[
 {"file":"a.sh","line":1,"endLine":1,"column":1,"endColumn":2,"level":"info","code":2034,"message":"x"},
 {"file":"a.sh","line":2,"endLine":2,"column":1,"endColumn":2,"level":"style","code":2006,"message":"y"}]}
JSON
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.runs[0].results[].level] == ["note","note"]'
}

# Zwei Funde derselben Regel duerfen die Regel nur EINMAL deklarieren und
# beide muessen per ruleIndex darauf zeigen — sonst zaehlt der
# Code-Scanning-Tab dieselbe Regel doppelt.
@test "gleiche Regel wird nur einmal deklariert, ruleIndex zeigt darauf" {
  cat > in.json <<'JSON'
{"comments":[
 {"file":"a.sh","line":1,"endLine":1,"column":1,"endColumn":2,"level":"warning","code":2086,"message":"x"},
 {"file":"b.sh","line":9,"endLine":9,"column":1,"endColumn":2,"level":"warning","code":2086,"message":"y"}]}
JSON
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.runs[0].tool.driver.rules | length == 1'
  echo "$output" | jq -e '[.runs[0].results[].ruleIndex] == [0,0]'
}

# Ein Absturz von shellcheck liefert leere oder kaputte Ausgabe. Die darf NICHT
# als "null Funde" durchgehen — dieselbe Fehlerklasse wie in kube-lint.yml.
@test "kaputte Eingabe bricht ab statt leeres SARIF zu liefern" {
  echo 'not json' > in.json
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kein gueltiges JSON"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/shell/shellcheck-to-sarif.bats`
Expected: FAIL — `python3: can't open file '.../scripts/shellcheck-to-sarif.py'`

- [ ] **Step 3: Write minimal implementation**

`scripts/shellcheck-to-sarif.py`:

```python
#!/usr/bin/env python3
"""Wandelt `shellcheck -f json1` in SARIF 2.1.0.

shellcheck kann kein SARIF. Statt ein weiteres fremdes Binary in den Katalog
zu holen, macht dieses Skript die Umwandlung — dasselbe Muster wie
scripts/merge-sarif-runs.py und scripts/merge-trivy-json.py.

Eingabe auf stdin, Ausgabe auf stdout.
"""
import argparse
import json
import sys

# SARIF kennt nur error/warning/note. shellchecks info und style haben dort
# keine Entsprechung; ohne diese Abbildung lehnt die CodeQL-Action den Upload
# ab, statt die Funde anzuzeigen.
LEVELS = {"error": "error", "warning": "warning", "info": "note", "style": "note"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool-version", default="unknown")
    args = ap.parse_args()

    raw = sys.stdin.read()
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        # Bewusst laut: eine leere oder kaputte Ausgabe bedeutet, dass
        # shellcheck gar nicht gelaufen ist. Als leeres SARIF durchgereicht
        # saehe das aus wie "null Funde".
        print(f"shellcheck-Ausgabe ist kein gueltiges JSON: {exc}", file=sys.stderr)
        return 1

    comments = doc.get("comments")
    if comments is None:
        print("shellcheck-Ausgabe hat kein Feld 'comments'", file=sys.stderr)
        return 1

    rules: list[dict] = []
    rule_index: dict[str, int] = {}
    results: list[dict] = []

    for c in comments:
        rule_id = f"SC{c['code']}"
        if rule_id not in rule_index:
            rule_index[rule_id] = len(rules)
            rules.append({
                "id": rule_id,
                "name": rule_id,
                "shortDescription": {"text": c.get("message", rule_id)},
                "helpUri": f"https://www.shellcheck.net/wiki/{rule_id}",
                "properties": {"tags": ["shell"]},
            })
        results.append({
            "ruleId": rule_id,
            "ruleIndex": rule_index[rule_id],
            "level": LEVELS.get(c.get("level", "warning"), "warning"),
            "message": {"text": c.get("message", "")},
            "locations": [{
                "physicalLocation": {
                    "artifactLocation": {"uri": c["file"]},
                    "region": {
                        "startLine": c.get("line", 1),
                        "startColumn": c.get("column", 1),
                        "endLine": c.get("endLine", c.get("line", 1)),
                        "endColumn": c.get("endColumn", c.get("column", 1)),
                    },
                },
            }],
        })

    sarif = {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {"driver": {
                "name": "ShellCheck",
                "version": args.tool_version,
                "informationUri": "https://www.shellcheck.net",
                "rules": rules,
            }},
            "results": results,
        }],
    }
    json.dump(sarif, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/shell/shellcheck-to-sarif.bats`
Expected: 5 Tests PASS

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/shellcheck-to-sarif.py
git add scripts/shellcheck-to-sarif.py tests/shell/shellcheck-to-sarif.bats
git commit -m "feat(lint-shell): SARIF-Konverter fuer shellcheck

shellcheck kann kein SARIF. Der Konverter aus \`-f json1\` haelt den
Katalog frei von einem weiteren fremden Binary — dasselbe Muster wie
merge-sarif-runs.py.

info und style fallen auf SARIF-Level note, sonst lehnt die
CodeQL-Action den Upload ab. Kaputte Eingabe bricht ab, statt als
\"null Funde\" durchzugehen."
```

### Task 2: Composite Action `install-shellcheck`

**Files:**
- Create: `actions/install-shellcheck/action.yml`

**Interfaces:**
- Consumes: nichts
- Produces: Action mit Inputs `version` (string, leer → Pin) und `shfmt` (string `'true'`/`'false'`, Default `'false'`) plus `shfmt_version`. Legt `shellcheck` und optional `shfmt` nach `/usr/local/bin`. Task 3 nutzt sie als `uses: ./.catalog/actions/install-shellcheck`.

- [ ] **Step 1: Write the action**

`actions/install-shellcheck/action.yml`:

```yaml
# actions/install-shellcheck/action.yml
name: install-shellcheck
description: |
  Install shellcheck (and optionally shfmt) as pinned, Renovate-managed
  binaries. Mirrors the install-kube-linter pattern — never a third-party
  setup action.

  Deliberately NOT `apt-get install shellcheck`: the catalog default runner is
  [self-hosted, Linux], and the apt version is unpinned and old. A lint gate
  whose ruleset differs per runner image produces findings that vanish on
  another machine.

inputs:
  version:
    description: 'shellcheck version (no leading v). Empty → pinned default.'
    required: false
    default: ''
  shfmt:
    description: 'When "true", also install shfmt.'
    required: false
    default: 'false'
  shfmt_version:
    description: 'shfmt version (no leading v). Empty → pinned default.'
    required: false
    default: ''

runs:
  using: composite
  steps:
    - name: Install shellcheck
      shell: bash
      env:
        # renovate: datasource=github-releases depName=koalaman/shellcheck
        SHELLCHECK_VERSION: '0.10.0'
        REQUESTED: ${{ inputs.version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$SHELLCHECK_VERSION}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=x86_64 ;;
          aarch64|arm64) A=aarch64 ;;
          *) echo "::error::Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; cd "$TMP"
        curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/shellcheck-v${VERSION}.linux.${A}.tar.xz" -o sc.tar.xz
        tar -xJf sc.tar.xz "shellcheck-v${VERSION}/shellcheck"
        sudo install -m 0755 "shellcheck-v${VERSION}/shellcheck" /usr/local/bin/shellcheck
        shellcheck --version

    - name: Install shfmt
      if: ${{ inputs.shfmt == 'true' }}
      shell: bash
      env:
        # renovate: datasource=github-releases depName=mvdan/sh
        SHFMT_VERSION: '3.10.0'
        REQUESTED: ${{ inputs.shfmt_version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$SHFMT_VERSION}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=amd64 ;;
          aarch64|arm64) A=arm64 ;;
          *) echo "::error::Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        curl -fsSL "https://github.com/mvdan/sh/releases/download/v${VERSION}/shfmt_v${VERSION}_linux_${A}" -o "$TMP/shfmt"
        sudo install -m 0755 "$TMP/shfmt" /usr/local/bin/shfmt
        shfmt --version
```

- [ ] **Step 2: Verify the action lints**

Run: `actionlint` (falls installiert) und `python3 tests/conventions/check-pin-scope-doc.py`
Expected: exit 0 — die Action nutzt keine fremden Actions, also keine SHA-Pins nötig.

- [ ] **Step 3: Add the contracts.md section**

`docs/contracts.md` bekommt eine Sektion `### actions/install-shellcheck` mit den drei Inputs `version`, `shfmt`, `shfmt_version` in der Form der Nachbarsektionen (`### actions/install-kube-linter` als Vorlage; Spaltenkopf `| Kind | Name | Type | Required | Default | Description |`).

- [ ] **Step 4: Run the contracts gate**

Run: `bash tests/conventions/check-contracts.sh`
Expected: exit 0 — die dokumentierten Namen decken sich mit `action.yml`.

- [ ] **Step 5: Commit**

```bash
git add actions/install-shellcheck/action.yml docs/contracts.md
git commit -m "feat(lint-shell): install-shellcheck als gepinnte Composite Action

Kein apt-get: der Default-Runner ist [self-hosted, Linux], und eine
ungepinnte apt-Version erzeugt Funde, die auf einer anderen Maschine
verschwinden. shfmt kommt nur, wenn es angefordert wird."
```

### Task 3: `lint-shell.yml`

**Files:**
- Create: `.github/workflows/lint-shell.yml`
- Modify: `docs/contracts.md`

**Interfaces:**
- Consumes: `actions/install-shellcheck` (Task 2), `scripts/shellcheck-to-sarif.py` (Task 1)
- Produces: `workflow_call`-Atom `lint-shell` mit Output `findings_count` (string). Task 4 ruft es auf, Task 13 rendert Aufrufe davon.

- [ ] **Step 1: Write the workflow**

`.github/workflows/lint-shell.yml`:

```yaml
# .github/workflows/lint-shell.yml
# Summary convention: docs/conventions/step-summary.md
#
# Stability surface (workflow_call contract — breaking changes = major bump):
#   inputs:  paths, severity, shellcheck_version, follow_sources,
#            scan_shebangs, shfmt, sarif, fail_on_findings, report_slug, runs_on
#   secrets: release_please_app_client_id, release_please_app_private_key
#   outputs: findings_count
name: lint-shell
on:
  workflow_call:
    inputs:
      paths:
        description: 'Newline-separated globs to check.'
        required: false
        type: string
        default: '**/*.sh'
      severity:
        description: 'shellcheck minimum severity: error, warning, info or style.'
        required: false
        type: string
        default: 'style'
      shellcheck_version:
        description: 'Override shellcheck version (empty → composite default).'
        required: false
        type: string
        default: ''
      follow_sources:
        description: 'Pass -x so `source lib/common.sh` is checked too.'
        required: false
        type: boolean
        default: true
      scan_shebangs:
        description: >-
          Also check tracked files WITHOUT a .sh suffix whose first line is a
          shell shebang. A linter that silently skips `scripts/deploy` checks
          half the scripts in many repos. Scoped by the same `paths` globs
          with the .sh requirement dropped, so it never widens into a
          whole-repo scan.
        required: false
        type: boolean
        default: true
      shfmt:
        description: 'Also run `shfmt -d` (format check).'
        required: false
        type: boolean
        default: false
      sarif:
        description: 'Upload SARIF to GitHub code-scanning. Auto-skipped on forks.'
        required: false
        type: boolean
        default: true
      fail_on_findings:
        description: 'Exit non-zero when shellcheck reports findings.'
        required: false
        type: boolean
        default: true
      report_slug:
        description: >-
          Suffix that makes this call's SARIF category and artifact name
          unique. Required when a repo calls this atom more than once in the
          same workflow.
        required: false
        type: string
        default: ''
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
    outputs:
      findings_count:
        description: 'Number of shellcheck findings.'
        value: ${{ jobs.lint.outputs.findings_count }}
    secrets:
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'

permissions:
  contents: read
  security-events: write
  actions: read

concurrency:
  group: lint-shell-${{ github.workflow }}-${{ github.ref }}-${{ inputs.paths }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 15
    outputs:
      findings_count: ${{ steps.count.outputs.findings_count }}
    steps:
      # Ein leeres runs_on faellt NICHT von selbst auf. GitHub plant den Job
      # dann auf irgendeinem Runner der Default-Gruppe ein und laesst ihn
      # arbeiten. `fromJSON` oben faengt nur KAPUTTES JSON ab — `[]` ist
      # gueltiges JSON und kommt hier an.
      # Hintergrund und der gemessene Lauf: tests/conventions/check-runs-on-guard.py
      - name: Reject an empty runs_on
        working-directory: ${{ github.workspace }}
        env:
          RUNS_ON: ${{ inputs.runs_on }}
        run: |
          set -euo pipefail
          trimmed="${RUNS_ON//[[:space:]]/}"
          if [[ "$trimmed" != "["*"]" || ! "$trimmed" =~ [A-Za-z0-9] ]]; then
            echo "::error::runs_on must be a non-empty JSON array of runner labels, got: ${RUNS_ON}" >&2
            echo "::error::an empty array does NOT fail the job — GitHub schedules it on any runner in the default group" >&2
            exit 1
          fi

      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
      - name: Mint catalog-scoped App token
        id: catalog-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3
        with:
          client-id: ${{ secrets.release_please_app_client_id }}
          private-key: ${{ secrets.release_please_app_private_key }}
          owner: serverkraken
          repositories: reusable-workflows
      - name: Resolve catalog ref
        id: catalog-ref
        env:
          IS_SELF_CI: ${{ github.repository == 'serverkraken/reusable-workflows' }}
          SELF_SHA: ${{ github.sha }}
        run: |
          if [[ "$IS_SELF_CI" == "true" ]]; then
            echo "ref=$SELF_SHA" >> "$GITHUB_OUTPUT"
          else
            # renovate-marker: catalog-major-ref
            echo "ref=v4" >> "$GITHUB_OUTPUT"
          fi
      - name: Checkout catalog for composite actions
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ steps.catalog-ref.outputs.ref }}
          token: ${{ steps.catalog-token.outputs.token }}
          path: .catalog

      - name: Install shellcheck
        uses: ./.catalog/actions/install-shellcheck
        with:
          version: ${{ inputs.shellcheck_version }}
          shfmt: ${{ inputs.shfmt }}

      - name: Collect files
        id: files
        env:
          PATHS: ${{ inputs.paths }}
          SCAN_SHEBANGS: ${{ inputs.scan_shebangs }}
        # `git ls-files` statt `find`: nur getrackte Dateien, und damit
        # automatisch nichts aus .catalog (das ist ein zweiter Checkout, kein
        # Teil des Index) und nichts Ungetracktes aus einem Vorlauf.
        run: |
          set -euo pipefail
          : > files.txt
          while IFS= read -r glob; do
            [[ -z "$glob" ]] && continue
            git ls-files -z -- "$glob" >> files.z || true
          done <<< "$PATHS"
          if [[ -f files.z ]]; then
            tr '\0' '\n' < files.z >> files.txt
          fi
          if [[ "$SCAN_SHEBANGS" == "true" ]]; then
            # Der Shebang-Scan folgt DENSELBEN Globs wie oben, nur ohne die
            # .sh-Bedingung: aus `scripts/**/*.sh` wird `scripts/**/*`.
            # Ohne diese Ableitung durchsuchte er das ganze Repo und ignorierte
            # damit die Angabe des Aufrufers — wer `paths: scripts/**/*.sh`
            # setzt, erwartet eine Begrenzung auf scripts/, nicht einen Scan
            # ueber jede getrackte Datei.
            : > shebang.z
            while IFS= read -r glob; do
              [[ -z "$glob" ]] && continue
              git ls-files -z -- "${glob%\*.sh}*" >> shebang.z || true
            done <<< "$PATHS"
            # Erste Zeile lesen, nicht die ganze Datei: bei Binaerdateien waere
            # ein grep ueber den vollen Inhalt teuer und irrefuehrend.
            while IFS= read -r f; do
              [[ -f "$f" ]] || continue
              [[ "$f" == *.sh ]] && continue
              head -c 200 "$f" 2>/dev/null | head -1 \
                | grep -Eq '^#!.*\b(ba|k|z|da)?sh\b' && echo "$f" >> files.txt || true
            done < <(tr '\0' '\n' < shebang.z)
          fi
          sort -u files.txt -o files.txt
          COUNT=$(wc -l < files.txt | tr -d ' ')
          echo "count=$COUNT" >> "$GITHUB_OUTPUT"
          echo "Zu pruefende Dateien: $COUNT"
          cat files.txt

      - name: Run shellcheck (json1)
        id: run
        env:
          SEVERITY: ${{ inputs.severity }}
          FOLLOW: ${{ inputs.follow_sources }}
          FILE_COUNT: ${{ steps.files.outputs.count }}
        # shellcheck beendet bei FUNDEN mit rc=1, der Schritt darf daran nicht
        # sterben — der SARIF-Upload und das Gate kommen danach. `|| true`
        # waere aber falsch: es wuerfe auch einen Absturz weg, und der saehe
        # dann aus wie "null Funde" (dieselbe Fehlerklasse wie Audit F-3 in
        # kube-lint.yml). Deshalb rc einfangen und die Ausgabe pruefen.
        run: |
          if [[ "$FILE_COUNT" == "0" ]]; then
            echo '{"comments":[]}' > shellcheck.json
            echo "::notice::keine passenden Dateien gefunden"
            exit 0
          fi
          ARGS=(-f json1 -S "$SEVERITY")
          [[ "$FOLLOW" == "true" ]] && ARGS+=(-x)
          set +e
          xargs -a files.txt shellcheck "${ARGS[@]}" > shellcheck.json 2> shellcheck.err
          rc=$?
          set -e
          cat shellcheck.err >&2 || true
          if [[ "$rc" -ne 0 && ! -s shellcheck.json ]]; then
            echo "::error::shellcheck exited $rc without producing a report — it did not check anything: $(tr -d '\n' < shellcheck.err)" >&2
            exit 1
          fi

      - name: Convert to SARIF
        env:
          CONVERTER: ${{ github.workspace }}/.catalog/scripts/shellcheck-to-sarif.py
        run: |
          set -euo pipefail
          VER=$(shellcheck --version | awk '/^version:/ {print $2}')
          python3 "$CONVERTER" --tool-version "${VER:-unknown}" \
            < shellcheck.json > shellcheck.sarif

      - name: Count findings
        id: count
        run: |
          set -euo pipefail
          COUNT=$(jq '[.runs[].results[]] | length' shellcheck.sarif)
          echo "findings_count=${COUNT:-0}" >> "$GITHUB_OUTPUT"
          echo "shellcheck findings: ${COUNT:-0}"

      - name: Run shfmt
        id: fmt
        if: inputs.shfmt
        continue-on-error: true
        run: |
          set -euo pipefail
          xargs -a files.txt shfmt -d

      - name: Derive report slug
        id: slug
        env:
          RAW: ${{ inputs.report_slug }}
        run: |
          set -euo pipefail
          slug="$(printf '%s' "${RAW:-}" | tr '/' '-' | tr -cd 'A-Za-z0-9._-')"
          if [ -n "$slug" ]; then
            echo "category=:$slug" >> "$GITHUB_OUTPUT"
            echo "artifact=-$slug" >> "$GITHUB_OUTPUT"
          else
            echo "category=" >> "$GITHUB_OUTPUT"
            echo "artifact=" >> "$GITHUB_OUTPUT"
          fi

      - name: Upload SARIF to code-scanning
        # Fork-PR guard only: on push/schedule there is no pull_request
        # context, and the upload on the default branch is the one that forms
        # the code-scanning baseline.
        if: inputs.sarif && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)
        uses: github/codeql-action/upload-sarif@7211b7c8077ea37d8641b6271f6a365a22a5fbfa # v4
        with:
          sarif_file: shellcheck.sarif
          category: lint-shell${{ steps.slug.outputs.category }}

      - name: Summary
        if: always()
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
          FILE_COUNT: ${{ steps.files.outputs.count }}
          SEVERITY: ${{ inputs.severity }}
          FAIL_ON_FINDINGS: ${{ inputs.fail_on_findings }}
          SHFMT_ENABLED: ${{ inputs.shfmt }}
          SHFMT_OUTCOME: ${{ steps.fmt.outcome }}
        run: |
          sc_version=$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}' || echo unknown)
          if [[ "${COUNT:-0}" == "0" ]]; then
            result="✓ no findings"
            sc_row="✓"
          elif [[ "$FAIL_ON_FINDINGS" == "true" ]]; then
            result="✗ ${COUNT} findings"
            sc_row="✗"
          else
            result="▲ ${COUNT} findings (gate disabled)"
            sc_row="▲"
          fi
          {
            echo "## lint-shell"
            echo ""
            echo "**Tool:** shellcheck ${sc_version}"
            echo "**Files:** ${FILE_COUNT}"
            echo "**Severity:** \`${SEVERITY}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Check | Status |"
            echo "|---|---|"
            echo "| shellcheck | ${sc_row} |"
            if [[ "$SHFMT_ENABLED" == "true" ]]; then
              if [[ "$SHFMT_OUTCOME" == "success" ]]; then
                echo "| shfmt | ✓ |"
              else
                echo "| shfmt | ✗ |"
              fi
            fi
          } >> "$GITHUB_STEP_SUMMARY" || true

      - name: Fail on findings
        if: inputs.fail_on_findings && steps.count.outputs.findings_count != '0'
        env:
          COUNT: ${{ steps.count.outputs.findings_count }}
        run: |
          jq -r '.runs[0].results[] | "::error file=\(.locations[0].physicalLocation.artifactLocation.uri),line=\(.locations[0].physicalLocation.region.startLine)::\(.ruleId) \(.message.text)"' \
            shellcheck.sarif | head -10 || true
          echo "::error::shellcheck found $COUNT issue(s)"
          exit 1

      - name: Fail on shfmt diff
        if: inputs.shfmt && inputs.fail_on_findings && steps.fmt.outcome == 'failure'
        run: |
          echo "::error::shfmt reported formatting differences"
          exit 1
```

- [ ] **Step 2: Add the contracts.md section**

`docs/contracts.md` bekommt `### .github/workflows/lint-shell.yml` mit allen zehn Inputs, dem Output `findings_count` und den zwei Secrets — Namen und Defaults exakt wie oben, sonst schlägt `check-contract-defaults.py` fehl.

- [ ] **Step 3: Run all convention gates**

```bash
bash tests/conventions/check-step-summary.sh
bash tests/conventions/check-contracts.sh
python3 tests/conventions/check-contract-defaults.py
python3 tests/conventions/check-runs-on-guard.py
python3 tests/conventions/check-reusable-permissions.py
python3 tests/conventions/check-ref-fork-guard.py
python3 tests/conventions/check-pin-scope-doc.py
```
Expected: alle exit 0

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint-shell.yml docs/contracts.md
git commit -m "feat(lint-shell): Shell-Lint-Atom fuer den Katalog

Shell ist die eine Sprache, die praktisch jedes Repo der Org enthaelt,
und hatte als einzige kein Atom.

Die Dateiliste kommt aus \`git ls-files\` — damit faellt der
.catalog-Checkout automatisch heraus. scan_shebangs erfasst zusaetzlich
Skripte ohne .sh-Endung.

shellcheck endet bei Funden mit rc=1; der Exit-Code wird eingefangen und
gegen die Ausgabe geprueft, statt mit \`|| true\` weggeworfen zu werden —
sonst saehe ein Absturz aus wie null Funde."
```

### Task 4: Fixtures und Self-CI-Jobs für `lint-shell`

**Files:**
- Create: `tests/fixtures/shell-clean/scripts/ok.sh`
- Create: `tests/fixtures/shell-findings/scripts/bad.sh`
- Create: `tests/fixtures/shell-findings/scripts/nosuffix`
- Modify: `.github/workflows/self-ci.yml`

**Interfaces:**
- Consumes: `lint-shell.yml` (Task 3)
- Produces: die Jobs `lint-shell-happy` und `lint-shell-findings`, beide im `needs:` des `summary`-Aggregators.

- [ ] **Step 1: Create the fixtures**

`tests/fixtures/shell-clean/scripts/ok.sh` — muss bei `-S style` sauber sein:

```bash
#!/usr/bin/env bash
# Fixture: haelt den lint-shell-Happy-Path sauber, auch bei -S style.
set -euo pipefail

greet() {
  local name="$1"
  printf 'hello %s\n' "$name"
}

greet "${1:-world}"
```

`tests/fixtures/shell-findings/scripts/bad.sh` — löst SC2086 aus:

```bash
#!/usr/bin/env bash
# Fixture: erzeugt bewusst SC2086 (ungequotete Variable), damit der
# Failure-Path des Gates geprueft wird.
target=$1
cp $target /tmp/
```

`tests/fixtures/shell-findings/scripts/nosuffix` — Datei **ohne** `.sh`, damit `scan_shebangs` mitgeprüft wird:

```bash
#!/bin/bash
# Fixture ohne .sh-Endung: nur scan_shebangs=true findet sie. SC2086 erneut.
files=$1
rm $files
```

- [ ] **Step 2: Add the happy-path job to self-ci.yml**

```yaml
  # ----- lint-shell: happy path -----
  lint-shell-happy:
    uses: ./.github/workflows/lint-shell.yml
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      paths: |-
        tests/fixtures/shell-clean/scripts/*.sh
      # Der Upload wuerde die Fixture-Funde in den Code-Scanning-Tab des
      # Katalogs schreiben und die echte Basislinie verfaelschen.
      sarif: false
      runs_on: '["ubuntu-latest"]'
    secrets:
      release_please_app_client_id: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      release_please_app_private_key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

- [ ] **Step 3: Add the failure-path job**

Das Gate muss **greifen**, der Job also fehlschlagen — geprüft wird per `continue-on-error` plus Assertion, wie es die bestehenden Failure-Path-Jobs im Repo tun. Vorlage: der `kube-lint`-Findings-Job.

```yaml
  # ----- lint-shell: Gate greift bei Funden -----
  lint-shell-findings:
    uses: ./.github/workflows/lint-shell.yml
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      paths: |-
        tests/fixtures/shell-findings/scripts/*.sh
      # AN, damit die Fixture ohne .sh-Endung tatsaechlich geprueft wird.
      # Der Scan folgt demselben Glob (scripts/*), bleibt also in der Fixture.
      scan_shebangs: true
      sarif: false
      # Das Atom soll die Funde MELDEN, ohne den Self-CI-Lauf rot zu faerben.
      # Geprueft wird der Zaehler, nicht der Exit-Code — so bleibt der Job im
      # summary-Graph und behauptet nichts Falsches.
      fail_on_findings: false
      runs_on: '["ubuntu-latest"]'
    secrets:
      release_please_app_client_id: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      release_please_app_private_key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}

  assert-lint-shell-findings:
    needs: [lint-shell-findings]
    runs-on: ubuntu-latest
    steps:
      - name: shellcheck muss die gepflanzten Funde sehen
        env:
          COUNT: ${{ needs.lint-shell-findings.outputs.findings_count }}
        run: |
          set -euo pipefail
          # >=2: je ein SC2086 aus bad.sh UND aus nosuffix. Ein Wert von 1
          # hiesse, dass scan_shebangs die Datei ohne Endung nicht erfasst hat.
          if [[ "${COUNT:-0}" -lt 2 ]]; then
            echo "::error::erwartet >=2 Funde (bad.sh und nosuffix), bekam '${COUNT}'" >&2
            echo "::error::genau 1 Fund bedeutet: scan_shebangs hat die Datei ohne .sh-Endung nicht erfasst" >&2
            exit 1
          fi
          echo "lint-shell meldete ${COUNT} Fund(e) — Gate-Pfad und scan_shebangs belegt"
```

- [ ] **Step 4: Wire both into the summary aggregator**

`.github/workflows/self-ci.yml`: `lint-shell-happy` und `assert-lint-shell-findings` in die `needs:`-Liste des `summary`-Jobs aufnehmen. `lint-shell-findings` selbst braucht keinen Eintrag — es hängt über `assert-lint-shell-findings` im Graph.

- [ ] **Step 5: Verify the coverage gate**

Run: `bash tests/conventions/check-summary-coverage.sh`
Expected: exit 0 — kein Job außerhalb des `summary`-Graphen.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/shell-clean tests/fixtures/shell-findings .github/workflows/self-ci.yml
git commit -m "test(lint-shell): Happy- und Failure-Path mit Fixtures

Die Findings-Fixture enthaelt zusaetzlich eine Datei ohne .sh-Endung,
damit scan_shebangs nicht ungeprueft bleibt.

Beide Jobs haengen im summary-Graphen — ein Job ausserhalb kann einen PR
nicht rot faerben und waere dekorativ."
```

---

# Phase 2 — `tofu-validate`

Ergebnis der Phase: `homelab-hetzner` kann seinen `tofu-validate`-Interim-Block gegen den Katalog-Aufruf tauschen und ist damit `opentofu/setup-opentofu@v1` los.

### Task 5: Composite Action `setup-tofu-toolchain`

**Files:**
- Create: `actions/setup-tofu-toolchain/action.yml`
- Modify: `docs/contracts.md`

**Interfaces:**
- Consumes: nichts
- Produces: Action mit Inputs `tofu_version`, `tflint` (`'true'`/`'false'`, Default `'false'`), `tflint_version`. Legt `tofu` und optional `tflint` nach `/usr/local/bin`. Tasks 6 und 9 nutzen sie.

- [ ] **Step 1: Write the action**

`actions/setup-tofu-toolchain/action.yml`:

```yaml
# actions/setup-tofu-toolchain/action.yml
name: setup-tofu-toolchain
description: |
  Install OpenTofu (and optionally tflint) as pinned, Renovate-managed
  binaries. Mirrors the setup-kube-toolchain pattern — direct binary installs,
  never a third-party setup action.

  OpenTofu, not Terraform: the binary is `tofu`, the registry is
  registry.opentofu.org. No serverkraken repo uses Terraform, so there is
  deliberately no `terraform` alias.

inputs:
  tofu_version:
    description: 'OpenTofu version (no leading v). Empty → pinned default.'
    required: false
    default: ''
  tflint:
    description: 'When "true", also install tflint.'
    required: false
    default: 'false'
  tflint_version:
    description: 'tflint version (no leading v). Empty → pinned default.'
    required: false
    default: ''

runs:
  using: composite
  steps:
    - name: Install OpenTofu
      shell: bash
      env:
        # renovate: datasource=github-releases depName=opentofu/opentofu
        TOFU_VERSION: '1.10.6'
        REQUESTED: ${{ inputs.tofu_version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$TOFU_VERSION}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=amd64 ;;
          aarch64|arm64) A=arm64 ;;
          *) echo "::error::Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; cd "$TMP"
        curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${VERSION}/tofu_${VERSION}_linux_${A}.zip" -o tofu.zip
        unzip -q tofu.zip tofu
        sudo install -m 0755 tofu /usr/local/bin/tofu
        tofu version

    - name: Install tflint
      if: ${{ inputs.tflint == 'true' }}
      shell: bash
      env:
        # renovate: datasource=github-releases depName=terraform-linters/tflint
        TFLINT_VERSION: '0.54.0'
        REQUESTED: ${{ inputs.tflint_version }}
      run: |
        set -euo pipefail
        VERSION="${REQUESTED:-$TFLINT_VERSION}"
        ARCH=$(uname -m)
        case "$ARCH" in
          x86_64) A=amd64 ;;
          aarch64|arm64) A=arm64 ;;
          *) echo "::error::Unsupported arch: $ARCH" >&2; exit 1 ;;
        esac
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; cd "$TMP"
        curl -fsSL "https://github.com/terraform-linters/tflint/releases/download/v${VERSION}/tflint_linux_${A}.zip" -o tflint.zip
        unzip -q tflint.zip tflint
        sudo install -m 0755 tflint /usr/local/bin/tflint
        tflint --version
```

- [ ] **Step 2: Add the contracts.md section**

`### actions/setup-tofu-toolchain` mit `tofu_version`, `tflint`, `tflint_version`.

- [ ] **Step 3: Run the gates**

```bash
bash tests/conventions/check-contracts.sh
python3 tests/conventions/check-pin-scope-doc.py
```
Expected: exit 0

- [ ] **Step 4: Commit**

```bash
git add actions/setup-tofu-toolchain/action.yml docs/contracts.md
git commit -m "feat(tofu): setup-tofu-toolchain als gepinnte Composite Action

Der Katalog verbietet fremde Setup-Actions. homelab-hetzner nutzt heute
opentofu/setup-opentofu@v1 im Interim-Block — diese Action loest sie ab.

OpenTofu, nicht Terraform: kein terraform-Alias, weil kein Repo der Org
Terraform benutzt."
```

### Task 6: `tofu-validate.yml`

**Files:**
- Create: `.github/workflows/tofu-validate.yml`
- Modify: `docs/contracts.md`

**Interfaces:**
- Consumes: `actions/setup-tofu-toolchain` (Task 5)
- Produces: Atom `tofu-validate` mit Output `checked_directories` (string). Tasks 7, 13 und 14 rufen es auf.

- [ ] **Step 1: Write the workflow**

`.github/workflows/tofu-validate.yml`:

```yaml
# .github/workflows/tofu-validate.yml
# Summary convention: docs/conventions/step-summary.md
#
# Stability surface (workflow_call contract — breaking changes = major bump):
#   inputs:  working_directories, tofu_version, tflint, lockfile_readonly, runs_on
#   secrets: release_please_app_client_id, release_please_app_private_key
#   outputs: checked_directories
#
# Dieses Atom ist bewusst CREDENTIAL-FREI: `tofu init -backend=false`
# ueberspringt die Backend-Initialisierung, laedt aber Module und Provider.
# Damit laeuft es auf Fork-PRs und in Repos, deren Cloud-Token es noch gar
# nicht gibt. Der Plan-Teil steht getrennt in tofu-plan.yml.
name: tofu-validate
on:
  workflow_call:
    inputs:
      working_directories:
        description: 'Newline-separated OpenTofu stack directories.'
        required: false
        type: string
        default: 'tofu'
      tofu_version:
        description: 'Override OpenTofu version (empty → composite default).'
        required: false
        type: string
        default: ''
      tflint:
        description: 'Also run tflint in each directory.'
        required: false
        type: boolean
        default: true
      lockfile_readonly:
        description: >-
          Pass -lockfile=readonly to `tofu init`, so a PR that would silently
          change .terraform.lock.hcl fails instead of drifting the provider
          pins unnoticed.
        required: false
        type: boolean
        default: true
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
    outputs:
      checked_directories:
        description: 'Number of directories validated.'
        value: ${{ jobs.validate.outputs.checked_directories }}
    secrets:
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'

permissions:
  contents: read

concurrency:
  group: tofu-validate-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directories }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  validate:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 20
    outputs:
      checked_directories: ${{ steps.run.outputs.checked_directories }}
    steps:
      - name: Reject an empty runs_on
        working-directory: ${{ github.workspace }}
        env:
          RUNS_ON: ${{ inputs.runs_on }}
        run: |
          set -euo pipefail
          trimmed="${RUNS_ON//[[:space:]]/}"
          if [[ "$trimmed" != "["*"]" || ! "$trimmed" =~ [A-Za-z0-9] ]]; then
            echo "::error::runs_on must be a non-empty JSON array of runner labels, got: ${RUNS_ON}" >&2
            echo "::error::an empty array does NOT fail the job — GitHub schedules it on any runner in the default group" >&2
            exit 1
          fi

      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
      - name: Mint catalog-scoped App token
        id: catalog-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3
        with:
          client-id: ${{ secrets.release_please_app_client_id }}
          private-key: ${{ secrets.release_please_app_private_key }}
          owner: serverkraken
          repositories: reusable-workflows
      - name: Resolve catalog ref
        id: catalog-ref
        env:
          IS_SELF_CI: ${{ github.repository == 'serverkraken/reusable-workflows' }}
          SELF_SHA: ${{ github.sha }}
        run: |
          if [[ "$IS_SELF_CI" == "true" ]]; then
            echo "ref=$SELF_SHA" >> "$GITHUB_OUTPUT"
          else
            # renovate-marker: catalog-major-ref
            echo "ref=v4" >> "$GITHUB_OUTPUT"
          fi
      - name: Checkout catalog for composite actions
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ steps.catalog-ref.outputs.ref }}
          token: ${{ steps.catalog-token.outputs.token }}
          path: .catalog

      - name: Install OpenTofu toolchain
        uses: ./.catalog/actions/setup-tofu-toolchain
        with:
          tofu_version: ${{ inputs.tofu_version }}
          tflint: ${{ inputs.tflint }}

      - name: Validate each stack
        id: run
        env:
          DIRS: ${{ inputs.working_directories }}
          TFLINT: ${{ inputs.tflint }}
          LOCKFILE_READONLY: ${{ inputs.lockfile_readonly }}
        # Eine Schleife statt einer Matrix: je Stack sind das Sekunden, und
        # eine Matrix erzeugte N Summary-Bloecke und N Runner-Slots dafuer.
        # Der Wechsel auf Matrix bliebe additiv, falls je ein Monorepo mit
        # vielen Stacks auftaucht.
        #
        # Es wird NICHT beim ersten Fehler abgebrochen: ein Lauf, der alle
        # Stacks zeigt, spart die zweite Runde.
        run: |
          set -uo pipefail
          : > tofu-results.tsv
          COUNT=0
          FAILED=0
          LOCK_ARG=""
          [[ "$LOCKFILE_READONLY" == "true" ]] && LOCK_ARG="-lockfile=readonly"
          while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            if [[ ! -d "$dir" ]]; then
              echo "::error::working directory does not exist: $dir" >&2
              printf '%s\tmissing\t-\t-\t-\n' "$dir" >> tofu-results.tsv
              FAILED=1
              continue
            fi
            COUNT=$((COUNT + 1))
            echo "::group::$dir"

            fmt_st="✓"; tofu fmt -check -recursive -diff "$dir" || { fmt_st="✗"; FAILED=1; }

            init_st="✓"
            # shellcheck disable=SC2086
            tofu -chdir="$dir" init -backend=false -input=false $LOCK_ARG \
              || { init_st="✗"; FAILED=1; }

            val_st="-"
            if [[ "$init_st" == "✓" ]]; then
              val_st="✓"; tofu -chdir="$dir" validate || { val_st="✗"; FAILED=1; }
            fi

            lint_st="-"
            if [[ "$TFLINT" == "true" && "$init_st" == "✓" ]]; then
              lint_st="✓"
              (cd "$dir" && tflint --no-color) || { lint_st="✗"; FAILED=1; }
            fi

            printf '%s\t%s\t%s\t%s\t%s\n' "$dir" "$fmt_st" "$init_st" "$val_st" "$lint_st" >> tofu-results.tsv
            echo "::endgroup::"
          done <<< "$DIRS"

          echo "checked_directories=$COUNT" >> "$GITHUB_OUTPUT"
          echo "failed=$FAILED" >> "$GITHUB_OUTPUT"
          if [[ "$COUNT" == "0" ]]; then
            echo "::error::no working directory was checked — is working_directories set correctly?" >&2
            exit 1
          fi

      - name: Summary
        if: always()
        env:
          TFLINT: ${{ inputs.tflint }}
          FAILED: ${{ steps.run.outputs.failed }}
          COUNT: ${{ steps.run.outputs.checked_directories }}
        run: |
          tofu_version=$(tofu version 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)
          if [[ "${FAILED:-1}" == "0" ]]; then
            result="✓ passed"
          else
            result="✗ failed"
          fi
          {
            echo "## tofu-validate"
            echo ""
            echo "**Tool:** OpenTofu ${tofu_version}"
            echo "**Stacks:** ${COUNT:-0}"
            echo "**Result:** ${result}"
            echo ""
            echo "| Stack | fmt | init | validate | tflint |"
            echo "|---|---|---|---|---|"
            if [[ -f tofu-results.tsv ]]; then
              while IFS=$'\t' read -r d f i v l; do
                echo "| \`${d}\` | ${f} | ${i} | ${v} | ${l} |"
              done < tofu-results.tsv
            fi
          } >> "$GITHUB_STEP_SUMMARY" || true

      - name: Fail on validation errors
        if: steps.run.outputs.failed != '0'
        run: |
          echo "::error::tofu-validate found problems (details in the step summary)"
          exit 1
```

- [ ] **Step 2: Add the contracts.md section**

`### .github/workflows/tofu-validate.yml` mit den fünf Inputs, dem Output und den zwei Secrets.

- [ ] **Step 3: Run all convention gates**

```bash
bash tests/conventions/check-step-summary.sh
bash tests/conventions/check-contracts.sh
python3 tests/conventions/check-contract-defaults.py
python3 tests/conventions/check-runs-on-guard.py
python3 tests/conventions/check-reusable-permissions.py
python3 tests/conventions/check-ref-fork-guard.py
```
Expected: alle exit 0

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/tofu-validate.yml docs/contracts.md
git commit -m "feat(tofu): credential-freies Validierungs-Atom

fmt -check, init -backend=false, validate, optional tflint. Das
-backend=false ist der Punkt, der das Atom ohne jedes Geheimnis laufen
laesst — auf Fork-PRs und in Repos ohne Cloud-Token.

-lockfile=readonly per Default: ein PR, der .terraform.lock.hcl still
aendern wuerde, faellt auf.

Eine Schleife statt Matrix — je Stack Sekundenarbeit, und eine Matrix
erzeugte N Summary-Bloecke dafuer."
```

### Task 7: Fixtures und Self-CI-Jobs für `tofu-validate`

**Files:**
- Create: `tests/fixtures/tofu-valid/main.tf`
- Create: `tests/fixtures/tofu-valid/versions.tf`
- Create: `tests/fixtures/tofu-invalid/main.tf`
- Modify: `.github/workflows/self-ci.yml`

**Interfaces:**
- Consumes: `tofu-validate.yml` (Task 6)
- Produces: Jobs `tofu-validate-happy` und `assert-tofu-validate-invalid` im `summary`-Graphen.

- [ ] **Step 1: Create the happy fixture**

Der `null`-Provider ist bewusst gewählt: er braucht keine Credentials und keinen Cloud-Zugriff, `init` holt ihn aus der Registry.

`tests/fixtures/tofu-valid/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
```

`tests/fixtures/tofu-valid/main.tf`:

```hcl
# Fixture: gueltiger, credential-freier Stack fuer den tofu-validate-Happy-Path.
variable "greeting" {
  type    = string
  default = "hallo"
}

resource "null_resource" "greeter" {
  triggers = {
    greeting = var.greeting
  }
}

output "greeting" {
  value = null_resource.greeter.triggers.greeting
}
```

- [ ] **Step 2: Create the invalid fixture**

`tests/fixtures/tofu-invalid/main.tf` — verstößt gegen `fmt` **und** referenziert eine unbekannte Variable, sodass auch `validate` fällt:

```hcl
# Fixture: bricht absichtlich fmt (Einrueckung) und validate (unbekannte
# Variable), damit der Failure-Path des Gates belegt ist.
terraform {
  required_version = ">= 1.9.0"
}

resource "null_resource" "broken" {
      triggers = {
    value = var.does_not_exist
  }
}
```

- [ ] **Step 3: Add the happy-path job to self-ci.yml**

```yaml
  # ----- tofu-validate: happy path -----
  tofu-validate-happy:
    uses: ./.github/workflows/tofu-validate.yml
    permissions:
      contents: read
    with:
      working_directories: |-
        tests/fixtures/tofu-valid
      # tflint braucht `tflint --init`, das Plugins aus GitHub zieht und im
      # Self-CI unnoetig Rate-Limit kostet. Der tflint-Pfad wird ueber die
      # Composite Action abgedeckt, nicht hier.
      tflint: false
      runs_on: '["ubuntu-latest"]'
    secrets:
      release_please_app_client_id: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      release_please_app_private_key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

- [ ] **Step 4: Add the failure-path job**

`tofu-validate` hat bewusst kein `fail_on_findings`-Ventil — ein ungültiger Stack MUSS rot werden. Der Failure-Path wird deshalb über `continue-on-error` am aufrufenden Job geprüft:

```yaml
  # ----- tofu-validate: ungueltiger Stack MUSS fehlschlagen -----
  tofu-validate-invalid:
    uses: ./.github/workflows/tofu-validate.yml
    permissions:
      contents: read
    with:
      working_directories: |-
        tests/fixtures/tofu-invalid
      tflint: false
      runs_on: '["ubuntu-latest"]'
    secrets:
      release_please_app_client_id: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      release_please_app_private_key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}

  assert-tofu-validate-invalid:
    needs: [tofu-validate-invalid]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Das Atom muss den kaputten Stack ablehnen
        env:
          RESULT: ${{ needs.tofu-validate-invalid.result }}
        run: |
          set -euo pipefail
          if [[ "$RESULT" != "failure" ]]; then
            echo "::error::erwartet 'failure' fuer den ungueltigen Stack, bekam '${RESULT}'" >&2
            echo "::error::ein gruenes tofu-validate auf kaputter HCL bedeutet, dass das Gate nichts prueft" >&2
            exit 1
          fi
          echo "tofu-validate hat den kaputten Stack korrekt abgelehnt"
```

- [ ] **Step 5: Wire into the summary aggregator**

`tofu-validate-happy` und `assert-tofu-validate-invalid` in die `needs:`-Liste des `summary`-Jobs. `tofu-validate-invalid` hängt über die Assertion im Graphen.

- [ ] **Step 6: Verify**

```bash
bash tests/conventions/check-summary-coverage.sh
```
Expected: exit 0

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/tofu-valid tests/fixtures/tofu-invalid .github/workflows/self-ci.yml
git commit -m "test(tofu): Happy- und Failure-Path fuer tofu-validate

Die Fixtures nutzen den null-Provider: kein Credential, kein
Cloud-Zugriff, trotzdem echtes init und validate.

Der Failure-Path prueft das Job-Ergebnis selbst — tofu-validate hat
bewusst kein fail_on_findings-Ventil, ungueltige HCL MUSS rot werden."
```

---

# Phase 3 — `tofu-plan`

Ergebnis der Phase: das Plan-Atom existiert, ist getestet und backend-agnostisch. `homelab-hetzner` verdrahtet es erst, wenn Decision 0002 entschieden und `tofu init -migrate-state` gelaufen ist — heute liegt der State dort lokal.

### Task 8: `tf_vars`-Parser als getestetes Skript

Die riskanteste Zeile des ganzen Atoms. Sie nimmt einen Secret-Text entgegen und setzt daraus Umgebungsvariablen. Inline wäre sie ungeprüft; als Skript ist sie mit bats abgedeckt — die Repo-Konvention verlangt genau das für tragende Bash-Logik.

**Files:**
- Create: `scripts/tf-vars-env.sh`
- Test: `tests/shell/tf-vars-env.bats`

**Interfaces:**
- Consumes: nichts
- Produces: `bash scripts/tf-vars-env.sh` liest `KEY=VALUE`-Zeilen von stdin und schreibt `TF_VAR_key=value` nach `$GITHUB_ENV` sowie `::add-mask::value` nach stdout. Exit 1 bei ungültigem Schlüssel. Task 9 ruft es auf.

- [ ] **Step 1: Write the failing test**

`tests/shell/tf-vars-env.bats`:

```bash
#!/usr/bin/env bats

# scripts/tf-vars-env.sh wandelt das `tf_vars`-Secret in TF_VAR_*-Variablen.
# Der Inhalt ist ein Geheimnis aus der Aufruferseite — der Parser muss ihn
# als feindlich behandeln, sonst ist er ein Env-Injection-Vektor.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tf-vars-env.sh"
  cd "$BATS_TEST_TMPDIR" || exit 1
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
}

@test "einfache Zuweisung wird zu TF_VAR_ mit Maske" {
  run bash -c "printf 'hcloud_token=abc123\n' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::abc123"* ]]
  grep -qx 'TF_VAR_hcloud_token=abc123' "$GITHUB_ENV"
}

@test "leere Zeilen und Kommentare werden uebersprungen" {
  run bash -c "printf '\n# kommentar\nfoo=bar\n' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  grep -qx 'TF_VAR_foo=bar' "$GITHUB_ENV"
  [ "$(grep -c '^TF_VAR_' "$GITHUB_ENV")" -eq 1 ]
}

# Werte duerfen alles enthalten — auch `=`. Nur am ERSTEN `=` wird getrennt.
@test "Wert mit Gleichheitszeichen bleibt vollstaendig" {
  run bash -c "printf 'url=https://x/?a=1&b=2\n' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  grep -qx 'TF_VAR_url=https://x/?a=1&b=2' "$GITHUB_ENV"
}

# Der Kern: ein Schluessel, der kein gueltiger Variablenname ist, koennte
# beliebige Env-Zeilen erzeugen. Er muss den Lauf abbrechen, nicht nur die
# Zeile ueberspringen — stilles Verwerfen sieht aus wie "Variable gesetzt".
@test "ungueltiger Schluessel bricht ab" {
  run bash -c "printf 'not-a-valid-name=x\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ungueltiger Variablenname"* ]]
}

@test "Schluessel mit Leerzeichen bricht ab" {
  run bash -c "printf 'foo bar=x\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
}

# Eine Zeile ohne `=` ist keine Zuweisung. Sie stillschweigend zu ignorieren
# hiesse, eine erwartete Variable fehlte spaeter kommentarlos.
@test "Zeile ohne Gleichheitszeichen bricht ab" {
  run bash -c "printf 'kaputt\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
}

# GITHUB_ENV ist zeilenbasiert. Ein Wert mit Zeilenumbruch koennte eine
# zweite, gefaelschte Zuweisung anhaengen.
@test "Wert mit eingebettetem Zeilenumbruch wird abgelehnt" {
  printf 'a=1\nPATH=/evil\n' > payload.txt
  run bash -c "bash '$SCRIPT' < payload.txt"
  # Beide Zeilen sind fuer sich gueltige Zuweisungen; PATH ist als Name
  # zulaessig, wird aber zu TF_VAR_PATH — nicht zu PATH. Genau das ist der
  # Schutz: das Praefix macht eine Uebernahme fremder Variablen unmoeglich.
  [ "$status" -eq 0 ]
  grep -qx 'TF_VAR_PATH=/evil' "$GITHUB_ENV"
  ! grep -qx 'PATH=/evil' "$GITHUB_ENV"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/shell/tf-vars-env.bats`
Expected: FAIL — `bash: .../scripts/tf-vars-env.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

`scripts/tf-vars-env.sh`:

```bash
#!/usr/bin/env bash
# Wandelt `KEY=VALUE`-Zeilen (aus dem `tf_vars`-Secret) in TF_VAR_*-Eintraege
# in $GITHUB_ENV und maskiert jeden Wert im Log.
#
# Der Inhalt kommt von der Aufruferseite und wird als feindlich behandelt:
#
#   - Jeder Schluessel muss ein gueltiger Shell-Variablenname sein. Ohne diese
#     Pruefung koennte eine konstruierte Zeile beliebige Env-Zuweisungen in
#     GITHUB_ENV schreiben.
#   - Das feste Praefix TF_VAR_ macht es unmoeglich, eine bestehende Variable
#     der Runner-Umgebung (PATH, HOME, GITHUB_TOKEN) zu ueberschreiben.
#   - Eine kaputte Zeile bricht ab, statt uebersprungen zu werden: eine
#     stillschweigend verworfene Variable faellt erst als unverstaendlicher
#     tofu-Fehler auf.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV muss gesetzt sein}"

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  [[ -z "${line// /}" ]] && continue
  [[ "$line" == \#* ]] && continue

  if [[ "$line" != *"="* ]]; then
    echo "::error::tf_vars Zeile ${lineno}: keine KEY=VALUE-Zuweisung" >&2
    exit 1
  fi

  key="${line%%=*}"
  value="${line#*=}"

  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    # Der Schluessel wird bewusst NICHT mit ausgegeben: er stammt aus einem
    # Secret und koennte selbst schuetzenswert sein.
    echo "::error::tf_vars Zeile ${lineno}: ungueltiger Variablenname" >&2
    exit 1
  fi

  # Maskieren, BEVOR der Wert irgendwo sonst auftauchen kann.
  echo "::add-mask::${value}"
  printf 'TF_VAR_%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/shell/tf-vars-env.bats`
Expected: 7 Tests PASS

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/tf-vars-env.sh
git add scripts/tf-vars-env.sh tests/shell/tf-vars-env.bats
git commit -m "feat(tofu-plan): getesteter tf_vars-Parser

Der Inhalt kommt aus einem Secret der Aufruferseite und wird als
feindlich behandelt: Schluessel muessen gueltige Variablennamen sein,
das feste TF_VAR_-Praefix verhindert die Uebernahme bestehender
Runner-Variablen, jeder Wert wird maskiert.

Eine kaputte Zeile bricht ab statt uebersprungen zu werden — eine still
verworfene Variable faellt sonst erst als unverstaendlicher tofu-Fehler
auf."
```

### Task 9: `tofu-plan.yml`

**Files:**
- Create: `.github/workflows/tofu-plan.yml`
- Modify: `docs/contracts.md`

**Interfaces:**
- Consumes: `actions/setup-tofu-toolchain` (Task 5), `scripts/tf-vars-env.sh` (Task 8)
- Produces: Atom `tofu-plan` mit Outputs `has_changes` (`'true'`/`'false'`) und `summary_line`. Task 11 ruft es auf.

- [ ] **Step 1: Write the workflow**

`.github/workflows/tofu-plan.yml`:

```yaml
# .github/workflows/tofu-plan.yml
# Summary convention: docs/conventions/step-summary.md
#
# Stability surface (workflow_call contract — breaking changes = major bump):
#   inputs:  working_directory, tofu_version, backend_config, comment_on_pr,
#            plan_json, lock, lock_timeout, runs_on
#   secrets: release_please_app_client_id, release_please_app_private_key,
#            backend_access_key, backend_secret_key, tf_vars
#   outputs: has_changes, summary_line
#
# SICHERHEIT — drei Punkte, die beim Aendern nicht verloren gehen duerfen:
#
#   1. `tofu show -json` redigiert `sensitive`-Werte NICHT, die
#      menschenlesbare Ausgabe schon. Deshalb ist plan_json opt-in und die
#      binaere tfplan wird NIE als Artefakt hochgeladen.
#   2. Unter `pull_request_target` liefe fremder PR-Code mit Zugriff auf die
#      Backend-Credentials. Das Atom weigert sich dort zu laufen.
#   3. Ein abgebrochener Plan kann einen State-Lock zurueckzulassen, der auch
#      den Apply am Laptop blockiert. Deshalb cancel-in-progress: false.
name: tofu-plan
on:
  workflow_call:
    inputs:
      working_directory:
        description: 'OpenTofu stack directory.'
        required: false
        type: string
        default: 'tofu'
      tofu_version:
        description: 'Override OpenTofu version (empty → composite default).'
        required: false
        type: string
        default: ''
      backend_config:
        description: >-
          Newline-separated `-backend-config=` arguments (bucket, endpoint,
          region). Credentials do NOT belong here — use the secrets.
        required: false
        type: string
        default: ''
      comment_on_pr:
        description: 'Post the plan as a sticky PR comment.'
        required: false
        type: boolean
        default: true
      plan_json:
        description: >-
          Upload `tofu show -json` as an artifact. OFF by default: unlike the
          human-readable output, the JSON does NOT redact values marked
          sensitive, so anyone who can download the artifact reads them in
          clear text.
        required: false
        type: boolean
        default: false
      lock:
        description: 'Take a state lock during plan.'
        required: false
        type: boolean
        default: true
      lock_timeout:
        description: 'Value for -lock-timeout.'
        required: false
        type: string
        default: '60s'
      runs_on:
        description: 'JSON-encoded array of runner labels.'
        required: false
        type: string
        default: '["self-hosted","Linux"]'
    outputs:
      has_changes:
        description: 'true when the plan contains changes.'
        value: ${{ jobs.plan.outputs.has_changes }}
      summary_line:
        description: 'The plan summary line, e.g. "2 to add, 1 to change, 0 to destroy".'
        value: ${{ jobs.plan.outputs.summary_line }}
    secrets:
      release_please_app_client_id:
        required: true
        description: 'GitHub App Client ID with contents:read on the catalog repo.'
      release_please_app_private_key:
        required: true
        description: 'PEM private key for the GitHub App.'
      backend_access_key:
        required: false
        description: 'S3-compatible backend access key → AWS_ACCESS_KEY_ID.'
      backend_secret_key:
        required: false
        description: 'S3-compatible backend secret key → AWS_SECRET_ACCESS_KEY.'
      tf_vars:
        required: false
        description: 'Newline-separated KEY=VALUE pairs, exported as TF_VAR_key.'

permissions:
  contents: read
  pull-requests: write

concurrency:
  # cancel-in-progress bewusst FALSE, abweichend von den Lint-Atomen: ein
  # abgebrochener Plan kann einen State-Lock hinterlassen, und der blockiert
  # den naechsten CI-Lauf UND den Apply am Laptop.
  group: tofu-plan-${{ github.workflow }}-${{ github.ref }}-${{ inputs.working_directory }}
  cancel-in-progress: false

jobs:
  plan:
    runs-on: ${{ fromJSON(inputs.runs_on) }}
    timeout-minutes: 30
    outputs:
      has_changes: ${{ steps.plan.outputs.has_changes }}
      summary_line: ${{ steps.plan.outputs.summary_line }}
    steps:
      - name: Reject an empty runs_on
        working-directory: ${{ github.workspace }}
        env:
          RUNS_ON: ${{ inputs.runs_on }}
        run: |
          set -euo pipefail
          trimmed="${RUNS_ON//[[:space:]]/}"
          if [[ "$trimmed" != "["*"]" || ! "$trimmed" =~ [A-Za-z0-9] ]]; then
            echo "::error::runs_on must be a non-empty JSON array of runner labels, got: ${RUNS_ON}" >&2
            echo "::error::an empty array does NOT fail the job — GitHub schedules it on any runner in the default group" >&2
            exit 1
          fi

      # Das Atom kann das `on:` des Aufrufers nicht bestimmen — aber es kann
      # sich weigern. Unter pull_request_target laeuft der Workflow aus dem
      # BASIS-Branch mit vollen Secrets, waehrend der Checkout den fremden
      # PR-Code holt: ein Plan-Lauf haette damit die Backend-Credentials.
      - name: Refuse to run under pull_request_target
        working-directory: ${{ github.workspace }}
        env:
          EVENT: ${{ github.event_name }}
        run: |
          set -euo pipefail
          if [[ "$EVENT" == "pull_request_target" ]]; then
            echo "::error::tofu-plan darf nicht unter pull_request_target laufen — fremder PR-Code haette Zugriff auf die Backend-Credentials" >&2
            echo "::error::den aufrufenden Workflow auf 'pull_request' umstellen" >&2
            exit 1
          fi

      # Fork-PRs haben keine Secrets; ohne Backend-Zugang gaebe es nur einen
      # verwirrenden Fehler tief im init. Sauber ueberspringen statt scheitern.
      - name: Detect fork PR
        id: fork
        env:
          EVENT: ${{ github.event_name }}
          HEAD_REPO: ${{ github.event.pull_request.head.repo.full_name }}
          THIS_REPO: ${{ github.repository }}
        run: |
          set -euo pipefail
          if [[ "$EVENT" == "pull_request" && "$HEAD_REPO" != "$THIS_REPO" ]]; then
            echo "is_fork=true" >> "$GITHUB_OUTPUT"
            echo "::notice::Fork-PR: tofu-plan wird uebersprungen (keine Backend-Credentials verfuegbar)"
          else
            echo "is_fork=false" >> "$GITHUB_OUTPUT"
          fi

      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        if: steps.fork.outputs.is_fork == 'false'
      - name: Mint catalog-scoped App token
        if: steps.fork.outputs.is_fork == 'false'
        id: catalog-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3
        with:
          client-id: ${{ secrets.release_please_app_client_id }}
          private-key: ${{ secrets.release_please_app_private_key }}
          owner: serverkraken
          repositories: reusable-workflows
      - name: Resolve catalog ref
        if: steps.fork.outputs.is_fork == 'false'
        id: catalog-ref
        env:
          IS_SELF_CI: ${{ github.repository == 'serverkraken/reusable-workflows' }}
          SELF_SHA: ${{ github.sha }}
        run: |
          if [[ "$IS_SELF_CI" == "true" ]]; then
            echo "ref=$SELF_SHA" >> "$GITHUB_OUTPUT"
          else
            # renovate-marker: catalog-major-ref
            echo "ref=v4" >> "$GITHUB_OUTPUT"
          fi
      - name: Checkout catalog for composite actions
        if: steps.fork.outputs.is_fork == 'false'
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          repository: serverkraken/reusable-workflows
          ref: ${{ steps.catalog-ref.outputs.ref }}
          token: ${{ steps.catalog-token.outputs.token }}
          path: .catalog

      - name: Install OpenTofu toolchain
        if: steps.fork.outputs.is_fork == 'false'
        uses: ./.catalog/actions/setup-tofu-toolchain
        with:
          tofu_version: ${{ inputs.tofu_version }}

      - name: Export TF_VAR_* from the tf_vars secret
        if: steps.fork.outputs.is_fork == 'false'
        env:
          TF_VARS: ${{ secrets.tf_vars }}
          PARSER: ${{ github.workspace }}/.catalog/scripts/tf-vars-env.sh
        run: |
          set -euo pipefail
          if [[ -n "${TF_VARS:-}" ]]; then
            printf '%s\n' "$TF_VARS" | bash "$PARSER"
          fi

      - name: Initialize backend
        if: steps.fork.outputs.is_fork == 'false'
        env:
          DIR: ${{ inputs.working_directory }}
          BACKEND_CONFIG: ${{ inputs.backend_config }}
          AWS_ACCESS_KEY_ID: ${{ secrets.backend_access_key }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.backend_secret_key }}
        run: |
          set -euo pipefail
          ARGS=()
          while IFS= read -r line; do
            [[ -z "${line// /}" ]] && continue
            ARGS+=("-backend-config=$line")
          done <<< "$BACKEND_CONFIG"
          tofu -chdir="$DIR" init -input=false "${ARGS[@]+"${ARGS[@]}"}"

      - name: Run tofu plan
        if: steps.fork.outputs.is_fork == 'false'
        id: plan
        env:
          DIR: ${{ inputs.working_directory }}
          LOCK: ${{ inputs.lock }}
          LOCK_TIMEOUT: ${{ inputs.lock_timeout }}
          AWS_ACCESS_KEY_ID: ${{ secrets.backend_access_key }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.backend_secret_key }}
        # -detailed-exitcode ist die eingebaute, eindeutige Antwort auf
        # "gibt es Aenderungen": 0 = keine, 2 = ja, 1 = Fehler. Deshalb KEIN
        # jq auf `tofu show -json`, dessen Struktur zwischen Versionen wandert.
        #
        # `set +e` ist Pflicht, nicht Bequemlichkeit: GitHub startet run-Bloecke
        # mit `bash -e`, und der ERWARTETE Erfolgsfall "es gibt Aenderungen"
        # ist rc=2. Ohne +e stirbt der Schritt, bevor rc ausgewertet wird —
        # dieselbe Falle wie in kube-lint.yml.
        run: |
          set -uo pipefail
          LOCK_ARGS=(-lock-timeout="$LOCK_TIMEOUT")
          [[ "$LOCK" == "true" ]] || LOCK_ARGS+=(-lock=false)
          set +e
          tofu -chdir="$DIR" plan -input=false -no-color -detailed-exitcode \
            "${LOCK_ARGS[@]}" -out=tfplan > plan.txt 2> plan.err
          rc=$?
          set -e
          cat plan.err >&2 || true
          case "$rc" in
            0) echo "has_changes=false" >> "$GITHUB_OUTPUT" ;;
            2) echo "has_changes=true"  >> "$GITHUB_OUTPUT" ;;
            *)
              echo "::error::tofu plan scheiterte (rc=$rc): $(tr -d '\n' < plan.err)" >&2
              echo "has_changes=false" >> "$GITHUB_OUTPUT"
              echo "failed=true" >> "$GITHUB_OUTPUT"
              exit 1
              ;;
          esac
          LINE=$(grep -E '^Plan: |^No changes\.' plan.txt | tail -1 || true)
          echo "summary_line=${LINE:-unknown}" >> "$GITHUB_OUTPUT"

      - name: Render plan as JSON
        if: steps.fork.outputs.is_fork == 'false' && inputs.plan_json
        env:
          DIR: ${{ inputs.working_directory }}
        run: |
          set -euo pipefail
          tofu -chdir="$DIR" show -json tfplan > plan.json

      - name: Upload plan JSON
        # Nur auf ausdruecklichen Wunsch. Die binaere tfplan wird NIE
        # hochgeladen — sie traegt dieselben Klartextwerte.
        if: steps.fork.outputs.is_fork == 'false' && inputs.plan_json
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: tofu-plan-json
          # `> plan.json` im Schritt davor schreibt ins cwd (Workspace-Root),
          # NICHT nach $DIR — `tofu -chdir` aendert das Arbeitsverzeichnis von
          # tofu, nicht das der Shell.
          path: plan.json
          if-no-files-found: error
          retention-days: 7
```

- [ ] **Step 2: Add the contracts.md section**

`### .github/workflows/tofu-plan.yml` mit den acht Inputs, zwei Outputs und fünf Secrets. Die Beschreibung von `plan_json` muss die Redaktionswarnung tragen — `check-contract-defaults.py` vergleicht Defaults, der Text ist für Menschen.

- [ ] **Step 3: Run all convention gates**

```bash
bash tests/conventions/check-contracts.sh
python3 tests/conventions/check-contract-defaults.py
python3 tests/conventions/check-runs-on-guard.py
python3 tests/conventions/check-reusable-permissions.py
python3 tests/conventions/check-ref-fork-guard.py
python3 tests/conventions/check-pin-scope-doc.py
```
Expected: alle exit 0. `check-step-summary.sh` schlägt hier noch fehl — die Summary kommt in Task 10.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/tofu-plan.yml docs/contracts.md
git commit -m "feat(tofu): Plan-Atom, backend-agnostisch

has_changes kommt aus -detailed-exitcode (0/2/1) statt aus einem
jq-Ausdruck auf einer Struktur, die zwischen Versionen wandert. set +e
ist dabei Pflicht: der Erfolgsfall 'es gibt Aenderungen' IST rc=2.

plan_json ist opt-in, weil tofu show -json sensitive-Werte im Gegensatz
zur Textausgabe nicht redigiert. Die binaere tfplan wird nie
hochgeladen.

pull_request_target wird hart abgelehnt; Fork-PRs werden sauber
uebersprungen statt tief im init zu scheitern.

AWS_*-Credentials passen auf Garage wie auf Hetzner Object Storage —
das Atom bleibt unabhaengig von Decision 0002 in homelab-hetzner."
```

### Task 10: Step-Summary und Sticky-PR-Kommentar für `tofu-plan`

**Files:**
- Create: `scripts/tofu-plan-render.sh`
- Test: `tests/shell/tofu-plan-render.bats`
- Modify: `.github/workflows/tofu-plan.yml`

**Interfaces:**
- Consumes: `tofu-plan.yml` (Task 9)
- Produces: `bash scripts/tofu-plan-render.sh <plan.txt> <limit>` schreibt den gekürzten Plan-Block nach stdout. Wird von Summary und Kommentar genutzt.

- [ ] **Step 1: Write the failing test**

`tests/shell/tofu-plan-render.bats`:

```bash
#!/usr/bin/env bats

# scripts/tofu-plan-render.sh kuerzt die Plan-Ausgabe auf ein Zeichenlimit.
# GitHub nimmt maximal 65536 Zeichen pro Kommentar; ein zu langer Plan wuerde
# den Kommentar-Aufruf scheitern lassen, statt gekuerzt anzukommen.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tofu-plan-render.sh"
  cd "$BATS_TEST_TMPDIR" || exit 1
}

@test "kurzer Plan geht unveraendert durch" {
  printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n' > plan.txt
  run bash "$SCRIPT" plan.txt 1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 to add"* ]]
  [[ "$output" != *"gekuerzt"* ]]
}

@test "langer Plan wird gekuerzt und sagt es" {
  for i in $(seq 1 500); do echo "  # resource.line_${i} will be created"; done > plan.txt
  run bash "$SCRIPT" plan.txt 500
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 900 ]
  [[ "$output" == *"gekuerzt"* ]]
}

# Kopf UND Fuss muessen erhalten bleiben: oben steht, was geaendert wird,
# unten die Zusammenfassungszeile. Nur den Kopf zu behalten verwuerfe genau
# die Zeile, auf die im Review geschaut wird.
@test "Kuerzung behaelt Anfang und Ende" {
  { echo "ERSTE-ZEILE"; for i in $(seq 1 500); do echo "fuellung_${i}"; done; echo "Plan: 3 to add, 0 to change, 0 to destroy."; } > plan.txt
  run bash "$SCRIPT" plan.txt 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERSTE-ZEILE"* ]]
  [[ "$output" == *"3 to add"* ]]
}

@test "fehlende Datei bricht ab" {
  run bash "$SCRIPT" gibtsnicht.txt 500
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/shell/tofu-plan-render.bats`
Expected: FAIL — Skript fehlt

- [ ] **Step 3: Write minimal implementation**

`scripts/tofu-plan-render.sh`:

```bash
#!/usr/bin/env bash
# Kuerzt eine tofu-plan-Ausgabe auf ein Zeichenlimit.
#
# GitHub nimmt hoechstens 65536 Zeichen pro Kommentar. Ein ungekuerzter Plan
# laesst den Kommentar-Aufruf scheitern — der Plan kaeme dann gar nicht an.
#
# Kopf UND Fuss bleiben erhalten: oben steht, was sich aendert, unten die
# Zusammenfassungszeile ("Plan: 2 to add, ..."). Nur den Kopf zu behalten
# verwuerfe genau die Zeile, auf die im Review zuerst geschaut wird.
set -euo pipefail

FILE="${1:?Plan-Datei fehlt}"
LIMIT="${2:-60000}"

if [[ ! -f "$FILE" ]]; then
  echo "::error::Plan-Datei nicht gefunden: $FILE" >&2
  exit 1
fi

SIZE=$(wc -c < "$FILE" | tr -d ' ')
if [[ "$SIZE" -le "$LIMIT" ]]; then
  cat "$FILE"
  exit 0
fi

HALF=$(( LIMIT / 2 ))
head -c "$HALF" "$FILE"
printf '\n\n... [gekuerzt: %s von %s Zeichen entfernt — Volltext in der Step-Summary] ...\n\n' \
  "$(( SIZE - LIMIT ))" "$SIZE"
tail -c "$HALF" "$FILE"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/shell/tofu-plan-render.bats`
Expected: 4 Tests PASS

- [ ] **Step 5: Add the summary and comment steps to tofu-plan.yml**

Ans Ende der `plan`-Job-Steps in `.github/workflows/tofu-plan.yml`:

```yaml
      - name: Summary
        if: always() && steps.fork.outputs.is_fork == 'false'
        env:
          DIR: ${{ inputs.working_directory }}
          HAS_CHANGES: ${{ steps.plan.outputs.has_changes }}
          SUMMARY_LINE: ${{ steps.plan.outputs.summary_line }}
          FAILED: ${{ steps.plan.outputs.failed }}
          RENDER: ${{ github.workspace }}/.catalog/scripts/tofu-plan-render.sh
        run: |
          tofu_version=$(tofu version 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)
          if [[ "${FAILED:-}" == "true" ]]; then
            result="✗ plan failed"
          elif [[ "$HAS_CHANGES" == "true" ]]; then
            result="▲ changes pending"
          else
            result="✓ no changes"
          fi
          {
            echo "## tofu-plan"
            echo ""
            echo "**Tool:** OpenTofu ${tofu_version}"
            echo "**Working dir:** \`${DIR}\`"
            echo "**Result:** ${result}"
            echo ""
            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Changes | ${HAS_CHANGES:-unknown} |"
            echo "| Summary | ${SUMMARY_LINE:-unknown} |"
            if [[ -f plan.txt ]]; then
              echo ""
              echo "<details><summary>Plan</summary>"
              echo ""
              echo '```'
              # 900k statt 1M: der Rest der Summary braucht auch Platz.
              bash "$RENDER" plan.txt 900000
              echo '```'
              echo ""
              echo "</details>"
            fi
          } >> "$GITHUB_STEP_SUMMARY" || true

      - name: Find existing plan comment
        id: find-comment
        if: >-
          steps.fork.outputs.is_fork == 'false' && inputs.comment_on_pr
          && github.event_name == 'pull_request'
        uses: peter-evans/find-comment@b30e6a3c0ed37e7c023ccd3f1db5c6c0b0c23aad # v4
        with:
          issue-number: ${{ github.event.pull_request.number }}
          comment-author: 'github-actions[bot]'
          body-includes: '<!-- tofu-plan:${{ inputs.working_directory }} -->'

      - name: Compose comment body
        id: comment-body
        if: >-
          steps.fork.outputs.is_fork == 'false' && inputs.comment_on_pr
          && github.event_name == 'pull_request'
        env:
          DIR: ${{ inputs.working_directory }}
          HAS_CHANGES: ${{ steps.plan.outputs.has_changes }}
          SUMMARY_LINE: ${{ steps.plan.outputs.summary_line }}
          RENDER: ${{ github.workspace }}/.catalog/scripts/tofu-plan-render.sh
        run: |
          set -euo pipefail
          BODY_FILE=comment.md
          {
            echo "<!-- tofu-plan:${DIR} -->"
            if [[ "$HAS_CHANGES" == "true" ]]; then
              echo "**OpenTofu plan — \`${DIR}\`: ▲ ${SUMMARY_LINE}**"
            else
              echo "**OpenTofu plan — \`${DIR}\`: ✓ keine Aenderungen**"
            fi
            echo ""
            echo "<details><summary>Plan anzeigen</summary>"
            echo ""
            echo '```'
            bash "$RENDER" plan.txt 60000
            echo '```'
            echo ""
            echo "</details>"
          } > "$BODY_FILE"
          # Zufaelliger Delimiter je Aufruf: mit einem festen wuerde eine Zeile
          # im Plan, die exakt der Delimiter ist, den Block vorzeitig schliessen
          # — und jede Folgezeile wuerde zu einem NEUEN Step-Output. Der
          # Planinhalt ist nicht unter unserer Kontrolle. Dasselbe Argument wie
          # in actions/post-prerelease-comment.
          DELIM="body_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
          if grep -qxF "$DELIM" "$BODY_FILE"; then
            echo "::error::generated delimiter collides with the comment body" >&2
            exit 1
          fi
          {
            echo "body<<$DELIM"
            cat "$BODY_FILE"
            echo "$DELIM"
          } >> "$GITHUB_OUTPUT"

      - name: Post or update plan comment
        if: >-
          steps.fork.outputs.is_fork == 'false' && inputs.comment_on_pr
          && github.event_name == 'pull_request'
        uses: peter-evans/create-or-update-comment@71345be0265236311c031f5c7866368bd1eff043 # v5
        with:
          issue-number: ${{ github.event.pull_request.number }}
          comment-id: ${{ steps.find-comment.outputs.comment-id }}
          edit-mode: replace
          body: ${{ steps.comment-body.outputs.body }}
```

> **Hinweis zum SHA-Pin:** die beiden `peter-evans`-Pins oben müssen gegen die im Repo bereits verwendeten geprüft und übernommen werden — `rg -n "peter-evans" .github actions` zeigt den Bestand. Weicht ein Wert ab, gilt der bestehende; `check-pin-scope-doc.py` erzwingt Konsistenz.

- [ ] **Step 6: Run the gates**

```bash
bats tests/shell/tofu-plan-render.bats
bash tests/conventions/check-step-summary.sh
python3 tests/conventions/check-pin-scope-doc.py
```
Expected: alle exit 0

- [ ] **Step 7: Commit**

```bash
chmod +x scripts/tofu-plan-render.sh
git add scripts/tofu-plan-render.sh tests/shell/tofu-plan-render.bats .github/workflows/tofu-plan.yml
git commit -m "feat(tofu-plan): Step-Summary und Sticky-PR-Kommentar

Die Kuerzung behaelt Kopf UND Fuss: unten steht die Zusammenfassungszeile,
auf die im Review zuerst geschaut wird.

Der Kommentar-Body geht ueber einen zufaelligen Heredoc-Delimiter — der
Planinhalt ist nicht unter unserer Kontrolle, und ein fester Delimiter
waere Output-Injection. Dasselbe Argument wie in
post-prerelease-comment."
```

### Task 11: Fixture und Self-CI-Job für `tofu-plan`

**Files:**
- Create: `tests/fixtures/tofu-plan-local/versions.tf`
- Create: `tests/fixtures/tofu-plan-local/main.tf`
- Modify: `.github/workflows/self-ci.yml`

**Interfaces:**
- Consumes: `tofu-plan.yml` (Tasks 9, 10)
- Produces: Jobs `tofu-plan-changes` und `assert-tofu-plan-changes` im `summary`-Graphen.

- [ ] **Step 1: Create the fixture**

Lokales Backend (kein `backend`-Block = local state) plus `null`-Provider: der Plan läuft offline und ohne jedes Credential, und weil kein State existiert, meldet er verlässlich Änderungen.

`tests/fixtures/tofu-plan-local/versions.tf`:

```hcl
# Kein backend-Block: lokaler State. Damit laeuft der Plan im Self-CI ohne
# Backend, ohne Credentials und ohne Netzzugang ausser der Provider-Registry.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
```

`tests/fixtures/tofu-plan-local/main.tf`:

```hcl
# Ohne vorhandenen State ist diese Ressource immer "to add" — der Plan meldet
# damit verlaesslich has_changes=true, und genau das prueft die Assertion.
resource "null_resource" "planned" {
  triggers = {
    fixture = "tofu-plan-local"
  }
}
```

- [ ] **Step 2: Add the job to self-ci.yml**

```yaml
  # ----- tofu-plan: lokaler State, null-Provider, keine Credentials -----
  tofu-plan-changes:
    uses: ./.github/workflows/tofu-plan.yml
    permissions:
      contents: read
      pull-requests: write
    with:
      working_directory: tests/fixtures/tofu-plan-local
      # Kein Remote-Backend in der Fixture, also auch kein Lock.
      lock: false
      # Der Katalog hat keine eigenen PRs zu kommentieren; der Kommentarpfad
      # wird ueber tofu-plan-render.bats abgedeckt, nicht hier.
      comment_on_pr: false
      runs_on: '["ubuntu-latest"]'
    secrets:
      release_please_app_client_id: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      release_please_app_private_key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}

  assert-tofu-plan-changes:
    needs: [tofu-plan-changes]
    runs-on: ubuntu-latest
    steps:
      - name: has_changes muss true sein
        env:
          HAS_CHANGES: ${{ needs.tofu-plan-changes.outputs.has_changes }}
          SUMMARY_LINE: ${{ needs.tofu-plan-changes.outputs.summary_line }}
        run: |
          set -euo pipefail
          # Ohne State ist die Ressource immer neu. Ein 'false' hiesse, dass
          # -detailed-exitcode falsch ausgewertet wird — genau der Fall, den
          # `set +e` im Plan-Schritt abfaengt.
          if [[ "$HAS_CHANGES" != "true" ]]; then
            echo "::error::erwartet has_changes=true fuer einen Stack ohne State, bekam '${HAS_CHANGES}'" >&2
            exit 1
          fi
          if [[ "$SUMMARY_LINE" != *"to add"* ]]; then
            echo "::error::summary_line sollte 'to add' enthalten, war: '${SUMMARY_LINE}'" >&2
            exit 1
          fi
          echo "tofu-plan meldete: ${SUMMARY_LINE}"
```

- [ ] **Step 3: Wire into the summary aggregator**

`assert-tofu-plan-changes` in die `needs:`-Liste des `summary`-Jobs.

- [ ] **Step 4: Verify**

```bash
bash tests/conventions/check-summary-coverage.sh
```
Expected: exit 0

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/tofu-plan-local .github/workflows/self-ci.yml
git commit -m "test(tofu-plan): Plan gegen lokalen State ohne Credentials

Die Fixture hat keinen backend-Block und nutzt den null-Provider: der
Plan laeuft offline. Ohne vorhandenen State ist die Ressource immer
'to add', damit prueft die Assertion has_changes=true belastbar.

Ein 'false' hier hiesse, dass -detailed-exitcode falsch ausgewertet
wird — genau der Fall, den set +e im Plan-Schritt abfaengt."
```

---

# Phase 4 — Onboarding und Adopter

### Task 12: Detektor-Signale `iac` und `shell`

Beide Signale sind **repo-weit und additiv** — anders als `gitops`, das die `primary_language` einer Komponente überschreibt. Ein Go-Service mit einem `tofu/`-Verzeichnis bleibt ein Go-Service und bekommt trotzdem den `tofu-validate`-Job.

**Files:**
- Modify: `internal/domain/profile.go`
- Modify: `internal/app/detect/service.go`
- Create: `tests/fixtures/iac-shell-repo/tofu/main.tf`
- Create: `tests/fixtures/iac-shell-repo/scripts/deploy.sh`
- Create: `tests/fixtures/iac-shell-repo/.taskfiles/helper.sh`
- Create: `tests/fixtures/iac-shell-repo/go.mod`
- Test: `internal/app/detect/iac_shell_test.go`

**Interfaces:**
- Consumes: nichts
- Produces: `domain.Profile.IaC *IaCSignal` (JSON `iac`, Feld `directories`) und `domain.Profile.Shell *ShellSignal` (JSON `shell`, Feld `paths`). Task 13 liest beide im Template als `.profile.iac.directories` und `.profile.shell.paths`.

- [ ] **Step 1: Write the failing test**

`internal/app/detect/iac_shell_test.go`:

```go
package detect

import (
	"reflect"
	"testing"
)

// Ein Repo mit tofu/ und Shell-Skripten muss beide Signale tragen — und
// dabei ein Go-Repo BLEIBEN. Die Signale sind additiv, nicht klassifizierend.
func TestIaCAndShellSignals(t *testing.T) {
	p := detectFixture(t, "iac-shell-repo").Profile

	if p.IaC == nil {
		t.Fatal("erwartet ein iac-Signal, bekam nil")
	}
	if got, want := p.IaC.Directories, []string{"tofu"}; !reflect.DeepEqual(got, want) {
		t.Errorf("iac.directories = %v, erwartet %v", got, want)
	}

	if p.Shell == nil {
		t.Fatal("erwartet ein shell-Signal, bekam nil")
	}
	want := []string{".taskfiles/**/*.sh", "scripts/**/*.sh"}
	if got := p.Shell.Paths; !reflect.DeepEqual(got, want) {
		t.Errorf("shell.paths = %v, erwartet %v", got, want)
	}

	if p.Components[0].PrimaryLanguage != "go" {
		t.Errorf("primary_language = %q, erwartet \"go\" — die Signale duerfen die Sprache nicht ueberschreiben",
			p.Components[0].PrimaryLanguage)
	}
}

// Der Kern der Rueckwaertskompatibilitaet: ein Repo ohne .tf und ohne .sh
// darf KEINE der beiden Schluessel im Profil tragen. `omitempty` sorgt dafuer,
// dass das gerenderte Profil-JSON bestehender Adopter byte-identisch bleibt —
// genau das prueft check-rendered-goldens.sh.
func TestNoIaCOrShellSignalWhenAbsent(t *testing.T) {
	p := detectFixture(t, "go-repo").Profile
	if p.IaC != nil {
		t.Errorf("go-repo darf kein iac-Signal haben, bekam %+v", p.IaC)
	}
	if p.Shell != nil {
		t.Errorf("go-repo darf kein shell-Signal haben, bekam %+v", p.Shell)
	}
}
```

- [ ] **Step 2: Create the fixture**

`tests/fixtures/iac-shell-repo/go.mod`:

```
module example.com/iac-shell-repo

go 1.24
```

`tests/fixtures/iac-shell-repo/tofu/main.tf`:

```hcl
# Fixture: genuegt, damit classifyIaC das Verzeichnis findet.
resource "null_resource" "fixture" {}
```

`tests/fixtures/iac-shell-repo/scripts/deploy.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "fixture"
```

`tests/fixtures/iac-shell-repo/.taskfiles/helper.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "fixture helper"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/app/detect/ -run 'IaCAndShell|NoIaCOrShell' -v`
Expected: FAIL — `p.IaC undefined (type domain.Profile has no field or method IaC)`

- [ ] **Step 4: Add the domain types**

In `internal/domain/profile.go`, im `Profile`-Struct nach `Consumers` ergänzen:

```go
	IaC            *IaCSignal       `json:"iac,omitempty"`
	Shell          *ShellSignal     `json:"shell,omitempty"`
```

Und nach `GitOpsSignal` die beiden Typen:

```go
// IaCSignal listet die OpenTofu-Stacks eines Repos. `omitempty` am Profilfeld
// ist Pflicht: ohne .tf-Dateien darf der Schluessel gar nicht erscheinen,
// sonst aendert sich das gerenderte Profil-JSON jedes bestehenden Adopters.
type IaCSignal struct {
	Directories []string `json:"directories"`
}

// ShellSignal listet Globs auf die Shell-Skripte eines Repos, nicht die
// Einzeldateien: eine neue Datei in scripts/ soll das Profil NICHT aendern
// und damit auch keinen Drift ausloesen.
type ShellSignal struct {
	Paths []string `json:"paths"`
}
```

- [ ] **Step 5: Add the classifiers**

In `internal/app/detect/service.go`, neben `classifyGitOps`:

```go
// Verzeichnisse, in denen weder IaC noch eigene Skripte des Repos stehen.
// .catalog ist der Katalog-Checkout aus einem Workflow-Lauf, vendor und
// node_modules sind Fremdcode — Funde dort waeren nicht die des Adopters.
var signalSkipDirs = map[string]bool{
	".git": true, ".catalog": true, "vendor": true, "node_modules": true,
	".terraform": true, ".venv": true, ".task": true,
}

// classifyIaC liefert die Verzeichnisse, die *.tf-Dateien enthalten.
// Rueckgabe nil (nicht ein leeres Signal), wenn es keine gibt — der
// Profilschluessel muss dann ganz fehlen.
func classifyIaC(repo string) *domain.IaCSignal {
	dirs := collectDirsWithSuffix(repo, ".tf")
	if len(dirs) == 0 {
		return nil
	}
	return &domain.IaCSignal{Directories: dirs}
}

// classifyShell liefert Globs statt Dateilisten. Wuerde hier jede einzelne
// Datei stehen, aenderte jedes neue Skript das Profil und loeste Drift aus,
// obwohl sich an der CI-Konfiguration nichts geaendert hat.
func classifyShell(repo string) *domain.ShellSignal {
	dirs := collectDirsWithSuffix(repo, ".sh")
	if len(dirs) == 0 {
		return nil
	}
	tops := map[string]bool{}
	for _, d := range dirs {
		top := d
		if i := strings.Index(d, string(filepath.Separator)); i > 0 {
			top = d[:i]
		}
		tops[top] = true
	}
	var out []string
	for t := range tops {
		if t == "." {
			out = append(out, "*.sh")
			continue
		}
		out = append(out, t+"/**/*.sh")
	}
	sort.Strings(out)
	return &domain.ShellSignal{Paths: out}
}

// collectDirsWithSuffix liefert die repo-relativen Verzeichnisse, die
// mindestens eine Datei mit der Endung enthalten — sortiert und dedupliziert.
func collectDirsWithSuffix(repo, suffix string) []string {
	seen := map[string]bool{}
	_ = filepath.WalkDir(repo, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if signalSkipDirs[d.Name()] {
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(d.Name(), suffix) {
			return nil
		}
		rel, relErr := filepath.Rel(repo, filepath.Dir(path))
		if relErr != nil {
			return nil
		}
		seen[rel] = true
		return nil
	})
	out := make([]string, 0, len(seen))
	for d := range seen {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}
```

Und im Aufbau des Profils (dort, wo `GitOps: gitops` gesetzt wird) ergänzen:

```go
		IaC:            classifyIaC(req.RepoPath),
		Shell:          classifyShell(req.RepoPath),
```

> Imports prüfen: `io/fs`, `path/filepath`, `sort`, `strings` müssen in `service.go` vorhanden sein.

- [ ] **Step 6: Run tests to verify they pass**

```bash
go test ./internal/app/detect/ -run 'IaCAndShell|NoIaCOrShell' -v
go test ./...
```
Expected: alle PASS — insbesondere die bestehenden Detektor-Tests, die belegen, dass sich für Repos ohne `.tf`/`.sh` nichts ändert.

- [ ] **Step 7: Verify the golden files are untouched**

Run: `bash tests/conventions/check-rendered-goldens.sh`
Expected: exit 0 — bestehende Goldens byte-identisch. Schlägt es fehl, ist `omitempty` an einem der beiden Profilfelder vergessen worden.

- [ ] **Step 8: Commit**

```bash
git add internal/domain/profile.go internal/app/detect/service.go \
        internal/app/detect/iac_shell_test.go tests/fixtures/iac-shell-repo
git commit -m "feat(onboard): iac- und shell-Signale im Detektor

Beide sind repo-weit und additiv — anders als gitops, das die
primary_language ueberschreibt. Ein Go-Service mit tofu/ bleibt ein
Go-Service und bekommt trotzdem den tofu-validate-Job.

shell liefert Globs statt Dateilisten: mit Einzeldateien loeste jedes
neue Skript Drift aus, obwohl sich an der CI-Konfiguration nichts
geaendert hat.

Beide Felder omitempty — Profile ohne .tf/.sh bleiben byte-identisch,
was check-rendered-goldens.sh erzwingt."
```

### Task 13: Template-Blöcke für `tofu-validate` und `lint-shell`

**Files:**
- Modify: `docs/adopter-templates/skeletons/ci.yml.tmpl`
- Create/Modify: Golden-Dateien für die neue Fixture

**Interfaces:**
- Consumes: `domain.Profile.IaC`, `domain.Profile.Shell` (Task 12); die Atome aus Tasks 3 und 6
- Produces: gerenderte `ci.yml`-Jobs `tofu-validate` und `shellcheck`

- [ ] **Step 1: Add the blocks to the template**

Ans **Ende** von `docs/adopter-templates/skeletons/ci.yml.tmpl`, hinter die per-Komponente-Kette — die Signale sind repo-weit, gehören also nicht in den `else if`-Zweig einer Komponente:

```gotemplate
{{- if index .profile "iac" }}

  tofu-validate:
    uses: serverkraken/reusable-workflows/.github/workflows/tofu-validate.yml@{{ $pin }}
    permissions:
      contents: read
    with:
      working_directories: |-
        {{- range $.profile.iac.directories }}
        {{ . }}
        {{- end }}
      tofu_version: {{`${{ vars.SK_TOFU_VERSION || '' }}`}}
    secrets: inherit
{{- end }}
{{- if index .profile "shell" }}

  shellcheck:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-shell.yml@{{ $pin }}
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      paths: |-
        {{- range $.profile.shell.paths }}
        {{ . }}
        {{- end }}
      shellcheck_version: {{`${{ vars.SK_SHELLCHECK_VERSION || '' }}`}}
    secrets: inherit
{{- end }}
```

- [ ] **Step 2: Check the scalar-quoting convention**

Run: `python3 tests/conventions/check-template-scalar-quoting.py`
Expected: exit 0. Schlägt es fehl, muss der betroffene Wert in Anführungszeichen — der Check existiert, weil ein unquotierter Wert wie `on` oder `1.10` von YAML als Bool bzw. Zahl gelesen wird.

- [ ] **Step 3: Render the new fixture and record its golden**

```bash
bash tests/conventions/check-rendered-goldens.sh
```
Expected: FAIL beim ersten Lauf — für `iac-shell-repo` existiert noch kein Golden. Das Golden nach dem im Skript beschriebenen Verfahren erzeugen, dann den Inhalt **von Hand lesen**: er muss genau die beiden neuen Jobs plus die Go-Jobs enthalten.

- [ ] **Step 4: Verify byte-stability for existing adopters**

Run: `bash tests/conventions/check-rendered-goldens.sh`
Expected: exit 0, und `git diff --stat` zeigt **keine** Änderung an bestehenden Golden-Dateien. Jede Änderung dort wäre Drift bei allen Adoptern.

- [ ] **Step 5: Commit**

```bash
git add docs/adopter-templates/skeletons/ci.yml.tmpl tests/
git commit -m "feat(onboard): tofu-validate und shellcheck im ci.yml-Template

Die Bloecke stehen hinter der Komponenten-Kette, nicht im gitops-Zweig:
beide Signale sind repo-weit. Ein Go-Service mit tofu/ bekommt damit
beides.

Bestehende Goldens bleiben byte-identisch — die Bloecke rendern nur,
wenn das jeweilige Signal existiert."
```

### Task 14: `homelab-hetzner` onboarden und Interim-Blöcke ablösen

> **Vorbefund, der hier zu beachten ist.** `homelab-hetzner` hat **kein `kubernetes/`-Verzeichnis** (Stand 2026-08-27, per API geprüft — HTTP 404; es ist auch nicht gitignored). Sein handgeschriebenes `ci.yml` ruft `kube-validate` aber mit `manifests_paths: kubernetes/apps, kubernetes/argo` auf. Diese Jobs sind **nie gelaufen**, weil `ci.yml` nur auf `pull_request` triggert und es bislang keinen PR gab.
>
> Zwei Folgen:
> 1. `detectGitOpsKubernetes` verlangt ein `kubernetes/`-Verzeichnis. Der Detektor stuft das Repo daher **nicht** als GitOps ein, und das gerenderte `ci.yml` enthält kein `kube-validate`/`kube-lint`/`secret-scan`. Das ist kein Verlust — die Jobs zeigen heute ins Leere.
> 2. Sobald die Manifeste unter `kubernetes/` landen, erkennt der Detektor sie beim nächsten Onboarding-Lauf automatisch und rendert die drei Jobs dazu.
>
> Der PR muss das im Beschreibungstext festhalten, damit niemand die verschwundenen Jobs für ein Versehen hält.

**Files:**
- Modify (im Adopter-Repo `serverkraken/homelab-hetzner`): `.github/workflows/ci.yml`
- Modify: `docs/onboarding-status.md` (wird vom Onboarding-Workflow selbst geschrieben)

**Interfaces:**
- Consumes: alle Atome aus Phasen 1–3, Template aus Task 13
- Produces: einen PR gegen `serverkraken/homelab-hetzner`

- [ ] **Step 1: Preview the render against the real repo**

```bash
git clone --depth 1 https://github.com/serverkraken/homelab-hetzner /tmp/hh-preview
go run ./cmd/sk-workflows preview --repo /tmp/hh-preview
```
Erwartete Ausgabe: ein `ci.yml` mit `trivy-fs` (bestehend), `tofu-validate` (`working_directories: tofu`) und `shellcheck` (`paths: .taskfiles/**/*.sh`, `scripts/**/*.sh`). Kein `kube-*`-Job — siehe Vorbefund.

- [ ] **Step 2: Diff the preview against the current ci.yml**

```bash
diff -u /tmp/hh-preview/.github/workflows/ci.yml <(go run ./cmd/sk-workflows preview --repo /tmp/hh-preview --stdout)
```
Jede Abweichung in eine von drei Klassen einordnen und schriftlich festhalten:
1. **gewollt** — Interim-Block weicht dem Katalog-Aufruf
2. **repo-spezifisch, muss bleiben** — der Talos-Schematic-ID-Job und die `files_ignore`-Liste an `trivy-fs`
3. **unerwartet** — hier stoppen und die Ursache klären, statt den Diff zu übernehmen

- [ ] **Step 3: Verify the two interim jobs are actually replaceable**

Prüfen, dass der gerenderte `shellcheck`-Job dieselben Dateien erfasst wie der Interim-Job (`scripts/*.sh scripts/lib/*.sh .taskfiles/template/resources/*.sh`). Der Glob `scripts/**/*.sh` deckt die ersten beiden ab, `.taskfiles/**/*.sh` den dritten. Zusätzlich greift `scan_shebangs`, das der Interim-Job nicht hatte — **hier können neue Funde auftauchen**. Vor dem PR lokal gegenprüfen:

```bash
cd /tmp/hh-preview && shellcheck -x $(git ls-files '*.sh') && echo "sauber"
```
Schlägt das fehl, gehören die Funde in einen **eigenen, vorgelagerten** PR am Adopter — nicht in den Onboarding-PR, sonst vermischen sich Zuständigkeiten.

- [ ] **Step 4: Open the adopter PR**

Der PR ersetzt beide INTERIM-Blöcke (siehe Spec § 9), lässt den Talos-Schematic-ID-Job unverändert stehen und beschreibt im Body:
- welche zwei Inline-Jobs entfallen und gegen welche Atome sie getauscht werden
- dass `opentofu/setup-opentofu@v1` damit verschwindet
- den `kubernetes/`-Vorbefund aus dem Kasten oben
- dass `tofu-plan` bewusst **nicht** verdrahtet wird, solange Decision 0002 offen ist und der State lokal liegt

- [ ] **Step 5: Verify the PR is green**

```bash
gh pr checks --repo serverkraken/homelab-hetzner <PR>
```
Expected: `tofu-validate`, `shellcheck`, `secscan` grün. Das ist zugleich der **erste echte Lauf** von `ci.yml` in diesem Repo — mit Auffälligkeiten ist zu rechnen, sie gehören ausgewertet und nicht weggeklickt.

- [ ] **Step 6: Confirm the onboarding status row**

Nach dem Merge erscheint `serverkraken/homelab-hetzner` in `docs/onboarding-status.md` und im Drift-Check. Der Eintrag wird vom Onboarding-Workflow geschrieben, nicht von Hand.

- [ ] **Step 7: Update the feature requests in flow**

Die beiden FRs `notes/fr-opentofu-atome` und `notes/fr-lint-shell` mit `flow_update_doc` als erledigt markieren, mit Verweis auf die Spec und die Release-Version. Der offen bleibende Teil — `tofu-plan` wartet auf Decision 0002 — gehört ausdrücklich vermerkt, sonst liest sich der FR später als vollständig umgesetzt.

---

## Reihenfolge und Releases

Phasen 1, 2 und 3 sind je für sich releasebar; jede ergibt einen Minor-Bump in `v4`. Phase 4 setzt voraus, dass die Atome unter `@v4` veröffentlicht sind — das Template pinnt auf den Major, und ein Aufruf auf ein noch nicht released Atom schlägt beim Adopter fehl.

Empfohlener Schnitt: Phasen 1+2 in einem Release (beide lösen je einen Interim-Block ab), Phase 3 in einem zweiten, Phase 4 nach dem zweiten Release.
