# v5 — Token-Vertrag statt Private-Key-Durchreichung (Audit D-1)

**Datum:** 2026-08-27 · **Status:** Entwurf, wartet auf Freigabe · **Audit:** D-1 `KRITISCH`

## Das Problem

`secrets: inherit` reicht den **App-Private-Key** — nicht nur einen geminteten
Token — an jedes Atom, das die Secrets deklariert. Die geminteten Tokens sind
korrekt gescopt, der Key ist es nicht. Wer den `v4`-Tag bewegen kann, kann ihn
exfiltrieren und Tokens für **jedes** Repo der Installation minten.

## Was die Messung ergeben hat

Gemessen am 2026-08-27 über alle Atome:

| | Anzahl | |
|---|---|---|
| Atome, die den Key deklarieren | **18** | |
| davon: minten selbst | 16 | |
| davon: reichen nur weiter | 2 | `release.yml`, `docker-build-multi.yml` |
| **minten nur einen KATALOG-Lesetoken** | **13** | `owner: serverkraken`, `contents: read` |
| minten einen ADOPTER-Schreibtoken | **3** | `semantic-release`, `chart-image-bump`, `version-badges` |

Das ist der entscheidende Befund: **der überwiegende Teil der Key-Verbraucher
braucht nirgends Schreibrechte.** Sie klonen den privaten Katalog, mehr nicht.

Ein einziger zentraler `app_token` wäre deshalb *mächtiger als nötig* — er
würde 13 Atomen Schreibrechte in die Hand geben, die heute nur lesen.

## Nachgeprüft — drei Prämissen dieses Entwurfs waren falsch

Zweitmeinungen von Codex und Gemini, jede Behauptung anschließend selbst gegen
Code bzw. Primärquelle geprüft.

### 1. Die „Lesetoken" sind keine Lesetoken

**Kein einziger** der 32 Mint-Aufrufe im Repo setzt `permission-*`. Die README
von `actions/create-github-app-token` sagt:

> „By default, the token inherits **all** of the installation's permissions."

Der Token ist auf das Katalog-Repo *begrenzt*, aber nicht auf Lesen
*beschränkt*, und die App hat laut `docs/operations.md` `workflows: write`.
Ein kompromittiertes „Leser"-Atom kann damit die Workflow-Dateien des Katalogs
umschreiben — also `v4` faktisch übernehmen.

**Die Einteilung „Leser/Schreiber" beschreibt die Absicht, nicht den
Credential.** Das ist eine eigenständige Schwachstelle, schwerer als die von
D-1 beschriebene, und sie ist **ohne Major-Bump behebbar** (siehe Schritt 0).

### 2. Ein Token lässt sich nicht zwischen Jobs reichen

Dieselbe README:

> „the token is revoked in the `post` step of the action, which means it
> **cannot be passed to another job**."

`skip-token-revoke: true` löst nur die Widerruf-Hälfte. Hinzu kommt: die
Maskierung, die die Action per `core.setSecret()` setzt, gilt im selben
Runner-Prozess — sie propagiert **nicht** automatisch in einen Folgejob. Ein
durchgereichter Token kann dort im Klartext in Logs landen.

Damit ist Weg (2) — oben einmal minten, nach unten reichen — nicht bloß
riskant, sondern nicht vorgesehen.

### 3. Die Deklaration zu entfernen bewirkt nichts

`secrets: inherit` reicht Secrets **implizit** weiter, unabhängig davon, was
das gerufene Atom in `on.workflow_call.secrets` deklariert. Das Org-Secret ist
auf „All private repositories" gesetzt.

Solange der Key als benanntes Org-Secret existiert und `inherit` am Aufrufort
steht, kann bösartiger Katalog-Code ihn schlicht referenzieren. **Die erste
Fassung dieses Entwurfs hätte D-1 nicht gelöst.**

### Was die Zweitmeinungen darüber hinaus ergaben

- **Doppel-Mint:** `chart-image-bump` und `version-badges` minten BEIDE Tokens
  (Schreib- und Lesetoken). Die Einteilung ist genauer: 13 reine Leser,
  3 Schreiber, davon 2 zusätzlich lesend.
- **`drift-check.yml`** benutzt den rohen Key an drei Stellen direkt aus dem
  Org-Secret. Kein `workflow_call`-Atom, also außerhalb der 18 — ein Angreifer
  bräuchte dort Push-Zugriff auf den Katalog, nicht nur den `v4`-Tag. Gehört
  trotzdem in die Betrachtung, wenn D-1 als „alle Verwendungsstellen" gelesen
  wird.
- **Kein Leak** des Keys in `run:`, `env:` oder Outputs — unabhängig gesucht,
  nichts gefunden.

## Der bessere Weg: den Checkout überflüssig machen

Beide Zweitmeinungen schlagen dasselbe vor, unabhängig voneinander: Composite
Actions **direkt** cross-repo referenzieren statt den Katalog zu klonen.

    uses: serverkraken/reusable-workflows/actions/setup-python-deps@v5

