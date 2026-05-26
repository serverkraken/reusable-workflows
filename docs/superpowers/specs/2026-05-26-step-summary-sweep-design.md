# `$GITHUB_STEP_SUMMARY` Sweep — Catalog-weite Konvention (Design Spec)

**Datum:** 2026-05-26
**Quelle:** Soenne — Tier-1-Item aus der Phase-8-Roadmap (`reference_phase8_candidate_roadmap.md`). Adopter sollen pro Atom-Run einen sofort lesbaren Markdown-Summary in der GitHub-Actions-Run-Page sehen, ohne in die Logs zu graben. Aktueller Stand: 8 von 22 Atoms schreiben Summaries, in heterogenem Format; 14 schreiben gar nichts.
**Scope:** Konvention festschreiben (`docs/conventions/step-summary.md`), bestehende Summaries auf die Konvention bringen, fehlende Summaries ergänzen, CI-Gate gegen Konvention-Verletzung in `validate.yml` einziehen. Minor-Release (`feat:`, kein Breaking).
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger).
**Vorgänger:** Bestehende heterogene Summary-Implementierungen in `trivy-image.yml`, `trivy-fs.yml`, `docker-build.yml`, `helm-publish.yml`, `semantic-release.yml`, `goreleaser.yml`, `cleanup-images.yml`, `onboard.yml`.

---

## 1. Goal

Jede consumer-facing oder org-interne Atom-Run zeigt einen einheitlichen, kurzen Markdown-Summary in der GitHub-Actions-Run-Page. Format und Pflichtfelder sind im Repo kanonisch festgehalten; ein CI-Gate verhindert, dass neue Atoms ohne Summary in den Catalog gelangen.

| Heute | Mit dem Spec |
|---|---|
| 8/22 Atoms schreiben Summary; Format heterogen (manche mit `## Heading`, manche ohne; manche mit Versions-Info, manche ohne) | Alle 18 consumer/org-internen Atoms schreiben Summary nach festem Schema; 4 Self-CI-Atoms explizit exempt |
| Konvention existiert nicht — Reviewer entscheiden ad-hoc | Konvention in `docs/conventions/step-summary.md`; Referenz in `CONTRIBUTING.md`; Top-Kommentar pro Atom-File |
| Neue Atoms vergessen Summary → erst beim manuellen Review (oder gar nicht) bemerkt | `validate.yml` läuft `tests/conventions/check-step-summary.sh`; Fehlende Summary bricht die CI mit Pfad zur Konvention |
| Adopter sehen Job-Logs durchsuchen, um z.B. Coverage % oder Trivy-Findings zu finden | Adopter sehen Werte im Run-Page-Summary, ein Scroll |

**Nicht Goal:**

- Shared composite action / shell-lib für Summary-Rendering. Approach B/C aus der Brainstorming-Phase wurden zugunsten von Approach A (inline pro Atom) verworfen. Lint-Atoms haben kein Catalog-Checkout; Composite-Action zu ziehen würde einen App-Token-Mint und Checkout-Step pro Atom kosten. YAGNI bis 3+ Atoms identische Tabellen rendern.
- Schema-Validation jenseits von "H2-Heading mit Atom-Name vorhanden". Stricter Checks (Pflichtfelder **Tool:**, **Result:**) wären brittle und würden mehr Wartung als Wert bringen.
- Migration der Self-CI-Atoms (`validate`, `integration`, `release`, `catalog-release`). Diese sind catalog-intern, redundant zu Caller-Summaries der getesteten Atoms und nicht adopter-sichtbar.
- Test-Coverage-Erweiterung der existierenden Caller-Tests. Visual-Verification beim Review-PR reicht — der CI-Gate fängt Absenz, die Konvention dokumentiert das Format, ein Caller-Test der Markdown-Inhalt parst wäre over-engineered.

## 2. Scope

### In Scope

