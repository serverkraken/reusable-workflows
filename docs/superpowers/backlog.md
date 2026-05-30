# Spec Backlog

Spec-Kandidaten, die aus laufenden Brainstorms bewusst ausgeklammert wurden. Jeder Eintrag ist ein potenzieller eigener Spec — Reihenfolge ist nicht festgelegt.

## Repo-Hygiene-Bootstrapping

Während des Onboardings zusätzlich setzen:
- `CODEOWNERS` (falls fehlt)
- Branch-Protection-Regeln auf dem Default-Branch (required checks aus Atom-Set)
- PR-Template (`.github/pull_request_template.md`)
- Standard-Labels (`type:bug`, `type:feat`, `release-please:*`)

- **Warum ausgeklammert:** Thematisch GitHub-Repo-Verwaltung, nicht Workflow-Rendering. Eigene Risiken (Branch-Protection-API erfordert `administration` Permission auf dem App-Token, anderes Berechtigungsbild).
- **Scope eines Folge-Specs:** dritter PR-Pfad (`Branch C — repo hygiene`) im `onboard.yml`, neben Add- und Cleanup-PR. App-Token-Berechtigungen erweitern. Bedingt rendern (nur wenn fehlt).
- **Abhängigkeiten:** Detection muss erkennen, ob `CODEOWNERS` / Branch-Protection bereits vorhanden ist — kommt mit dem `repo_hygiene`-Feld aus Spec "Smarter Onboarding".

## PR-Comment-Retries (`/onboard rerun`)

Adopter triggern Onboarding-Reruns per Kommentar in einem bestehenden Onboarding-PR (`/onboard rerun`, `/onboard dry-run`).

- **Warum ausgeklammert:** UX-Politur. Heute genügt der zentrale `workflow_dispatch`.
- **Scope eines Folge-Specs:** `issue_comment`-Trigger im `onboard.yml`, Kommando-Parser, Re-Dispatch des Matrix-Targets. Achtung: `issue_comment`-Auth-Modell weicht von `workflow_dispatch` ab.
- **Abhängigkeiten:** Keine.
- **Referenz:** `2026-05-16-onboarding-workflow-design.md` § "Out of scope (future)".

## Rollback / Un-Onboard

Geordneter Rückzug eines Adopter-Repos aus dem Reusable-Catalog (gerenderte Dateien wieder entfernen, ggf. Legacy-Workflows wiederherstellen).

- **Warum ausgeklammert:** Heute deckt `git revert` des Add-PRs den Bedarf ab. Echter Un-Onboard-Workflow wird erst relevant, wenn ein Adopter länger drin war und seinen Stand stark verändert hat.
- **Scope eines Folge-Specs:** inverser Renderer; löscht gerenderte Dateien, signalisiert Legacy-Restore aus Git-History.
- **Abhängigkeiten:** Keine.
- **Referenz:** `2026-05-16-onboarding-workflow-design.md` § "Out of scope (future)".

## Helm-Publish-Pages-Atom (GH-Pages-Style)

Aktueller Hand-rolled-Flow in `calert-helm`, `helm-chart-tshock`, `smarthome-helm` (jeweils `.github/workflows/helm.yaml`): bei push auf main → `mathieudutour/github-tag-action` ermittelt next-semver → patcht `version:` in `<chart>/Chart.yaml` → klont `git@github.com:serverkraken/helm-charts` via Deploy-Key (`secrets.HELM_DEPLOY_KEY`) → `helm package` ins geklonte Repo → `helm repo index --url https://serverkraken.github.io/helm-charts/ --merge index.yaml` → commit+push zurück → Git-Tag auf dem Chart-Repo. Veröffentlicht über `serverkraken/helm-charts` (Default-Branch + GitHub Pages, URL `https://serverkraken.github.io/helm-charts/`).

Der Katalog hat aktuell **nur** `helm-publish.yml` (OCI → `ghcr.io/.../charts`); GH-Pages-Pfad existiert nicht als Atom.

