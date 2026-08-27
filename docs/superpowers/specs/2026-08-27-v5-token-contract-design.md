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

1. Entscheidung ueber den Katalog-Credential treffen (siehe
   „Token-Lebensdauer"): statischer PAT/Deploy Key oder durchgereichter
   App-Token. Danach einmalig anlegen — Org-Rechte noetig.
2. 13 Leser-Atome: Key-Deklaration → `catalog_token`, Mint-Schritt entfällt.
3. 3 Schreiber-Atome: Key-Deklaration bleibt vorerst, oder `app_token`.
4. 2 Weiterreicher: Deklaration entsprechend anpassen.
5. Adopter-Templates + Goldens.
6. `docs/contracts.md` — der Secrets-Block ist Teil des Vertrags jedes Atoms.
7. Konventions-Gate: kein Atom darf den Private Key deklarieren, das nicht
   nachweislich einen adopter-gescopten Schreibtoken braucht.

Schritt 7 ist der, der verhindert, dass das zurückrutscht — nach dem Muster
der übrigen Gates dieses Katalogs.

## Warum das nicht nebenbei passiert

Der Aufrufvertrag **jedes** Atoms ändert sich. Das ist ein Major-Bump mit
Re-Onboarding für jeden Adopter der Organisation, und es gehört nicht in
denselben Release wie kleinere Funde.
