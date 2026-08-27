# IaC- und Shell-Atome — Design

**Datum:** 2026-08-27
**Status:** entworfen
**Auslöser:** zwei Feature Requests aus `serverkraken/homelab-hetzner`, in flow als
`notes/fr-opentofu-atome` und `notes/fr-lint-shell`.

## 1. Problem

Der Katalog deckt Go, Python, Rust, Flutter, Helm, Docker und Kubernetes-Manifeste
ab. Zwei Klassen fehlen vollständig:

- **Infrastructure as Code.** Kein einziges Atom. Ein Repo mit einem `tofu/`-Verzeichnis
  kann den Job nur inline schreiben — genau die Duplikation, gegen die der Katalog
  gebaut wurde.
- **Shell.** `lint-go`, `lint-python`, `lint-rust`, `lint-flutter`, `lint-helm` und
  `kube-lint` existieren; für Shell gibt es nichts. `shellcheck` taucht nur als
  Nebenschritt *innerhalb* anderer Atome auf, nie für die Skripte eines Adopters.
  Shell ist zugleich die eine Sprache, die praktisch jedes Repo der Org enthält.

`homelab-hetzner` (3-Node-Talos-Cluster auf Hetzner Cloud) ist der erste Adopter
mit beiden Formen. Seine Kubernetes-Seite wird sauber bedient (`trivy-fs`,
`kube-validate`, `kube-lint`, `secret-scan`); für OpenTofu und die fünf Shell-Skripte
trägt das Repo zwei als **INTERIM** markierte Inline-Jobs, die auf diese Spec verweisen.

Warum es zuschlägt: IaC ist die Klasse, bei der ein ungeprüfter PR am teuersten ist.
Ein Tippfehler in einer `hcloud_server`-Ressource kann beim Merge drei Nodes ersetzen
und damit etcd samt lokaler Daten verwerfen. Das Modul setzt
`lifecycle.ignore_changes = [image, ssh_keys]` genau dagegen — ob der Schutz nach einer
Änderung noch greift, sieht man ausschließlich im Plan-Output.

## 2. Scope

**Im Scope:**

1. `actions/install-shellcheck` + `.github/workflows/lint-shell.yml` + `scripts/shellcheck-to-sarif.py`
2. `actions/setup-tofu-toolchain` + `.github/workflows/tofu-validate.yml`
3. `.github/workflows/tofu-plan.yml`
4. Onboarding: `iac`- und `shell`-Signale im Detektor, zwei Blöcke in `ci.yml.tmpl`,
   Adopter-PR gegen `homelab-hetzner`

**Nicht im Scope:**

- **`tofu-apply.yml`.** Apply bleibt in `homelab-hetzner` bewusst manuell, weil ein
  fehlgeleiteter Apply die Cluster-Nodes ersetzt. Für spätere IaC-Repos kann sich das
  ändern; dann eigene Spec.
- **`scanners`-Input an `trivy-fs.yml`.** Der FR fordert ihn — er existiert bereits,
  Default `vuln,secret,misconfig`. IaC-Misconfig-Scanning läuft heute schon.
- **Decision 0002 (State-Backend) in `homelab-hetzner`.** Garage vs. Hetzner Object
  Storage ist eine Adopter-Entscheidung. Die Atome werden backend-agnostisch gebaut.
- **Der Talos-Schematic-ID-Check.** Er steht heute im Interim-Block, ist aber
  repo-spezifisch und bleibt im Adopter.
- **Checksum-Verifikation der Tool-Downloads.** Kein Installer im Katalog
  (`install-trivy`, `install-gitleaks`, `install-kube-linter`) prüft Checksums.
  Die neuen folgen dem Hausstil; eine Härtung gälte für alle und wäre eine eigene
  Arbeit.
- **Terraform-Alias.** Kein serverkraken-Repo benutzt Terraform. Binary ist `tofu`,
  Registry `registry.opentofu.org`.

## 3. Phasen

| Phase | Inhalt | Abhängigkeit |
|---|---|---|
| 1 | `lint-shell.yml`, `install-shellcheck`, SARIF-Konverter | keine |
| 2 | `setup-tofu-toolchain`, `tofu-validate.yml` | keine |
| 3 | `tofu-plan.yml` | Phase 2 (Toolchain) |
| 4 | Detektor + Template + Adopter-PR | Phasen 1–3 |