Kein Checkout, kein Token, kein Credential. Die Org-Freigabe
(`access_level=organization`) ist laut Runbook § 2 bereits gesetzt.

**Eigene Messung, weil beide Zweitmeinungen hier zu weit gingen** — das gilt
nicht für 13 Atome, sondern für acht:

| | Atome |
|---|---|
| **nur Composite Actions** → Checkout eliminierbar | `lint-python`, `lint-flutter`, `docker-build`, `secret-scan`, `build-flutter-android`, `e2e-kind`, `test-python`, `test-flutter` |
| **brauchen echte Repo-Inhalte** | `chart-image-bump`, `version-badges`, `onboard`, `trivy-image`, `trivy-fs`, `kube-validate`, `kube-lint`, `release-flutter-android` |

Die zweite Hälfte lädt Skripte und Configs (`scripts/chart-image-bump.py`,
`configs/kube-linter.yaml`). Die ließen sich in Composite Actions verlagern —
eine Action kann eigene Dateien mitbringen und über `${{ github.action_path }}`
ausführen. Derselbe Mechanismus, aber Umbauarbeit.

**Noch nicht belegt:** ob die Org-Freigabe neben Reusable Workflows auch
Composite Actions cross-repo ohne Token abdeckt. Die Doku formuliert „an action
**or** reusable workflow", was dafür spricht. Vor jedem Umbau mit einem
Testlauf nachweisen.

## Der Entwurf

Zwei getrennte Secrets. Keins davon ist so mächtig wie der Key.

```yaml
secrets:
  catalog_token:   # contents:read auf serverkraken/reusable-workflows
  app_token:       # adopter-gescopt, schreibend — nur für die drei Schreiber
```

| Atom-Gruppe | bekommt | Schaden bei Leak |
|---|---|---|
| 13 Leser | `catalog_token` | Lesezugriff auf einen privaten Katalog. Kein Minting. |
| 3 Schreiber | `app_token` | Schreibzugriff auf **ein** Adopter-Repo, 1 Stunde. |
| heute (v4) | Private Key | Tokens für **jedes** Repo der Installation, unbefristet. |

Der `catalog_token` ist für **jeden** Adopter und **jedes** Atom identisch —
derselbe Scope, dieselben Rechte. Er ist damit ein natürlicher Kandidat für ein
Organisations-Secret und muss gar nicht je Lauf gemintet werden.

## Die App wird NICHT ersetzt

Naheliegendes Missverständnis, deshalb ausdrücklich: `serverkraken-release-bot`
bleibt und wird **zentraler**, nicht überflüssig.

- Die App ist das, **was Tokens überhaupt ausstellt**. `create-github-app-token`
  tauscht Client-ID plus Private Key gegen einen kurzlebigen, eng gescopten
  Token. Ohne App gibt es nichts zu tauschen.
- Unabhängig von D-1 ist der Actor `serverkraken-release-bot[bot]` tragend für
  den Release-Weg: er umgeht die Org-Regel, die `github-actions[bot]` das
  Anlegen von PRs verbietet. Ohne die App öffnet release-please keine
  Release-PRs.

Auch der Private Key bleibt. Was sich ändert, ist **wo** er benutzt wird:

```
HEUTE     Key ──> 18 Atome im Katalog (Code, der unter @v4 mitwandert)
NACHHER   Key ──> eine Stelle im Repo des Adopters, tauscht einmal
```

Der eigentliche Gewinn ist nicht „weniger Key", sondern: **der Key gelangt
nicht mehr in Code, der sich unter einem beweglichen Tag ändert.** Heute zeigt
`@v4` auf Katalog-Code, den jedes Release verschiebt; wer ihn ändern kann,
sieht den Key. Nachher lebt die Tausch-Stelle als materialisierte, im
Onboarding-PR gereviewte Datei im Adopter-Repo — die wandert nicht mit.

## Offene Entwurfsfrage: Token-Lebensdauer

**Korrektur zur ersten Fassung dieses Entwurfs.** Dort stand, `catalog_token`
könne als Organisations-Secret „gar nicht je Lauf gemintet" werden und ein
statischer Lesetoken könne nicht ablaufen. **Das geht mit einem App-Token
nicht:** App-Installations-Tokens laufen immer nach einer Stunde ab, eine
statische Variante gibt es nicht.

Ein statischer Katalog-Lesetoken müsste deshalb ein anderer Credential-Typ
sein:

| Variante | statisch? | Haken |
|---|---|---|
| App-Token | nein, 1 h | genau deshalb diese Frage |
| Fine-grained **PAT**, `contents: read` auf den Katalog | ja | hängt an einem **Benutzerkonto**, jährliche Rotation, neuer Credential-Typ |
| **Deploy Key** auf dem Katalog-Repo | ja | Checkout über SSH statt HTTPS |

