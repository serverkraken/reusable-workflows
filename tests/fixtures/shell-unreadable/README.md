# shell-unreadable

Eine Fixture mit genau einem getrackten `.sh`, das ein **kaputter Symlink** ist:
`scripts/dangling.sh` zeigt auf eine Datei, die es nicht gibt.

Der Fall ist nicht konstruiert — so sieht ein Repo aus, in dem das Ziel eines
Skript-Symlinks geloescht wurde, ohne den Link mitzunehmen.

Er ist der einzige billige Weg, shellchecks fatalen Ausgang zu provozieren:
`git ls-files` listet den Link, shellcheck kann ihn nicht oeffnen und beendet
mit **rc=2 — bei einem gueltigen, leeren Bericht auf stdout**:

```
$ shellcheck -f json1 -S style gibtsnicht.sh
rc=2
stdout: {"comments":[]}
stderr: gibtsnicht.sh: openBinaryFile: does not exist
```

Genau daran lief die alte Pruefung in `lint-shell.yml` vorbei
(`rc != 0 && ! -s shellcheck.json`): der Bericht war nicht leer, also griff die
Bedingung nicht, der Konverter erzeugte gueltiges SARIF, der Count war 0 und
der Job wurde gruen — ohne eine einzige Zeile geprueft zu haben.

Benutzt von `test-lint-shell-unreadable` in `failure-paths-nightly.yml`.
