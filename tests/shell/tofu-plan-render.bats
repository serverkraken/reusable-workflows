#!/usr/bin/env bats

# scripts/tofu-plan-render.sh kuerzt die Plan-Ausgabe auf ein Zeichenlimit.
# GitHub nimmt maximal 65536 Zeichen pro Kommentar; ein zu langer Plan wuerde
# den Kommentar-Aufruf scheitern lassen, statt gekuerzt anzukommen.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tofu-plan-render.sh"
  cd "$BATS_TEST_TMPDIR" || exit 1
}

@test "kurzer Plan geht unveraendert durch" {
  printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n' > plan.txt
  run bash "$SCRIPT" plan.txt 1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 to add"* ]]
  [[ "$output" != *"gekuerzt"* ]]
}

@test "langer Plan wird gekuerzt und sagt es" {
  for i in $(seq 1 500); do echo "  # resource.line_${i} will be created"; done > plan.txt
  run bash "$SCRIPT" plan.txt 500
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 900 ]
  [[ "$output" == *"gekuerzt"* ]]
}

# Kopf UND Fuss muessen erhalten bleiben: oben steht, was geaendert wird,
# unten die Zusammenfassungszeile. Nur den Kopf zu behalten verwuerfe genau
# die Zeile, auf die im Review geschaut wird.
@test "Kuerzung behaelt Anfang und Ende" {
  { echo "ERSTE-ZEILE"; for i in $(seq 1 500); do echo "fuellung_${i}"; done; echo "Plan: 3 to add, 0 to change, 0 to destroy."; } > plan.txt
  run bash "$SCRIPT" plan.txt 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERSTE-ZEILE"* ]]
  [[ "$output" == *"3 to add"* ]]
}

@test "fehlende Datei bricht ab" {
  run bash "$SCRIPT" gibtsnicht.txt 500
  [ "$status" -ne 0 ]
}

# Ohne Backticks im Plan bleibt es beim gewohnten dreifachen Zaun.
@test "Zaun ist dreifach, wenn der Plan keine Backticks enthaelt" {
  printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n' > plan.txt
  run bash "$SCRIPT" plan.txt 1000
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = '```' ]
  [ "$(printf '%s\n' "$output" | tail -1)" = '```' ]
}

# Der Kern: der Planinhalt ist Adopter-Text. Enthaelt ein Output-Wert eine
# Zeile aus drei Backticks, schloesse ein fester ```-Zaun genau dort — und
# alles danach (`</details>`, ein Markdown-Link) rendert als ECHTES Markdown
# im Kommentar des Bots. Der Zaun muss deshalb laenger sein als die laengste
# Backtick-Folge im Inhalt.
@test "Plan mit eigenem Code-Zaun kann nicht ausbrechen" {
  printf 'vorher\n```\n</details>\n[phish](https://example.invalid)\nnachher\n' > plan.txt
  run bash "$SCRIPT" plan.txt 10000
  [ "$status" -eq 0 ]
  first="$(printf '%s\n' "$output" | head -1)"
  last="$(printf '%s\n' "$output" | tail -1)"
  # Vier Backticks: eins mehr als die laengste Folge im Inhalt.
  [ "$first" = '````' ]
  [ "$last" = '````' ]
  # Keine Zeile DAZWISCHEN darf den Block schliessen koennen, also keine
  # Zeile darf so lang oder laenger sein als der Zaun.
  inner="$(printf '%s\n' "$output" | sed '1d;$d')"
  ! printf '%s\n' "$inner" | grep -qx '`\{4,\}'
  # Der Inhalt ist vollstaendig da — gekuerzt wurde nichts.
  [[ "$output" == *"</details>"* ]]
  [[ "$output" == *"nachher"* ]]
}

# Auch gegen laengere Folgen: der Zaun waechst mit.
@test "Zaun waechst ueber die laengste Backtick-Folge hinaus" {
  printf 'a\n`````\nb\n' > plan.txt
  run bash "$SCRIPT" plan.txt 10000
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = '``````' ]
  [ "$(printf '%s\n' "$output" | tail -1)" = '``````' ]
}

# Nach `tail -c` endet der gekuerzte Inhalt nicht zwingend mit einem
# Zeilenumbruch. Ohne den stuende der schliessende Zaun am Ende der letzten
# Inhaltszeile und waere keiner mehr.
@test "schliessender Zaun steht auch nach Kuerzung auf eigener Zeile" {
  printf 'x%.0s' $(seq 1 400) > plan.txt
  run bash "$SCRIPT" plan.txt 100
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = '```' ]
}
