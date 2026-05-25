# Cosign-based SLSA Provenance — Free-tier-friendly Attest Swap (Design Spec)

**Datum:** 2026-05-25
**Quelle:** Soenne — `actions/attest-build-provenance@v4` (heutiger Default in `release.yml` und `docker-build.yml`) erfordert für Private-Repos eine bezahlte GitHub-Plan-Stufe (Team/Enterprise). Free-Private-Repos brechen mit aktivem Default. Constraint memorialized in `project_free_tier_constraint.md`.
**Scope:** Replace `actions/attest-build-provenance@v4` mit `cosign attest --type slsaprovenance`. Identischer Input-Contract, neue Implementation. Permissions-Cleanup. Integration-Test-Erweiterung. **v4-Major-Release.**
**Konsumiert von:** Implementation Plan (writing-plans als Nachfolger).
**Vorgänger:** v3.x Stand mit `attest-build-provenance@v4`. Cosign-Sign-Pfad (`sign: true`) ist seit der ARC-Runner-Image-Cutover (memory: `project_custom_runner_image_todo`) etabliert — derselbe Trust-Root wird hier wiederverwendet.

---

## 1. Goal

Free-tier-private-Adopter können `attest: true` (Default) verwenden, ohne dass GitHub das Plan-Upgrade verlangt. Authenticity- und Provenance-Garantien bleiben sigstore-basiert auf demselben Niveau wie der bestehende `cosign sign`-Pfad.

| Heute | Mit dem Spec |
|---|---|
| `attest: true` (Default) callt `actions/attest-build-provenance@v4` → schreibt in GitHub-Artifact-Attestations-API → **fails auf Free-Private** | `attest: true` (Default) callt `cosign attest --type slsaprovenance` → hängt SLSA-v1.0-Predicate als OCI-Sidecar an `<image>@<digest>` → **funktioniert auf jedem Plan** |
| Verifikation via `gh attestation verify` | Verifikation via `cosign verify-attestation --type slsaprovenance` |
| Sichtbar im Repo-Tab "Attestations" (nur Team/Enterprise) | Sichtbar via `cosign tree` / OCI-Sidecar in GHCR |
| Permissions: `attestations: write` + `artifact-metadata: write` zusätzlich zu `packages: write` + `id-token: write` | Permissions: nur `packages: write` + `id-token: write` |

**Nicht Goal:**
- Provider-Toggle (`attest_provider: cosign|github` Input). YAGNI — keine bekannten Paid-Tier-Adopter im serverkraken-Setup; ein späteres Hinzufügen wäre non-breaking.
- Migration zu `slsa-framework/slsa-github-generator`. Eigene Reusable-Workflow-Kaskade, mehr Permissions, mehr Komplexität, kein klarer Mehrwert über `cosign attest --type slsaprovenance` für unseren Maßstab.
- Verifikations-Atom für Consumer-Seite. Separater Spec-Kandidat (Tier C in der Phase-8-Liste). Hier nur die Produzenten-Seite.
- Re-attestation alter Images. Nur neue Builds ab v4 bekommen das neue Format.

## 2. Scope

### In Scope

| Concern | Outcome |
|---|---|
| **C-1** Attest-Step ersetzen | `docker-build.yml:396-402` — `actions/attest-build-provenance@v4`-Step weicht `cosign attest`-Step mit inline-generiertem SLSA-v1.0-Predicate |
| **C-2** Permissions-Cleanup | Entferne `attestations: write` + `artifact-metadata: write` aus `release.yml`, `docker-build.yml`, `docker-build-multi.yml`, `integration.yml` top-level `permissions:` Blöcken |
| **C-3** Integration-Test Verifikation | Neuer Job `assert-attestation-verifies` in `integration.yml` — installiert Cosign, ruft `cosign verify-attestation --type slsaprovenance` gegen `test-docker-build`-Output |
| **C-4** File-Header-Docstrings | Update Doc-Comments in `docker-build.yml`, `release.yml` damit sie cosign-based statt API-based attest beschreiben |
| **C-5** v4-Major-Release | Conventional-Commit-Marker `feat!:` triggert release-please Major-Bump |
| **C-6** Memory-Update | `troubleshooting_artifact_metadata_caller_cascade.md` als obsolet markieren — Permission wird in v4 nicht mehr gebraucht |