- **Warum ausgeklammert:** Hand-rolled funktioniert; 3 Chart-Repos sind onboarded aber gerendertes `release.yml` ruft `semantic-release.yml` ohne Publish-Stufe — Repos behalten ihr `helm.yaml` parallel. Konsolidierung erfordert mehrere Designentscheidungen (siehe Scope).
- **Scope eines Folge-Specs:** Neuer Atom `helm-publish-pages.yml` mit Inputs `chart_path`, `pages_repo` (default `serverkraken/helm-charts`), `pages_url` (default `https://serverkraken.github.io/helm-charts/`), `deploy_key_secret_name` ODER App-Token-Variante, `chart_version` (oder semver-bump-Modus). Renderer-Logik: bei Chart-Detection (Root oder Subdir) + Repo-Topic (z.B. `sk-helm-publish-pages`) → release.yml ruft den Atom. Version-Bump muss release-please-`helm`-Type-Lücke schließen (release-please bumpt `version:` in `Chart.yaml` nicht von sich aus).
- **Abhängigkeiten:** Klärung von `helm-publish.yml` (OCI) Disposition — siehe nächster Eintrag.
- **Referenz:** Hand-rolled `serverkraken/smarthome-helm/.github/workflows/helm.yaml`; `helm-publish.yml` (OCI-Variante im Katalog).

## helm-publish.yml (OCI) Disposition

`helm-publish.yml` im Katalog pusht Charts als OCI-Artefakte nach `ghcr.io/<org>/charts`. **Kein Adopter ruft den Atom aktuell.** Drei Optionen für die Zukunft:

1. Erhalten als Alternative — Adopter wählt OCI oder Pages via Topic.
2. Zu Multi-Target-Atom konsolidieren — `helm-publish.yml` mit Input `target=pages|oci|both`.
3. Deprecaten — nur Pages-Atom (siehe vorheriger Eintrag) supporten, OCI entfernen.

- **Warum ausgeklammert:** Erst entscheidbar, sobald der Pages-Atom existiert und produktiv läuft.
- **Scope eines Folge-Specs:** Entscheidung dokumentieren, ggf. OCI-Atom umbauen/entfernen. Adopter-Migrationspfad falls existierende Caller (heute: keine) später entstehen.
- **Abhängigkeiten:** Pages-Atom muss zuerst da sein.
- **Referenz:** `.github/workflows/helm-publish.yml`.

## kubeconform-Validation als standalone Atom

Hand-rolled `helm-pr.yaml` der Chart-Repos macht zusätzlich zu `helm lint` und `helm template` eine **kubeconform**-Validation (rendert die Manifests, validiert sie gegen die Kubernetes-Schemas). homelab-study hat ein eigenes `kubeconform.yaml`-Workflow das `kubernetes/**`-Pfade validiert. Der Katalog hat **kein kubeconform-Atom**.

Zwei Adoptions-Pfade:
1. In Helm-Chart-Repos als zusätzliche Lint-Stufe nach `helm template`.
2. In GitOps-Repos gegen die gerenderten `kubernetes/`-Manifeste (separater Trigger, eigene Pfad-Filter).

- **Warum ausgeklammert:** Mehrere Use-Cases mit unterschiedlichem Input-Surface; sauberer Design-Cut nötig.
- **Scope eines Folge-Specs:** Standalone Atom `kube-validate.yml` mit Inputs `manifests_path`, `kubernetes_versions` (Schema-Targets), `strict` (bool), `skip_resources` (CSV). Kann von Helm-Chart-Repos (nach Helm-Render) oder GitOps-Repos (direkt auf gerenderte Manifeste) genutzt werden. Pinned kubeconform-Version, schema-cache via gh-actions cache.
- **Abhängigkeiten:** Keine technischen.
- **Referenz:** Hand-rolled `serverkraken/smarthome-helm/.github/workflows/helm-pr.yaml`; `serverkraken/homelab-study/.github/workflows/kubeconform.yaml`.

## Python-Detection ohne pyproject.toml

`scripts/lib/onboard-detect-lib.sh` erkennt Python ausschließlich an `pyproject.toml`. `serverkraken/anio6-hass` ist ein Python-Repo (`pytest.ini`, `tests/`, `test_api.py`) **ohne** `pyproject.toml` → wird als `generic` klassifiziert → ci.yml emittiert nur `trivy-fs`, kein `lint-python` / `test-python`. Onboard-PR #7 ist live mit nur secscan.

