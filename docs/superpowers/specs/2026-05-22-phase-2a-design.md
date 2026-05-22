# Phase 2a — Quick-Win Hardening (Design Spec)

**Datum:** 2026-05-22
**Quelle:** `REVIEW-2026-05-22.md` § N Phase 2 (Teilmenge)
**Scope:** HIGH-1, INK-2, MED-25, HIGH-2, MED-2, MED-3, HIGH-5
**Konsumiert von:** Implementation Plan (writing-plans next)
**Vorgänger:** `2026-05-22-phase-1-critical-fixes-design.md` (gemerged als PR #86/#87/#88, release 3.10.1)

---

## 1. Goal

Drei mechanische Quick-Win-PRs schließen, die alle direkten Adopter-Pain bedeuten:

- **Cross-Repo-Adopter** von `docker-build@v3`, `trivy-image@v3`, `trivy-fs@v3` bekommen heute v2-Composite-Actions eingecheckt (HIGH-1).
- **Cross-Repo-Adopter** von `release.yml@v3` schlagen am Permission-Ceiling fehl (HIGH-2). Multi-Image- und Custom-Runner-Adopter sind blockiert (MED-2/3).
- **Onboard-Operator** ohne explizites `pin_version` produziert v1-Templates (HIGH-5).

Alle Änderungen sind non-breaking auf Caller-Seite (additive Inputs, Major-Version-Bump im Default, Default-Wert-Änderung mit kompatiblem neuem Wert).

## 2. Scope

### In Scope

| Concern | Findings | Outcome |
|---|---|---|
| **A. Cross-Repo Catalog-Ref Bump** | HIGH-1, INK-2, MED-25 | Alle 6 verbliebenen `ref=v2` in `docker-build.yml` (4×), `trivy-image.yml`, `trivy-fs.yml` auf `v3` gehoben. Kommentare „floating v2" → „floating v3". Anti-Drift-Marker für künftige Major-Bumps. |
| **B. `release.yml` Cross-Repo-Tauglichkeit** | HIGH-2, MED-2, MED-3 | Top-level `permissions:`-Block als UNION der nested Calls. Neue optionale Inputs `runs_on_amd64`/`_arm64`/`_merge` und `image_name`, an `docker-build.yml` durchgereicht. |
| **C. `onboard.yml` pin_version Default** | HIGH-5 | Default in `workflow_dispatch` und `workflow_call` von `v1` → `v3`. Kommentar „update beim nächsten Major". |

### Out of Scope (eigenes Phase-2b/c Spec)

- HIGH-6 onboard.yml Failure-Caller
- HIGH-7 semantic-release.yml Tests
- HIGH-8 statische Adopter-Templates (Decision-heavy)

### Auch out of Scope

- Cosmetic/Doc-Drift-Items (MED-16, MED-17, etc.) — Phase 3
- Performance-Items (PERF-1 Timeouts, etc.) — Phase 5

## 3. Background

### 3.1 HIGH-1 — Cross-Repo-Ref-Mechanik

`docker-build.yml`, `trivy-image.yml`, `trivy-fs.yml` minten zur Laufzeit einen Catalog-Checkout, um auf `actions/install-trivy`, `actions/ghcr-login`, `actions/compute-prerelease-tag` zugreifen zu können. Der Ref dafür ist hardcoded — heute `v2`, soll `v3` sein. `lint-python.yml` und `test-python.yml` haben den korrekten `v3`-Wert (in Phase 1 nicht verändert, war schon korrekt). Sechs Stellen sind stale:

- `docker-build.yml:124, 220, 308, 455`
- `trivy-image.yml:89`
- `trivy-fs.yml:102`

Plus Kommentar-Drift („# Cross-repo: catalog ref = v2 (floating)" → v3).

### 3.2 HIGH-2 — Permission-Ceiling für Cross-Repo

`release.yml` callt `semantic-release.yml`, `docker-build.yml`, `trivy-image.yml`. Same-repo-Calls ignorieren das Permission-Ceiling. Bei Cross-Repo-Aufruf (`uses: serverkraken/reusable-workflows/.github/workflows/release.yml@v3`) erbt der Caller GitHub-Defaults (`contents:read`, `metadata:read`); die nested Calls scheitern am Strict-Intersection-Check.

Union der nested Permissions:
- `semantic-release.yml`: `contents:write`, `pull-requests:write`, `issues:write`
- `docker-build.yml`: `contents:read`, `packages:write`, `id-token:write`, `attestations:write`, `artifact-metadata:write`, `pull-requests:write`
- `trivy-image.yml`: `contents:read`, `security-events:write`, `packages:read`, `actions:read`

= `contents:write`, `packages:write`, `id-token:write`, `attestations:write`, `artifact-metadata:write`, `pull-requests:write`, `issues:write`, `security-events:write`, `actions:read`

### 3.3 MED-2 / MED-3 — Passthrough-Inputs

`release.yml` callt `docker-build.yml`, das `runs_on_amd64`/`runs_on_arm64`/`runs_on_merge` und `image_name` als Inputs deklariert. `release.yml` reicht keinen dieser Inputs durch. Adopter ohne den Standard-self-hosted-Pool oder Multi-Image-Repos sind gezwungen, `release.yml` zu umgehen und Atoms direkt zu verdrahten.

### 3.4 HIGH-5 — pin_version Default

`onboard.yml:28` (dispatch) und `:55` (workflow_call) defaulten beide auf `v1`. Der Katalog ist auf v3 (post-3.10.1). Alle bisherigen produktiven Dispatches (onboarding-status.md zeigt 4 Adopter) haben `pin_version: v3` explizit gesetzt. Ein versehentlicher Dispatch ohne Override produziert Templates ohne App-Token-Catalog-Checkout (v2+), ohne `artifact-metadata: write` (v2.0.4+), ohne `SK_*`-Override-Vars (v3.9.0+).

## 4. Design per Concern

### 4.1 Concern A — Cross-Repo Catalog-Ref Bump

**Mechanische Änderung:** `echo "ref=v2"` → `echo "ref=v3"` an 6 Stellen + Kommentare.

**Anti-Drift-Marker:** Renovate kann auf Bash-`echo`-Lines nicht direkt regex'en. Pragmatische Lösung: ein einheitlicher Kommentar-Marker im Repo direkt über jeder `ref=`-Zeile, der die Major-Major-Versions-Synchronisation explizit macht:

```bash
# When the catalog rolls to a new major, also update the lint-python.yml and test-python.yml refs.
# renovate-marker: catalog-major-ref
echo "ref=v3" >> "$GITHUB_OUTPUT"
```

Renovate wird das nicht automatisch bumpen, aber ein zentraler grep-bare Marker macht den nächsten Major-Bump in 5 Sekunden auffindbar (statt 7 verstreuten Vorkommen).

**Tests:** Keine neuen. Bestehende Integration-Tests `test-docker-build`, `test-trivy-image-*`, `test-trivy-fs-*` müssen weiterhin grün laufen. Sie machen heute denselben Catalog-Checkout — wenn der `v3`-Ref tatsächlich verfügbar ist (was er ist, da Phase 1 v3.10.1 zur v3-Linie zählt), bricht nichts.

**Risiko:** Niedrig. Der Cross-Repo-Adopter-Pfad ist nicht durch Integration-Tests abgedeckt (die laufen alle same-repo, da fallen sie auf die `same-repo`-Branch des `if`-Blocks). Die Integration-Test-Coverage bleibt also unverändert; der eigentliche Cross-Repo-Pfad ist Smoke-getestet durch Adopter-Repos in der Org.

### 4.2 Concern B — `release.yml` Cross-Repo-Tauglichkeit

#### B.1 Top-Level `permissions:`-Block

Direkt vor `concurrency:` einfügen:

```yaml
permissions:
  contents: write
  packages: write
  id-token: write
  attestations: write
  artifact-metadata: write
  pull-requests: write
  issues: write
  security-events: write
  actions: read
```

UNION aller nested Calls (siehe §3.2). Same-repo-Caller verlieren nichts; Cross-Repo-Caller können jetzt die nested Atoms ceiling-konform aufrufen.

#### B.2 Neue Inputs

In den `inputs:`-Block einfügen (nach den existierenden, vor `secrets:`):

```yaml
      image_name:
        description: 'Image name. Default: caller repo (owner/repo). Passed through to docker-build.yml.'
        required: false
        type: string
        default: ''
      runs_on_amd64:
        required: false
        type: string
        default: '["self-hosted","Linux","X64","performance"]'
      runs_on_arm64:
        required: false
        type: string
        default: '["self-hosted","Linux","ARM64"]'
      runs_on_merge:
        required: false
        type: string
        default: '["self-hosted","Linux","low-performance"]'
```

Defaults sind 1:1 identisch zu `docker-build.yml` (Konsistenz-Anforderung — Adopter, die `release.yml` benutzen, bekommen exakt die gleichen Defaults wie wenn sie `docker-build.yml` direkt aufrufen).

#### B.3 Passthrough an `docker-build` Job

Im bestehenden `docker-build`-Job (Zeilen 62-75) den `with:`-Block erweitern:

```yaml
  docker-build:
    needs: semantic-release
    if: needs.semantic-release.outputs.release_created == 'true' && inputs.build_image
    uses: ./.github/workflows/docker-build.yml
    secrets: inherit
    with:
      tag: ${{ needs.semantic-release.outputs.tag_name }}
      prerelease: false
      image_name: ${{ inputs.image_name }}
      dockerfile: ${{ inputs.dockerfile }}
      context: ${{ inputs.context }}
      platforms: ${{ inputs.platforms }}
      sign: ${{ inputs.sign }}
      attest: ${{ inputs.attest }}
      sbom: ${{ inputs.sbom }}
      runs_on_amd64: ${{ inputs.runs_on_amd64 }}
      runs_on_arm64: ${{ inputs.runs_on_arm64 }}
      runs_on_merge: ${{ inputs.runs_on_merge }}
```

#### B.4 Tests

Existierende Caller-Tests für `release.yml` gibt es nicht (release ist nicht in `integration.yml` referenziert — würde HIGH-7 in Phase 2b adressieren). Pragmatisch für 2a: nur `actionlint`/`yamllint` müssen grün bleiben. Schema-Korrektheit wird durch CI implizit geprüft.

Optional: ein neuer happy-path Caller-Test, der `release.yml` mit dry-run-Mode aufruft. Aber das öffnet die Frage der semantic-release-Mock-Strategie (Teil von HIGH-7) und überdehnt 2a. **Entscheidung: keine neuen Tests in 2a.**

#### B.5 Risiken

- Permission-Block ist additiv — bestehende Same-Repo-Adopter sehen keinen Unterschied.
- Neue Inputs sind alle `required: false` mit defaults — keine bestehende Adopter-Caller-Datei muss angefasst werden.
- Bei einem hypothetischen Adopter, der `release.yml` heute über Cross-Repo callt und am Permission-Ceiling silent failt, wird nach diesem Fix der Job versuchen, mit den vollen Permissions zu laufen. Wenn der Adopter explizit weniger erlaubt hat (`permissions: contents:read`), kommt die Permission-Ceiling jetzt vom Adopter-Caller-Workflow, nicht von `release.yml`. Erwartetes Verhalten.

### 4.3 Concern C — `onboard.yml` pin_version Default

**Trivialer Edit:**

```yaml
# .github/workflows/onboard.yml:28 (workflow_dispatch.inputs.pin_version)
# Vorher:
        default: v1
# Nachher (und gleicher Edit an Zeile 55 für workflow_call.inputs.pin_version):
        default: v3
```

Zusätzlich ein Kommentar oberhalb der Input-Definition (einmal, am Ersten der beiden Stellen):

```yaml
      # pin_version: catalog @version that rendered templates pin to.
      # NOTE: When a new catalog major releases, bump this default and the
      # one in the workflow_call inputs below.
      pin_version:
        description: 'Catalog @version that rendered templates pin to'
        required: false
        type: string
        default: v3
```

**Tests:** Keine. Existierende `test-onboard-dry-run` Integration-Test ruft `onboard.yml` mit `pin_version: v3` explizit — die Default-Änderung tangiert den Test-Pfad nicht. Manuelle Verifikation: einen Adopter dispatchen ohne `pin_version` override und Output-Templates inspizieren. **In 2a nur dispatch-Smoke; volle Verifikation in 2b/3.**

**Risiko:** Niedrig. Wer `pin_version` heute weglässt, bekommt v1 — wer das ändert, bekommt v3. Es gibt keinen Caller, der von „Default ist immer v1" semantisch abhängig ist (alle 4 produktiven Adopter setzen es explizit).

## 5. Interface Contracts

| File | Change-Class | Caller-Breaking? |
|---|---|---|
| `docker-build.yml` | Internes Verhalten (Cross-Repo-Catalog-Ref) | NEIN — Schema unverändert |
| `trivy-image.yml` | Internes Verhalten | NEIN |
| `trivy-fs.yml` | Internes Verhalten | NEIN |
| `release.yml` | Additive Inputs (`image_name`, `runs_on_*`) + neues `permissions:` | NEIN — additive, Defaults sind backward-kompatibel |
| `onboard.yml` | Default-Wert von `pin_version` | Operationell: Operatoren ohne Override bekommen anderes Verhalten. Konsumenten (via `workflow_call`) sind unbeeinflusst, weil alle bekannten Caller den Wert explizit setzen. |

Drei Patch-Bumps via release-please:
- `fix(docker-build,trivy): bump cross-repo catalog ref to v3` (1 commit, 3 files)
- `fix(release): add cross-repo-ready permissions and passthrough inputs` (1 commit, 1 file)
- `fix(onboard): default pin_version to v3 (current major)` (1 commit, 1 file)

## 6. Test Strategy

| Test | Existiert | Behavior |
|---|---|---|
| `test-docker-build` (integration.yml) | ✓ | Same-repo path nicht betroffen vom v2→v3 ref bump; grün bleiben |
| `test-trivy-image-*` (integration.yml) | ✓ | Same-repo path; grün bleiben |
| `test-trivy-fs-*` (integration.yml) | ✓ | Same-repo path; grün bleiben |
| `test-onboard-dry-run` (integration.yml) | ✓ | Wird mit explizitem `pin_version: v3` aufgerufen; grün bleiben |
| `actionlint`/`yamllint` (validate.yml) | ✓ | Müssen alle 3 PR-Changes akzeptieren |
| Neue Caller für `release.yml` | ✗ | Nicht in 2a — Phase 2b (HIGH-7) |

Lokale Verifikation in jedem Worktree: `actionlint .github/workflows/*.yml` und `yamllint .github/workflows/*.yml`.

## 7. PR Plan

Drei Worktrees, parallel branchbar von `origin/main`:

### PR-D: `fix/cross-repo-catalog-ref-v3`
- **Worktree:** `.worktrees/catalog-ref-v3`
- **Files:** `docker-build.yml`, `trivy-image.yml`, `trivy-fs.yml`
- **Commit:** `fix(docker-build,trivy): bump cross-repo catalog ref to v3`

### PR-E: `fix/release-permissions-and-passthrough`
- **Worktree:** `.worktrees/release-yml-passthrough`
- **Files:** `release.yml`
- **Commit:** `fix(release): add cross-repo-ready permissions and passthrough inputs`

### PR-F: `fix/onboard-pin-version-v3-default`
- **Worktree:** `.worktrees/onboard-pin-v3`
- **Files:** `onboard.yml`
- **Commit:** `fix(onboard): default pin_version to v3 (current major)`

Reihenfolge: parallel oder beliebig. Keine Inter-PR-Abhängigkeit. PR-Body-Style: kein Claude-Attribution-Footer (Memory: `feedback_pr_style`).

## 8. Acceptance Criteria

- [ ] PR-D merged: alle Cross-Repo-Catalog-Checkouts in den 3 Workflows pinnen auf `v3`. `rg 'echo "ref=v[0-9]"' .github/workflows/` zeigt nur `v3`.
- [ ] PR-E merged: `release.yml` hat top-level `permissions:`-Block; `image_name`+`runs_on_*` als optionale Inputs; alle vier an `docker-build`-Job durchgereicht.
- [ ] PR-F merged: `onboard.yml` `pin_version` default ist `v3` an beiden Stellen.
- [ ] `actionlint` und `yamllint` clean auf allen geänderten Files.
- [ ] CI Integration-Tests `test-docker-build`, `test-trivy-*`, `test-onboard-dry-run` grün auf jeder Branch.
- [ ] Drei Conventional-Commits → drei Patch-Bumps im nächsten release-please-PR (3.10.2 bei sequenziellem Merge oder zusammen in einem Release).

## 9. Open Questions

Keine. Alle Entscheidungspunkte aus dem Brainstorming sind fixiert:

1. ✓ Phase 2 in 2a (jetzt) + 2b/c (später) gesplittet
2. ✓ `release.yml` Input-Naming spiegelt `docker-build.yml` 1:1
3. ✓ `pin_version` Default hardcoded `v3` + Kommentar; kein dynamischer „latest stable"
4. ✓ Renovate-Annotation: ein einheitlicher `# renovate-marker:`-Kommentar pro Ref-Zeile als grep-bare Anchor (Renovate ignoriert ihn, aber Humans finden ihn beim nächsten Bump)
5. ✓ Keine neuen Tests in 2a — Test-Coverage-Erweiterung gehört in 2b
