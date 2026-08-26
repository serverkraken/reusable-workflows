#!/usr/bin/env bats

# scripts/merge-sarif-runs.py collapses one SARIF per scanned platform into a
# single run, because the CodeQL action refuses several runs under one category.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/merge-sarif-runs.py"
  cd "$BATS_TEST_TMPDIR" || exit 1
}

# Writes a SARIF file. $1=path, $2=json array of rule ids, $3=json array of
# [ruleId, ruleIndex, uri] triples for the results.
write_sarif() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, rule_ids, results = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
doc = {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    "version": "2.1.0",
    "runs": [{
        "tool": {"driver": {"name": "Trivy", "version": "0.74.0",
                            "rules": [{"id": r, "shortDescription": {"text": r}} for r in rule_ids]}},
        "results": [{"ruleId": rid, "ruleIndex": idx, "level": "error",
                     "message": {"text": rid},
                     "locations": [{"physicalLocation": {"artifactLocation": {"uri": uri}}}]}
                    for rid, idx, uri in results],
        "columnKind": "utf16CodeUnits",
    }],
}
json.dump(doc, open(path, "w"))
PY
}

@test "merges two platforms into exactly one run" {
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"]]'
  write_sarif b.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"]]'

  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -eq 0 ]

  run python3 -c "import json;print(len(json.load(open('out.sarif'))['runs']))"
  [ "$output" = "1" ]
}

# The regression that broke mailstack's release: a directory of per-platform
# SARIFs reaches code-scanning as several runs sharing one category.
@test "identical findings on both platforms collapse into one" {
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"]]'
  write_sarif b.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"]]'

  python3 "$SCRIPT" out.sarif a.sarif b.sarif
  run python3 -c "import json;print(len(json.load(open('out.sarif'))['runs'][0]['results']))"
  [ "$output" = "1" ]
}

@test "a finding present on only one platform survives" {
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"]]'
  write_sarif b.sarif '["CVE-1","CVE-2"]' '[["CVE-1",0,"pkg-a"],["CVE-2",1,"pkg-b"]]'

  python3 "$SCRIPT" out.sarif a.sarif b.sarif
  run python3 -c "
import json
ids = sorted(r['ruleId'] for r in json.load(open('out.sarif'))['runs'][0]['results'])
print(','.join(ids))"
  [ "$output" = "CVE-1,CVE-2" ]
}

# The load-bearing part: ruleIndex is a position in tool.driver.rules. If the
# second file orders its rules differently, copying the index verbatim would
# point every one of those alerts at the wrong CVE.
@test "ruleIndex is remapped when the inputs order rules differently" {
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"]]'
  write_sarif b.sarif '["CVE-2","CVE-1"]' '[["CVE-2",0,"pkg-b"],["CVE-1",1,"pkg-a"]]'

  python3 "$SCRIPT" out.sarif a.sarif b.sarif
  run python3 -c "
import json
run = json.load(open('out.sarif'))['runs'][0]
rules = run['tool']['driver']['rules']
bad = [r['ruleId'] for r in run['results'] if rules[r['ruleIndex']]['id'] != r['ruleId']]
print('mismatch:' + ','.join(bad) if bad else 'all-consistent')"
  [ "$output" = "all-consistent" ]
}

@test "the same CVE against two different packages stays two findings" {
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"],["CVE-1",0,"pkg-b"]]'

  python3 "$SCRIPT" out.sarif a.sarif
  run python3 -c "import json;print(len(json.load(open('out.sarif'))['runs'][0]['results']))"
  [ "$output" = "2" ]
}

