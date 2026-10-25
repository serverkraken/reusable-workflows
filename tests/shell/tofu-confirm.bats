#!/usr/bin/env bats

# scripts/tofu-confirm.sh ist die letzte Huerde vor einem Destroy oder einem
# force-unlock. Ueber einen Workflow ist sie nicht pruefbar: beide Atome
# laufen nur unter workflow_dispatch, die Self-CI auf pull_request und das
# Nightly auf schedule — der Event-Riegel schlaegt dort zuerst zu. Deshalb
# haengt die Abdeckung dieser Logik allein an dieser Datei.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/tofu-confirm.sh"
}

@test "DESTROY: exakter Text wird akzeptiert" {
  run bash "$SCRIPT" DESTROY serverkraken/homelab-hetzner tofu -- "DESTROY serverkraken/homelab-hetzner tofu"
  [ "$status" -eq 0 ]
  [[ "$output" == *"akzeptiert"* ]]
}

@test "DESTROY: falscher State wird abgelehnt" {
  run bash "$SCRIPT" DESTROY serverkraken/homelab-hetzner prod -- "DESTROY serverkraken/homelab-hetzner tofu"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DESTROY serverkraken/homelab-hetzner prod"* ]]
}

@test "DESTROY: falsches Repo wird abgelehnt" {
  run bash "$SCRIPT" DESTROY serverkraken/homelab-hetzner tofu -- "DESTROY serverkraken/anderes-repo tofu"
  [ "$status" -eq 1 ]
}

# Der haeufigste Tippfehler ueberhaupt, und einer, der bei einem lockeren
# Vergleich durchginge.
@test "DESTROY: fuehrende oder abschliessende Leerzeichen werden abgelehnt" {
  run bash "$SCRIPT" DESTROY serverkraken/repo tofu -- " DESTROY serverkraken/repo tofu"
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" DESTROY serverkraken/repo tofu -- "DESTROY serverkraken/repo tofu "
  [ "$status" -eq 1 ]
}

@test "DESTROY: Kleinschreibung wird abgelehnt" {
  run bash "$SCRIPT" DESTROY serverkraken/repo tofu -- "destroy serverkraken/repo tofu"
  [ "$status" -eq 1 ]
}

@test "DESTROY: leere Eingabe wird abgelehnt" {
  run bash "$SCRIPT" DESTROY serverkraken/repo tofu -- ""
  [ "$status" -eq 1 ]
}

# Nur das Verzeichnis abzutippen waere die schwache Variante, gegen die dieses
# Format gebaut ist.
@test "DESTROY: nur der State-Name reicht nicht" {
  run bash "$SCRIPT" DESTROY serverkraken/repo tofu -- "tofu"
  [ "$status" -eq 1 ]
}

@test "UNLOCK: exakter Text mit Lock-ID wird akzeptiert" {
  run bash "$SCRIPT" UNLOCK serverkraken/repo tofu 1f2e3d4c -- "UNLOCK serverkraken/repo tofu 1f2e3d4c"
  [ "$status" -eq 0 ]
}

# Der Fall, gegen den die Lock-ID in der Bestaetigung ueberhaupt steht: wer
# eine ALTE ID abtippt, loest womoeglich den Lock eines noch laufenden Applys.
@test "UNLOCK: falsche Lock-ID wird abgelehnt" {
  run bash "$SCRIPT" UNLOCK serverkraken/repo tofu 1f2e3d4c -- "UNLOCK serverkraken/repo tofu aaaabbbb"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1f2e3d4c"* ]]
}

@test "UNLOCK: fehlende Lock-ID in der Eingabe wird abgelehnt" {
  run bash "$SCRIPT" UNLOCK serverkraken/repo tofu 1f2e3d4c -- "UNLOCK serverkraken/repo tofu"
  [ "$status" -eq 1 ]
}

# Ohne diese Pruefung entstuende ein erwarteter Text mit einer Luecke, den man
# leichter zufaellig trifft.
@test "leerer State-Name bricht ab, statt eine Luecke zu erlauben" {
  run bash "$SCRIPT" DESTROY serverkraken/repo "" -- "DESTROY serverkraken/repo "
  [ "$status" -eq 1 ]
  [[ "$output" == *"duerfen nicht leer sein"* ]]
}

@test "unbekannte Aktion bricht mit Nutzungshinweis ab" {
  run bash "$SCRIPT" VERNICHTE serverkraken/repo tofu -- "egal"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Aufruf:"* ]]
}

# Der Trenner haelt die Stelligkeit fest, auch wenn die Eingabe selbst wie
# weitere Argumente aussieht.
@test "eine Eingabe mit Leerzeichen verschiebt die Stelligkeit nicht" {
  run bash "$SCRIPT" DESTROY serverkraken/repo tofu -- "DESTROY serverkraken/repo tofu extra"
  [ "$status" -eq 1 ]
}