Beides führt einen Credential ein, den es heute nicht gibt. Das ist keine
Kleinigkeit und war in der ersten Fassung als gelöst dargestellt.

### Woran es konkret hängt

Der Katalog-Klon passiert früh in jedem Job. Wird ganz oben **einmal** gemintet
und läuft ein Job 90 Minuten später an — weil er hinter einem langen
Multi-Arch-Build wartet —, ist der Token abgelaufen und der Klon scheitert.

Drei Wege:

1. **Pro Job minten** (wie heute). Kein Ablaufproblem — aber jeder Job braucht
   wieder den Key, und D-1 ist nicht gelöst.
2. **Oben einmal minten, Token durchreichen.** Löst D-1, mit Ablaufrisiko bei
   langen Pipelines.
3. **Statischer Katalog-Credential** (PAT oder Deploy Key) für die 13 Leser,
   App-Token nur für die 3 Schreiber. Löst beides, um den Preis eines neuen
   Credential-Typs.

**Empfehlung: (3) für die Leser, (2) für die drei Schreiber.** Die drei
Schreiber laufen kurz — Sekunden bis Minuten —, dort ist die Stunde nie knapp.
Für die 13 Leser entfällt mit (3) das Minting ersatzlos.

Das ist eine Entscheidung über die Credential-Landschaft der Organisation, nicht
bloß über YAML. Sie gehört ausdrücklich nicht in die Umsetzung hineinentschieden.

## Migration

- `@v4` bleibt unverändert bestehen. Kein Adopter wird gebrochen.
- `@v5` verlangt die neuen Secrets. Re-Onboarding über `onboard.yml` mit
  `pin_version: v5` rendert die Templates entsprechend.
- Die Adopter-Templates minten bzw. reichen die Secrets durch; `secrets:
  inherit` bleibt die Schreibweise, nur der Inhalt ändert sich.

## Was zu tun ist

### Schritt 0 — sofort, additiv, ohne Major

An allen 32 Mint-Aufrufen die Rechte verengen:

```yaml
permission-contents: read      # bzw. das, was die Stelle wirklich braucht
```

Behebt die unter „Nachgeprüft (1)" beschriebene Schwachstelle — die schwerere
der beiden — ohne einen einzigen Adopter zu berühren. Unabhängig vom
v5-Zeitplan. Zusätzlich prüfen, ob die App `workflows: write` überhaupt
braucht.

### Danach, in dieser Reihenfolge

1. **Nachweisen**, dass Composite Actions cross-repo ohne Token erreichbar
   sind (ein Testlauf). Trägt das, entfallen für 8 Atome Checkout UND
   Credential vollständig.
2. Für die 8 Atome mit echtem Dateibedarf entscheiden: Skripte in Composite
   Actions verlagern (dann ebenfalls credential-frei) oder Katalog-Credential.
3. **Nur falls (2) einen Credential braucht:** Typ entscheiden — dedizierte
   Katalog-Leser-App mit `permission-contents: read` ist einem PAT oder Deploy
   Key vorzuziehen, weil sie weder an einem Benutzerkonto hängt noch langlebig
   ist. Wer ihn rotiert und wo er liegt, gehört zur Entscheidung.
4. **Die 3 Schreiber-Atome bekommen `app_token`, ohne Rückfall auf den rohen
   Key.** Diese Weiche stand in der ersten Fassung offen („Key-Deklaration
   bleibt vorerst, oder `app_token`") — das wäre ein Widerspruch in sich
   gewesen: ausgerechnet die mächtigsten Atome blieben über den unbefristeten
   Key kompromittierbar, während v5 als Lösung für D-1 gilt.
   Der Token muss **pro Schreiber-Job** gemintet werden, nicht oben einmal —
   siehe „Nachgeprüft (2)". `chart-image-bump` läuft absichtlich NACH langen
   Image-Builds; ein früh gemintetes Token wäre dort alt.
5. `secrets: inherit` an den Aufrufstellen durch explizites Mapping ersetzen.
   Ohne das bleibt der Key erreichbar, egal was die Atome deklarieren.
6. Adopter-Templates, Goldens, `docs/contracts.md`.
7. Konventions-Gate: kein `secrets: inherit` auf Katalog-Aufrufe, kein
   Mint-Aufruf ohne `permission-*`, keine Key-Deklaration außerhalb der
   Schreiber.
8. Migrationsfenster mit hartem Ende, danach **den alten Key widerrufen**.
   Solange `@v4` mit dem alten Key weiterlebt, ist D-1 nicht behoben, sondern
   nur umgangen. Ein unbefristetes Parallelbestehen ist kein Endzustand.

## Warum das nicht nebenbei passiert

Der Aufrufvertrag **jedes** Atoms ändert sich. Das ist ein Major-Bump mit
Re-Onboarding für jeden Adopter der Organisation, und es gehört nicht in
denselben Release wie kleinere Funde.