### Out of Scope

- `attest_provider`-Input (Provider-Toggle) — siehe Section 1 "Nicht Goal"
- Verifikations-Atom für Adopter-Side-Verify-Pipeline
- Anpassung der bypass-callers (`actions-runner-image`) — deren ungenutzte Permission-Declarations sind harmlos
- Floating-Tag-Update-Policy ändern — v3 bleibt frozen, v4 wird neue Floating-Major

## 3. Background

### 3.1 Warum `attest-build-provenance` für Free-Private bricht

`actions/attest-build-provenance@v4` schreibt in die **GitHub Artifact-Attestations-API**. Diese API gehört zur Code-Security-Suite; für Private-Repos verlangt sie GitHub Team oder Enterprise. Free-Private-Repos bekommen 403 auf den API-Call und der Step bricht den Job ab. Public-Repos (Catalog selbst ist `PUBLIC`, verifiziert via `gh repo view`) sind nicht betroffen — daher merkt die catalog-eigene Integration-Test-Suite das Problem heute nicht.

### 3.2 Warum Cosign der natürliche Swap ist

Cosign ist bereits voll integriert für den `sign: true`-Pfad (`docker-build.yml:385-394`):

```yaml
- name: Install Cosign
  if: inputs.sign
  uses: sigstore/cosign-installer@v4.1.2

- name: Sign image
  if: inputs.sign
  env:
    IMG: ghcr.io/${{ needs.version.outputs.image_name }}
    DIGEST: ${{ steps.merge_step.outputs.digest }}
  run: cosign sign --yes "$IMG@$DIGEST"
```

- **Trust-Root identisch:** Keyless via GitHub-OIDC → Sigstore Fulcio (CA) → Rekor (Transparency-Log). Derselbe Mechanismus, der `sign: true` heute trägt, signiert auch die Attestation. Keine zusätzliche Key-Verwaltung.
- **Storage identisch:** Sidecar-Artifacts werden im OCI-Registry am Image-Digest abgelegt (`sha256-<digest>.sig` für Signatures, `sha256-<digest>.att` für Attestations — Cosign-Konvention). GHCR speichert das nativ; Storage zählt zur GHCR-Quota.
- **Permissions identisch:** `packages: write` (Push der Sidecars) + `id-token: write` (OIDC) — beides ist für `sign: true` bereits erforderlich. Kein neues Permission-Bit.
- **Verifikation identisch zum Sign-Pfad:** `cosign verify` (für Sign) und `cosign verify-attestation` (für Attest) teilen dieselbe Cert-Chain-Validation; ein Adopter der `cosign verify` heute kann, kann morgen auch `verify-attestation`.

### 3.3 SLSA-Provenance-Format

`cosign attest --type slsaprovenance` erwartet ein In-Toto-Predicate, das dem **SLSA Provenance v1.0**-Schema entspricht. Felder:

- `buildType` — Identifiziert den Build-Prozess (wir setzen `https://github.com/actions/runner/buildTypes/workflow/v1`)
- `builder.id` — Welche Workflow-Definition den Build ausführte (`https://github.com/<org>/<repo>/.github/workflows/<workflow>@<ref>`)
- `invocation.configSource` — Git-Source des Workflows (URI + Commit-SHA)
- `invocation.parameters` / `environment` — Eingaben (leer halten, da inputs bereits via `materials` referenziert werden; vermeidet Leak)
- `metadata.buildInvocationId` — `<repo>/actions/runs/<run_id>` für Backlink
- `metadata.buildStartedOn` — RFC3339-Zeitstempel
- `metadata.completeness` — Wir setzen `parameters: true` (Workflow-Inputs sind im Predicate-Builder dokumentiert), `environment: false`, `materials: false`
- `materials[]` — Git-Source des Builds (URI + Commit-SHA, derselbe wie `configSource` für single-repo-Builds)

