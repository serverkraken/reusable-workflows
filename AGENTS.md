# AGENTS.md

Überblick für Menschen und KI-Agenten, die in diesem Repo arbeiten. Details stehen in den verlinkten Dokumenten; diese Datei ersetzt sie nicht.

## Projektziel

Zentraler, versionierter Katalog wiederverwendbarer GitHub-Actions-Workflows ("Atome") der Org `serverkraken`. Adopter-Repos halten nur dünne Caller-Workflows und referenzieren den Katalog mit `uses: serverkraken/reusable-workflows/.github/workflows/<atom>.yml@v4`. `@v4` ist ein **floating major**-Tag und wandert mit jedem Release. Neue Repos werden über den `onboard`-Workflow automatisch verdrahtet (Details: README, `docs/operations.md`).

## Aufbau

- `.github/workflows/` enthält zwei Arten von Dateien:
  - **Atome** (`on: workflow_call`, z. B. `lint-*`, `test-*`, `docker-build*`, `trivy-*`, `tofu-*`, `kube-*`, `semantic-release`, `release` als Orchestrator, `onboard`). Sie sind die öffentliche Schnittstelle.
  - **Self-CI und Betrieb** (kein `workflow_call`): `validate`, `integration`, `self-ci`, `catalog-release`, `drift-check`, `onboard-sweep`, `failure-paths-nightly`, `nightly-runner-parity`.
- `actions/` sind composite actions (Toolchain-Setup, Tool-Installation, `onboard-*`, `setup-sk-workflows`), intern von den Atomen genutzt.
- `scripts/` (Bash/Python) enthält die Logik, die Atome und Actions aufrufen; `scripts/lib/` sind gemeinsame Bibliotheken.
- `cmd/sk-workflows` + `internal/` (`domain`, `ports`, `app`, `adapters`, `manifest`) bilden die Go-CLI `sk-workflows` (Detect, Render, Drift). Sie ist die Hauptengine des Onboardings, die Bash-Skripte sind Fallback; `tests/conventions/check-engine-parity.sh` erzwingt identische Ausgabe.
- `catalog/onboard-defaults.json` ist die Quelle der Repo-Defaults (Branch-Protection u. a.) für Adopter.
- `docs/adopter-templates/skeletons/` enthält die Vorlagen der gerenderten Caller-Workflows.
- `tests/`: `conventions/` (Gates, siehe unten), `shell/` (bats-Tests für Skripte und Gates), `fixtures/` (Beispiel-Repos für Integration und Onboarding).

## Vertrag (öffentliche API)

`inputs`, `outputs` und `secrets` jedes Atoms sind öffentliche API. [`docs/contracts.md`](docs/contracts.md) muss sie vollständig und mit korrekten Defaults beschreiben; das erzwingen `check-contracts.sh` und `check-contract-defaults.py`.

- Neuer optionaler Input mit sicherem Default, neuer Output, interne Umordnung: **minor** (`feat:`).
- Pflicht-Input hinzufügen, Input entfernen oder umbenennen, Output umbenennen, Verhalten inkompatibel ändern: **major** (`feat!:` oder `BREAKING CHANGE:`).
- Vertragsänderung und `docs/contracts.md` gehören in denselben Commit.

## Konventionen und Gates

`validate.yml` läuft auf jedem PR. Konventionen stehen in `docs/conventions/`; neue Konvention dort ablegen, in `CONTRIBUTING.md` verlinken und wenn möglich als Gate ergänzen.

| Gate | Zweck |
|---|---|
| actionlint (v1.7.12), yamllint | Syntax und Stil von Workflows und YAML |
| `check-step-summary.sh` | Jeder Atom schreibt den Pflichtblock nach `$GITHUB_STEP_SUMMARY` |
| `check-contracts.sh`, `check-contract-defaults.py` | Dokumentierte Inputs und Defaults entsprechen dem Quellcode |
| `check-repo-defaults-doc.py`, `check-pin-scope-doc.py`, `check-repo-badges.sh` | README und Doku stimmen mit Quellen (Defaults, Pin-Umfang, go.mod/LICENSE) überein |
| `check-scan-covers-build.py` | Jede gebaute Architektur wird auch gescannt |
| `check-ref-fork-guard.py` | Checkout eines vom Aufrufer gelieferten `ref` hat einen Fork-Guard |
| `check-run-interpolation.sh` | Kein `${{ }}` in `run:`-Bodies; Werte laufen über `env:` |
| `check-summary-coverage.sh` | Jeder Job in `integration.yml`/`self-ci.yml` ist über `needs:` von `summary` erreichbar, sonst ist er dekorativ (Ausnahme nur mit `# summary-exempt: <Grund>`) |
| `check-rendered-goldens.sh`, `check-template-scalar-quoting.py` | Goldens frieren keine ungültigen Werte ein; Profildaten in Templates sind gequotet |
| `check-runs-on-guard.py` | Jeder Job mit `runs_on*`-Input lehnt leeren Wert als ersten Schritt ab |
| `check-renovate-markers.py` | Jeder `# renovate:`-Marker wird von einem customManager in `.github/renovate.json5` erfasst |
| `check-reusable-permissions.py` | Caller-Jobs gewähren mindestens die `permissions:` des aufgerufenen Atoms |
| `renovate-config-check`, `shell-tests` | Renovate-Config valide; bats-Suite |

Weitere Regeln:

- Actions werden per SHA gepinnt mit Trailer `# vX.Y.Z` (Renovate pflegt die Pins); keine reinen Tag-Referenzen.
- Neue Atome halten die Konventionen `docs/conventions/step-summary.md`, `runs-on-guard.md`, `reusable-permissions.md` ein.
- Self-CI-Pfade des Go-Codes erzwingen `go vet`, golangci-lint und 90 % Coverage.

## Befehle (lokal)

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest   # Workflows
pipx run yamllint .github/ actions/ tests/                          # YAML
for f in tests/conventions/*.sh; do bash "$f"; done                 # Shell-Gates
for f in tests/conventions/*.py; do python3 "$f"; done              # Python-Gates
bats tests/shell/                                                   # braucht bats, jq, gomplate
go vet ./... && go test ./...                                       # Go-CLI
```

`check-engine-parity.sh` läuft als Job `engine-parity` in `self-ci`. `act` kann Self-hosted-Labels, Cosign-Keyless und GHCR-Push nicht abbilden; dafür gilt `integration.yml`.

## Release

Conventional Commits steuern release-please (`feat` minor, `fix` patch, `feat!` major; `docs`/`test`/`ci`/`chore` ohne Bump). `catalog-release.yml` ruft das eigene Atom `semantic-release.yml` auf (Dogfooding), taggt `vX.Y.Z`, verschiebt die floating Tags `vX` und `vX.Y` und baut die `sk-workflows`-Binaries (`scripts/build-sk-workflows-assets.sh`). Konfiguration: `release-please-config.json`, `.release-please-manifest.json`. Nie von Hand taggen oder `CHANGELOG.md` editieren.

## Wo was steht

- `README.md`: Überblick, Architektur, Atom-Tabelle, Onboarding
- `CONTRIBUTING.md`: lokale Validierung, Commits, Kompatibilität, Pinning, Onboarding-Abnahme
- `docs/contracts.md`: Inputs/Outputs/Secrets aller Atome und Actions
- `docs/operations.md`: Betrieb (GitHub App, Onboarding, Drift, Sweep, Overrides, Tofu)
- `docs/conventions/`: Einzelkonventionen mit zugehörigen Gates
