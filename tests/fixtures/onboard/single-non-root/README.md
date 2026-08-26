# single-non-root fixture

EINE Komponente, die NICHT an der Wurzel liegt: `monorepo=false`, `path=svc`.

Deckt Audit **J-6** ab. Bis dahin bildete keine Fixture diesen Fall ab —
deshalb blieb er unbemerkt, obwohl er das Release-Gating still ausser Kraft
setzte:

- `release-please-config.json` traegt korrekt den Package-Key `svc`
  (aus dem A-2/J-2-Fix).
- `release.yml` gatete aber auf `needs.release-please.outputs.release_created`,
  und diesen unpraefixierten Output setzt release-please NUR fuer das
  Wurzelpaket `.`. Fuer `svc` heisst er `svc--release_created`.

Folge: Tag und GitHub-Release entstehen, docker-build und Publish laufen nie.
Alles gruen, nichts veroeffentlicht.

Der A-2/J-2-Fix hat den Fall erst freigelegt — solange der Package-Key
faelschlich `.` war, passte das flache Gate dazu.

Das Golden haelt fest, dass `release.yml` hier den PFAD-Vertrag benutzt
(`paths_released` / `releases['svc']`), nicht den flachen.
