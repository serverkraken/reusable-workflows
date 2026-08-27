#!/usr/bin/env bats

# scripts/tf-vars-env.sh wandelt das `tf_vars`-Secret in TF_VAR_*-Variablen.
# Der Inhalt ist ein Geheimnis aus der Aufruferseite — der Parser muss ihn
# als feindlich behandeln, sonst ist er ein Env-Injection-Vektor.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tf-vars-env.sh"
  cd "$BATS_TEST_TMPDIR" || exit 1
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
}

@test "einfache Zuweisung wird zu TF_VAR_ mit Maske" {
  run bash -c "printf 'hcloud_token=abc123\n' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::abc123"* ]]
  grep -qx 'TF_VAR_hcloud_token=abc123' "$GITHUB_ENV"
}

@test "leere Zeilen und Kommentare werden uebersprungen" {
  run bash -c "printf '\n# kommentar\nfoo=bar\n' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  grep -qx 'TF_VAR_foo=bar' "$GITHUB_ENV"
  [ "$(grep -c '^TF_VAR_' "$GITHUB_ENV")" -eq 1 ]
}

# Werte duerfen alles enthalten — auch `=`. Nur am ERSTEN `=` wird getrennt.
@test "Wert mit Gleichheitszeichen bleibt vollstaendig" {
  run bash -c "printf 'url=https://x/?a=1&b=2\n' | bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  grep -qx 'TF_VAR_url=https://x/?a=1&b=2' "$GITHUB_ENV"
}

# Der Kern: ein Schluessel, der kein gueltiger Variablenname ist, koennte
# beliebige Env-Zeilen erzeugen. Er muss den Lauf abbrechen, nicht nur die
# Zeile ueberspringen — stilles Verwerfen sieht aus wie "Variable gesetzt".
@test "ungueltiger Schluessel bricht ab" {
  run bash -c "printf 'not-a-valid-name=x\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ungueltiger Variablenname"* ]]
}

@test "Schluessel mit Leerzeichen bricht ab" {
  run bash -c "printf 'foo bar=x\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
}

@test "leerer Schluessel bricht ab" {
  run bash -c "printf '=value\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
}

# Eine Zeile ohne `=` ist keine Zuweisung. Sie stillschweigend zu ignorieren
# hiesse, eine erwartete Variable fehlte spaeter kommentarlos.
@test "Zeile ohne Gleichheitszeichen bricht ab" {
  run bash -c "printf 'kaputt\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
}

# GITHUB_ENV ist zeilenbasiert. Der Input wird Zeile fuer Zeile gelesen.
# Ein mehrzeiliger Secret wird daher in separate Kandidaten zerlegt.
# Das TF_VAR_-Praefix schuetzt davor, dass eine dieser Zeilen eine bestehende
# Runner-Variable (wie PATH) ueberschreiben koennte.
@test "mehrzeiliger Payload wird in getrennte Zuweisungen zerlegt — das TF_VAR_-Praefix schuetzt vor Uebernahme" {
  printf 'a=1\nPATH=/evil\n' > payload.txt
  run bash -c "bash '$SCRIPT' < payload.txt"
  [ "$status" -eq 0 ]
  grep -qx 'TF_VAR_PATH=/evil' "$GITHUB_ENV"
  ! grep -qx 'PATH=/evil' "$GITHUB_ENV"
}
