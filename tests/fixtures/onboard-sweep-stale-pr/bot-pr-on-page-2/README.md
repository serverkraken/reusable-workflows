# bot-pr-on-page-2 fixture

35 offene PRs; der Bot-PR steht an **Position 33** — also hinter der ersten
Seite, die `gh api` ohne `--paginate` liefert (30 Eintraege).

Deckt Audit **H-20** ab. Ohne `--paginate` findet die Pruefung den Bot-PR
nicht, meldet `no-pr`, und der Sweep legt einen ZWEITEN Onboarding-PR an,
obwohl schon einer offen ist.

Die Fixture wirkt nur, weil `tests/shell/lib/gh-stub.sh` seit H-20 die erste
Seite abschneidet, wenn `--paginate` fehlt. Vorher gab der Stub immer die
vollstaendige Liste aus — ein Test dagegen waere in beiden Fassungen gruen
gewesen und damit wertlos.
