# monorepo-nested-go

Komponenten DREI Ebenen tief (`services/<team>/<dienst>`) — eine Tiefe, die
beide Engines erlauben, die aber bis Audit B-12 keine Fixture abgedeckt hat.

Deshalb konnte der Unterschied unbemerkt bleiben: der Go-Detektor begrenzt das
Komponenten-VERZEICHNIS auf drei Ebenen, `find` in der Bash-Engine begrenzte die
gefundene DATEI auf drei — also das Verzeichnis auf zwei. Go fand hier beide
Komponenten, die Bash-Engine kollabierte das Repo auf `["."]`.

Das Paritäts-Gate vergleicht beide Engines über alle Fixtures; ohne ein Layout
dieser Tiefe hatte es nichts zu vergleichen.