Das Format ist kompatibel mit:
- `cosign verify-attestation --type slsaprovenance`
- `slsa-verifier` (SLSA-Framework-Tool, optional auf Consumer-Seite)
- jedem In-Toto-aware Tool (Kyverno, OPA-Gatekeeper, etc.)

### 3.4 Warum keine Provider-Toggle

Drei Argumente gegen ein `attest_provider`-Input:
1. **Keine bekannten Paid-Tier-Adopter** in der serverkraken-Org — alle Adopter laufen auf Free-Plans. Toggle wäre Code für eine Anwendergruppe von Null.
2. **YAGNI auf v4-Major-Bump** — der ganze Sinn eines Major-Bumps ist Contract-Vereinfachung. Eine neue Input-Achse direkt im Major-Cut hinzufügen verschlechtert das.
3. **Nicht-breaking nachreichbar** — falls später jemand `gh attestation verify`-Kompatibilität braucht, kann der Toggle in v4.1 als optionaler Input mit Default `cosign` eingeführt werden, ohne v3-Adopter zu betreffen.

### 3.5 v4 als sauberer Reset

v3 bleibt nutzbar für Adopter, die aus irgendeinem Grund am API-basierten Attestation-Pfad hängen (z. B. weil sie Provenance über das Repo-UI sehen wollen und auf Team/Enterprise sind). v3-Floating-Tag wird **nicht** weiter gepflegt nach v4-Release — das ist Standard-Praxis (vgl. Memory `reference_review_2026_05_22_roadmap` mit den Phase-1-bis-6-Releases auf v3).

## 4. Design per Concern

### 4.1 C-1 — Attest-Step ersetzen

**File:** `.github/workflows/docker-build.yml`
**Lines:** 396-402 ersetzt durch:

```yaml
- name: Attest build provenance (cosign SLSA v1.0)
  if: inputs.attest
  env:
    IMG: ghcr.io/${{ needs.version.outputs.image_name }}
    DIGEST: ${{ steps.merge_step.outputs.digest }}
    REPO: ${{ github.repository }}
    REF: ${{ github.ref }}
    SHA: ${{ github.sha }}
    RUN_ID: ${{ github.run_id }}
    WORKFLOW: ${{ github.workflow }}
  run: |
    set -euo pipefail
    BUILD_STARTED="$(date -u -Iseconds)"
    cat > predicate.json <<EOF
    {
      "buildType": "https://github.com/actions/runner/buildTypes/workflow/v1",
      "builder": {
        "id": "https://github.com/${REPO}/.github/workflows/${WORKFLOW}@${REF}"
      },
      "invocation": {
        "configSource": {
          "uri": "git+https://github.com/${REPO}@${REF}",
          "digest": {"sha1": "${SHA}"},
          "entryPoint": "${WORKFLOW}"
        },
        "parameters": {},
        "environment": {}
      },
      "metadata": {
        "buildInvocationId": "${REPO}/actions/runs/${RUN_ID}",
        "buildStartedOn": "${BUILD_STARTED}",
        "completeness": {"parameters": true, "environment": false, "materials": false},
        "reproducible": false
      },
      "materials": [
        {
          "uri": "git+https://github.com/${REPO}@${REF}",
          "digest": {"sha1": "${SHA}"}
        }
      ]
    }
    EOF
    cosign attest --yes --type slsaprovenance \
      --predicate predicate.json "${IMG}@${DIGEST}"
```

