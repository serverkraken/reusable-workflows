# symlinked-signals

Fixture fuer die Symlink-Semantik der iac-/shell-Signale (Review-Fund I3).

Go (`filepath.WalkDir`) meldet einen Symlink-auf-Datei als Nicht-Verzeichnis
und zaehlte ihn frueher mit; der Bash-Zwilling nutzt `find -type f` und
schloss ihn aus. Ein Repo mit einer verlinkten `.tf`/`.sh` lieferte damit je
nach Schalter `use_go_cli` ein anderes Profil, und keine Fixture enthielt
einen Symlink — das Paritaets-Gate konnte die Abweichung nicht sehen.

Vereinheitlicht auf "Symlinks zaehlen nicht". Erwartetes Profil:

    .iac.directories == ["tofu"]
    .shell.paths     == ["scripts/**/*.sh"]

`linked-only/` enthaelt AUSSCHLIESSLICH Symlinks — einen gueltigen und einen
kaputten, je Endung. Zaehlte eine der Engines Symlinks mit, erschiene das
Verzeichnis als Stack (`linked-only`) bzw. als Glob
(`linked-only/**/*.sh`). Der kaputte Link ist dabei der schaerfere Fall: er
darf kein Stack-Verzeichnis aus einer Datei erzeugen, die es nicht gibt.

## Die Symlinks liegen nicht im Repo

Getrackte Symlinks lassen den Runner beim Entpacken JEDER Composite-Action
des Katalogs abbrechen (#458); `tests/conventions/check-no-symlinks.sh`
verbietet sie. Die Links stehen deshalb in `symlinks.txt` und werden zur
Testlaufzeit in einer Kopie angelegt:

- bats und `check-engine-parity.sh`: `tests/shell/lib/materialize-symlinks.sh`
- Go: `materializedFixture()` in `internal/app/detect/symlink_fixture_test.go`

Die nackte Fixture (ohne Links) liefert dasselbe Profil — wer gegen sie statt
gegen die Kopie testet, prueft nichts. Beide Tests sichern das mit einer
Pruefung ab, dass `linked-only/dangling.*` wirklich ein kaputter Link ist.