@test "a single input file is passed through as one run" {
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1",0,"pkg-a"]]'

  run python3 "$SCRIPT" out.sarif a.sarif
  [ "$status" -eq 0 ]
  run python3 -c "
import json
d = json.load(open('out.sarif'))
run = d['runs'][0]
print(f\"{len(d['runs'])},{len(run['results'])},{run['tool']['driver']['name']}\")"
  [ "$output" = "1,1,Trivy" ]
}

@test "a result without a ruleId fails loudly instead of guessing an index" {
  python3 - <<'PY'
import json
doc = {"version": "2.1.0", "runs": [{
    "tool": {"driver": {"name": "Trivy", "rules": [{"id": "CVE-1"}]}},
    "results": [{"level": "error", "message": {"text": "no rule id"}}]}]}
json.dump(doc, open("a.sarif", "w"))
PY
  run python3 "$SCRIPT" out.sarif a.sarif
  [ "$status" -ne 0 ]
  [[ "$output" == *"ruleId"* ]]
}

@test "empty results produce a valid single-run document" {
  write_sarif a.sarif '[]' '[]'
  write_sarif b.sarif '[]' '[]'

  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -eq 0 ]
  run python3 -c "
import json
d = json.load(open('out.sarif'))
print(f\"{len(d['runs'])},{len(d['runs'][0]['results'])}\")"
  [ "$output" = "1,0" ]
}

# === Regel-Konflikte (Audit I-2) ===
#
# Bei gleicher Regel-ID gewinnt die erste Definition, und die zweite wird
# verworfen. In `rule` stecken unter anderem `defaultConfiguration.level` und
# die Severity-Tags, die code-scanning anzeigt — ein Konflikt kann den Bericht
# also verfaelschen.
#
# Gemessen tritt das im tatsaechlichen Anwendungsfall NICHT auf: trivy 0.74.0
# gegen node:10-alpine, linux/amd64 und linux/arm64, ergab 63 Regeln je
# Plattform und bei gleicher ID byte-gleichen Inhalt — null Abweichungen.
# Deshalb wird gemeldet statt abgebrochen: ein Abbruch wuerde Scans an einem
# Ereignis brechen, das noch nie beobachtet wurde.

@test "eine Regel mit gleicher ID und anderem Inhalt wird gemeldet" {
  python3 - a.sarif <<'PY'
import json, sys
doc = {"version": "2.1.0", "runs": [{
    "tool": {"driver": {"name": "Trivy", "rules": [
        {"id": "CVE-1", "defaultConfiguration": {"level": "warning"}}]}},
    "results": [{"ruleId": "CVE-1", "ruleIndex": 0, "level": "warning",
                 "message": {"text": "x"}, "locations": []}]}]}
json.dump(doc, open(sys.argv[1], "w"))
PY
  python3 - b.sarif <<'PY'
import json, sys
doc = {"version": "2.1.0", "runs": [{
    "tool": {"driver": {"name": "Trivy", "rules": [
        {"id": "CVE-1", "defaultConfiguration": {"level": "error"}}]}},
    "results": [{"ruleId": "CVE-1", "ruleIndex": 0, "level": "error",
                 "message": {"text": "x"}, "locations": []}]}]}
json.dump(doc, open(sys.argv[1], "w"))
PY

  run python3 "$SCRIPT" merged.sarif a.sarif b.sarif
  [ "$status" -eq 0 ]
  [[ "$output" == *"SARIF rule CVE-1 differs between runs"* ]]
  # Das abweichende Feld muss benannt sein, sonst ist die Warnung nicht
  # nachvollziehbar.
  [[ "$output" == *"defaultConfiguration"* ]]
  # Der Merge laeuft trotzdem durch und behaelt beide Befunde: sie
  # unterscheiden sich im `level` und sind damit zwei Ergebnisse.
  [ "$(jq '.runs[0].results | length' merged.sarif)" -eq 2 ]
}

@test "identische Regeln erzeugen keine Warnung" {
  # Gegenprobe: eine Warnung, die bei jedem Merge erscheint, liest niemand.
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1", 0, "pkg/a"]]'
  write_sarif b.sarif '["CVE-1"]' '[["CVE-1", 0, "pkg/b"]]'
  run python3 "$SCRIPT" merged.sarif a.sarif b.sarif
  [ "$status" -eq 0 ]
  [[ "$output" != *"differs between runs"* ]]
}

# ---------------------------------------------------------------------------
# Audit L-5: artifactLocation.index ist dieselbe Falle wie ruleIndex, eine Ebene
# darueber. Er indiziert in `run.artifacts`, und der zusammengefuehrte Lauf
# behielt nur die Liste des ERSTEN Eingangs. Ein Ergebnis aus der zweiten Datei
# trug seinen alten Index weiter und benannte damit die Datei, die im ersten Lauf
# zufaellig an dieser Stelle stand.
#
# Gemessen: trivy 0.74.0 schreibt gar keine artifacts-Liste (geprueft an einem
# `trivy fs --format sarif`-Lauf; der Schluessel fehlt, Ergebnisse verweisen nur
# ueber uri). Der Pfad schlummert also beim heutigen Scanner — die Tests hier
# sorgen dafuer, dass er trotzdem nicht ungeprueft ist.

# $1=Pfad, $2=json-Array von uris (artifacts), $3=json-Array von
# [ruleId, uri, artifactIndex].
write_sarif_with_artifacts() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, uris, results = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
doc = {
    "version": "2.1.0",
    "runs": [{
        "tool": {"driver": {"name": "Trivy",
                            "rules": [{"id": r} for r, _, _ in results]}},
        "artifacts": [{"location": {"uri": u}} for u in uris],
        "results": [{"ruleId": rid, "ruleIndex": i, "level": "error",
                     "message": {"text": rid},
                     "locations": [{"physicalLocation": {
                         "artifactLocation": {"uri": uri, "index": idx}}}]}
                    for i, (rid, uri, idx) in enumerate(results)],
    }],
}
json.dump(doc, open(path, "w"))
PY
}

# Welche Datei nennt der Fund $2 in der Ausgabe $1 — aufgeloest ueber den Index.
resolved_uri() {
  jq -r --arg id "$2" '.runs[0] as $r
    | $r.results[] | select(.ruleId == $id)
    | $r.artifacts[.locations[0].physicalLocation.artifactLocation.index].location.uri // "AUSSERHALB"' "$1"
}

