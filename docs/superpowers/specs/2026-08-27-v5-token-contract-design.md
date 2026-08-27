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

## Offene Entwurfsfrage: Token-Lebensdauer

Heute mintet **jedes Atom frisch**. Eine lange Pipeline hat deshalb immer einen
gültigen Token. Zentral einmal minten heißt: der Token ist 1 Stunde gültig, und
ein Release-Lauf mit Multi-Arch-Build plus Scans kann daran kratzen.

Drei Auswege, in absteigender Empfehlung:

1. **`catalog_token` als Organisations-Secret**, gar nicht je Lauf gemintet.
   Löst das Problem für 13 von 16 Atomen vollständig — ein statischer
   Lesetoken kann nicht ablaufen. Die drei Schreiber minten weiter frisch,
   und sie laufen alle **kurz** (Sekunden bis Minuten), nicht über Stunden.
2. Token je Job minten statt je Workflow — reduziert die Ersparnis, behält
   aber die Frische.
3. Ablauf hinnehmen und dokumentieren. Nicht empfohlen: der Fehlerfall
   erscheint als `401` mitten in einem langen Release.

**Empfehlung: (1).** Sie ist zugleich die einfachste und macht den häufigsten
Pfad key-frei, ohne neue Ablauf-Risiken.

## Migration

- `@v4` bleibt unverändert bestehen. Kein Adopter wird gebrochen.
- `@v5` verlangt die neuen Secrets. Re-Onboarding über `onboard.yml` mit
  `pin_version: v5` rendert die Templates entsprechend.
- Die Adopter-Templates minten bzw. reichen die Secrets durch; `secrets:
  inherit` bleibt die Schreibweise, nur der Inhalt ändert sich.

## Was zu tun ist

1. `catalog_token` als Organisations-Secret anlegen (manuell, einmalig).
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