| Concern | Outcome |
|---|---|
| **C-1** Konvention-Doc | Neue Datei `docs/conventions/step-summary.md`: Schema, Glyphen, Per-Klasse-Body-Spezifikation, kopierbare Beispiele |
| **C-2** CONTRIBUTING.md-Verweis | Neue Section "Atom-Konventionen" in `CONTRIBUTING.md` mit Link zu C-1 |
| **C-3** File-Header-Kommentar | Jeder in-scope Atom bekommt am Anfang die Zeile `# Summary convention: docs/conventions/step-summary.md` |
| **C-4** Bestehende Summaries auf Konvention bringen | `trivy-image.yml`, `trivy-fs.yml`, `docker-build.yml`, `helm-publish.yml`, `semantic-release.yml`, `goreleaser.yml`, `cleanup-images.yml` — H2-Heading auf Atom-Name normalisieren, **Tool:**/**Result:**-Zeilen ergänzen wo fehlend |
| **C-5** Fehlende Summaries ergänzen | `lint-go.yml`, `lint-python.yml`, `lint-rust.yml`, `lint-helm.yml`, `test-go.yml`, `test-python.yml`, `test-rust.yml`, `docker-build-multi.yml`, `onboard-sweep.yml`, `drift-check.yml` |
| **C-6** `onboard.yml` Konformitäts-Pass | 6 existierende Summary-Writes auf konsistenten H2-Header bringen (Pro-Target-Diff-Heading bleibt; ein zusätzlicher Atom-Level-Header wird vorangestellt) |
| **C-7** CI-Gate | Neues Script `tests/conventions/check-step-summary.sh`; neue Test-Bats-File `tests/shell/check-step-summary.bats`; neuer Step in `validate.yml` |
| **C-8** Self-CI-Allowlist | Explizite Liste im Check-Script: `validate.yml`, `integration.yml`, `release.yml`, `catalog-release.yml` |

### Out of Scope

- Composite-Action oder shell-lib für Summary-Rendering (siehe Section 1 "Nicht Goal")
- Schema-Validation jenseits H2-Presence (siehe Section 1 "Nicht Goal")
- Migration Self-CI-Atoms (siehe Section 1 "Nicht Goal")
- Erweiterung der `tests/callers/*.yml` — bestehende Caller produzieren das Summary jetzt automatisch
- Lokalisierung / i18n der Summary-Strings — Englisch, wie bisher
- Machine-readable Summary-Output (z.B. JSON-Sidecar). Markdown-only, GitHub rendert es nativ.

## 3. Background

### 3.1 Wie `GITHUB_STEP_SUMMARY` heute funktioniert

`$GITHUB_STEP_SUMMARY` ist eine Env-Var, die GitHub Actions pro Step setzt und auf eine schreibbare Datei zeigt. Inhalt landet im Job-Summary-Tab der Run-Page, Markdown wird gerendert. Max 1 MB pro Step. Schreibvorgänge sind `>>` (append); GitHub aggregiert über alle Steps eines Jobs.

Idiomatisches Pattern in diesem Repo (z.B. `trivy-image.yml`):

```bash
{
  echo "## Trivy image scan"
  echo ""
  echo "**Image:** $IMAGE"
  echo "**Findings:** **$COUNT**"
} >> "$GITHUB_STEP_SUMMARY"
```

### 3.2 Warum es jetzt zusammenführen?

Drei beobachtete Probleme:

1. **Diagnostik-Reibung:** Adopter, die Trivy-Findings, Coverage-%, oder Docker-Image-Digest sehen wollen, müssen in die Step-Logs. Ein H2 mit Key-Value-Block macht das zu einem Scroll auf der Run-Page.
2. **Inkonsistenz:** `semantic-release.yml` schreibt Summary in einem Code-Fence ohne Heading; `trivy-image.yml` schreibt mit `## Trivy image scan` (Heading != Atom-Name); `docker-build.yml` schreibt mit `**Tags:**` ohne H2. Reviewer haben kein objektives Kriterium.
3. **Drift-Risiko:** Neue Atoms (z.B. `docker-build-multi.yml`, das im letzten Quartal entstand) wurden ohne Summary gemerged. Niemand merkte es bis zum Adopter-Feedback.

Punkt 3 ist der Treiber für den CI-Gate (C-7) — die Konvention muss enforced, nicht nur dokumentiert sein.

### 3.3 Warum Approach A (inline pro Atom)

Aus der Brainstorming-Phase:

- **Approach B (Composite Action `actions/job-summary`):** Lint-Atoms haben kein Catalog-Checkout. Composite ziehen würde App-Token-Mint + Checkout-Step pro Atom kosten — siehe `troubleshooting_cross_repo_catalog_checkout.md`. Composite-Inputs sind ausserdem schlecht für variable strukturierte Daten (Markdown als String-Input ist hässlich).
- **Approach C (Shared shell-lib `scripts/lib/summary-lib.sh`):** Selbes Checkout-Problem wie B. Halbe Lösung, da fachlichen Zeilen weiterhin pro Atom geschrieben werden.
- **Approach A (inline pro Atom, geteilte Konvention via Spec):** Konsistent mit existierendem Code, kein Indirektions-Layer, kein extra Checkout. Drift-Risiko wird durch C-7 (CI-Gate) abgefedert.

## 4. Konvention (das Schema)

Volltext aus `docs/conventions/step-summary.md` (Auszug — kanonisch in C-1):

### 4.1 Pflicht-Struktur

```markdown
## <atom-name>

**Tool:** <toolname> <version>
**Result:** <glyph> <one-line status>

<atom-spezifischer Body — Tabelle oder Key-Value-Liste>
```

- **H2-Heading:** exakt `## <atom-name>`, wobei `<atom-name>` der Dateiname ohne `.yml` ist. Beispiele: `## lint-go`, `## docker-build-multi`. Die CI-Gate-Regex matched darauf.
- **Tool-Zeile:** Name + Version des primären Tools. Bei mehreren Tools (z.B. `lint-go` hat `go vet` + `golangci-lint`) Komma-separiert: `**Tools:** go vet, golangci-lint v2.12.2`.
- **Result-Zeile:** Genau ein Unicode-Glyph aus dieser Liste:
  - `✓` — Success (alle Checks pass, build erfolgreich, etc.)
  - `✗` — Failure (mind. ein Check failed, build broke, etc.)
  - `▲` — Warning/Partial (z.B. Trivy fand Findings, aber `fail_on_findings=false`; oder Coverage unter Threshold mit `enforce=false`)
  - Konsistent mit `feedback_no_emoji_use_glyphs.md`.
- **Body:** Pro Atom-Klasse spezifisch — siehe Section 4.2.

### 4.2 Per Atom-Klasse: Body-Inhalt

| Klasse | Pflicht-Body |
|---|---|
| `lint-*` | Working-Dir, Tabelle `\| Check \| Status \|` mit Zeile pro Tool (z.B. `go vet`, `golangci-lint`) |
| `test-*` | Working-Dir, Test-Count (run/pass/fail), Coverage % + Threshold, Duration |
| `trivy-*` | Target (Image-Ref oder Pfad), Severities-Filter, Findings-Count-Tabelle nach Severity |
| `docker-build`, `docker-build-multi` | Tags, Digest, Platforms, Sign/Attest/SBOM-Status-Zeile |
| `helm-publish` | Chart-Name, Version, OCI-Ref, Digest |
| `semantic-release` | Old-Version → New-Version, Bump-Type, Release-URL (oder "no release" wenn idle) |
| `goreleaser` | Tag, Artifact-Count, Release-URL |
| `cleanup-images` | Tabelle `\| Rule \| Kept \| Deleted \|` |
| `onboard`, `onboard-sweep`, `drift-check` | Aktueller Body bleibt; nur H2-Header voranstellen |

### 4.3 Style-Regeln

- **Code-Inline:** Image-Refs, Pfade, Versions-Strings in Backticks.
- **Tabellen:** Pipes mit Spaces gepolstert (`| key | value |`).
- **Keine Emoji.** Nur Unicode-Glyphen aus der Liste oben.
- **Keine externe Links** ausser auf GHCR/GitHub-eigene URLs (Release-Page, Compare-View).
- **Append, nicht overwrite:** Immer `>>`, nie `>`.

## 5. Robustness-Regeln

Pro Atom-Klasse:

| Klasse | Step-Condition | Rationale |
|---|---|---|
| `lint-*` | `if: always()` | Issue-Count auch bei Fail sichtbar (golangci-lint exit≠0 ist häufig) |
| `test-*` | `if: always()` | Coverage muss auch bei rotem Test berichtet werden |
| `trivy-*` | `if: always()` | Findings müssen auch bei `fail_on_findings=true` sichtbar werden, bevor der Fail-Step abbricht |
| `docker-build*` | normaler Step (kein `always()`) | Digest existiert erst nach erfolgreichem Push; vor Push gibt's nichts zu berichten |
| `helm-publish`, `semantic-release`, `goreleaser`, `cleanup-images` | normaler Step | Werte existieren erst nach Erfolg |
| `onboard*`, `drift-check` | wie heute | Bestehende Conditions bleiben |

Alle Summary-Schreibvorgänge mit `|| true` ummanteln:

```bash
{
  echo "## lint-go"
  ...
} >> "$GITHUB_STEP_SUMMARY" || true
```

Begründung: Ein Schreibfehler (z.B. Quota-Überschreitung bei 1 MB-Cap) darf den Job nicht brechen. Summary ist Observability, nicht Funktionalität.

## 6. CI-Gate (C-7)

### 6.1 Script `tests/conventions/check-step-summary.sh`

Pseudo-Code:

```bash
#!/usr/bin/env bash
set -euo pipefail

SELF_CI_ALLOWLIST=(
  "validate.yml"
  "integration.yml"
  "release.yml"
  "catalog-release.yml"
)

CONVENTION_DOC="docs/conventions/step-summary.md"
FAILED=0

for file in .github/workflows/*.yml; do
  basename=$(basename "$file")
  atom_name="${basename%.yml}"

  # Skip self-CI
  for skip in "${SELF_CI_ALLOWLIST[@]}"; do
    [[ "$basename" == "$skip" ]] && continue 2
  done

  # Check 1: GITHUB_STEP_SUMMARY write present
  if ! grep -q 'GITHUB_STEP_SUMMARY' "$file"; then
    echo "FAIL: $basename writes no \$GITHUB_STEP_SUMMARY."
    echo "      See $CONVENTION_DOC for the required format."
    FAILED=1
    continue
  fi

  # Check 2: H2 heading matches atom name
  if ! grep -qE "^[[:space:]]*echo[[:space:]]+(['\"])## ${atom_name}\1" "$file" && \
     ! grep -qE "^[[:space:]]+## ${atom_name}([[:space:]]|$)" "$file"; then
    echo "FAIL: $basename writes summary but no '## ${atom_name}' heading found."
    echo "      Heading must match atom filename per $CONVENTION_DOC."
    FAILED=1
  fi
done

exit $FAILED
```

Die zweite Regex deckt zwei Patterns ab:

- `echo "## lint-go"` — Single-line echo (häufig).
- Heredoc oder mehrzeilige `{ echo … }`-Blöcke mit literal `## lint-go` (im onboard-Style).

### 6.2 Bats-Test `tests/shell/check-step-summary.bats`

Drei Cases:

1. **Happy path:** Mock-Workflow-File mit korrekter Konvention → exit 0.
2. **Missing summary:** Mock ohne `GITHUB_STEP_SUMMARY` → exit 1, stderr enthält `writes no $GITHUB_STEP_SUMMARY`.
3. **Wrong heading:** Mock mit Summary aber `## something-else` → exit 1, stderr enthält `no '## <atom>' heading found`.

### 6.3 `validate.yml`-Integration

Neuer Step nach actionlint/yamllint:

```yaml
- name: Check step-summary convention
  run: bash tests/conventions/check-step-summary.sh
```

Fail-Mode: Job rot, Fehlermeldung verlinkt die Konvention-Doc.

## 7. Implementation Outline

PR-Shape: **Ein PR** mit atomic commits gruppiert nach Concern. Worktree `.worktrees/step-summary` auf Branch `feat/step-summary-sweep`.

Vorgeschlagene Commit-Reihenfolge (jeder commit für sich grün):

1. `docs(conventions): add step-summary convention` — C-1, C-2 (Konvention-Doc + CONTRIBUTING-Verweis)
2. `test(conventions): add step-summary check script + bats` — C-7 (Script + Tests, noch nicht in validate.yml verdrahtet)
3. `feat(lint): step-summary writes for lint-{go,python,rust,helm}` — C-5 (Teil 1)
4. `feat(test): step-summary writes for test-{go,python,rust}` — C-5 (Teil 2)
5. `feat(trivy): step-summary writes for docker-build-multi, normalize trivy-*` — C-4 (trivy) + C-5 (docker-build-multi)
6. `feat(docker): normalize step-summary in docker-build` — C-4 (docker-build)
7. `feat(release): normalize step-summary in helm-publish, semantic-release, goreleaser, cleanup-images` — C-4 (Rest)
8. `feat(onboard): step-summary writes for onboard-sweep, drift-check; normalize onboard` — C-5 (org-intern) + C-6
9. `feat(workflows): add convention file-header comments` — C-3 (alle 18 Atoms)
10. `feat(validate): enforce step-summary convention in CI` — Verdrahtung in `validate.yml`

Reihenfolge wichtig: Convention-Doc zuerst, CI-Gate **zuletzt** verdrahten, sonst brechen alle Zwischenstand-Commits die CI.

## 8. Testing

### 8.1 Automatisierte Tests

- `tests/shell/check-step-summary.bats` — 3 Cases (siehe 6.2)
- Bestehende `tests/callers/*.yml` — keine Änderung, sie produzieren Summaries jetzt einfach

### 8.2 Manuelle Verifikation (im Review-PR)

- Worktree gegen Test-Repo pushen (oder via `act` lokal): jeden Atom-Run aufrufen, Run-Page öffnen, Summary visuell prüfen
- Stichproben:
  - `lint-go` mit grünem Repo → ✓-Glyph, beide Tools `✓` in Tabelle
  - `lint-go` mit `golangci-lint` failure → ✗-Glyph, `golangci-lint` Zeile `✗`
  - `test-python` mit Coverage über Threshold → ✓
  - `test-python` mit Coverage unter Threshold (und `coverage_threshold` so gesetzt dass es failed) → ✗ mit Coverage-Wert sichtbar
  - `trivy-image` mit Findings (Test-Image mit bekanntem CVE) → ▲ oder ✗ je nach `fail_on_findings`
  - `docker-build` happy → ✓ mit Tags, Digest, Platforms, Sign-Status-Zeile

### 8.3 CI-Gate-Verifikation

- Nach Commit 10 (Validate-Verdrahtung): künstlich einen Summary-Write aus z.B. `lint-go` entfernen, push, CI muss rot werden mit Pfad zur Konvention-Doc. Revert.

## 9. Risiken

| Risiko | Mitigation |
|---|---|
| **R-1** Bestehender Caller-Test bricht durch Summary-Inhalts-Änderung | Caller-Tests parsen Summary-Inhalt nicht (nur Job-Status). Risiko ist hypothetisch. |
| **R-2** CI-Gate-Regex matched eine legitime Schreibweise nicht | Bats-Tests decken die zwei häufigsten Patterns ab. Falls beim Sweep ein dritter Pattern auftaucht, Regex iterativ erweitern. |
| **R-3** `\|\| true` maskiert echten Bash-Fehler in der Summary-Pipe | Akzeptiert. Summary ist Observability; ein Tippfehler in der Echo-Pipe darf den Job nicht brechen. Visual-Review fängt's. |
| **R-4** 1 MB-Cap überschritten bei sehr großen Trivy-Reports | Trivy-Summary listet nur Counts pro Severity, keine per-CVE-Tabelle. Cap-Risiko bei <100 Byte pro Run. |
| **R-5** Existierende `## Trivy image scan`-Heading wird auf `## trivy-image` umbenannt — Adopter, die sich auf den Heading-Namen verlassen | Sehr unwahrscheinlich (Heading-String ist UX, nicht API). Erwähnen im Release-Note. |
| **R-6** Onboard-Workflow-Heading-Konflikt mit existierenden Pro-Target-`## Rendered diff for <target>`-Headings | Atom-Level-`## onboard` wird ganz an den Anfang gestellt, Pro-Target-Headings bleiben als H3 (`### Rendered diff for …`) oder bleiben H2 darunter. Im Onboard-Commit entscheiden, Visual-Review. |

## 10. Rollback

Da kein Breaking Change und kein Permission-/Auth-Surface betroffen ist:

- **Vor CI-Gate-Verdrahtung (Commits 1-9):** Per `git revert` einzelner Commits. Adopter sehen nur Summary-Inhalt-Änderungen, kein Funktionsverhalten.
- **Nach CI-Gate-Verdrahtung (Commit 10):** Revert von Commit 10 deaktiviert den Gate; Summary-Writes bleiben. Falls schon released: Bugfix-Release mit `revert: enforce step-summary convention in CI` + `feat:` Commit für korrigierte Gate-Logik.
- Catalog-Release ist Minor (`feat:`), keine v3→v4-Bump nötig.

## 11. Memory-Updates nach Implementation

- Neue troubleshooting-Memory falls beim Sweep eine nicht-offensichtliche Gotcha aufkommt (z.B. spezifische Heredoc-Pattern, die der CI-Gate-Regex erweitert braucht)
- `reference_phase8_candidate_roadmap.md`: Tier-1-Item "STEP_SUMMARY through all atoms" als DONE markieren mit Datum

---

## Anhang A — Beispiel-Summaries

### `lint-go` (success)

```markdown
## lint-go

**Tools:** go vet, golangci-lint v2.12.2
**Working dir:** `./services/api`
**Result:** ✓ passed

| Check | Status |
|---|---|
| go vet | ✓ |
| golangci-lint | ✓ |
```

### `test-python` (failure, coverage under threshold)

```markdown
## test-python

**Tool:** pytest 8.3.2
**Working dir:** `.`
**Result:** ✗ coverage 84% < threshold 90%

| Metric | Value |
|---|---|
| Tests run | 142 |
| Passed | 142 |
| Failed | 0 |
| Coverage | 84% |
| Threshold | 90% |
| Duration | 38s |
```

### `trivy-image` (findings, fail_on_findings=false)

```markdown
## trivy-image

**Tool:** Trivy 0.58.1
**Image:** `ghcr.io/serverkraken/foo:v1.2.3`
**Severities:** HIGH, CRITICAL
**Result:** ▲ 3 findings (gate disabled)

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| HIGH | 2 |
```

### `docker-build-multi` (happy)

```markdown
## docker-build-multi

**Tool:** Buildx, distributed multi-arch
**Result:** ✓ pushed

| Field | Value |
|---|---|
| Tags | `v1.2.3`, `latest` |
| Digest | `sha256:abc…` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Sign | ✓ cosign keyless |
| Attest | ✓ SLSA provenance |
| SBOM | ✓ SPDX-JSON |
```