- **Warum ausgeklammert:** Detection-Erweiterung mit Risikobild auf alle Adopter; sauberer Spec nötig wegen pm-Detection-Order (memory `troubleshooting_python_pm_detection`: Probe via `pyproject.toml`-Content, nicht Lockfile).
- **Scope eines Folge-Specs:** Zusätzliche Python-Marker `setup.py` / `setup.cfg` / `requirements.txt` mit klarer Präzedenz (pyproject.toml first). pm-Detection-Branch für non-pyproject: `pip+requirements.txt`. Bats-Coverage für die drei neuen Marker plus die Präzedenzregel. Adopter-Auswirkung: anio6-hass bekommt nach Re-Onboard `lint-python`/`test-python`; ggf. `coverage_threshold` runter, falls Coverage <80%.
- **Abhängigkeiten:** Keine.
- **Referenz:** `scripts/lib/onboard-detect-lib.sh:359`; memory `troubleshooting_python_pm_detection`.

## GitOps-Profil + Talos/Kubernetes-Atoms

`serverkraken/homelab-study` und `serverkraken/homelab-incus-oracle` sind GitOps-Repos für Talos-Kubernetes-Cluster (ArgoCD App-of-Apps, SOPS+Age secrets, makejinja/Jinja2 templating via `task configure`, deploy = git push). Beide werden vom aktuellen Renderer als `generic` klassifiziert → ci.yml enthält nur `trivy-fs`. Tatsächlich genutzte Hand-rolled-Workflows:

- **homelab-study** (8 Workflows): `e2e.yaml` (Talos-cluster-test, configure-matrix), `kubeconform.yaml` (Schema-validation), `kube-linter.yaml` (Best-practices), `gitleaks.yaml` (Secret-scan), `trivy.yaml`, `release.yaml` (monatlicher cron), `label-sync.yaml`, `labeler.yaml`.
- **homelab-incus-oracle** (3 Workflows): `e2e.yaml`, `label-sync.yaml`, `labeler.yaml` — schlanker, weniger pre-merge-Validation.

Beide Repos sind ähnlich strukturiert (Bootstrap-Templates → `task configure` rendert → committed `kubernetes/`-Tree), unterscheiden sich aber in CI-Tiefe.

- **Warum ausgeklammert:** Nicht-triviale Detection-Frage (GitOps-Marker ≠ ein einzelnes File) + atomistischer Schnitt unklar (sechs Workflows reagieren auf unterschiedliche Pfad-Trigger, manche brauchen self-hosted runner mit SOPS-Key). Erfordert Konsultation der projekt-spezifischen Skills (`/homelab-kubernetes-ops` Skill in beiden Repos).
- **Scope eines Folge-Specs:** (a) Detection: GitOps-Marker-Set definieren (`bootstrap/templates/` + `Taskfile.yml` + `*.sops.yaml` + `kubernetes/` als rendered output). (b) Profile-Feld `gitops_kubernetes` (bool). (c) Atom-Set: bestehende `trivy-fs` plus drei neue — `kube-validate.yml` (siehe vorheriger Eintrag), `kube-linter.yml`, `gitleaks.yml`. Ggf. ein composite `setup-talos-toolchain` für mise + SOPS-Bootstrap. (d) Renderer-Branch: bei GitOps-Detection → ci.yml mit diesem erweiterten Set; release.yml = cron-getriebener tag (kein release-please). (e) `e2e.yaml` bleibt repo-spezifisch (Cluster-Configure-Matrix mit SOPS-Key — zu individuell für ein Atom).
- **Abhängigkeiten:** `kube-validate.yml` Atom (siehe vorheriger Eintrag). gitleaks und kube-linter sind eigene Atom-Specs.
- **Referenz:** `serverkraken/homelab-study/.github/workflows/`; `serverkraken/homelab-incus-oracle/.github/workflows/`; `homelab-study/CLAUDE.md` + `.agent/skills/homelab-kubernetes-ops/SKILL.md`.
