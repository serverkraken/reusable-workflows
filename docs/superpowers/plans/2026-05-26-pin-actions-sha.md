# Pin Actions by SHA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Renovate-driven SHA-pinning für alle GitHub Actions im Catalog durch zwei Edits in `.github/renovate.json5` plus eine kurze Section in `CONTRIBUTING.md`. Kein Massen-Re-Write der 28 Workflow-Files in dieser PR — Renovate erzeugt nach Merge eine grouped Pin-PR.

**Architecture:** Single PR, zwei file edits. `helpers:pinGitHubActionDigests` Preset zu `extends`-Array; neue `packageRule` für `matchUpdateTypes: ['pin']` zum Gruppieren der initialen Pin-Updates. Ongoing automerge-Rule für minor/patch bleibt unverändert. CONTRIBUTING.md bekommt neue "Action Pinning" Section.

**Tech Stack:** Renovate JSON5-config, Markdown, `renovate-config-validator` CLI (via npx) für lokale Validierung.

**Spec:** `docs/superpowers/specs/2026-05-26-pin-actions-sha-design.md` — authoritative reference. Wenn dieser Plan und das Spec voneinander abweichen, gewinnt das Spec.

---

## File Structure

**Modified files (2):**

| Path | Concern |
|---|---|
| `.github/renovate.json5` | Preset zu `extends`; neue `packageRule` für `matchUpdateTypes: ['pin']` |
| `CONTRIBUTING.md` | Neue Section "Action Pinning" am Ende |

**Commit map** (1 atomic commit):

1. `chore(renovate): enable SHA pinning for GitHub Actions` → Tasks 1 + 2 zusammengefasst

**Reihenfolge:** Renovate-Config-Edit zuerst (Task 1), CONTRIBUTING-Section zweite (Task 2), beide werden in einem Commit zusammengefasst (Task 3) — sie sind logisch eine Änderung.

---

## Pre-flight: Worktree setup

### Task 0.1: Sync main + create worktree

**Files:** none (git only)

- [ ] **Step 1: Sync local main**

```bash
git fetch origin main
git checkout main
git pull --rebase origin main
```

Expected: `Your branch is up to date with 'origin/main'.` (oder leichtes fast-forward auf die letzten lokalen-only docs-commits)

- [ ] **Step 2: Create worktree**

```bash
git worktree add .worktrees/pin-actions-sha -b feat/pin-actions-sha main
```

Expected: `Preparing worktree (new branch 'feat/pin-actions-sha')`

- [ ] **Step 3: Verify**

```bash
git worktree list
```

Expected: neuer Eintrag `.worktrees/pin-actions-sha [feat/pin-actions-sha]`.

Alle nachfolgenden Tasks (1–4) laufen aus `.worktrees/pin-actions-sha`.

---

## Task 1: Renovate-Config-Edit

**Files:**
- Modify: `.github/renovate.json5`

### Zwei Änderungen an einem File: preset-extend + neue packageRule.

- [ ] **Step 1: Preset zu `extends`-Array hinzufügen**

Im worktree, öffne `.github/renovate.json5`. Finde den `extends:` Block (Lines 3-8):

```json5
  extends: [
    'config:recommended',
    ':dependencyDashboard',
    ':semanticCommits',
    'group:allNonMajor',
  ],
```

Füge `'helpers:pinGitHubActionDigests',` als neue letzte Zeile innerhalb des Arrays ein:

```json5
  extends: [
    'config:recommended',
    ':dependencyDashboard',
    ':semanticCommits',
    'group:allNonMajor',
    'helpers:pinGitHubActionDigests',
  ],
```

- [ ] **Step 2: Neue `packageRule` für initial-pin gruppieren**

Im selben File, finde die existing "Major updates always require review"-Rule (Lines 49-59):

```json5
    {
      description: 'Major updates always require review',
      matchUpdateTypes: [
        'major',
      ],
      automerge: false,
      labels: [
        'dependencies',
        'major',
      ],
    },
```

Direkt nach dieser Rule, vor dem schließenden `],` des `packageRules` Arrays, neue Rule einfügen:

```json5
    {
      description: 'Initial SHA-pin: bundle all pin updates into one PR',
      matchManagers: [
        'github-actions',
      ],
      matchUpdateTypes: [
        'pin',
      ],
      groupName: 'Pin all GitHub Actions to SHA',
      automerge: false,
      labels: [
        'dependencies',
        'security',
      ],
    },
```

