# Konvention: leeres `runs_on` muss laut scheitern

Jeder Job, der seinen Runner aus einem `runs_on*`-Eingang auflöst, prüft
diesen Wert als **ersten** Schritt und bricht bei einer leeren Auswahl ab.

Gate: [`tests/conventions/check-runs-on-guard.py`](../../tests/conventions/check-runs-on-guard.py)
· Tests: [`tests/shell/check-runs-on-guard.bats`](../../tests/shell/check-runs-on-guard.bats)

## Warum

Ein leeres `runs_on` fällt nicht von selbst auf. GitHub plant den Job dann auf
**irgendeinem Runner der Default-Gruppe** ein und lässt ihn arbeiten.

Gemessen am Lauf `33050121217`: `cleanup-images` wurde mit `runs_on: '[]'`
aufgerufen und landete auf `serverkraken-runner-arm64-5qq4z-l8h98` — einem
echten self-hosted Runner, mit **leerer** Label-Liste — in einem Job mit
`packages: write`. Der Aufruf war ein Fehlerpfad-Test, der das Gegenteil
behauptete; die Lücke stand also im Katalog, während ein grüner Haken
Abdeckung meldete.

Für einen Adopter mit vertipptem oder aus einer Expression berechnetem
`runs_on` heißt das: kein Fehler, sondern Arbeit auf einer Maschine, die
niemand ausgewählt hat.

## Was der Wächter kann — und was nicht

Er verhindert **nicht**, dass der Job eingeplant wird. Wenn ein Schritt läuft,
ist der Runner längst zugeteilt, und ein `workflow_call` kann das nicht
abfangen, ohne jedem Adopter einen zusätzlichen Job aufzuzwingen.

Er verhindert, dass der Job **arbeitet**.

## Arbeitsteilung mit `fromJSON`

`runs-on: ${{ fromJSON(inputs.runs_on) }}` weist **kaputtes** JSON bereits beim
Einplanen ab — der Wächter wird dann nie erreicht. Er deckt genau die Werte ab,
die JSON-gültig und trotzdem falsch sind:

| Wert | `fromJSON` | Wächter |
|---|---|---|
| `["self-hosted","Linux"]` | ok | ok |
| `[]`, `[ ]` | ok | **abgelehnt** |
| `[""]`, `[" ", ""]` | ok | **abgelehnt** |
| `"ubuntu-latest"`, `null`, `{}` | ok | **abgelehnt** |
| `nicht-json` | **abgelehnt** | nie erreicht |

Der Vertrag in [`docs/contracts.md`](../contracts.md) nennt durchgehend
„JSON-encoded array of runner labels" — der Wächter setzt genau das durch,
statt es zu erweitern.

## Warum der Wächter den Workspace festnagelt

```yaml
working-directory: ${{ github.workspace }}
```

Diese Zeile sieht nach Rauschen aus und ist keins. Der Wächter läuft **vor dem
Checkout**. Ein Job-Ebene-`defaults.run.working-directory` — `goreleaser.yml`
hat eins — zeigt dann auf ein Verzeichnis, das es noch nicht gibt, und der
Schritt stirbt mit `No such file or directory`, statt irgendetwas zu prüfen.
Gemessen am Lauf `33062297620`. Das Gate erzwingt die Zeile deshalb.

## Warum reines Bash und kein `jq`

14 der 25 Atome benutzen `jq` überhaupt nicht. Eine `jq`-Abhängigkeit wäre eine
neue Anforderung an Adopter-Runner, ausgerechnet in dem Schritt, der niemals
selbst der Grund für einen roten Job sein darf. `fromJSON` hat das Parsen schon
erledigt; der Wächter muss nur noch „Array, und benennt es etwas" beantworten.

## Wo der Wächter *nicht* hingehört

Atome, die `runs_on*` nur an ein anderes Atom **weiterreichen**
(`release.yml`, die `docker-build-multi`-Weitergaben), haben kein eigenes
`runs-on:`. Dort greift der Wächter des aufgerufenen Atoms — eine zweite
Prüfung im Weiterreicher würde denselben Wert doppelt validieren. Das Gate
überspringt solche Jobs bewusst.