**Voraussetzungen:**
- Cosign-Installer-Step (`docker-build.yml:385-387`) muss **vor** dem Attest-Step ausgeführt werden. Heute hängt der Installer am `if: inputs.sign`-Conditional. → Conditional auf `if: inputs.sign || inputs.attest` erweitern, sonst fehlt der Cosign-Binary wenn nur `attest: true` ohne `sign: true` gesetzt ist.

```diff
- - name: Install Cosign
-   if: inputs.sign
-   uses: sigstore/cosign-installer@v4.1.2
+ - name: Install Cosign
+   if: inputs.sign || inputs.attest
+   uses: sigstore/cosign-installer@v4.1.2
```

### 4.2 C-2 — Permissions-Cleanup

**Files:** vier Workflows mit unnötigen Permission-Declarations.

```diff
# .github/workflows/docker-build.yml
 permissions:
   contents: read
   packages: write
   id-token: write
-  attestations: write
-  # actions/attest-build-provenance@v4 additionally writes to GitHub's new
-  # Artifact Metadata storage API. Without this, the attestation itself
-  # still succeeds but a noisy warning is emitted on every release.
-  artifact-metadata: write
   pull-requests: write
```

```diff
# .github/workflows/docker-build-multi.yml
 permissions:
   contents: read
   packages: write
   id-token: write
-  attestations: write
-  # nested docker-build's permission ceiling — declare here so the nested
-  # attest-build-provenance step doesn't get capped down.
-  artifact-metadata: write
```

```diff
# .github/workflows/release.yml
 permissions:
-  # UNION of nested calls: semantic-release (contents/pull-requests/issues:write),
-  # docker-build (packages/id-token/attestations/artifact-metadata:write +
-  # pull-requests:write), trivy-image (security-events:write, packages:read, actions:read).
+  # UNION of nested calls: semantic-release (contents/pull-requests/issues:write),
+  # docker-build (packages/id-token:write + pull-requests:write),
+  # trivy-image (security-events:write, packages:read, actions:read).
   contents: write
   packages: write
   id-token: write
-  attestations: write
-  artifact-metadata: write
   pull-requests: write
   issues: write
   security-events: write
   actions: read
```

```diff
# .github/workflows/integration.yml
 permissions:
   contents: write
   packages: write
   id-token: write
-  attestations: write
-  artifact-metadata: write
   security-events: write
   pull-requests: write
   issues: write
   actions: read
```

Comment am Top von `integration.yml` (lines 9-15) wird aktualisiert: kein Bezug mehr auf `attest-build-provenance@v4`'s Metadata-Persistence-Path.

### 4.3 C-3 — Integration-Test Verifikation

**File:** `.github/workflows/integration.yml`
**Position:** Direkt nach dem bestehenden `test-docker-build`-Job (etwa nach Zeile 50).

```yaml
  # ----- attestation verification (proves the cosign attest step produced
  # a sigstore-bundled SLSA predicate at the OCI sidecar location) -----
  assert-attestation-verifies:
    needs: test-docker-build
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      packages: read
    steps:
      - name: Install Cosign
        uses: sigstore/cosign-installer@v4.1.2
      - name: GHCR login (read-only)
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | \
            cosign login ghcr.io -u "${{ github.actor }}" --password-stdin
      - name: Verify cosign SLSA attestation
        env:
          IMG_REF: ${{ needs.test-docker-build.outputs.image_ref }}
        run: |
          set -euo pipefail
          # OIDC identity: this workflow run on the catalog repo.
          # The certificate-identity-regexp must match the URL that the docker-build
          # workflow's runtime OIDC token put in the cert's SAN — which is the
          # docker-build.yml workflow path (NOT integration.yml), since that's the
          # workflow that actually invoked cosign attest.
          cosign verify-attestation \
            --type slsaprovenance \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com \
            --certificate-identity-regexp '^https://github\.com/serverkraken/reusable-workflows/\.github/workflows/docker-build\.yml@' \
            "$IMG_REF" > /tmp/att.json
          # Sanity-check the decoded predicate has expected fields
          jq -e '.payload' /tmp/att.json > /dev/null
          echo "✓ Cosign SLSA attestation verifies for $IMG_REF"
```

