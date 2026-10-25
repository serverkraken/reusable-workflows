# Renovate-Marker-Wächter und Toolchain-Versionen — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jeder Renovate-Marker im Katalog wird von einem `customManager` gegriffen, ein Prüfskript hält das dauerhaft fest, und die dadurch stehengebliebenen Toolchain-Pins werden auf aktuell gehoben.

**Architecture:** Erst der Wächter (er schlägt heute fehl und benennt die dreizehn toten Marker), dann die Reparatur der Konfiguration (zwei generische `matchStrings` statt sechs namentlicher Manager), dann der Versionssprung, den der reparierte Manager künftig selbst erledigt. Der bestehende Ad-hoc-Wächter für Trivy in `validate.yml` wird durch das allgemeine Skript ersetzt.

**Tech Stack:** Python 3 (stdlib), Renovate (JSON5-Konfiguration), GitHub Actions, OpenTofu, tflint.

**Spec:** `docs/superpowers/specs/2026-08-28-tofu-apply-destroy-design.md`, § 9 „Phase 0 im Detail"

## Global Constraints

- **Arbeitsverzeichnis:** Worktree `.worktrees/tofu-apply-destroy`, Branch `feat/tofu-apply-destroy`. Alle Pfade unten sind relativ dazu.
- **Keine Suche über `rg`/`grep` für Marker-Inventuren.** ripgrep überspringt versteckte Verzeichnisse, `.github` ist eines — eine Inventur ohne `--hidden` meldet ein zu gutes Ergebnis. Das Prüfskript arbeitet mit expliziten Pfadlisten.
- **Conventional Commits**, Präfix englisch, Body auf Deutsch.
- **Alle Änderungen additiv.** Der Versionssprung ist eine Verhaltensänderung ohne Vertragsänderung: Minor-Bump in `v4`, CHANGELOG-würdig.
- **Gates, die vor jedem Commit grün sein müssen:**
  ```bash
  python3 tests/conventions/check-contract-defaults.py
  python3 tests/conventions/check-runs-on-guard.py
  bash tests/conventions/check-contracts.sh
  bash tests/conventions/check-step-summary.sh
  ```
- **Belegte Ausgangslage** (gemessen, nicht angenommen): 21 Marker brauchen einen `customManager`, acht werden gegriffen, dreizehn nicht. Zwei weitere Markervorkommen sind Sonderfälle und gehören **nicht** dazu — `actions/setup-python-deps/action.yml` annotiert eine `uses:`-Zeile (eingebauter Actions-Manager), und `.github/workflows/validate.yml` trägt den Markertext als Suchmuster in einem `run`-Block.

---

### Task 1: Wächter für Renovate-Marker

Das Skript inventarisiert alle Marker und prüft, ob einer der `matchStrings` aus `.github/renovate.json5` an genau dieser Stelle greift. Es muss nach dem Schreiben **fehlschlagen** — das ist der Beweis, dass es den Defekt sieht.

Präzedenz im Repo: `tests/conventions/check-ref-fork-guard.py` und `check-runs-on-guard.py` folgen demselben Muster (stdlib-Python, `::error::`-Ausgabe, Exit-Code als Gate).

**Files:**
- Create: `tests/conventions/check-renovate-markers.py`

**Interfaces:**
- Consumes: nichts aus früheren Tasks.
- Produces: ein ausführbares Skript, das mit Exit 0 (alle Marker gegriffen) oder Exit 1 (mit Liste der ungegriffenen) endet. Task 2 macht es grün, Task 2 verdrahtet es in `validate.yml`.

- [ ] **Step 1: Skript schreiben**

