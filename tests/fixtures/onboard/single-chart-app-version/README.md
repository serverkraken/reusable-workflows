# single-chart-app-version fixture

EINE Chart-Komponente an der Wurzel mit `app_version: true`.

Deckt Audit **A-5** ab. Bis dahin bildete keine Fixture diesen Fall ab —
deshalb blieb er unbemerkt:

- `release-please-config.monorepo.json.tmpl` gibt den `extra-files`-Eintrag
  laengst aus.
- `release-please-config.json.tmpl` — das Template fuer EINE Komponente —
  kannte den Zweig gar nicht.

Eine einzelne Chart-Komponente mit `app_version: true` bekam also nichts, und
zwar still: release-pleases helm-Strategie schreibt nur `version:` um,
`appVersion` friert ein. Genau der Fall, fuer den die Option gebaut wurde.

Eine Warnung gab es auch nicht — die aus J-8 greift nur bei NICHT-Helm.

Das Golden haelt fest, dass `release-please-config.json` hier den
`extra-files`-Eintrag traegt.
