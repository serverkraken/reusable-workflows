#!/usr/bin/env bash
# tests/conventions/check-no-symlinks.sh
#
# Gate: kein getrackter Symlink im Repo.
#
# Warum: ein Adopter laedt `serverkraken/reusable-workflows/actions/<name>@v4`
# als Composite-Action. Der Runner holt dafuer das Archiv des GANZEN Commits
# und entpackt es in "Set up job". Drei absichtlich kaputte Symlinks in
# tests/fixtures liessen genau das mit "Could not find file …" abbrechen — fuer
# jede Composite-Action des Katalogs zugleich, gesehen in flow-web (#458).
#
# Verboten ist jeder Symlink, nicht nur der kaputte: ob ein Link beim Entpacken
# aufloest, haengt an Ziel und Archivreihenfolge, "kein Symlink" dagegen ist
# eindeutig pruefbar. Tests, die Symlinks brauchen, legen sie zur Laufzeit in
# einem Temp-Verzeichnis an (Beispiel: tests/fixtures/onboard/symlinked-signals,
# Manifest symlinks.txt).
#
# Massgeblich ist der Git-Index (Mode 120000), nicht das Arbeitsverzeichnis:
# ungetrackte Links landen nie im Archiv.
#
# Bats fixtures invoke this from a temp repo; CI invokes it from the repo root.

set -euo pipefail

# -z: Pfade roh statt C-gequotet, sonst traefe die Annotation bei Umlauten,
# Tabs oder Anfuehrungszeichen die Datei nicht. Eintrag: "<mode> <sha> <stage>\t<pfad>".
# Prozess-Substitution statt Pipe, damit `found` im Hauptshell landet; der
# Exit-Status von git wird danach eigens geprueft.
found=0
while IFS= read -r -d '' entry; do
  [[ "${entry%% *}" == "120000" ]] || continue
  found=1
  echo "::error file=${entry#*$'\t'}::getrackter Symlink — bricht das Laden der Composite-Actions des Katalogs ab (#458). Zur Testlaufzeit anlegen statt einchecken."
done < <(git ls-files -s -z)
wait $! || { echo "check-no-symlinks: git ls-files schlug fehl" >&2; exit 1; }

if (( found )); then
  exit 1
fi

echo "check-no-symlinks: kein getrackter Symlink"