Test-Pfade in `integration.yml`:
- **Happy:** `test-docker-build` (attest: true) → `assert-attestation-verifies` ✓
- **Negativ:** `test-docker-build-cve` (attest: false) → kein Verify-Job — verify-Aufruf gegen non-attestiertes Image würde fail, was Intent ist (wir testen, dass `attest: false` keine Attestation produziert nicht durch positive verify, sondern dadurch dass der Verify-Job einfach nicht läuft).

### 4.4 C-4 — File-Header-Docstrings

**File:** `.github/workflows/docker-build.yml`
**Position:** Top-Comment-Block

```diff
 # Reusable workflow: build a multi-arch image distributed across native
 # amd64/arm64 self-hosted runners, push by digest, stitch a manifest list,
-# optionally cosign-sign, optionally attest build provenance via the
-# GitHub Artifact Attestations API, optionally generate an SBOM artifact.
+# optionally cosign-sign, optionally attest build provenance as a
+# cosign-attached SLSA v1.0 in-toto predicate (free-tier-compatible:
+# stored as OCI sidecar at <image>@<digest>, verified with
+# `cosign verify-attestation --type slsaprovenance`),
+# optionally generate an SBOM artifact.
```

**File:** `.github/workflows/release.yml`
**Position:** input description für `attest:`

```diff
       attest:
-        description: 'Generate SLSA build provenance attestation for the image.'
+        description: 'Generate SLSA v1.0 build provenance attestation for the image. Uses cosign keyless signing (free-tier compatible). Verify with `cosign verify-attestation --type slsaprovenance`.'
         required: false
         type: boolean
         default: true
```

**File:** `.github/workflows/docker-build.yml`
**Position:** input description für `attest:`

Spiegelung der release.yml-Beschreibung.

### 4.5 C-5 — v4-Major-Release

Conventional-Commit-Trigger:

```
feat!: switch to cosign-based SLSA provenance (free-tier compatible)

BREAKING CHANGE: `attest: true` now produces a cosign-attached SLSA v1.0
attestation stored as OCI sidecar at <image>@<digest>, replacing the
GitHub Artifact Attestations API call. This makes attest work on
free-tier private repos. Consumers verifying with `gh attestation verify`
must switch to `cosign verify-attestation --type slsaprovenance`. Input
contract is unchanged; only the implementation differs.
```

release-please erkennt `!` und bumped 3.x → 4.0.0. Self-CI `release.yml` cuttet den v4-Floating-Tag.

### 4.6 C-6 — Memory-Update

Nach v4-Release wird `troubleshooting_artifact_metadata_caller_cascade.md` umgeschrieben:

> **Status:** Obsolet seit catalog v4.0.0. Cosign-based attestation braucht weder `attestations:write` noch `artifact-metadata:write`. Bypass-callers können diese Permissions entfernen, müssen aber nicht (harmlos ungenutzt).

Memory-Edit erfolgt im selben PR oder direkt danach — nicht erst im Plan-Phase.

## 5. Interface Contracts

| Input/Output | Before (v3) | After (v4) | Caller-Breaking? |
|---|---|---|---|
| `attest:` input (release.yml, docker-build.yml) | `boolean`, default `true` | `boolean`, default `true` | NO — Shape identisch |
| `sign:`, `sbom:`, alle anderen Inputs | unchanged | unchanged | NO |
| `image_ref` Output, `digest` Output | unchanged | unchanged | NO |
| Verifikations-CLI auf Consumer-Seite | `gh attestation verify` | `cosign verify-attestation --type slsaprovenance` | **YES — Soft-Break.** Dokumentiert im CHANGELOG. |
| Top-level `permissions:` Declarations | `attestations:write` + `artifact-metadata:write` required | nicht mehr required | NO — Permissions sind additive; bypass-callers, die sie noch deklarieren, sind unbroken |
| OCI-Sidecar-Location | GitHub-API-managed | `ghcr.io/<image>@<digest>` mit `.att`-Tag-Variant | **YES — Soft-Break.** Verifikation läuft komplett anders, aber Trust-Root identisch |