Die `packageRules` Array endet jetzt mit dieser neuen Rule, dann `],`, dann `vulnerabilityAlerts: {...}`.

- [ ] **Step 3: Lokal validieren mit `renovate-config-validator`**

Aus dem worktree-Root:

```bash
npx --yes --package renovate -- renovate-config-validator .github/renovate.json5
```

Expected:
```
 INFO: Validating .github/renovate.json5
 INFO: Config validated successfully
```

Bei Fehler: jedes diagnostic-Line lesen, gegen die Edits aus Step 1-2 vergleichen, Tippfehler beheben, Step 3 wiederholen.

- [ ] **Step 4: Inhalt verifizieren mit jq**

```bash
jq -r '.extends | join(",")' .github/renovate.json5
```

Expected: `config:recommended,:dependencyDashboard,:semanticCommits,group:allNonMajor,helpers:pinGitHubActionDigests`

Note: jq parsiert JSON5 via die kommentar-toleranten Modi der modernen jq-Versionen; falls jq scheitert wegen JSON5-spezifischer Syntax (unquoted keys, trailing commas), nutze dieses fallback:

```bash
grep "helpers:pinGitHubActionDigests" .github/renovate.json5
```

Expected: eine Zeile, die `'helpers:pinGitHubActionDigests',` enthält.

```bash
grep -c "Initial SHA-pin" .github/renovate.json5
```

Expected: `1`

---

## Task 2: CONTRIBUTING-Section hinzufügen

**Files:**
- Modify: `CONTRIBUTING.md`

- [ ] **Step 1: Neue Section am Ende anhängen**

`CONTRIBUTING.md` endet aktuell (Line 51) mit:

```markdown
Document any new gotcha in `CLAUDE-troubleshooting.md` so the next session benefits.
```

Am File-Ende, nach dieser Zeile, neue Section anhängen:

```markdown

## Action Pinning

All GitHub Actions in `.github/workflows/` and `actions/*/action.yml` are pinned to
SHA digests with a `# v<version>` trailer comment, e.g.:

    uses: actions/checkout@8e5e7e5ab8b370d6c329ec480221332ada57f0ab # v3.5.2

Renovate is configured with `helpers:pinGitHubActionDigests` and maintains the
pins automatically — both initial pinning and ongoing updates. Manual edits
should follow the same format; Renovate will re-pin any tag-only references on
its next run.

Background: defense-in-depth against tag-injection (tj-actions/changed-files
incident, March 2025).
```

Wichtig: führende Leerzeile direkt nach Line 51, damit die Section vom vorherigen Absatz getrennt ist.

- [ ] **Step 2: Markdown-Format spotcheck**

```bash
tail -20 CONTRIBUTING.md
```

Expected output endet mit der "Background: defense-in-depth..." Zeile. Heading `## Action Pinning` muss sichtbar sein, und der Beispiel-Code-Block muss eingerückt sein (4 Spaces, kein triple-backtick — der pattern ist konsistent mit dem Beispiel-Code in der existing "Local validation" Section).

```bash
wc -l CONTRIBUTING.md
```

Expected: ~68 Zeilen (war 51, plus ~17 für die neue Section).

---

## Task 3: Commit + Push + PR

**Files:** none (git only)

- [ ] **Step 1: Stage + commit beide Files in einem commit**

```bash
git add .github/renovate.json5 CONTRIBUTING.md
git status
```

Expected: zwei modified Files staged, nichts anderes.

```bash
git commit -m "chore(renovate): enable SHA pinning for GitHub Actions

Adds helpers:pinGitHubActionDigests preset and a packageRule that
groups the initial pin-PR. Ongoing minor/patch automerge rule
already covers SHA-bumps tied to non-major releases.

Defense-in-depth against tag-injection (tj-actions/changed-files
incident, March 2025)."
```

Expected: ein neuer commit auf `feat/pin-actions-sha`. Conventional-commit `chore:` löst keinen release-please-Bump aus.

- [ ] **Step 2: Push**

```bash
git push -u origin feat/pin-actions-sha
```

Expected: branch created on origin, link zum compare-view ausgegeben.

- [ ] **Step 3: PR erstellen**

```bash
gh pr create --title "chore(renovate): enable SHA pinning for GitHub Actions" --body "$(cat <<'EOF'
## Summary

- Aktiviert `helpers:pinGitHubActionDigests` preset für `manager:github-actions` — Renovate pinnt nach Merge alle Actions auf SHA digests mit `# v<ver>` Trailer-Kommentar
- Neue `packageRule` für `matchUpdateTypes: ['pin']` bündelt das initiale Pinning in einer einzigen grouped PR statt ~25 einzelner
- Existing minor/patch automerge-Rule für `github-actions` bleibt unverändert — fängt ongoing SHA-Bumps tied to non-major Releases ab
- `CONTRIBUTING.md` bekommt eine "Action Pinning" Section, die die Policy festhält

Defense-in-depth gegen tag-injection (tj-actions/changed-files-Incident März 2025).

Kein workflow_call interface change → `chore` commit, kein Release-Bump.

## Test plan

- [ ] `renovate-config-validator` lokal exit 0
- [ ] `validate.yml` CI (actionlint + yamllint + step-summary gate) green
- [ ] Nach Merge: erste Renovate-Run erzeugt grouped PR namens "Pin all GitHub Actions to SHA" mit ~25 unique action refs in 28 Files
- [ ] Pin-PR Format: `uses: <repo>@<40-hex-sha> # v<version>`
- [ ] Pin-PR Integration-Tests green
- [ ] Pin-PR manuell merged → zweiter Renovate-Run produziert NULL weitere Pin-PRs (idempotency check)
EOF
)"
```

Expected: PR-URL stdout. Note die PR-Nummer für die spätere Review/Merge-Phase.

- [ ] **Step 4: PR-CI abwarten**

```bash
gh pr checks --watch
```

Expected: alle Checks green (`validate`, `integration` falls triggered, etc.). Bei Fehler: diagnostic lesen, fix-commit auf gleichem branch, push, wait again.

---

## Task 4: Post-merge Validation (post-PR-merge, separate session)

Diese Tasks laufen NACH Merge der PR, nicht innerhalb dieses Plans-Execution. Hier nur dokumentiert für die Acceptance-Criteria-Verifikation.

- [ ] **Schritt A: Renovate-Run triggern**

Option 1 — warten auf Cron: nächster Monday 6am Berlin, automatisch.

Option 2 — manuell triggern: navigate to `https://github.com/serverkraken/reusable-workflows/issues` → "Dependency Dashboard" issue → checkbox "Check this box to trigger a request for Renovate to run again on this repository".

- [ ] **Schritt B: Pin-PR verifizieren**

Erwarte eine neue PR namens "Pin all GitHub Actions to SHA" mit:
- ~28 modified Files (`.github/workflows/*.yml` + `actions/*/action.yml`)
- Pro Action-Ref: `uses: <repo>@<40-hex-sha> # v<version>` Format
- ~25 unique action refs sind erfasst