```python
#!/usr/bin/env python3
"""Jeder Renovate-Marker im Katalog braucht einen customManager, der ihn greift.

Marker sind reine Kommentare. Fehlt der passende customManager in
.github/renovate.json5, sieht die Datei gewartet aus, wird aber nie
aktualisiert -- genau so blieben TOFU_VERSION, TFLINT_VERSION,
golangci_lint_version und zehn weitere Pins stehen.

Bewusst KEINE Suche ueber rg/grep: ripgrep ueberspringt versteckte
Verzeichnisse, und .github ist eines. Eine Inventur ohne --hidden sieht
ausschliesslich actions/ und meldet ein zu gutes Ergebnis. Deshalb explizite
Pfadlisten.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github" / "renovate.json5"

# Ein Marker zaehlt nur, wenn die Zeile mit dem Kommentarzeichen BEGINNT.
# Damit faellt der Markertext heraus, der in validate.yml als Suchmuster in
# einem run-Block steht ("PATTERN='# renovate: ...'").
MARKER = re.compile(r"^\s*#\s*renovate:\s*datasource=(?P<ds>\S+)\s+depName=(?P<dep>\S+)")
VERSION_KEY = re.compile(r"^\s*[A-Za-z_]+_[Vv]ersion:")
USES_KEY = re.compile(r"^\s*uses:")
COMMENT = re.compile(r"^\s*#")
LOOKAHEAD = 8


def target_files() -> list[pathlib.Path]:
    files = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    files += sorted(ROOT.glob("actions/*/action.yml"))
    return files


def single_quoted_strings(text: str) -> list[str]:
    """Einfach gequotete JSON5-Strings holen, Kommentare uebersprungen.

    Warum kein Regex ueber die ganze Datei: renovate.json5 enthaelt den
    Kommentar "Renovate's migration tool". Dieses Apostroph eroeffnet fuer
    einen naiven Quote-Zaehler einen Schein-String, der die naechste echte
    matchString verschluckt -- konkret die fuer Trivy, die dann faelschlich
    als fehlend gemeldet wird. Deshalb ein kleiner Tokenizer, der `//`- und
    `/* */`-Kommentare sowie doppelt gequotete Strings ueberspringt.

    Das JSON5-Escaping wird dabei gleich aufgeloest (\\' -> ', \\\\ -> \\),
    Regex-Escapes wie \\s bleiben erhalten.
    """
    out: list[str] = []
    buf: list[str] | None = None
    i, n = 0, len(text)
    while i < n:
        char = text[i]
        if buf is not None:
            if char == "\\" and i + 1 < n:
                nxt = text[i + 1]
                buf.append(nxt if nxt in "\\'\"" else "\\" + nxt)
                i += 2
                continue
            if char == "'":
                out.append("".join(buf))
                buf = None
                i += 1
                continue
            buf.append(char)
            i += 1
            continue
        if char == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if char == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if char == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if char == "'":
            buf = []
            i += 1
            continue
        i += 1
    return out


def match_patterns() -> list[re.Pattern[str]]:
    patterns: list[re.Pattern[str]] = []
    for raw in single_quoted_strings(CONFIG.read_text(encoding="utf-8")):
        if "renovate:" not in raw:
            continue
        # Renovate nutzt Go-Syntax fuer benannte Gruppen, Python will (?P<...>.
        pattern = raw.replace("(?<", "(?P<")
        try:
            patterns.append(re.compile(pattern))
        except re.error as exc:
            print(f"::error::matchString laesst sich nicht kompilieren: {pattern!r} ({exc})")
            sys.exit(1)
    if not patterns:
        print("::error::keine matchStrings in .github/renovate.json5 gefunden")
        sys.exit(1)
    return patterns


def classify(lines: list[str], idx: int) -> str:
    """Braucht der Marker einen customManager, oder haengt er an einer uses:-Zeile?"""
    for look in lines[idx + 1 : idx + 1 + LOOKAHEAD]:
        if COMMENT.match(look) or not look.strip():
            continue
        if USES_KEY.match(look):
            return "action-pin"
        if VERSION_KEY.match(look):
            return "custom"
    return "custom"


def markers(text: str) -> tuple[list[tuple[int, int, int, str]], int]:
    """((Start, Ende, Zeilennummer, depName) je Marker, Zahl der uses:-Pins).

    Start und Ende umspannen die ganze MARKER-ZEILE, nicht nur ihren Anfang:
    die matchStrings beginnen beim `#`, nicht bei der Einrueckung davor. Ein
    Vergleich auf den Zeilenanfang meldet sonst jeden Marker als ungegriffen --
    auch die, fuer die ein Manager existiert.
    """
    found: list[tuple[int, int, int, str]] = []
    skipped = 0
    lines = text.splitlines(keepends=True)
    offset = 0
    for idx, line in enumerate(lines):
        hit = MARKER.match(line)
        if hit:
            if classify(lines, idx) == "action-pin":
                skipped += 1
            else:
                found.append((offset, offset + len(line), idx + 1, hit.group("dep")))
        offset += len(line)
    return found, skipped


def main() -> int:
    patterns = match_patterns()
    uncovered: list[str] = []
    total = 0
    action_pins = 0

    for path in target_files():
        text = path.read_text(encoding="utf-8")
        starts = {m.start() for pattern in patterns for m in pattern.finditer(text)}
        found, skipped = markers(text)
        action_pins += skipped
        for start, end, lineno, dep in found:
            total += 1
            if not any(start <= s < end for s in starts):
                rel = path.relative_to(ROOT)
                uncovered.append(f"{rel}:{lineno} → {dep}")

    if uncovered:
        print(f"::error::{len(uncovered)} von {total} Renovate-Markern werden von keinem customManager gegriffen.")
        print("Diese Pins sehen gewartet aus, werden aber nie aktualisiert:")
        for entry in uncovered:
            print(f"  - {entry}")
        print("Fix: passenden matchString in .github/renovate.json5 ergaenzen.")
        return 1

    print(f"OK: alle {total} Renovate-Marker werden von einem customManager gegriffen "
          f"({action_pins} uses:-Pin(s) uebersprungen — dafuer ist Renovates eingebauter "
          f"Actions-Manager zustaendig).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Ausführbar machen und laufen lassen — es MUSS fehlschlagen**

```bash
chmod +x tests/conventions/check-renovate-markers.py
python3 tests/conventions/check-renovate-markers.py; echo "rc=$?"
```

Erwartet: `rc=1`, Meldung „13 von 21 Renovate-Markern werden von keinem customManager gegriffen", und in der Liste stehen unter anderem `actions/setup-tofu-toolchain/action.yml → opentofu/opentofu` und `.github/workflows/lint-go.yml → golangci/golangci-lint`.

Weicht die Zahl ab, **nicht das Skript an die Zahl anpassen**, sondern die Abweichung klären: entweder ist ein Marker dazugekommen, oder `classify()` stuft einen Sonderfall falsch ein.

- [ ] **Step 3: Gegenprobe, dass das Skript nicht blind alles meldet**

Die acht bereits abgedeckten Marker dürfen **nicht** in der Liste stehen. Prüfen:

```bash
python3 tests/conventions/check-renovate-markers.py | grep -E "trivy|kind|kubernetes/kubernetes|cilium-cli|helm-unittest|helm/helm" \
  && echo "FEHLER: abgedeckter Marker wird als ungegriffen gemeldet" \
  || echo "OK: nur ungegriffene Marker gemeldet"
```

Erwartet: `OK: nur ungegriffene Marker gemeldet`.

- [ ] **Step 4: Commit**

```bash
git add tests/conventions/check-renovate-markers.py
git commit -m "test: Waechter fuer ungegriffene Renovate-Marker

Marker sind Kommentare; ohne passenden customManager sieht ein Pin gewartet
aus und wird nie aktualisiert. Das Skript inventarisiert alle Marker und
prueft, ob einer der matchStrings an genau dieser Stelle greift.

Es schlaegt derzeit bewusst fehl (13 von 21) und ist noch nicht in validate.yml
verdrahtet -- das passiert, sobald die Konfiguration repariert ist.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Renovate-Konfiguration reparieren

Sechs namentliche Manager werden durch **einen** Manager mit **zwei** `matchStrings` ersetzt. Die beiden Formen sind für einen gemeinsamen Ausdruck zu verschieden: einzeilig `KEY_VERSION: 'wert'` direkt unter dem Marker gegen mehrzeilig mit `default:` einige Zeilen darunter. `datasource` und `depName` kommen aus dem Marker selbst, `depNameTemplate` und `datasourceTemplate` entfallen deshalb.

Zwei Abhängigkeiten brauchen ein `extractVersion`, das bisher im Manager bzw. im Marker stand. Es wandert nach `packageRules`, damit der generische Manager ohne Sonderfälle auskommt.

**Files:**
- Modify: `.github/renovate.json5` (Block `customManagers`, Block `packageRules`)
- Modify: `.github/workflows/validate.yml` (Ad-hoc-Trivy-Wächter raus, neues Skript rein)

**Interfaces:**
- Consumes: `tests/conventions/check-renovate-markers.py` aus Task 1.
- Produces: eine Konfiguration, unter der das Skript mit Exit 0 endet.

- [ ] **Step 1: `customManagers` ersetzen**

Alle sechs bestehenden Einträge im `customManagers`-Array durch diesen einen ersetzen. Die erklärenden `NOTE`-Kommentare zu `fileMatch` und zum `$`-Fallstrick bleiben erhalten — sie sind weiterhin gültig.

```json5
  customManagers: [
    {
      // NOTE: customManagers still uses `fileMatch` -- Renovate's migration
      // tool generates `managerFilePatterns` here, but the validator (and
      // some Renovate runtimes) reject it inside customManagers. Keep
      // `fileMatch` until upstream sorts this out.
      //
      // NOTE: matchStrings are compiled WITHOUT the `m` flag, so `$` means
      // end-of-INPUT, not end-of-line. Terminate on `['"]?\s` (a single
      // following whitespace/newline char), never on `['"]?\s*$`.
      //
      // EIN generischer Manager statt sechs namentlicher: datasource und
      // depName stehen bereits im Marker. Ein neues Werkzeug braucht damit
      // nur noch seinen Marker, keinen Eintrag hier.
      // tests/conventions/check-renovate-markers.py haelt das fest.
      customType: 'regex',
      fileMatch: [
        '^\\.github/workflows/.+\\.ya?ml$',
        '^actions/.+/action\\.ya?ml$',
      ],
      matchStrings: [
        // Form 1 -- einzeilig: KEY_VERSION: 'wert' direkt unter dem Marker.
        // `[^\n]*` schluckt ein optionales `extractVersion=` im Marker; der
        // Wert dafuer steht in packageRules, nicht hier.
        '#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)[^\\n]*\\n\\s*[A-Za-z_]+_VERSION:\\s*[\'"]?(?<currentValue>\\S+?)[\'"]?\\s',
        // Form 2 -- mehrzeilig: Input-Default einige Zeilen unter dem Marker.
        // `[\s\S]*?` ueberbrueckt description/required/type ohne dotall-Flag.
        '#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)[^\\n]*\\n\\s*[a-z_]+_version:[\\s\\S]*?default:\\s*[\'"]?(?<currentValue>\\S+?)[\'"]?\\s',
      ],
    },
  ],
```

- [ ] **Step 2: `packageRules` um die beiden `extractVersion`-Fälle ergänzen**

An das bestehende `packageRules`-Array anhängen:

```json5
    {
      // Trivy taggt `v0.70.0`, der Pin traegt `0.70.0`.
      // Stand frueher als extractVersionTemplate im Trivy-Manager.
      matchDatasources: ['github-releases'],
      matchPackageNames: ['aquasecurity/trivy'],
      extractVersion: '^v(?<version>.*)$',
    },
    {
      // kustomize taggt `kustomize/v5.5.0`. Stand frueher inline im Marker
      // in actions/setup-kube-toolchain/action.yml -- der generische Manager
      // liest es dort nicht mehr aus.
      matchDatasources: ['github-releases'],
      matchPackageNames: ['kubernetes-sigs/kustomize'],
      extractVersion: '^kustomize/v(?<version>.+)$',
    },
```

- [ ] **Step 3: Wächter laufen lassen — jetzt MUSS er grün sein**

```bash
python3 tests/conventions/check-renovate-markers.py; echo "rc=$?"
```

Erwartet: `rc=0` und `OK: alle 21 Renovate-Marker werden von einem customManager gegriffen.`

Schlägt ein einzelner Marker weiterhin fehl, liegt es fast immer an der Einrückung des Wertes oder an einem Anführungszeichenstil, den `[\'"]?` nicht abdeckt — den betroffenen Marker einzeln gegen den Ausdruck prüfen, nicht das Prüfskript aufweichen.

- [ ] **Step 4: JSON5 syntaktisch validieren**

```bash
npx --yes --package renovate -- renovate-config-validator .github/renovate.json5
```

Erwartet: `Config validated successfully`. Ohne Netzzugang entfällt der Schritt; dann mindestens `python3 -c "import json5" 2>/dev/null || true` überspringen und die Datei im nächsten Renovate-Lauf beobachten.

- [ ] **Step 5: Ad-hoc-Trivy-Wächter in `validate.yml` ersetzen**

Der bestehende Schritt greppt den Trivy-Marker und die `TRIVY_VERSION`-Zeile — genau die Prüfung, die das neue Skript für alle Marker macht. Er entfällt; stattdessen wird das Skript in die Kette der Konventions-Checks aufgenommen, unmittelbar hinter `check-runs-on-guard.py`:

```yaml
      - name: Check every Renovate marker is picked up by a customManager
        run: python3 tests/conventions/check-renovate-markers.py
```

- [ ] **Step 6: Gates laufen lassen**

```bash
python3 tests/conventions/check-renovate-markers.py
bash tests/conventions/check-step-summary.sh
bash tests/conventions/check-contracts.sh
python3 tests/conventions/check-contract-defaults.py
```

Erwartet: alle vier ohne Fehlerausgabe.

- [ ] **Step 7: Commit**

```bash
git add .github/renovate.json5 .github/workflows/validate.yml
git commit -m "fix: alle Renovate-Marker greifen wieder

Von 21 Markern, die einen customManager brauchen, griffen acht. Dreizehn waren
Dekoration -- darunter TOFU_VERSION und TFLINT_VERSION, aber auch
golangci_lint_version, ct_version und cargo_llvm_cov_version. Ihre Pins standen
seit ihrer Einfuehrung still.

Sechs namentliche Manager werden durch einen generischen mit zwei matchStrings
ersetzt: datasource und depName stehen im Marker selbst. Ein neues Werkzeug
braucht damit nur noch seinen Marker. Die beiden extractVersion-Faelle (Trivy,
kustomize) wandern nach packageRules.

Der Ad-hoc-Waechter fuer Trivy in validate.yml entfaellt; das allgemeine
Pruefskript ersetzt ihn.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Toolchain-Versionen nachziehen

Die beiden Pins, die durch den toten Manager stehengeblieben sind, werden von Hand auf aktuell gehoben. Danach übernimmt Renovate.

Der Sprung ist gemessen unbedenklich (Spec § 3): tflint 0.64 hat `ruleset.terraform` weiterhin gebündelt und feuert ohne `--init`; die gültige Fixture bleibt bei rc=0; OpenTofu 1.12.6 lässt `-lockfile=readonly` und das Lockfile unangetastet.

**Files:**
- Modify: `actions/setup-tofu-toolchain/action.yml:33` (`TOFU_VERSION`), `:55` (`TFLINT_VERSION`)

**Interfaces:**
- Consumes: den reparierten Manager aus Task 2 (sonst würde der Pin erneut einfrieren).
- Produces: Katalog-Default OpenTofu `1.12.6`, tflint `0.64.0`.

- [ ] **Step 1: Pins setzen**

In `actions/setup-tofu-toolchain/action.yml`:

```yaml
        # renovate: datasource=github-releases depName=opentofu/opentofu
        TOFU_VERSION: '1.12.6'
```

```yaml
        # renovate: datasource=github-releases depName=terraform-linters/tflint
        TFLINT_VERSION: '0.64.0'
```

- [ ] **Step 2: Belegen, dass die Fixtures den Sprung überstehen**

Lokal, in einer Kopie außerhalb des Repos (ein `tofu init` im Repo hinterließe ein `.terraform/`):

```bash
TMP=$(mktemp -d)
cp -R tests/fixtures/tofu-valid/. "$TMP/"
( cd "$TMP" && tofu init -backend=false -input=false -lockfile=readonly -no-color >/dev/null && echo "init rc=$?" \
  && tofu validate -no-color >/dev/null && echo "validate rc=$?" \
  && tflint --no-color; echo "tflint rc=$?" )
rm -rf "$TMP"
```

Erwartet: `init rc=0`, `validate rc=0`, `tflint rc=0`. Voraussetzung: lokal installiertes `tofu` 1.12.6 und `tflint` 0.64.0 — sonst prüft der Schritt die falschen Versionen.

- [ ] **Step 3: Prüfen, dass der Wächter weiterhin grün ist**

```bash
python3 tests/conventions/check-renovate-markers.py; echo "rc=$?"
python3 tests/conventions/check-contract-defaults.py; echo "rc=$?"
```

Erwartet: beide `rc=0`. `check-contract-defaults.py` betrifft dokumentierte **Input**-Defaults; die gepinnten Versionen sind Umgebungsvariablen der Composite und stehen nicht in `docs/contracts.md` — der Check darf also unverändert grün bleiben.

- [ ] **Step 4: Commit**

```bash
git add actions/setup-tofu-toolchain/action.yml
git commit -m "feat: OpenTofu 1.12.6 und tflint 0.64.0 als Katalog-Default

Beide Pins standen still, weil ihre Renovate-Marker von keinem customManager
gegriffen wurden (siehe vorheriger Commit). OpenTofu lag zwei, tflint zehn
Minors zurueck.

Gemessen unbedenklich: tflint 0.64 hat ruleset.terraform gebuendelt und feuert
ohne --init (Gegenprobe: vier Funde auf einer Probe mit Verstoessen, rc=2), die
gueltige Fixture bleibt rc=0. OpenTofu 1.12.6 laesst -lockfile=readonly
unberuehrt, das Lockfile bleibt byte-identisch.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Adopter-Pin angleichen

`homelab-hetzner` pinnt seine Werkzeuge über `mise`. Der Kommentar dort sagt ausdrücklich, dass Laptop- und CI-Version zusammenpassen müssen — sonst formatiert der Laptop anders, als `tofu fmt -check` im PR verlangt. Nach Task 3 gilt das für tflint erneut.

**Anderes Repository.** Dieser Task erzeugt einen eigenen PR in `serverkraken/homelab-hetzner`, nicht in diesem Worktree.

**Files:**
- Modify: `/Users/msoent/SourceCode/serverkraken/homelab-hetzner/.mise.toml`

**Interfaces:**
- Consumes: die Versionen aus Task 3.
- Produces: nichts, was spätere Tasks brauchen — Abschluss der Phase.

- [ ] **Step 1: Ist-Stand prüfen**

```bash
cd /Users/msoent/SourceCode/serverkraken/homelab-hetzner
rg -n "opentofu|tflint" .mise.toml
git status --porcelain
```

Erwartet: `aqua:opentofu/opentofu` steht auf `1.12.6` (passt bereits), tflint auf `0.59.1` (weicht ab). Arbeitsbaum sauber — sonst zuerst klären, was dort liegt.

- [ ] **Step 2: tflint angleichen und Branch anlegen**

```bash
git switch -c chore/align-tflint-with-catalog
```

In `.mise.toml` den tflint-Eintrag auf `0.64.0` setzen.

- [ ] **Step 3: Belegen, dass der Stack damit sauber bleibt**

```bash
mise install
cd tofu && tofu fmt -check -recursive -diff . ; echo "fmt rc=$?"
tflint --no-color; echo "tflint rc=$?"
```

Erwartet: `fmt rc=0`. Für tflint ist rc=0 erwünscht — meldet es Funde (rc=2), gehören die in den PR-Text, damit sichtbar ist, was der neuere Regelsatz zusätzlich sieht. **Nicht** stillschweigend Regeln abschalten.

- [ ] **Step 4: Commit und PR**

```bash
git add .mise.toml
git commit -m "chore: tflint 0.64.0, gleichziehen mit dem Katalog

Der Katalog-Default steht seit dem Renovate-Fix auf 0.64.0. Der Kommentar in
dieser Datei verlangt, dass Laptop und CI dieselbe Version fahren -- sonst
formatiert der Laptop anders, als tofu fmt -check im PR verlangt.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
gh pr create --fill
```

---

## Selbst-Review

**Der Skriptcode in Task 1 wurde gegen dieses Repo ausgeführt, nicht nur geschrieben.**
Ergebnis: `Marker gesamt (customManager-relevant): 21 · uebersprungen (uses:-Pin): 1 ·
ohne Manager: 13` — dieselben dreizehn Abhängigkeiten, die die Spec nennt. Zwei Fehler
kamen dabei heraus und stehen oben bereits korrigiert im Code:

1. **Naive String-Extraktion.** Ein Regex über die ganze JSON5-Datei verschluckt die
   erste `matchString`, weil der Kommentar „Renovate's migration tool" ein Apostroph
   enthält. Trivy wurde dadurch als ungegriffen gemeldet, obwohl ein Manager existiert.
   Behoben durch den Tokenizer in `single_quoted_strings()`.
2. **Offset-Vergleich am Zeilenanfang.** Die `matchStrings` greifen beim `#`, nicht bei
   der Einrückung davor — der Vergleich meldete deshalb *alle* 21 Marker als ungegriffen.
   Behoben durch den Spannenvergleich in `markers()`.

Wer den Plan ausführt, sollte trotzdem Step 2 und 3 ernst nehmen: sie sind der Beweis,
dass das Skript in *seiner* Arbeitskopie dasselbe sieht.

**Spec-Abdeckung.** § 9 „Phase 0 im Detail" verlangt drei Dinge: den generischen Manager mit zwei `matchStrings` (Task 2), den Versionssprung (Task 3) und das Angleichen von `.mise.toml` (Task 4). Der Wächter (Task 1) geht darüber hinaus — die Spec fordert ihn nicht ausdrücklich, aber ohne ihn kehrt der Defekt beim nächsten neuen Werkzeug zurück. Der Dry-Run-Vorbehalt aus § 9 ist als Step 4 in Task 2 abgebildet.

**Offen und bewusst so.** Ob Renovate den generischen Manager im echten Lauf so greift wie das Prüfskript, zeigt erst der erste Lauf gegen das Repo. Das Skript prüft die Regex-Abdeckung, nicht Renovates Verhalten — es kann einen Manager grün melden, den Renovate wegen `extractVersion`- oder `versioning`-Feinheiten anders auflöst. Der erste Renovate-PR nach dem Merge ist deshalb zu beobachten: er sollte die dreizehn stehengebliebenen Pins in Bewegung bringen.
