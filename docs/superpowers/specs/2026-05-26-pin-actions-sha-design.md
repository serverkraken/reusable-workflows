# Pin GitHub Actions by SHA — Renovate-Driven Pinning (Design Spec)

**Datum:** 2026-05-26
**Quelle:** Phase 8 Tier-1 Roadmap-Item — defense-in-depth gegen tag-injection (tj-actions/changed-files-Incident, März 2025). Aktuell sind alle ~25 unique 3rd-party + first-party Actions im Catalog tag-gepinnt (`@v6` etc.), kein SHA-Pinning.
**Scope:** Single PR mit Edit an `.github/renovate.json5` — aktiviert `pinDigests` für `manager:github-actions`. Kein Massen-Re-Write der 28 Workflow/Action-Files in dieser PR — Renovate öffnet nach Merge eine grouped Pin-PR.
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger).
**Vorgänger:** v4.0.3 Stand, Renovate `config:recommended` ohne pinDigests.

---

## 1. Goal

Alle GitHub Actions in `.github/workflows/*.yml` (20 Workflows) und `actions/*/action.yml` (8 Composite Actions) werden auf SHA digests gepinnt mit einem `# v<version>` Trailer-Kommentar. Renovate übernimmt die Wartung der Pins — sowohl das initiale Pinning als auch nachfolgende Updates.

| Heute | Mit dem Spec |
|---|---|
| `uses: actions/checkout@v6` (Floating-Major-Tag) | `uses: actions/checkout@<sha40> # v6.0.2` |
| Tag-injection Risiko — Tag kann force-moved werden | Immutable SHA, force-move ändert nichts |
| Renovate sieht nur major Bumps (v6 → v7) | Renovate sieht jeden minor/patch (v6.0.2 → v6.0.3) als digest-update + version-comment-update |
| Inkonsistent mit Adopter-Predigt (`@v4` floating-major durch Catalog kontrolliert) | Catalog selbst praktiziert was es predigt: SHA-Pinning |

**Nicht Goal:**
- Manuelles Pre-Pinning der 28 Files in dieser PR. Renovate macht das nach Merge automatisch in einer grouped PR.
- Containerfile/docker-compose SHA-Pinning. Catalog hat keine produktiven Containerfiles (Test-Fixtures sind in `ignorePaths`).
- Adopter-Templates ändern. Templates rufen ausschließlich `serverkraken/reusable-workflows/.../@{{ $pin }}` — keine 3rd-party-refs, kein Impact.
- Whitelist für first-party Actions (`actions/*`, `github/*`). Konsistente Policy: alles pinnen. Defense-in-depth setzt voraus, dass auch first-party Actions kompromittierbar sind (tj-actions-Vorfall war nicht first-party, aber selbe Klasse).
- Custom CI-Guard, der tag-only refs blockiert. Renovate `pinDigests: true` rewriteted tag-pins beim nächsten Lauf zurück zu SHA — redundant.

## 2. Scope

### In Scope

| Concern | Outcome |
|---|---|
| **C-1** `pinDigests` aktivieren | `helpers:pinGitHubActionDigests` Preset zu `extends` hinzufügen — setzt intern `pinDigests: true` für `manager:github-actions` |
| **C-2** Initial-Pin gruppieren | Neue `packageRule` mit `matchUpdateTypes: ['pin']` und `groupName: 'Pin all GitHub Actions to SHA'` — ein grouped PR statt 25 einzelner |
| **C-3** Ongoing automerge unverändert | Bestehende `automerge: true` für `matchManagers: ['github-actions']` + `matchUpdateTypes: ['minor', 'patch']` deckt SHA-Bumps tied to non-major Releases ab — kein Edit |
| **C-4** CONTRIBUTING-Doc | Kurze Section in `CONTRIBUTING.md` die Pinning-Policy festhält und Renovate als Wartung erwähnt |

### Out of Scope

- Pre-Pinning aller 28 Files in dieser PR — siehe Section 1 "Nicht Goal"
- Verifikations-CI-Guard gegen tag-only refs
- Pinning-Erweiterung auf Containerfile/docker-compose Manager
- Anpassung der Adopter-Templates
- Versionsbump (kein workflow_call interface change → `chore(renovate)` commit-prefix)

## 3. Background

### 3.1 Warum SHA-Pinning

GitHub Action-Tags (`@v6`) sind mutable. `git tag -f v6 <new-sha> && git push --force-with-lease origin v6` ist mit Repo-Write-Access ein Einzeiler. Der **tj-actions/changed-files-Incident im März 2025** demonstrierte das im Großstil: kompromittiertes Maintainer-Account, `v45`-Tag force-moved zu malicious commit, ~25k consumers betroffen.

