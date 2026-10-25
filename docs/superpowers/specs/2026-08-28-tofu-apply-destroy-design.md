# Tofu-Apply-, Destroy- und Drift-Atome — Design

**Datum:** 2026-08-28
**Status:** entworfen
**Auslöser:** Wunsch, einen `tofu plan` vor dem Apply zu sehen und ein `tofu destroy`
aus der CI auslösen zu können.
**Vorgänger:** `specs/2026-08-27-iac-shell-atoms-design.md` — dort war `tofu-apply.yml`
ausdrücklich ausgeklammert („dann eigene Spec"). Das ist diese Spec.

## 1. Problem

Der Katalog kann IaC heute nur *lesen*: `tofu-validate.yml` prüft credential-frei,
`tofu-plan.yml` plant gegen das Backend und hängt das Ergebnis an den PR. Was danach
kommt — der Apply — passiert von Hand am Laptop. Damit fehlt drei Dinge:

- **Kein nachvollziehbarer Apply.** Wer wann was angewandt hat, steht in keiner
  Historie. Der Plan im PR und der Apply am Laptop sind zwei getrennte Vorgänge ohne
  Kopplung; zwischen beiden kann sich der State bewegen.
- **Kein Destroy-Pfad.** Eine Umgebung abzuräumen ist Handarbeit mit lokalem State
  und lokalen Credentials.
- **Keine Drift-Erkennung.** `drift-check.yml` im Katalog prüft *Onboarding*-Drift der
  Adopter gegen die Katalogversion — nicht, ob die echte Infrastruktur von ihrem Code
  abgewichen ist.

## 2. Scope

**Im Scope:**

1. `actions/tofu-stack-exec` — Composite für Backend-Init, tf_vars, tofu-Aufruf, Aufräumen
2. `.github/workflows/tofu-apply.yml`
3. `.github/workflows/tofu-destroy.yml`
4. `.github/workflows/tofu-unlock.yml`
5. `.github/workflows/tofu-drift.yml`
6. Anpassungen an `tofu-plan.yml` (optionaler `emit_plan`, Concurrency, korrigierter Kopfkommentar)
7. **Phase 0:** Renovate-Manager reparieren, OpenTofu und tflint auf aktuell heben
8. `ci.yml.tmpl`: auskommentierter `tofu-plan`-Block beim `iac`-Signal

**Nicht im Scope:**

- **Policy-Gate auf `plan.json`** (Conftest/OPA). Eigene Toolchain, eigene Arbeit.
- **SARIF-Upload für tflint** in `tofu-validate.yml`. Sinnvoll, aber unabhängig von
  Apply und Destroy.
- **Backend-Entscheidung des Adopters.** Die Atome bleiben backend-agnostisch. Siehe
  aber § 7.3 — Garage ist für diesen Ablauf disqualifiziert, und Decision 0002 in
  `homelab-hetzner` empfiehlt es heute noch.
- **Ein `environment`-Input.** Begründung in § 4.

## 3. Was empirisch verifiziert wurde

Diese Spec beruht an den kritischen Stellen auf Messung, nicht auf Dokumentationslage.
Alle Läufe mit OpenTofu 1.12.6 gegen `tests/fixtures/tofu-plan-local` bzw.
`tests/fixtures/tofu-valid`.

| Behauptung | Ergebnis |
|---|---|
| Native Plan-Verschlüsselung (`TF_ENCRYPTION`, pbkdf2 + aes_gcm) wirkt | `tofu show tfplan` ohne Schlüssel: „Plan read error: the given plan file is encrypted and requires a valid encryption configuration to decrypt". Klartext-Marker im Planfile nicht auffindbar |
| Verschlüsselter Plan lässt sich anwenden | `tofu apply tfplan` mit Schlüssel läuft durch |
| State wird von derselben Konfiguration erfasst | Marker in `terraform.tfstate` nicht auffindbar |
| Gespeicherter Plan schützt vor zwischenzeitlicher State-Änderung | „Error: Saved plan is stale — the state was changed by another operation after the plan was created" |
| tflint 0.64 braucht kein `--init` für das Terraform-Regelwerk | `+ ruleset.terraform (0.15.0-bundled)`; gegen eine Probe mit vier Verstößen: 4 Funde, rc=2 |
| tflint 0.64 lässt die gültige Fixture in Ruhe | rc=0 |
| OpenTofu 1.12.6 bricht `-lockfile=readonly` nicht | `init` rc=0, `validate` rc=0, Lockfile byte-identisch |
| **Required Reviewers auf Team-Plan, privates Repo** | **HTTP 422: „Please ensure the billing plan supports the required reviewers protection rule."** Das Environment wurde dabei trotzdem angelegt — mit `protection_rules: []` |

Der letzte Punkt hat das Design umgeworfen. Er ist in § 4 ausgeführt.

## 4. Der Riegel: warum kein Environment-Gate

Der ursprüngliche Entwurf sah einen Lauf mit zwei Jobs vor: `plan`, dann ein
GitHub-Environment mit Required Reviewer als Pause, dann `apply`. Das trägt nicht.

**Required Reviewers sind auf dem Team-Plan in privaten Repositories nicht
verfügbar** (§ 3, letzte Zeile). Sämtliche Adopter-Repos sind privat.

Zwei Details, die dabei aufgefallen sind und unabhängig davon dokumentiert gehören:

1. **GitHub legt ein unbekanntes Environment automatisch an — ohne Protection Rules.**
   Der abgelehnte Request hat das Environment `sk-gate-probe` trotz `422` erzeugt, mit
   leerer `protection_rules`-Liste. Ein Tippfehler im Namen erzeugt also ein Gate, das
   syntaktisch gültig aussieht und nichts tut. Deshalb bekommen die Atome **keinen
   `environment`-Input**: er würde Sicherheit suggerieren, die er nicht liefert.
2. **`environment:` ist auf einem Job, der per `jobs.<id>.uses:` einen Reusable
   Workflow aufruft, gar nicht erlaubt.** Die zulässigen Keywords sind `uses`, `with`,
   `secrets`, `needs`, `if`, `permissions`, `concurrency`, `strategy`. Der Kopfkommentar
   von `tofu-plan.yml` rät heute genau dazu („den aufrufenden Job an ein geschütztes
   `environment` mit Required Reviewers hängen") — dieser Rat ist nicht umsetzbar und
   wird mit dieser Arbeit korrigiert.

**Stattdessen ist die Dispatch-Aktion der Riegel.** Der Mensch liest den Plan im
PR-Kommentar und löst den Apply anschließend von Hand mit der Run-ID dieses Plans aus.
Die Freigabe ist damit kein GitHub-Feature, sondern eine bewusste Handlung mit einem
Argument, das den konkreten Plan benennt.

Das ist möglich, weil der Plan **nativ verschlüsselt** ist (§ 3). Ein Klartext-Artefakt
mit `sensitive`-Werten wäre über Läufe hinweg nicht vertretbar gewesen — Chiffrat ist es.

## 5. Ablauf

```
PULL REQUEST
  tofu-validate        credential-frei
  tofu-plan            emit_plan: true
    ├─ Sticky-Kommentar mit dem Plantext          ← das liest der Mensch
    ├─ Step-Summary mit dem vollen Plan
    └─ Artefakt: tfplan (verschlüsselt) + plan-meta.json

                        Mensch entscheidet

MANUELL: Actions → tofu-apply → Run workflow
  plan_run_id: <Run-ID des Plan-Laufs>
    ├─ Artefakt aus jenem Lauf holen
    ├─ Vorprüfungen (§ 6.3) — Alter, Katalog-SHA, Stack, tofu-Version
    ├─ State-Backup (§ 7.2)
    ├─ tofu apply tfplan     → „Saved plan is stale" schützt von selbst
    └─ Outputs, Aufräumen, Incident-Pfad für errored.tfstate
```

`tofu-destroy` ist derselbe Ablauf in zwei Dispatches: der erste erzeugt den
Destroy-Plan und **hält an**, der zweite wendet ihn an (§ 6.4).

## 6. Verträge

### 6.1 `actions/tofu-stack-exec` (Composite)

Kapselt, was heute in `tofu-plan.yml` inline steht und sonst vierfach entstünde:
tf_vars-Parsing in eine Datei unter `$RUNNER_TEMP`, Backend-Init, den tofu-Aufruf und
das Aufräumen. Composite-Steps laufen im selben Job und Runner, die Eigenschaft „die
`TF_VAR_*` leben nur in einer Shell" überlebt den Umzug.

| Input | Zweck |
|---|---|
| `command` | `plan` \| `plan-destroy` \| `apply` \| `unlock` |
| `working_directory` | Stack |
| `backend_config` | zeilenweise `-backend-config=` |
| `plan_file` | Pfad der tfplan (bei `apply`) |
| `lock_timeout` | `-lock-timeout` |

**Composite Actions können keine `secrets:` deklarieren.** Alles Geheime kommt per
`with:` aus dem aufrufenden Atom und wird dort deklariert.

Der **Rahmen** jedes Jobs bleibt dupliziert und wandert *nicht* in die Composite:
`runs_on`-Wächter (muss laut `check-runs-on-guard.py` erster Step sein), App-Token,
Katalog-Checkout (Composites sind nur aus `.catalog` referenzierbar — Henne und Ei).

### 6.2 `tofu-plan.yml` — Änderungen

Additiv, damit kein Major-Bump entsteht:

| Neu | Default | Zweck |
|---|---|---|
| `emit_plan` | `false` | tfplan + `plan-meta.json` als Artefakt hochladen |
| `plan_retention_days` | `3` | Retention des Artefakts |
| `concurrency_key` | = `working_directory` | State-Identität; geht in die Concurrency-Gruppe und in `plan-meta.json` |

`emit_plan` verlangt eine konfigurierte Verschlüsselung (§ 7.1) und **verweigert sonst
den Upload**. Secret `tf_encryption` ist optional — nur mit `emit_plan: true` Pflicht,
womit der bestehende Vertrag unverändert bleibt.

Weiter: Concurrency-Gruppe auf `tofu-observe-…` (§ 6.7), Kopfkommentar korrigiert (§ 4).

`plan-meta.json` trägt, was der Apply prüfen muss: Katalog-SHA, `working_directory`,
`concurrency_key`, OpenTofu-Version, Zeitstempel, Commit-SHA des Adopters.

### 6.3 `tofu-apply.yml`

`on: workflow_call`. Das Atom **weigert sich** unter `pull_request`,
`pull_request_target` und `workflow_run` (Muster wie in `tofu-plan.yml`); der Aufrufer
verdrahtet es auf `workflow_dispatch`.

| Input | Default | Zweck |
|---|---|---|
| `plan_run_id` | — (Pflicht) | Lauf, der den Plan erzeugt hat |
| `working_directory` | `tofu` | Stack |
| `concurrency_key` | = `working_directory` | State-Identität fürs Scheduling |
| `max_plan_age_minutes` | `120` | Plan-TTL |
| `tofu_version`, `backend_config`, `runs_on`, `lock_timeout`, `report_slug` | wie `tofu-plan` | |
| `outputs_allowlist` | `''` | zeilenweise Namen der zu exportierenden Outputs |

**Outputs:** `applied`, `summary_line`, `apply_status`, `outputs_json`.

**Vorprüfungen, alle fail-closed:** Plan jünger als `max_plan_age_minutes`; Katalog-SHA
im Artefakt identisch mit dem gerade ausgecheckten; `working_directory` und
`concurrency_key` stimmen überein; OpenTofu-Version stimmt überein. Jede Abweichung
bricht ab, bevor tofu überhaupt startet.

Die **Katalog-SHA-Prüfung** ist nicht Zierrat: Adopter pinnen den beweglichen `v4`.
Läuft der Apply Stunden nach dem Plan, kann `v4` weitergerückt sein — der Apply liefe
dann mit anderem Katalog-Code als der Plan. Deshalb übernimmt der Apply den SHA aus dem
Artefakt, statt `v4` neu aufzulösen.

`Saved plan is stale` bleibt der eingebaute Schutz gegen State-Änderungen (§ 3). Die
TTL deckt den anderen Fall ab, den der Stale-Check *nicht* sieht: Ressourcen, die
außerhalb des States verändert wurden.

### 6.4 `tofu-destroy.yml`

Zwei Dispatches, ein Atom:

- **Ohne `plan_run_id`:** `plan -destroy`, Artefakt und Step-Summary, dann Stopp mit dem
  Hinweis, mit welcher Run-ID der zweite Dispatch zu starten ist. Es wird nichts zerstört.
- **Mit `plan_run_id` und `confirm`:** dieselben Vorprüfungen wie beim Apply, dann
  `apply` des gespeicherten Destroy-Plans.

`confirm` muss exakt `DESTROY <owner/repo> <concurrency_key>` lauten. `working_directory`
allein wäre zu schwach — das hieße meist „tippe `tofu`". Zusätzlich `allowed_refs`
(Default: nur der Default-Branch).

**Kein `tofu destroy -auto-approve`.** Es wird immer der gespeicherte Plan angewandt,
sonst führt der zweite Dispatch einen anderen Vorgang aus als den freigegebenen.

### 6.5 `tofu-unlock.yml`

Dispatch-only. Inputs `lock_id`, `concurrency_key`, `working_directory`, `confirm`
(kombiniert Repo, `concurrency_key` und `lock_id`).

Ein `force-unlock` ist gefährlich: die Lock-ID beweist nicht, dass der ursprüngliche
Halter tot ist — ein erzwungener Unlock während eines laufenden Applys erzeugt zwei
gleichzeitige Schreiber. Das Atom fordert deshalb die vollständige Bestätigung und
verweist in der Summary auf das Runbook: erst den zugehörigen Run und dessen
Runner-Zustand prüfen, dann unlocken.

### 6.6 `tofu-drift.yml`

`on: workflow_call`, **ohne eigenen `schedule:`** — ein Cron im Katalog liefe im
Katalog, nicht beim Adopter. Der Zeitplan gehört in den Wrapper.

| Input | Default | Zweck |
|---|---|---|
| `issue_label` | `tofu-drift` | Label des rollenden Issues |
| `fail_on_drift` | `false` | Job rot färben, wenn Drift besteht |

**Outputs:** `has_changes`, `summary_line`, `issue_number`.

Öffnet bzw. aktualisiert ein rollendes Issue bei Drift und **schließt es wieder**,
sobald der Drift verschwunden ist — das Muster steht bereits in `drift-check.yml`.
Braucht `issues: write`; Apply und Destroy erben ausdrücklich **kein**
`pull-requests: write` aus `tofu-plan.yml`.

### 6.7 Concurrency

| Gruppe | Atome |
|---|---|
| `tofu-mutate-<repo>-<concurrency_key>` | apply, destroy, unlock |
| `tofu-observe-<repo>-<concurrency_key>` | plan, drift |

Beide mit `cancel-in-progress: false`. `github.ref` gehört **nicht** in den Schlüssel:
mit `ref` liefen PR-Plan und Apply in verschiedenen Gruppen, und die Serialisierung
wäre verfehlt.

**Anmerkung zur Begründung.** Die Aufteilung wurde beschlossen, als der Apply noch eine
Freigabepause *innerhalb* des Laufs hatte — eine gemeinsame Gruppe hätte alle Pläne über
das ganze Freigabefenster blockiert. Mit dem Dispatch-Modell liegt die Wartezeit
zwischen den Läufen, das Argument ist entfallen. Die Aufteilung bleibt, weil sie
weiterhin verhindert, dass PR-Pläne hinter einem laufenden Apply eingereiht und von
neueren Läufen verdrängt werden; sie ist jetzt aber eine Bequemlichkeit, keine
Notwendigkeit.

**Was die Gruppen nicht leisten:** GitHub-Concurrency gilt pro Repository. Zwei Repos
mit demselben Backend-State koordinieren darüber nichts — dort ist einzig das
Backend-Lock die echte Serialisierung.

## 7. State

### 7.1 Verschlüsselung ist Voraussetzung, nicht Option

Alle Atome, die einen Plan oder State anfassen, verlangen eine
`TF_ENCRYPTION`-Konfiguration über das Secret `tf_encryption`.

Der **Nachweis** ist das erfolgreiche Lesen unter erzwungener Konfiguration, nicht ein
Byte-Präfix. Ein Test auf `{"meta":{"key_provider…` wäre unzuverlässig:
`encrypted_metadata_alias` kann den Metadaten-Schlüssel umbenennen, und ein beliebiges
Klartext-JSON kann den Präfix fälschen. Der Adopter verankert stattdessen

```hcl
encryption {
  state { enforced = true }
  plan  { enforced = true }
}
```

womit OpenTofu selbst jeden unverschlüsselten Zugriff ablehnt. Der Präfix-Test darf als
*Diagnose* in der Summary stehen, nie als Freigabeentscheidung.

### 7.2 State-Backup

Vor jedem Apply sichert das Atom das **rohe** State-Objekt aus dem Bucket als Artefakt.
Weil der State Chiffrat ist (§ 7.1), ist dieses Artefakt kein Leck.

Bucket und Key kommen aus **expliziten Inputs**, nicht aus `.terraform/terraform.tfstate`.
Diese Datei enthält die aufgelöste Backend-Konfiguration zwar verlässlich, ist aber
internes Format ohne Stabilitätszusage — derselbe Grund, aus dem `tofu-plan.yml` bewusst
`-detailed-exitcode` statt `jq` auf `show -json` verwendet.

| Input | Zweck |
|---|---|
| `state_bucket`, `state_key` | Objektpfad |
| `state_workspace_key_prefix` | Default `env:`; der echte Pfad lautet bei Nicht-Default-Workspace `<prefix>/<workspace>/<key>` |
| `state_endpoint`, `state_path_style` | S3-kompatible Endpunkte |

Sind sie leer, **entfällt das Backup mit sichtbarer Warnung in der Summary** — es
scheitert nicht, aber es behauptet auch nichts.

Dafür kommt ein gepinnter S3-Client in `setup-tofu-toolchain`. Damit wird der
Backup-Pfad S3-spezifisch; das Atom bleibt es im Übrigen nicht.

### 7.3 Locking und die Wahl des Backends

**Nachtrag (nach der Umsetzung).** Der `pg`-Backend löst die Locking-Frage,
statt sie zu umgehen: Postgres-Advisory-Locks sind echtes Locking, ohne
Conditional Writes und ohne offene Frage nach der S3-Implementierung. Läuft die
Datenbank unter CloudNativePG mit `barmanObjectStore`, ist auch die
Wiederherstellung gelöst — WAL-Archiving mit Point-in-Time-Recovery ist einem
Artefakt pro Lauf überlegen. Deshalb sichert das Atom bei `backend_type: pg`
bewusst nichts selbst.

Der `conn_str` kommt als Secret `backend_conn_str` (→ `PG_CONN_STR`), niemals
über `backend_config`: der ist ein Input und stünde im Klartext in der
Workflow-Datei des Adopters.

Es bleibt eine Bedingung aus dem ursprünglichen Argument bestehen: die
Datenbank darf **nicht** in dem Cluster liegen, den der State beschreibt.

Der Rest dieses Abschnitts gilt unverändert für S3-kompatible Backends.



**Verifiziert: Garage kann weder Locking noch Bucket-Versionierung.** Damit ist Garage
als State-Backend für diesen Ablauf disqualifiziert — zwei Schreiber (CI und Laptop)
ohne Sperre auf einem State ohne Wiederherstellungspunkt.

Für S3-kompatible Backends ohne DynamoDB ist `use_lockfile = true` (OpenTofu ≥ 1.10) der
Weg; es beruht auf Conditional Writes. Ob **Hetzner Object Storage** das unterstützt, ist
**unverifiziert** und muss vor der Adoption mit zwei konkurrierenden Prozessen getestet
werden.

Konsequenz für `homelab-hetzner`: Decision 0002 empfiehlt heute Garage und muss
umgeschrieben werden. Bis dahin bleiben Apply und Destroy dort ungenutzt — wie schon
`tofu-plan`.

Locking ist bei Apply, Destroy und Drift **nicht abschaltbar**: kein `lock`-Input, nur
`lock_timeout`. Bei `tofu-plan` bleibt `lock` erhalten, weil ein lesender Plan darauf
verzichten darf.

## 8. Sicherheitsgrenzen

**Die Vertrauensgrenze aus `tofu-plan.yml` bleibt bestehen.** `tofu plan` führt
Adopter-Konfiguration aus; der `external`-Provider startet beliebige Programme, und der
Kindprozess erbt die Umgebung des Schritts. Der Dispatch-Riegel schützt den *Apply*,
nicht den *Plan*.

Daraus folgen zwei Forderungen an den Vertrag:

- **Getrennte Credentials.** Der Plan-Lauf soll **nur lesende** Backend-Credentials
  bekommen, der Apply-Lauf schreibende. Ein Riegel, der erst nach dem Plan greift,
  schützt keine Secrets, die der Plan schon hatte.
- **Provider-Credentials frieren nicht im Plan ein.** Sie müssen dem Apply erneut
  übergeben werden — der Vertrag darf nicht behaupten, ein Apply brauche keine
  `tf_vars`.

**Runner-Architektur.** Ein gespeicherter Plan überlebt keinen Wechsel zwischen amd64
und arm64. Plan- und Apply-Lauf müssen dieselben `runs_on`-Labels verwenden, und
`[self-hosted, Linux]` pinnt die Architektur nicht — der Vertrag warnt ausdrücklich.

**`errored.tfstate`.** Schlägt ein Apply nach bereits geänderten Ressourcen beim
Zurückschreiben fehl, legt OpenTofu diese Datei im Arbeitsverzeichnis ab. Sie wird
**gesichert, nicht gelöscht** — sie kann die einzige aktuelle State-Kopie sein — und der
Job wird rot mit Verweis auf das Runbook. Ob jeder Fehlerpfad sie verschlüsselt
schreibt, ist nicht verifiziert; das Runbook behandelt sie vorsorglich als sensibel.

**Artefakte.** tfplan und State-Backup sind Chiffrat, Retention kurz und Namen über
`report_slug`/`concurrency_key` eindeutig. Die Output-Filterung verlässt sich **nicht
allein** auf `sensitive` — exportiert wird nur, was in `outputs_allowlist` steht.

## 9. Phasen

| Phase | Inhalt | Abhängigkeit |
|---|---|---|
| 0 | Renovate-Manager reparieren; OpenTofu 1.10.6 → 1.12.6, tflint 0.54.0 → 0.64.0 | keine |
| 1 | `actions/tofu-stack-exec`; `tofu-plan.yml` darauf umbauen, `emit_plan` ergänzen | 0 |
| 2 | `tofu-apply.yml` inkl. Vorprüfungen und State-Backup | 1 |
| 3 | `tofu-destroy.yml`, `tofu-unlock.yml` | 2 |
| 4 | `tofu-drift.yml` inkl. Auto-Close | 1 |
| 5 | Template-Block, `docs/contracts.md`, Runbook, Decision-0002-Hinweis | 2–4 |

### Phase 0 im Detail

`.github/renovate.json5` deckt nur einen Teil der Renovate-Marker ab. Von **21 Markern,
die einen `customManager` brauchen, greifen acht — dreizehn sind Dekoration**: sie
stehen in der Datei, aber kein Manager fasst sie an, weshalb ihre Pins nie aktualisiert
wurden.

| Form | Abgedeckt | Ohne Manager |
|---|---|---|
| einzeilig, `KEY_VERSION: 'wert'` direkt unter dem Marker | `TRIVY_VERSION`, `KIND_VERSION`, `KUBECTL_VERSION`, `CILIUM_CLI_VERSION`, `HELM_UNITTEST_VERSION` | `TOFU_VERSION`, `TFLINT_VERSION`, `SHELLCHECK_VERSION`, `SHFMT_VERSION`, `GITLEAKS_VERSION`, `KUBE_LINTER_VERSION`, `KUBECONFORM_VERSION`, `KUSTOMIZE_VERSION`, `SOPS_VERSION`, `KSOPS_VERSION` |
| mehrzeilig, Input-`default:` einige Zeilen unter dem Marker | `helm_version` (in `e2e-kind`, `helm-publish`, `lint-helm`) | `golangci_lint_version`, `ct_version`, `cargo_llvm_cov_version` |

Es trifft also nicht nur die IaC-Werkzeuge: auch golangci-lint, chart-testing und
cargo-llvm-cov werden seit ihrer Einführung nicht aktualisiert. Bei OpenTofu sind es
zwei, bei tflint zehn Minors Rückstand.

Zwei weitere Markervorkommen sind **keine** Fälle für einen customManager und müssen
vom Prüfskript ausgenommen werden: `actions/setup-python-deps/action.yml` annotiert eine
`uses:`-Zeile — dafür ist Renovates eingebauter Actions-Manager zuständig — und
`validate.yml` enthält den Markertext als Suchmuster in einem `run`-Block. Dieser Block
ist ein **bestehender Ad-hoc-Wächter**, der ausschließlich für Trivy prüft, ob Marker und
Versionszeile zusammenpassen; das neue Prüfskript verallgemeinert ihn und ersetzt ihn.

**Wie der Rückstand unentdeckt bleiben konnte, gehört zur Lehre:** `ripgrep` überspringt
versteckte Verzeichnisse, und `.github` ist eines. Eine Marker-Inventur ohne `--hidden`
sieht ausschließlich `actions/` und meldet ein zu gutes Ergebnis. Das Prüfskript arbeitet
deshalb mit expliziten Pfadlisten, nicht mit einer Suche.

Der Ersatz ist **ein** Manager mit **zwei** `matchStrings`, weil die beiden Formen für
einen gemeinsamen Ausdruck zu verschieden sind — ein Lazy-Match über Zeilengrenzen wäre
fehleranfällig:

- **einzeilig:** übernimmt `datasource` und `depName` aus dem Marker selbst, nimmt ein
  optionales `extractVersion=` mit und terminiert auf `['"]?\s` statt `['"]?\s*$`. Der
  `$`-Fallstrick ist im Repo bereits einmal aufgetreten und in `renovate.json5`
  kommentiert — `$` bedeutet dort Ende der *Eingabe*, nicht Ende der Zeile.
- **mehrzeilig:** der bestehende `helm_version`-Ausdruck, verallgemeinert auf einen
  beliebigen Input-Namen, damit er `ct_version` mit abdeckt.

Weil die Marker uneinheitliche Versionsstile haben (mit und ohne führendes `v`), muss
ein gemeinsames `extractVersionTemplate` per Dry-Run gegen alle Marker belegt werden,
bevor Phase 0 als fertig gilt.

Der Versionssprung ist gemessen unbedenklich (§ 3). Mitzuziehen: `.mise.toml` in
`homelab-hetzner` pinnt tflint 0.59.1.

## 10. Test- und Konventionspflichten

| Pflicht | Gate |
|---|---|
| Sektion in `docs/contracts.md` je Atom **und** für `tofu-stack-exec` | `check-contracts.sh` |
| Dokumentierte Defaults = tatsächliche Defaults | `check-contract-defaults.py` |
| Step-Summary nach Schema, `runs_on`-Wächter als **erster** Step jedes Jobs | `check-step-summary.sh`, `check-runs-on-guard.py` |
| Integrationsjobs vom `summary`-Aggregator erreichbar **oder** `# summary-exempt: <Grund>` | `check-summary-coverage.sh` |
| Actions auf SHA gepinnt, Zahl der Katalog-Checkouts in der README nachgezogen | `check-pin-scope-doc.py` |
| Katalog-Ref-/Fork-Guard, auch bei einem `ref`-Checkout in `tofu-destroy` | `check-ref-fork-guard.py` |
| Golden-Files nach der Template-Änderung neu erzeugt | `check-rendered-goldens.sh` |

Eine **veraltete** `summary-exempt`-Markierung — Marker gesetzt, Job aber weiterhin über
`needs:` erreichbar — lässt das Gate ebenfalls scheitern. Es ist entweder–oder.

### Fixtures und Fälle

| Fixture / Fall | Zweck |
|---|---|
| `tests/fixtures/tofu-apply-local` | `null`-Provider, lokaler State, Verschlüsselung aktiv — Apply-Happy-Path |
| Verschlüsselter Transport | `tofu show` ohne Schlüssel muss scheitern (die Prüfung aus § 3 als Assertion) |
| Stale-Plan | State bewegen, gespeicherten Plan anwenden, „Saved plan is stale" erwarten |
| Plan-TTL | Artefakt mit altem Zeitstempel → Abbruch vor dem tofu-Aufruf |
| Katalog-SHA-Mismatch | manipulierte `plan-meta.json` → Abbruch |
| Backup ohne Verschlüsselung | Negativtest: Upload muss verweigert werden |
| `confirm`-Mismatch | Abbruch vor jedem tofu-Aufruf |
| Event-Riegel | Apply unter `pull_request`, Destroy ohne Dispatch |
| Destroy destruktiv | im Nightly, nach dem `cleanup-images`-Muster (`failure-paths-nightly.yml`) |

**Bewusst ungetestet:** dass ein Mensch den Dispatch auslöst. Getestet wird die Mechanik
— Artefakt-Übergabe zwischen Läufen, Entschlüsselung, Vorprüfungen. Die Self-CI ruft die
Atome dafür direkt auf.

## 11. Versionierung

Alle Änderungen sind **additiv**: neue Workflows, eine neue Composite Action, ein
optionaler Input an `tofu-plan.yml` mit Default. Kein bestehender Pflicht-Input ändert
sich. Minor-Bumps innerhalb von `v4`.

Zwei sichtbare Verhaltensänderungen gehören ins CHANGELOG, auch ohne Major:

- `tofu-plan` wechselt die Concurrency-Gruppe; Pläne desselben Stacks serialisieren.
- Die Toolchain-Defaults springen auf OpenTofu 1.12.6 und tflint 0.64.0.

## 12. Offene Punkte

| Punkt | Status |
|---|---|
| Conditional Writes bei Hetzner Object Storage (`use_lockfile`) | unverifiziert — vor Adoption mit zwei konkurrierenden Prozessen testen |
| Ob `errored.tfstate` auf jedem Fehlerpfad verschlüsselt geschrieben wird | unverifiziert — Runbook behandelt sie vorsorglich als sensibel |
| `concurrency.queue: max` als Ersatz für das Verdrängen wartender Läufe | strittig; wenn es existiert, ist es für die `mutate`-Gruppe die bessere Wahl. In einem Wegwerf-Workflow zu prüfen — ein Irrtum kostet nur einen YAML-Fehler |
| Decision 0002 in `homelab-hetzner` | muss umgeschrieben werden: Garage ist disqualifiziert (§ 7.3) |