Phase 1 ist bewusst zuerst: kleinstes Stück, sofortiger Nutzen für `homelab-mail-nue`,
`homelab-study`, `homelab-incus-oracle` und `wartung`, und unabhängig von der offenen
Backend-Frage.

## 4. `lint-shell.yml`

### Vertrag

| Input | Typ | Default | Zweck |
|---|---|---|---|
| `paths` | string (multiline) | `**/*.sh` | zu prüfende Globs |
| `severity` | string | `style` | `error`/`warning`/`info`/`style` |
| `shellcheck_version` | string | Katalog-Default | Pin; der Renderer setzt im Aufrufer `${{ vars.SK_SHELLCHECK_VERSION || '' }}` |
| `follow_sources` | boolean | `true` | `-x`: `source lib/common.sh` mitprüfen |
| `scan_shebangs` | boolean | `true` | zusätzlich getrackte Dateien ohne `.sh` mit Shell-Shebang |
| `shfmt` | boolean | `false` | Formatprüfung (`shfmt -d`) |
| `sarif` | boolean | `true` | Upload ins Code-Scanning |
| `fail_on_findings` | boolean | `true` | Gate |
| `report_slug` | string | `''` | Mehrfachaufruf im selben Workflow |
| `runs_on` | string | `["self-hosted","Linux"]` | Runner-Labels |

**Output:** `findings_count`.
**Secrets:** `release_please_app_client_id`, `release_please_app_private_key` (Katalog-Checkout).

### Entscheidungen

**Gepinntes Binary statt `apt-get`.** Der FR schlägt `apt-get install shellcheck` auf
`ubuntu-latest` vor. Der Katalog-Default-Runner ist `[self-hosted, Linux]`, und die
apt-Version ist ungepinnt und alt. Ein Lint-Gate, dessen Regelsatz je Runner-Image
variiert, produziert Funde, die auf einer anderen Maschine verschwinden. Also
`actions/install-shellcheck` nach dem Muster von `install-kube-linter`, mit
Renovate-Marker auf `koalaman/shellcheck`; `shfmt` aus `mvdan/sh` im selben Schritt,
nur wenn eingeschaltet.

**SARIF über einen eigenen Konverter.** shellcheck kann kein SARIF. Statt ein weiteres
fremdes Binary einzuschleppen: `scripts/shellcheck-to-sarif.py` aus `-f json1`. Der
Katalog hat mit `merge-sarif-runs.py` und `merge-trivy-json.py` dasselbe Muster bereits
zweimal, beide unit-testbar.

**`scan_shebangs` per Default an.** Ein Shell-Linter, der `scripts/deploy` ohne Endung
überspringt, prüft in vielen Repos die Hälfte. Der Preis: beim Onboarding tauchen Funde
in Dateien auf, die niemand auf der Rechnung hatte. Abschaltbar, aber die richtige
Voreinstellung. Die Suche läuft über `git ls-files`, damit nichts Ungetracktes und
nichts aus `.catalog` einbezogen wird.

**`.catalog` wird ausgeschlossen.** Der Katalog-Checkout ist ein Implementierungsdetail
dieses Atoms; seine Test-Fixtures dürfen nicht in Adopter-Reports bluten — dieselbe
Regel wie `--skip-dirs .catalog` in `trivy-fs.yml`.

## 5. `setup-tofu-toolchain`

Direktinstallation aus `opentofu/opentofu`-Releases (`tofu_${V}_linux_${arch}.zip`),
Arch-Mapping wie in `setup-kube-toolchain` (`x86_64`→`amd64`, `aarch64|arm64`→`arm64`),
Verifikation über `tofu version`.

| Input | Default | Zweck |
|---|---|---|
| `tofu_version` | Pin mit Renovate-Marker | leer → Katalog-Default |
| `tflint` | `'false'` | zusätzlich `tflint` installieren |
| `tflint_version` | Pin | eigener Renovate-Marker |