@test "artifact indices are remapped, not carried over" {
  # Der zweite Lauf kennt eine Datei, die der erste nicht hat, und sein Fund
  # zeigt auf Position 1 SEINER Liste.
  write_sarif_with_artifacts a.sarif '["usr/lib/libssl.so"]' \
    '[["CVE-1","usr/lib/libssl.so",0]]'
  write_sarif_with_artifacts b.sarif '["usr/lib/libssl.so","usr/bin/curl"]' \
    '[["CVE-2","usr/bin/curl",1]]'

  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(resolved_uri out.sarif CVE-1)" = "usr/lib/libssl.so" ]
  [ "$(resolved_uri out.sarif CVE-2)" = "usr/bin/curl" ]
  # Gleiche Datei in beiden Laeufen kollabiert, die neue kommt dazu.
  [ "$(jq '.runs[0].artifacts | length' out.sarif)" -eq 2 ]
}

# Der boesere Fall: der erste Lauf hat genug Artefakte, dass der uebernommene
# Index NICHT ins Leere zeigt, sondern auf eine existierende, falsche Datei.
# Ohne Umschreiben wurde der curl-Fund der README zugeschrieben — still, ohne
# Fehler, mitten im code-scanning-Bericht.
@test "a carried-over index would name a real but wrong file" {
  write_sarif_with_artifacts a.sarif '["usr/lib/libssl.so","README.md"]' \
    '[["CVE-1","usr/lib/libssl.so",0]]'
  write_sarif_with_artifacts b.sarif '["usr/lib/libssl.so","usr/bin/curl"]' \
    '[["CVE-2","usr/bin/curl",1]]'

  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(resolved_uri out.sarif CVE-2)" = "usr/bin/curl" ]
  [ "$(resolved_uri out.sarif CVE-2)" != "README.md" ]
}

@test "parentIndex is remapped along with the artifact list" {
  python3 - <<'PY'
import json
def doc(uris, parents, results):
    arts = [{"location": {"uri": u}} for u in uris]
    for child, parent in parents.items():
        arts[child]["parentIndex"] = parent
    return {"version": "2.1.0", "runs": [{
        "tool": {"driver": {"name": "T", "rules": [{"id": r} for r, _, _ in results]}},
        "artifacts": arts,
        "results": [{"ruleId": r, "ruleIndex": i, "level": "error",
                     "message": {"text": r},
                     "locations": [{"physicalLocation": {
                         "artifactLocation": {"uri": u, "index": idx}}}]}
                    for i, (r, u, idx) in enumerate(results)]}]}
json.dump(doc(["app.jar"], {}, [["CVE-1", "app.jar", 0]]), open("a.sarif", "w"))
# Zweiter Lauf: app.jar plus ein darin enthaltenes Element, dessen parentIndex
# auf Position 0 SEINER Liste zeigt.
json.dump(doc(["app.jar", "app.jar!/lib/x.jar"], {1: 0},
              [["CVE-2", "app.jar!/lib/x.jar", 1]]), open("b.sarif", "w"))
PY
  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(resolved_uri out.sarif CVE-2)" = "app.jar!/lib/x.jar" ]
  # parentIndex muss auf app.jar zeigen, nicht auf sich selbst oder ins Leere.
  local parent
  parent="$(jq -r '.runs[0] as $r
    | ($r.artifacts | to_entries[] | select(.value.location.uri == "app.jar!/lib/x.jar") | .value.parentIndex) as $p
    | $r.artifacts[$p].location.uri' out.sarif)"
  [ "$parent" = "app.jar" ]
}

# Ein Index, der in seinem eigenen Lauf gar nicht existiert, ist kaputte
# Eingabe — daran darf nicht weitergerechnet werden.
@test "an artifact index outside its own run fails loudly" {
  write_sarif_with_artifacts a.sarif '["only.txt"]' '[["CVE-1","only.txt",0]]'
  write_sarif_with_artifacts b.sarif '["only.txt"]' '[["CVE-2","ghost.txt",7]]'

  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -ne 0 ]
  [[ "$output" == *"artifact index 7"* ]] || { echo "$output"; false; }
}

# trivy schreibt keine artifacts. Der Merger darf dann auch keine erfinden —
# sonst traegt die hochgeladene Datei ein leeres Feld, das vorher nicht da war.
@test "inputs without artifacts produce no artifacts key" {
  write_sarif a.sarif '["CVE-1"]' '[["CVE-1",0,"a.txt"]]'
  write_sarif b.sarif '["CVE-2"]' '[["CVE-2",0,"b.txt"]]'

  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -eq 0 ]
  [ "$(jq '.runs[0] | has("artifacts")' out.sarif)" = "false" ]
}

# Das Umschreiben geschieht in place — ohne tiefe Kopie veraenderte es das
# Eingabedokument mit, und ein zweiter Aufruf saehe bereits umgeschriebene Werte.
@test "merging does not mutate the input documents" {
  write_sarif_with_artifacts a.sarif '["x"]' '[["CVE-1","x",0]]'
  write_sarif_with_artifacts b.sarif '["x","y"]' '[["CVE-2","y",1]]'
  local before; before="$(cat b.sarif)"

  run python3 "$SCRIPT" out.sarif a.sarif b.sarif
  [ "$status" -eq 0 ]
  [ "$(cat b.sarif)" = "$before" ]
}