Spotcheck Beispiele (visual review im PR diff):
- `uses: actions/checkout@<sha> # v6.x.x`
- `uses: docker/build-push-action@<sha> # v7.x.x`
- `uses: dtolnay/rust-toolchain@<sha> # master` (Branch-ref, kein Tag → comment ist branch-name)

- [ ] **Schritt C: Pin-PR CI verifizieren**

Integration-Tests im Pin-PR müssen green sein. Bei Fehler: meist ein einzelner Action-Pin Inkompatibilität mit der existing Workflow-Logik — diagnostiziere, ggf. floating-Tag belassen über Renovate-Ignore-Rule.

- [ ] **Schritt D: Pin-PR mergen + Idempotency-Check**

Nach Merge, manuell zweiten Renovate-Run triggern (Schritt A wieder). Erwarte: KEINE neue Pin-PR. Falls doch eine erscheint → bug-report dieses Plans + spec.

---

## Self-Review Checklist (vor Plan-Approval)

Diese Sektion ist Schreib-Hilfe für den Plan-Author, nicht Teil der Execution.

**1. Spec coverage:**
- C-1 (`pinDigests` aktivieren) → Task 1, Step 1
- C-2 (Initial-Pin gruppieren) → Task 1, Step 2
- C-3 (Ongoing automerge unverändert) → kein Edit, dokumentiert in Plan-Architecture
- C-4 (CONTRIBUTING-Doc) → Task 2

Alle Acceptance-Criteria sind in Task 1-4 abgedeckt.

**2. Placeholder scan:** keine TBD/TODO. Jeder Step zeigt das exakte Code/Commando.

**3. Type consistency:** preset-name (`helpers:pinGitHubActionDigests`), groupName (`Pin all GitHub Actions to SHA`), label-namen (`dependencies`, `security`) sind im Plan konsistent verwendet.

**4. Ambiguity check:** jq-fallback dokumentiert für den Fall dass jq JSON5 nicht parst (Step 4 in Task 1).
