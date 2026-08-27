#!/usr/bin/env bats

# scripts/tf-vars-env.sh wandelt das `tf_vars`-Secret in eine sourcebare Datei
# mit TF_VAR_*-Zuweisungen. Der Inhalt ist ein Geheimnis aus der Aufruferseite
# — der Parser muss ihn als feindlich behandeln, sonst ist er ein
# Injection-Vektor. Seit die Ausgabe GESOURCT statt in $GITHUB_ENV geschrieben
# wird, ist das woertlich zu nehmen: eine schlecht gequotete Zeile waere
# Code-Ausfuehrung im Plan-Schritt, nicht nur eine falsche Variable.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tf-vars-env.sh"
  cd "$BATS_TEST_TMPDIR" || exit 1
  OUT="$BATS_TEST_TMPDIR/tf-vars.env"
}

# Der Aufrufer macht `set -a; . <datei>; set +a`. Genauso wird hier geprueft:
# ein Test gegen den Dateitext allein saehe kaputtes Quoting nicht.
sourced() {
  ( set -a; . "$OUT"; set +a; eval "printf '%s' \"\${$1-}\"" )
}

@test "einfache Zuweisung wird zu TF_VAR_ mit Maske" {
  run bash -c "printf 'hcloud_token=abc123\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::abc123"* ]]
  [ "$(sourced TF_VAR_hcloud_token)" = "abc123" ]
}

@test "leere Zeilen und Kommentare werden uebersprungen" {
  run bash -c "printf '\n# kommentar\nfoo=bar\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -eq 0 ]
  [ "$(sourced TF_VAR_foo)" = "bar" ]
  [ "$(grep -c '^TF_VAR_' "$OUT")" -eq 1 ]
}

# Werte duerfen alles enthalten — auch `=`. Nur am ERSTEN `=` wird getrennt.
@test "Wert mit Gleichheitszeichen bleibt vollstaendig" {
  run bash -c "printf 'url=https://x/?a=1&b=2\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -eq 0 ]
  [ "$(sourced TF_VAR_url)" = "https://x/?a=1&b=2" ]
}

# Der Kern: ein Schluessel, der kein gueltiger Variablenname ist, koennte
# beliebige Zeilen erzeugen. Er muss den Lauf abbrechen, nicht nur die
# Zeile ueberspringen — stilles Verwerfen sieht aus wie "Variable gesetzt".
@test "ungueltiger Schluessel bricht ab" {
  run bash -c "printf 'not-a-valid-name=x\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ungueltiger Variablenname"* ]]
}

@test "Schluessel mit Leerzeichen bricht ab" {
  run bash -c "printf 'foo bar=x\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -ne 0 ]
}

@test "leerer Schluessel bricht ab" {
  run bash -c "printf '=value\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -ne 0 ]
}

# Eine Zeile ohne `=` ist keine Zuweisung. Sie stillschweigend zu ignorieren
# hiesse, eine erwartete Variable fehlte spaeter kommentarlos.
@test "Zeile ohne Gleichheitszeichen bricht ab" {
  run bash -c "printf 'kaputt\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -ne 0 ]
}

# Der Input wird Zeile fuer Zeile gelesen. Ein mehrzeiliger Secret wird daher
# in separate Kandidaten zerlegt. Das TF_VAR_-Praefix schuetzt davor, dass eine
# dieser Zeilen eine bestehende Runner-Variable (wie PATH) ueberschreiben
# koennte.
@test "mehrzeiliger Payload wird in getrennte Zuweisungen zerlegt — das TF_VAR_-Praefix schuetzt vor Uebernahme" {
  printf 'a=1\nPATH=/evil\n' > payload.txt
  run bash -c "bash '$SCRIPT' '$OUT' < payload.txt"
  [ "$status" -eq 0 ]
  [ "$(sourced TF_VAR_PATH)" = "/evil" ]
  ! grep -qx "PATH='/evil'" "$OUT"
}

# CRLF: der eigentliche Fund. `read -r` liefert bei einem mit
# Windows-Zeilenenden geschriebenen Secret `wert\r`. Maskiert wuerde dann
# GENAU dieser String — GitHub maskiert nur exakte Treffer, und tofu gibt
# spaeter `wert` ohne CR aus. Der Wert stuende im Klartext im Log und im
# PR-Kommentar, waehrend die Maske aussaehe, als griffe sie.
@test "CRLF-Zeile liefert den Wert ohne CR — und maskiert ihn ohne CR" {
  run bash -c "printf 'token=geheim\r\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -eq 0 ]
  [ "$(sourced TF_VAR_token)" = "geheim" ]
  # Die Maske darf kein CR tragen, sonst maskiert sie den falschen String.
  [[ "$output" == *"::add-mask::geheim"* ]]
  printf '%s' "$output" | grep -q $'::add-mask::geheim\r' && return 1
  return 0
}

# Die Datei wird GESOURCT. Ein Wert mit einfachem Anfuehrungszeichen darf
# dabei nicht aus seinem Quoting ausbrechen — sonst waere jedes tf_vars-Secret
# ein Weg, im Plan-Schritt beliebige Befehle auszufuehren.
@test "Wert mit Anfuehrungszeichen bricht nicht aus dem Quoting aus" {
  run bash -c "printf \"evil=x'; touch PWNED; :'\n\" | bash '$SCRIPT' '$OUT'"
  [ "$status" -eq 0 ]
  [ "$(sourced TF_VAR_evil)" = "x'; touch PWNED; :'" ]
  [ ! -e PWNED ]
}

@test "Wert mit Leerzeichen ueberlebt das Sourcen als EIN Wert" {
  run bash -c "printf 'msg=zwei woerter\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -eq 0 ]
  [ "$(sourced TF_VAR_msg)" = "zwei woerter" ]
}

# Die Datei traegt Klartext-Secrets. Auf dem self-hosted Pool ist der
# Runner-Benutzer nicht allein auf der Maschine.
@test "Ausgabedatei ist nur fuer den Besitzer lesbar" {
  run bash -c "printf 'a=1\n' | bash '$SCRIPT' '$OUT'"
  [ "$status" -eq 0 ]
  perms=$(stat -f '%Lp' "$OUT" 2>/dev/null || stat -c '%a' "$OUT")
  [ "$perms" = "600" ]
}

@test "fehlende Ausgabedatei als Argument bricht ab" {
  run bash -c "printf 'a=1\n' | bash '$SCRIPT'"
  [ "$status" -ne 0 ]
}