**Version impact:** `feat!:` → release-please default = Major-Bump → v4.0.0.

## 6. Test Strategy

| Surface | Verification |
|---|---|
| Bestehender `test-docker-build` Job | Bleibt unverändert grün — proves der neue Cosign-Step funktioniert auf der Runner-Pool (gettext-base / cosign-installer Prereq sind seit Image v1.2.1 baked-in, vgl. memory `project_custom_runner_image_todo`) |
| Neuer `assert-attestation-verifies` Job | Catches die Cosign-Sign-Pfad-Korrektheit: OIDC-Identity matches docker-build.yml, Predicate decoded, SLSA-Type recognized |
| `test-docker-build-cve` (attest: false) | Bleibt grün — Attest-Step skipped (kein verify-Job dranhängend) |
| `actionlint` + `yamllint` PR check | Stays grün — YAML-Strukturänderungen sind small + lokal |
| Integration für `release.yml` (test-release-end-to-end) | Bleibt grün — release.yml nested call propagates jetzt nur noch die kleinere Permission-Set |
| Post-merge auf v4 | Manual smoke: einer der Adopter (z. B. flow, smarthome-jukebox-go) cuttet auf `@v4`, triggert Release, prüft mit `cosign verify-attestation` lokal |
| Adopter-side regression | Adopter auf `@v3` weiterhin unbroken — v3 ist frozen, v4 ist opt-in via floating tag |

**Edge case absichtlich nicht getestet:** Adopter auf Free-Private. Catalog selbst ist `PUBLIC`, kann den Code-Path nicht reproduzieren. Vertrauen auf Cosign-OCI-Pfad (kein GitHub-API-Call) + Soenne's eigene Validierung auf einem seiner Private-Repos nach Merge.

## 7. PR Plan

### Single PR — `feat/cosign-attest-swap`

- **Worktree:** `.worktrees/cosign-attest-swap`
- **Branch:** `feat/cosign-attest-swap`
- **Files:**
  - `.github/workflows/docker-build.yml` (Cosign-Installer-Conditional + Attest-Step + Permissions + Header + Input-Desc)
  - `.github/workflows/docker-build-multi.yml` (Permissions)
  - `.github/workflows/release.yml` (Permissions + Input-Desc + Top-Comment)
  - `.github/workflows/integration.yml` (Permissions + assert-attestation-verifies Job + Top-Comment)
- **Commits (3):**
  1. `feat!: switch to cosign-based SLSA provenance (free-tier compatible)` — der eigentliche Swap (docker-build.yml + permissions + header + input-desc)
  2. `chore(integration): verify cosign attestation in CI` — neuer assert-Job
  3. `docs: update workflow descriptions for cosign-based attest` — falls noch separate Doc-Touchups übrig sind, sonst in Commit 1 inkludiert
- **PR-Body-Style:** kein Claude-Attribution-Footer, kein Emoji (Memory `feedback_pr_style`, `feedback_no_emoji_use_glyphs`)
- **Reviewer-Flow:** Subagent-Driven-Development mit 2-Stage-Review (Memory `feedback_phase_workflow_pattern`)
- **Memory-Update:** Im selben PR oder als follow-up commit auf main — `troubleshooting_artifact_metadata_caller_cascade.md` als obsolet markieren

## 8. Acceptance Criteria