SHA-Pinning eliminiert das Risiko: `@<sha40>` ist immutable (git's content-addressed model). Selbst wenn der Tag-Pointer bewegt wird, gilt das Original-SHA weiter.

Trade-off: jede Action-Version-Bewegung wird sichtbar (mehr Renovate-PRs). Das Auto-Merge-Setup federt den operativen Aufwand ab.

### 3.2 Warum Renovate-driven statt manuelles Massen-Pre-Pinning

Drei Alternativen wurden evaluiert (Brainstorming 2026-05-26):

| Approach | Aufwand | End-State Cleanness | Risk |
|---|---|---|---|
| Manuell pre-pinnen alle 28 Files + Renovate aktivieren | hoch | hoch | manuelle SHA-Fehler |
| **Nur Renovate-Config aktivieren** (gewählt) | niedrig | mittel (Zwischenzustand bis Renovate läuft) | niedrig (Renovate ist deterministisch) |
| Hybrid (manuell 3rd-party, Renovate first-party) | mittel | inkonsistent | mittel (Logik split) |

Soenne wählt Renovate-driven: minimaler Edit, Renovate stellt End-State maschinell sicher, kein human-error in 25 SHA-Strings.

### 3.3 Renovate `helpers:pinGitHubActionDigests` Preset

[Documented Renovate preset](https://docs.renovatebot.com/presets-helpers/#helperspingithubactiondigests). Inhalt:

```json
{
  "github-actions": {
    "pinDigests": true
  }
}
```

Effekt: alle Action-References im `manager:github-actions` Scope (`.github/workflows/*.{yml,yaml}` und `action.yml`) werden bei nächstem Renovate-Run auf SHA gerewritten mit Version-Comment-Trailer.

### 3.4 Existing Renovate-Setup

`.github/renovate.json5` enthält bereits:
- `config:recommended`, `:dependencyDashboard`, `:semanticCommits`, `group:allNonMajor`
- Auto-merge für `github-actions` minor+patch (mit Integration-Tests als Gate)
- Major-Bumps gated
- Supply-chain group, Docker group, Vulnerability-Alerts
- `customManagers` für `TRIVY_VERSION` (Trivy-CLI-Pin in `install-trivy/action.yml`) — siehe Memory `project_renovate_custommanagers`

Pinning-Edit fügt sich nahtlos ein.

## 4. Design per Concern

### C-1: `pinDigests` aktivieren

**File:** `.github/renovate.json5`

**Diff:**
```diff
   extends: [
     'config:recommended',
     ':dependencyDashboard',
     ':semanticCommits',
     'group:allNonMajor',
+    'helpers:pinGitHubActionDigests',
   ],
```

**Wirkung:** Renovate-Runtime erkennt `pinDigests: true` für github-actions-Manager. Beim nächsten Run werden tag-refs (`@v6`) detektiert und Pin-Updates (updateType: `pin`) generiert.

### C-2: Initial-Pin gruppieren

**File:** `.github/renovate.json5`

**Diff (neue Rule, am Ende der `packageRules` Array, vor `vulnerabilityAlerts`):**
```diff
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
+    {
+      description: 'Initial SHA-pin: bundle all pin updates into one PR',
+      matchManagers: [
+        'github-actions',
+      ],
+      matchUpdateTypes: [
+        'pin',
+      ],
+      groupName: 'Pin all GitHub Actions to SHA',
+      automerge: false,
+      labels: [
+        'dependencies',
+        'security',
+      ],
+    },
   ],
```

**Wirkung:** statt ~25 individueller pin-PRs öffnet Renovate einen einzelnen mit `groupName: 'Pin all GitHub Actions to SHA'`. `automerge: false` weil Initial-Pin sicherheitsrelevant ist — Soenne reviewed die SHAs manuell.

### C-3: Ongoing automerge — kein Edit

Bestehende Rule:
```json5
{
  description: 'GitHub Actions — auto-merge minor+patch (gated by integration tests)',
  matchManagers: ['github-actions'],
  matchUpdateTypes: ['minor', 'patch'],
  automerge: true,
  automergeType: 'pr',
  groupName: 'GitHub Actions',
},
```

Nach SHA-Pinning werden Version-Bewegungen (z.B. v6.0.2 → v6.0.3) weiterhin als `minor`/`patch` updateType klassifiziert (Renovate prüft den Trailer-Comment `# v6.0.2` für Semver). SHA + comment werden zusammen aktualisiert. **Kein Edit nötig.**

`digest` updates (SHA-Bewegung ohne Tag-Bewegung, z.B. `dtolnay/rust-toolchain@master` wenn master-branch sich bewegt) fallen NICHT unter `minor`/`patch` — bleiben gated. Akzeptabel: Master-Branch-Bewegungen sollen sichtbar sein.

### C-4: CONTRIBUTING-Doc

**File:** `CONTRIBUTING.md` (existiert; falls nicht, neu anlegen — wird im Plan geprüft)

**Neue Section (am Ende, vor anderen "Tools"/"References" wenn vorhanden):**
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

## 5. Interface Contracts

**Renovate-Config:** kein Adopter-facing Contract. `.github/renovate.json5` ist catalog-intern.

**Workflow-Outputs / Inputs:** unverändert. Adopter konsumieren `@v4` floating tag — keine Sicht auf SHA-Pinning des Catalog-Inneren.

**Composite-Action-Inputs:** unverändert.

## 6. Test Strategy

Catalog-CI ist kein Sicherheitsnetz für diesen Edit — Logic-Test-Coverage ist NICHT betroffen, der Edit ändert nur Renovate-Verhalten.

| Validierungs-Stufe | Methode | Pass-Kriterium |
|---|---|---|
| **Statisch** | `npx --package renovate -- renovate-config-validator .github/renovate.json5` lokal | exit 0, "config is valid" |
| **Catalog-CI** | `validate.yml` (actionlint + yamllint + step-summary gate) auf PR | green, keine Regression |
| **Post-Merge Renovate-Run** | Manueller Trigger via `dependency-dashboard` issue ODER Wartezeit auf Monday 6am Berlin cron | Renovate öffnet eine grouped PR namens "Pin all GitHub Actions to SHA" |
| **Pin-PR Inhalt** | Manuelle Diff-Review | ~25 unique action refs in 28 Files auf SHA umgestellt, jedes mit `# v<ver>` Trailer |
| **Pin-PR Catalog-CI** | Integration-Tests grün auf Pin-PR | alle existing pull_request jobs green |
| **Steady-State** | Zweiter Renovate-Run nach Pin-PR-Merge | KEINE weiteren Pin-PRs (Renovate idempotent) |

## 7. PR Plan

**Eine PR.** Conventional-commit: `chore(renovate): enable SHA pinning for GitHub Actions`.

Files in der PR:
- `.github/renovate.json5` — preset-extend + neue packageRule
- `CONTRIBUTING.md` — Action-Pinning-Section

Lokal-only commits zu main vor PR (per `feedback_phase_workflow_pattern`-Konvention):
- `docs/superpowers/specs/2026-05-26-pin-actions-sha-design.md` — diese Spec
- `docs/superpowers/plans/2026-05-26-pin-actions-sha.md` — der Implementation-Plan

Branch: `feat/pin-actions-sha` in worktree `.worktrees/pin-actions-sha/`.

Kein Release. `chore:` commit löst keinen release-please Version-Bump aus.

## 8. Acceptance Criteria

- [ ] `.github/renovate.json5` enthält `helpers:pinGitHubActionDigests` in `extends`
- [ ] `.github/renovate.json5` enthält `packageRule` für `matchUpdateTypes: ['pin']` mit `groupName: 'Pin all GitHub Actions to SHA'` und `automerge: false`
- [ ] `CONTRIBUTING.md` enthält Action-Pinning-Section
- [ ] `renovate-config-validator` lokal exit 0
- [ ] PR-CI (actionlint + yamllint + step-summary-gate) green
- [ ] PR merged ohne Konflikte
- [ ] Erste Renovate-Run nach Merge erzeugt grouped Pin-PR mit allen 28 Files
- [ ] Pin-PR Format-spotcheck: `uses: <repo>@<40-hex-sha> # v<version>`
- [ ] Pin-PR Integration-Tests green
- [ ] Pin-PR manuell merged → zweiter Renovate-Run produziert NULL weitere Pin-PRs

## 9. Open Questions

Keine offen. Alle Designentscheidungen geklärt:
- Approach: Renovate-driven (kein manuelles Pre-Pinning)
- Automerge-Policy: minor/patch SHA-Bumps auto, major + digest gated
- Scope: github-actions only, keine Whitelist, keine Containerfile-Erweiterung
- Versionsbump: keiner (`chore` commit)
