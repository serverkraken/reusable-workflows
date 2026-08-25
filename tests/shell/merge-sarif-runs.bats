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
