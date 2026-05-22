# Phase 2c — Adopter-Template Cleanup (Design Spec)

**Datum:** 2026-05-22
**Quelle:** `REVIEW-2026-05-22.md` HIGH-8, MED-20, ADOPT-1, ADOPT-2
**Scope:** Statische Adopter-Template-`.yml`-Dateien löschen + dead JSON-Templates löschen + README Quick Start auf `onboard.yml` umstellen
**Konsumiert von:** Implementation Plan (writing-plans next)
**Vorgänger:** Phase 2a (gemerged als #90/#91/#92, Release 3.10.2)

---

## 1. Goal

Die statischen `docs/adopter-templates/{ci,release,prerelease,cleanup}.yml` Dateien sind aus der V1-Era (pinnen `@v1`). Die README schickt Adopter heute zu diesen Files. Sie sind funktional schwächer als das, was `onboard.yml` produziert (Skeletons enthalten lint+test composition, `SK_*` Override-Vars, App-Token-Catalog-Checkout — statische Templates haben nichts davon). Zwei parallele Onboarding-Pfade mit unterschiedlichem Output-Niveau erzeugen Confusion und Drift-Risiko.

Phase 2c eliminiert den schwächeren Pfad: statische Templates werden gelöscht, README pivotet auf `onboard.yml` als kanonischen Adopter-Einstieg. Skeletons unter `docs/adopter-templates/skeletons/` werden zur Single Source of Truth für „was wird gerendert" via Hyperlinks.

## 2. Scope

### In Scope

| Action | Files |
|---|---|
| Delete (4 V1-era static templates) | `docs/adopter-templates/ci.yml`<br>`docs/adopter-templates/release.yml`<br>`docs/adopter-templates/prerelease.yml`<br>`docs/adopter-templates/cleanup.yml` |
| Delete (2 dead sed-style configs, MED-20) | `docs/adopter-templates/release-please-config.json.tmpl`<br>`docs/adopter-templates/release-please-manifest.json.tmpl` |
| Rewrite | `README.md` "Quick start (adopters)" section (~ Zeilen 5-23) |

### Out of Scope

- `docs/adopter-templates/skeletons/` (live gomplate templates für onboard-render) — bleibt
- `docs/adopter-templates/configs/` (live JSON tmpls für release-please) — bleibt
- README ab Zeile 25 (atoms table, "What it does" section, contracts links) — bleibt
- Historische Plans/Specs unter `docs/superpowers/` die auf `docs/adopter-templates/` referenzieren — frozen documentation, bleibt
- `CONTRIBUTING.md`, `docs/operations.md`, `docs/contracts.md` — keine Änderung nötig (keine Refs auf die 6 zu löschenden Dateien gefunden)
- `scripts/onboard-render.sh:47-48` (`SKELETONS=$CATALOG/docs/adopter-templates/skeletons`, `CONFIGS=$CATALOG/docs/adopter-templates/configs`) — Pfade unverändert; keine Code-Refs auf die gelöschten Dateien

## 3. Background

### 3.1 Dual-Path-Problem (HIGH-8)

Heute gibt es zwei Adopter-Onboarding-Pfade:

**Path 1 — Static Templates:** README empfiehlt copy-paste der 4 statischen `.yml` Files. Diese pinnen `@v1`. Beispiel `ci.yml` enthält nur `trivy-fs` (kein lint, kein test). Beispiel `release.yml` callt `release.yml@v1` ohne `image_name`/`runs_on_*`-Overrides. Der Adopter bekommt einen minimalen, v1-era Setup.

**Path 2 — Onboarding-Workflow:** `onboard.yml` rendert via gomplate die Skeletons gegen die detected Profile-JSON eines Repos. Output enthält:
- Lint+Test-Atoms (lint-go/python/rust/helm + test-go/python/rust)
- `SK_*` Override-Vars (15+ per-repo configurable knobs)
- App-Token-basierter Cross-Repo Catalog-Checkout
- Release-eligibility per Dockerfile (multi-image support)

Der Funktionsgap zwischen Path-1- und Path-2-Output ist erheblich. Ein Adopter, der heute die README liest, landet auf Path 1 und bekommt einen objektiv schlechteren Setup. Die Maintenance-Last beider Pfade ist asymmetrisch: Skeletons werden aktiv weiterentwickelt (per-repo-override-vars, release-eligibility, etc.), statische Templates frozen seit Mai 2026.

### 3.2 Dead JSON-Templates (MED-20)

Top-Level `docs/adopter-templates/release-please-config.json.tmpl` und `…/release-please-manifest.json.tmpl` benutzen sed-style Placeholders (`{{RELEASE_TYPE}}`, `{{VERSION}}`). Das ist ein älterer Render-Mechanismus. Die aktiven, von `onboard-render.sh` benutzten Templates leben unter `docs/adopter-templates/configs/` und benutzen gomplate (`{{ $pin }}`, `{{ .profile.components }}`). Die top-level sed-Variants sind dead code: `rg 'docs/adopter-templates/release-please-' scripts/` zeigt nur die `configs/`-Variants.

## 4. Design

### 4.1 Löschen — 6 Files

```
docs/adopter-templates/
├── ci.yml                                    DELETE
├── release.yml                               DELETE
├── prerelease.yml                            DELETE
├── cleanup.yml                               DELETE
├── release-please-config.json.tmpl           DELETE (dead, MED-20)
├── release-please-manifest.json.tmpl         DELETE (dead, MED-20)
├── configs/                                  KEEP (live, used by onboard-render.sh)
│   ├── release-please-config.json.tmpl
│   ├── release-please-config.monorepo.json.tmpl
│   └── release-please-manifest.json.tmpl
└── skeletons/                                KEEP (live, used by onboard-render.sh)
    ├── ci.yml.tmpl
    ├── release.yml.tmpl
    ├── prerelease.yml.tmpl
    └── cleanup.yml.tmpl
```

Nach dem Delete enthält `docs/adopter-templates/` nur noch die beiden aktiven Subdirectories. Damit ist die Struktur selbsterklärend: was unter `adopter-templates/` lebt, ist Input für den Onboarding-Renderer.

### 4.2 README-Rewrite

**Vorher** (Zeilen 5-23):

```markdown
## Quick start (adopters)

**Prerequisites** (one-time per repo):

1. `release-please-config.json` in repo root (see [release-please docs](…) for `release-type` per language).
2. `.release-please-manifest.json` in repo root with initial version, e.g. `{ ".": "0.0.0" }`.
3. The `serverkraken-release-bot` GitHub App must be installed on the repo (org-wide install handles this automatically).

**Then** copy templates from [`docs/adopter-templates/`](docs/adopter-templates/) into `.github/workflows/` of your repo:

| Template          | Trigger              | Purpose                                              |
|-------------------|----------------------|------------------------------------------------------|
| `release.yml`     | push → main          | Full release pipeline …                              |
| `ci.yml`          | pull_request         | PR-time security scan (trivy-fs)                     |
| `prerelease.yml`  | workflow_dispatch    | Manual image build …                                 |
| `cleanup.yml`     | weekly cron          | GHCR retention                                       |

That's the complete onboarding. No per-repo secret setup …
```

**Nachher**:

```markdown
## Quick start (adopters)

**Prerequisite** (one-time per repo):

- The `serverkraken-release-bot` GitHub App must be installed on the repo
  (org-wide install handles this automatically). No per-repo secret setup —
  `secrets: inherit` reaches the org-level App secrets.

**Then** dispatch the onboarding workflow from this catalog repo's Actions tab:

1. Open [`onboard.yml`](.github/workflows/onboard.yml) in the catalog's
   Actions tab.
2. Click "Run workflow" and set `target_repos: owner/repo` (comma-separated
   for multiple). Leave other inputs at their defaults.
3. Onboarding produces two PRs in the target repo:
   **PR-A** adds the rendered workflows + `.github/onboard.lock.json` +
   release-please configs; **PR-B** removes any superseded legacy workflows.
4. Merge PR-A. Push a `feat:`/`fix:` commit. release-please opens a release
   PR. Merge it → image build + trivy scan + release run automatically.

See [`docs/operations.md`](docs/operations.md) §5 for the full onboarding
contract and operator-facing knobs.

### What gets rendered

The onboarding renders 4 workflows in `.github/workflows/` of the target
repo, pinned to `@v3` (the current catalog major). The skeleton sources are
the canonical reference for what each contains:

- [`ci.yml.tmpl`](docs/adopter-templates/skeletons/ci.yml.tmpl) — lint + test + trivy-fs (pull_request)
- [`release.yml.tmpl`](docs/adopter-templates/skeletons/release.yml.tmpl) — release-please → image build → trivy-image (push → main)
- [`prerelease.yml.tmpl`](docs/adopter-templates/skeletons/prerelease.yml.tmpl) — manual image build (workflow_dispatch)
- [`cleanup.yml.tmpl`](docs/adopter-templates/skeletons/cleanup.yml.tmpl) — GHCR retention (weekly cron)

All four expose `SK_*` repo/org variables for per-adopter overrides — see
the rendered files for the full list, or [`docs/contracts.md`](docs/contracts.md)
for the upstream workflow input schemas.

### Manual setup (advanced)

If the onboarding workflow doesn't fit (target repo outside the
serverkraken org, GitHub App not installed, etc.), compose the atoms
directly. See [`docs/contracts.md`](docs/contracts.md) for each workflow's
input/output/secret schema and the
[`docs/adopter-templates/skeletons/`](docs/adopter-templates/skeletons/)
directory for reference renders that you can adapt by hand.
```

Begründungen:
- **Prerequisite-Block** auf einen Punkt zusammengezogen: release-please-Configs gehören nicht mehr in den Pre-Req-Block, weil das Onboarding sie selbst generiert.
- **4-Schritt-Flow** zeigt den End-to-End-Pfad inklusive Verifikation (release PR merge → image build läuft).
- **"What gets rendered"** als Linkliste statt Tabelle: Skeletons sind Single Source of Truth, kein Drift möglich.
- **"Manual setup (advanced)"**: ehrliche Tür für Adopter, die den App-Token-Flow nicht haben. Verweist auf Contracts + Skeletons als Reference, kein dedizierter zweiter Maintenance-Pfad.

### 4.3 Was NICHT geändert wird

Der Rest der README (ab "What it does", Atoms-Tabelle, Composite Actions Tabelle, contracts.md-Link an der Stelle) bleibt unverändert. Phase 3 wird die übrigen Doku-Drift-Items adressieren (README-Coverage-Threshold 90% vs. 80%, Contracts-Link-Target, etc.).

## 5. Interface Contracts

Keine. Reine Documentation-Änderung, keine Workflow- oder Script-Schnittstellen tangiert.

Commit-Class: `refactor(docs)` — kein Patch-Bump-fähiger Wert. release-please bewertet `refactor:`-Commits standardmäßig als non-versioning per `.release-please-config.json` Konvention. Wenn ein Bump gewünscht ist, kann das im Plan auf `docs(adopters):` mit dem `changelog-sections`-Mapping geändert werden — aber für eine reine Cleanup-Aktion ohne Verhaltensänderung ist „no version bump" das richtige Signal.

## 6. Tests / Verification

- `actionlint`/`yamllint`: n/a (keine Workflow-Files)
- Nach dem Commit: `rg 'docs/adopter-templates/(ci|release|prerelease|cleanup)\.yml' .` liefert nur Treffer in `docs/superpowers/plans/*` und `REVIEW-2026-05-22.md` (frozen documentation). Kein Treffer in `README.md`, `CONTRIBUTING.md`, oder `scripts/`.
- README muss valid Markdown bleiben (visuell verifizieren — kein Linter im Repo).
- `scripts/onboard-render.sh` ist nicht betroffen (verwendet nur `skeletons/` und `configs/`).
- Bestehende `tests/shell/onboard-render.bats` Golden-Tests müssen weiter grün laufen (verifizieren keine Render-Output-Änderung).

## 7. PR Plan

**Single PR:**
- Branch: `refactor/remove-static-adopter-templates`
- Worktree: `.worktrees/remove-static-templates`
- Files: 4 deletions + 2 deletions + 1 README rewrite
- Commit: `refactor(docs): remove static adopter templates, pivot README to onboard.yml`
- PR-Body folgt Repo-Style (kein Claude-Attribution-Footer)

Reihenfolge: Sequenziell innerhalb des PR — Deletes zuerst, dann README. Single commit am Ende.

## 8. Acceptance Criteria

- [ ] PR merged: 6 Dateien gelöscht; README Quick Start pivotet auf onboard.yml.
- [ ] `rg 'docs/adopter-templates/(ci|release|prerelease|cleanup)\.yml' README.md CONTRIBUTING.md scripts/` empty.
- [ ] README rendert valid Markdown (Github-Preview ok).
- [ ] `tests/shell/onboard-render.bats` weiterhin grün (no render-output regression).
- [ ] Commit-Message Conventional: `refactor(docs):` Prefix, kein Claude-Footer.

## 9. Open Questions

Keine. Decisions aus Brainstorming fixiert:

1. ✓ Option A gewählt: löschen + onboard.yml-pivot, kein zweites Template-System aufrechterhalten.
2. ✓ "What gets rendered" als Skeleton-Linkliste (Single Source of Truth, kein Drift).
3. ✓ "Manual setup (advanced)" als ehrliche Tür für Non-App-Adopter, aber ohne dedizierte Maintenance-Last.
4. ✓ Scope eng — kein Toucheing der anderen Doku-Drift-Items (Phase 3).
