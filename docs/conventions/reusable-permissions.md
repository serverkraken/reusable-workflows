# Konvention: Aufrufer müssen genug Rechte gewähren

Gewährt ein Job mit `uses: ./.github/workflows/<atom>.yml` ein `permissions:`,
muss es mindestens das abdecken, was `<atom>.yml` auf Workflow-Ebene
deklariert.

Gate: [`tests/conventions/check-reusable-permissions.py`](../../tests/conventions/check-reusable-permissions.py)
· Tests: [`tests/shell/check-reusable-permissions.bats`](../../tests/shell/check-reusable-permissions.bats)

## Warum

Zu wenig zu gewähren lässt nicht den **Job** scheitern, sondern weist den
**gesamten Lauf** beim Start ab:

```
conclusion: startup_failure
```

Kein Job, kein Log, keine Annotation, nichts in der Actions-Oberfläche, das die
Ursache nennt. `actionlint` fängt es auch nicht — beide Dateien sind für sich
gültig, der Defekt steckt in ihrer **Beziehung**.

Gemessen an den Läufen `33074131069` und `33074876898`: die Nightly rief
`goreleaser.yml` mit

```yaml
permissions:
  contents: write
```

während `goreleaser.yml` `contents: write` **und** `packages: write`
deklariert. Alle 51 Jobs des Laufs hörten wegen einer fehlenden Zeile auf zu
existieren.

## Warum es so leicht zu übersehen ist

Weil es meistens gutgeht. `self-ci.yml` gewährt `version-badges.yml` genau
`contents: write` — und mehr deklariert das Atom nicht. Die beiden Mengen
stimmen durch die Beschaffenheit des Atoms überein, nicht durch eine Regel, an
die sich jemand halten musste.

## Was geprüft wird

Rangfolge `none` < `read` < `write`. Für jeden Job mit
`uses: ./.github/workflows/<x>.yml`, der **selbst** ein `permissions:`
deklariert, muss jeder von `<x>.yml` deklarierte Bereich mindestens so stark
gewährt sein.

Ein Job **ohne** `permissions:` wird bewusst nicht geprüft: er erbt die
Vorgaben des aufrufenden Workflows, und das ist eine andere, legitime Wahl.