**Kein `opentofu/setup-opentofu@v1`.** Das ist die Third-Party-Setup-Action, die der
Katalog ausdrücklich verbietet (`setup-kube-toolchain`: „direct binary installs, pinned,
Renovate-managed — never third-party setup actions"). Der Interim-Block in
`homelab-hetzner` nutzt sie heute; der Adopter-PR beseitigt genau das.

## 6. `tofu-validate.yml`

Der credential-freie Gatekeeper. Sein Wert liegt darin, dass er **ohne jedes Geheimnis**
läuft: auf Fork-PRs und in Repos, deren Cloud-Token noch gar nicht existiert.

| Input | Typ | Default | Zweck |
|---|---|---|---|
| `working_directories` | string (multiline) | `tofu` | ein Stack je Zeile |
| `tofu_version` | string | Katalog-Default | Pin; der Renderer setzt im Aufrufer `${{ vars.SK_TOFU_VERSION || '' }}` |
| `tflint` | boolean | `true` | zusätzlicher Lauf |
| `lockfile_readonly` | boolean | `true` | `-lockfile=readonly` |
| `runs_on` | string | `["self-hosted","Linux"]` | Runner-Labels |

**Output:** `checked_directories` (Anzahl).

Ablauf je Verzeichnis: `tofu fmt -check -recursive -diff` → `tofu init -backend=false
-input=false` → `tofu validate` → optional `tflint`.

**`-backend=false` ist der Punkt, der das Atom credential-frei hält.** Es überspringt
nur die Backend-Initialisierung; Module und Provider werden weiterhin geladen, `validate`
ist also vollwertig.

**`-lockfile=readonly` per Default.** Ein PR, der `.terraform.lock.hcl` still ändern
würde, fällt damit auf, statt die Provider-Pins unbemerkt zu verschieben.

**Ein Job mit Schleife, keine Matrix.** Abweichend vom FR. Eine Matrix erzeugt N
Step-Summary-Blöcke und N Runner-Slots für einen Lauf, der je Stack Sekunden dauert;
`homelab-hetzner` hat genau einen Stack. Die Schleife liefert eine Summary mit einer
Zeile je (Stack, Check). Taucht ein Monorepo mit vielen Stacks auf, ist der Wechsel auf
Matrix additiv.

## 7. `tofu-plan.yml`

Das Atom mit der Sicherheitsfläche. Es braucht Credentials und Backend-Zugriff.

| Input | Typ | Default | Zweck |
|---|---|---|---|
| `working_directory` | string | `tofu` | Stack |
| `tofu_version` | string | Katalog-Default | Pin |
| `backend_config` | string (multiline) | `''` | je Zeile ein `-backend-config=` |
| `comment_on_pr` | boolean | `true` | Plan als PR-Kommentar |
| `plan_json` | boolean | `false` | `tofu show -json` als Artefakt |
| `lock` | boolean | `true` | State-Lock beim Plan |
| `lock_timeout` | string | `60s` | `-lock-timeout` |
| `runs_on` | string | `["self-hosted","Linux"]` | Runner-Labels |

**Outputs:** `has_changes` (bool), `summary_line` (z. B. `2 to add, 1 to change, 0 to destroy`).

**Secrets (alle optional):**

| Secret | Wirkung |
|---|---|
| `backend_access_key` | → `AWS_ACCESS_KEY_ID` |
| `backend_secret_key` | → `AWS_SECRET_ACCESS_KEY` |
| `tf_vars` | multiline `KEY=VALUE` → `TF_VAR_key` |

### Sechs Entscheidungen, die vom FR abweichen

**7.1 `has_changes` über `-detailed-exitcode`, nicht über JSON-Parsing.**
`tofu plan -detailed-exitcode` liefert 0 = keine Änderungen, 2 = Änderungen, 1 = Fehler.
Das ist die eingebaute, eindeutige Antwort — kein `jq` auf eine Struktur, die zwischen
Versionen wandern kann. Wichtig für die Implementierung: `set +e` um den Aufruf, sonst
tötet `bash -e` den Schritt beim erwarteten Exit-Code 2 (dieselbe Falle wie in
`kube-lint.yml`).

**7.2 Das JSON-Artefakt wird opt-in (`plan_json`, Default `false`).**
Der FR will `tofu show -json` immer hochladen. Das ist ein Datenleck: **die
menschenlesbare Plan-Ausgabe redigiert `sensitive`-Werte, die JSON-Ausgabe nicht.**
Wer das Artefakt herunterlädt, sieht Klartext. Default aus, mit Warnung im Vertrag.

**7.3 Die Binär-`tfplan` wird nie hochgeladen.** Sie enthält dieselben Klartextwerte.
Sie entsteht als `-out=tfplan`, wird mit `tofu show -no-color tfplan` gerendert und
verbleibt im Workspace.

**7.4 `cancel-in-progress: false`.** Abweichend von allen Lint-Atomen. Ein abgebrochener
`plan` kann einen State-Lock zurücklassen, und der blockiert dann den nächsten CI-Lauf
*und* den Apply am Laptop. Eine Lint-Ausführung ist zustandslos und darf sterben; ein
Plan nicht.

**7.5 `pull_request_target` wird hart abgelehnt.** Das Atom kann das `on:` des Aufrufers
nicht bestimmen, aber es kann sich weigern: läuft es unter `pull_request_target`, bricht
es mit klarer Fehlermeldung ab. Unter `pull_request_target` liefe fremder PR-Code mit
Zugriff auf die Backend-Credentials. Zusätzlich Fork-Guard nach dem Muster der
SARIF-Uploads.

**7.6 Credentials über Secrets, nie über Inputs.**
`backend_config` bleibt ein normaler Input — dort stehen nur Bucket, Endpoint, Region.
Zugangsdaten kommen als benannte optionale Secrets. `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` funktionieren für Garage **und** Hetzner Object Storage, weil
beide S3-kompatibel sind — das Atom bleibt damit von Decision 0002 unabhängig.
`tf_vars` wird zeilenweise geparst; jeder Schlüssel muss `^[A-Za-z_][A-Za-z0-9_]*$`
erfüllen (sonst Env-Injection über konstruierte Zeilen), jeder Wert wird per
`::add-mask::` maskiert, bevor er gesetzt wird.

### PR-Kommentar

Sticky über Marker `<!-- tofu-plan:<working_directory> -->`, nach dem erprobten Muster
aus `actions/post-prerelease-comment` — inklusive zufälligem Heredoc-Delimiter gegen
Output-Injection. Ausgabe in `<details>` gefaltet, auf GitHubs Grenze von 65.536 Zeichen
gekürzt (Kopf und Fuß erhalten, mit sichtbarem Kürzungshinweis); der Volltext steht in
der Step-Summary.

### Bekannte Konsequenz

`homelab-hetzner` kann `tofu-plan` erst verdrahten, wenn Decision 0002 entschieden und
`tofu init -migrate-state` gelaufen ist. Heute ist der Backend-Block in
`tofu/versions.tf` auskommentiert und der State liegt lokal — ein Plan in CI hätte
keinen gemeinsamen State und meldete bei jedem Lauf „3 Server werden erstellt". Das
Atom wird gebaut, getestet und bleibt dort zunächst ungenutzt. Es ist das einzige Stück
dieser Arbeit, das den Interim-Zustand in `homelab-hetzner` nicht sofort auflöst.

## 8. Onboarding

Im Detektor (`internal/app/detect/service.go`) zwei neue Signale, analog zu
`classifyGitOps`:

- `iac` — Verzeichnisse, die `*.tf` enthalten
- `shell` — getrackte Shell-Dateien mit der Endung `.sh`

**Bewusste Einschränkung beim `shell`-Signal:** Erkannt wird ausschließlich die
Endung `.sh`, nicht der Shebang. Ein Repo, dessen Skripte alle endungslos sind
(`scripts/deploy`, `bin/release`), bekommt daher **kein `shell`-Signal und
folglich auch keinen gerenderten `lint-shell`-Job** — es muss den Job von Hand
in seine `ci.yml` schreiben. Shebang-Erkennung wäre für den Detektor ein echtes
Paritätsrisiko: sie müsste in Go *und* in Bash byte-identisch entscheiden, wann
eine Datei gelesen wird, wie mit Binärdateien, ungültigen Encodings und
Leseberechtigungen umgegangen wird — und `check-engine-parity.sh` erzwingt
identische Ausgabe. Sie ist deshalb zurückgestellt, nicht vergessen.

Das Atom `lint-shell` selbst kennt den Shebang-Scan sehr wohl (Input
`scan_shebangs`, Standard `true`) — die Lücke ist auf den Detektor beschränkt:
er entscheidet nur, *ob* der Job gerendert wird.

Beide `omitempty`: Repos ohne diese Signale rendern **byte-identisch** wie heute. Das ist
keine Stilfrage, sondern das, was `check-rendered-goldens.sh` erzwingt.

In `docs/adopter-templates/skeletons/ci.yml.tmpl` zwei zusätzliche Blöcke hinter dem
GitOps-Zweig, die `tofu-validate` und `lint-shell` rendern, wenn das jeweilige Signal
vorliegt. Sie tragen die Override-Variablen nach Hausmuster
(`${{ vars.SK_TOFU_VERSION || '' }}`, `${{ vars.SK_SHELLCHECK_VERSION || '' }}`), damit
ein Adopter die Tool-Version pro Repo ziehen kann, ohne den Vertrag zu verlassen.

Danach wird `homelab-hetzner` onboarded und erscheint in `docs/onboarding-status.md`
sowie im Drift-Check.

## 9. Adopter-Änderung in `homelab-hetzner`

Der PR ersetzt beide INTERIM-Blöcke:

```yaml
  shellcheck:
    uses: serverkraken/reusable-workflows/.github/workflows/lint-shell.yml@v4
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      paths: |-
        scripts/**/*.sh
        .taskfiles/**/*.sh
    secrets: inherit

  tofu-validate:
    uses: serverkraken/reusable-workflows/.github/workflows/tofu-validate.yml@v4
    permissions:
      contents: read
    with:
      working_directories: |-
        tofu
    secrets: inherit
```

Der Talos-Schematic-ID-Job bleibt unverändert im Repo stehen — er prüft, ob die Image
Factory das Schematic akzeptiert und `nodes.yaml` dazu passt, und ist damit
repo-spezifisch.

## 10. Test- und Konventionspflichten

Jedes neue Atom löst dasselbe Pflichtprogramm aus:

| Pflicht | Gate |
|---|---|
| Sektion in `docs/contracts.md` mit exakten Input-/Output-/Secret-Namen | `check-contracts.sh` |
| Step-Summary nach Schema + Header-Zeile `# Summary convention: …` | `check-step-summary.sh` |
| `runs_on`-Wächter (leeres JSON-Array ablehnen) | `check-runs-on-guard.py` |
| Integrationsjobs erreichbar vom `summary`-Aggregator | `check-summary-coverage.sh` |
| Actions auf SHA gepinnt | `check-pin-scope-doc.py` |
| Katalog-Ref-/Fork-Guard | `check-ref-fork-guard.py` |
| Dokumentierte Defaults = tatsächliche Defaults | `check-contract-defaults.py` |

Fixtures und Fälle:

| Fixture | Zweck |
|---|---|
| `tests/fixtures/shell-clean` | `lint-shell` Happy Path |
| `tests/fixtures/shell-findings` | shellcheck-Fund → Gate greift; deckt auch `scan_shebangs` ab (Datei ohne `.sh`) |
| `tests/fixtures/tofu-valid` | `tofu-validate` Happy Path |
| `tests/fixtures/tofu-invalid` | `fmt`-Verstoß und ungültige HCL → Gate greift |
| `tests/fixtures/tofu-plan-local` | `tofu-plan` gegen **lokales Backend mit `null`-Provider** — läuft offline und ohne Credentials, deckt `has_changes` in beiden Ausprägungen ab |

Unit-Tests: `scripts/shellcheck-to-sarif.py` gegen aufgezeichnete `json1`-Ausgaben;
die `tf_vars`-Parserlogik gegen Injection-Versuche (mehrzeilige Werte, `PATH=x`,
Schlüssel mit Bindestrich).

## 11. Versionierung

Alle Änderungen sind **additiv**: neue Workflows, neue Actions, neue optionale Felder im
Profil. Keine bestehende Input-, Output- oder Secret-Signatur ändert sich. Das ergibt
Minor-Bumps innerhalb von `v4`; ein Major ist nicht nötig.
