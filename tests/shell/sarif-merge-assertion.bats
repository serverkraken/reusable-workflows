#!/usr/bin/env bats

# Die Assertion `Assert one SARIF run and a merged JSON report` aus
# integration.yml, gegen synthetische Merge-Ergebnisse.
#
# Warum getrennt vom CI-Job: der Job laeuft gegen echte Trivy-Artefakte und
# sieht deshalb nur den Gutfall. Ein Merge, der alles verwirft oder alles
# doppelt zaehlt, laesst sich in CI nicht herbeifuehren — und genau die waren
# es, die durchrutschten.
#
# Der Fund (K-19): geprueft wurden Run-Anzahl, Rule-Indizes, JSON-Praesenz und
# Plattform-Anzahl — nie die ERGEBNIS-Anzahl. Auf einer leeren Ergebnisliste
# ist die Rule-Index-Pruefung vakuum-wahr. Gegen den Stand davor gemessen:
#
#   normal (7 Ergebnisse, dedupliziert)   bestand
#   leer (Merge verwarf alles)            bestand   <- falsch
#   doppelt (konkateniert statt dedupt)   bestand   <- falsch
#   zuviel (mehr als beide Plattformen)   bestand   <- falsch
#
# Getestet wird der ausgelieferte run-Rumpf, aus der YAML gezogen — eine Kopie
# im Test wuerde nur beweisen, dass die Kopie stimmt.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORK="$(mktemp -d)"

  python3 - "$REPO_ROOT/.github/workflows/integration.yml" > "$WORK/assert.sh" <<'PY'
import sys

lines = open(sys.argv[1]).read().splitlines()
needle = "- name: Assert one SARIF run and a merged JSON report"
start = next((i for i, l in enumerate(lines) if l.strip() == needle), None)
if start is None:
    sys.exit(f"step not found: {needle}")
for i in range(start, len(lines)):
    if lines[i].strip() in ("run: |", "run: |-"):
        indent = len(lines[i]) - len(lines[i].lstrip()) + 2
        body = []
        for raw in lines[i + 1:]:
            if raw.strip() and len(raw) - len(raw.lstrip()) < indent:
                break
            body.append(raw[indent:] if len(raw) >= indent else "")
        print("\n".join(body))
        sys.exit(0)
sys.exit("no run block under that step")
PY
  [ -s "$WORK/assert.sh" ]
}

teardown() {
  rm -rf "$WORK"
}

# $1 = Fallname, $2 = Ergebnisse im Merge, $3 = ja|nein (jedes Finding doppelt),
# $4/$5 = Ergebnisse je Plattform. Die Findings tragen echte Dedup-Schluessel
# ([ruleId, level, message.text, locations]) — denselben, den
# scripts/merge-sarif-runs.py verwendet.
make_case() {
  local dir="$WORK/$1"
  mkdir -p "$dir/report/trivy-sarif"
  python3 - "$dir/report" "$2" "$3" "$4" "$5" <<'PY'
import json, os, sys

rep, merged_n, dup, p1, p2 = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])

def doc(n, duplicate=False):
    rules = [{"id": f"CVE-2020-{1000 + i}"} for i in range(max(n, 1))]
    res = [{
        "ruleId": f"CVE-2020-{1000 + i}",
        "level": "error",
        "message": {"text": f"finding {i}"},
        "locations": [{"physicalLocation": {"artifactLocation": {"uri": f"pkg/{i}"}}}],
        "ruleIndex": i,
    } for i in range(n)]
    if duplicate:
        res = res + [dict(r) for r in res]
    return {"runs": [{"tool": {"driver": {"rules": rules}}, "results": res}]}

json.dump(doc(merged_n, dup == "ja"), open(os.path.join(rep, "trivy-image.sarif"), "w"))
json.dump({"Results": []}, open(os.path.join(rep, "trivy-image.json"), "w"))
for name, n in (("linux-amd64", p1), ("linux-arm64", p2)):
    json.dump(doc(n), open(os.path.join(rep, "trivy-sarif", f"{name}.sarif"), "w"))
PY
  echo "$dir"
}

@test "ein sauber deduplizierter Merge besteht" {
  # Gegenprobe zu den drei Defektfaellen: waere die Assertion zu scharf, wuerde
  # sie alles abweisen und die Tests unten blieben trotzdem gruen.
  d=$(make_case normal 7 nein 7 7)
  run bash -c "cd '$d' && bash '$WORK/assert.sh'"
  [ "$status" -eq 0 ]
}

@test "ein Merge ohne jedes Ergebnis faellt durch" {
  d=$(make_case leer 0 nein 7 7)
  run bash -c "cd '$d' && bash '$WORK/assert.sh'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"0 results"* ]]
}

@test "doppelt gezaehlte Findings fallen durch" {
  d=$(make_case doppelt 7 ja 7 7)
  run bash -c "cd '$d' && bash '$WORK/assert.sh'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"twice"* ]]
}

@test "mehr Ergebnisse als beide Plattformen zusammen meldeten faellt durch" {
  d=$(make_case zuviel 20 nein 7 7)
  run bash -c "cd '$d' && bash '$WORK/assert.sh'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"in total"* ]]
}