- [ ] `actionlint` + `yamllint` PR check grün
- [ ] `test-docker-build` Job grün — Build produziert Image inkl. Attestation-Sidecar
- [ ] `assert-attestation-verifies` Job grün — `cosign verify-attestation --type slsaprovenance` succeeds gegen test-docker-build-Output
- [ ] `test-docker-build-cve` Job grün — Build mit `attest: false` produziert keine Attestation, keine assert-Stufe schlägt fehl
- [ ] `test-release-end-to-end` Job grün — release.yml-nested-call funktioniert mit reduzierten Permissions
- [ ] semantic-release nach Merge cuttet `v4.0.0` und force-moved `v4`-Floating-Tag
- [ ] Soenne manuell verifiziert auf einem seiner Private-Repos: `release.yml@v4` läuft erfolgreich mit `attest: true` (Default)
- [ ] Memory `troubleshooting_artifact_metadata_caller_cascade.md` aktualisiert auf "obsolet seit v4"

## 9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cosign-Installer fehlt zur Laufzeit, wenn nur `attest: true` ohne `sign: true` gesetzt ist | Medium | C-1 Diff erweitert `if: inputs.sign` → `if: inputs.sign \|\| inputs.attest` am Installer-Step. Im Spec dokumentiert. |
| Predicate-JSON-Heredoc bricht bei Shell-Special-Chars in Env-Vars (z. B. `$` in Workflow-Namen) | Low | Workflow-Namen / Repo-Pfade in serverkraken-Org sind sanitized. Falls künftig riskant: jq-basiertes Predicate-Building statt heredoc. Postponed bis konkreter Failure-Case. |
| `cosign verify-attestation` schlägt im assert-Job fehl wegen Cert-Identity-Regexp-Mismatch (z. B. wenn Branch-Refs anders aufgelöst werden) | Medium | Regexp `^https://github\.com/serverkraken/reusable-workflows/\.github/workflows/docker-build\.yml@` matcht alle ref-Suffixes (Branch, Tag, SHA). Falls fail im PR-Check: anchored-Regexp lockern (`--certificate-identity-regexp '.*docker-build\.yml.*'`) als Hotfix in selber PR. |
| Adopter, die `gh attestation verify` automation hatten (kein bekannter Fall in serverkraken) | Low | v3 bleibt nutzbar. CHANGELOG dokumentiert die Migration. Aktive Outreach nicht nötig — kein bekannter Consumer. |
| bypass-callers (`actions-runner-image`'s hand-rolled release.yml) brechen weil sie `attestations: write` deklarieren, das im neuen Catalog nicht mehr "gebraucht" wird | NONE | Permissions sind additive. Ungenutzte Declarations brechen nichts. Memory `troubleshooting_artifact_metadata_caller_cascade` wird auf "obsolet" aktualisiert; aktive Cleanup-PRs in bypass-callers optional. |
| GHCR-Storage-Quota-Druck durch zusätzliche `.att`-Sidecars (Free-Private hat 500 MB Limit) | Low | SLSA-Predicate ist klein (~2 KB unsigniert, ~10 KB als sigstore-Bundle). Selbst bei 100 Releases pro Repo: 1 MB. Vernachlässigbar gegenüber Image-Sizes. |
| v3-Floating-Tag-Konsumenten erwarten Bug-Fixes auf v3 nach v4-Release | Low | Standard-Org-Praxis: Floating-Major-Tag bleibt frozen nach Nachfolger-Release. Falls v3-Hotfix nötig: per-PR-Entscheid. |

## 10. Open Questions

Keine. Alle Entscheidungen aus dem Brainstorm fixiert:

1. ✓ Approach A (Hard swap, kein Provider-Toggle)
2. ✓ v4-Major-Bump via `feat!:` Commit
3. ✓ Cosign-Attest statt `slsa-framework/slsa-github-generator`
4. ✓ SLSA-v1.0-Predicate-Schema
5. ✓ Permissions-Cleanup im selben Cut
6. ✓ Verifikations-Atom für Consumer ist **separater** späterer Phase-8-Spec (Tier C), nicht hier inkludiert
7. ✓ Cosign-Installer-Conditional aufweiten (`sign || attest`)
8. ✓ Integration-Test bekommt einen positiven Verify-Assertion-Job
