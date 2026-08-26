#!/usr/bin/env bats

# scripts/merge-trivy-json.py folds one Trivy JSON report per scanned platform
# into the single report the summary, the findings table, the annotations and
# the gate all read.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/merge-trivy-json.py"
  cd "$BATS_TEST_TMPDIR" || exit 1
}

# $1=path, $2=Target, $3=json array of [VulnerabilityID, PkgName, Severity]
write_report() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, target, vulns = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
doc = {
    "SchemaVersion": 2,
    "ArtifactName": "example:latest",
    "Results": [{
        "Target": target, "Class": "os-pkgs", "Type": "alpine",
        "Vulnerabilities": [
            {"VulnerabilityID": v, "PkgID": f"{p}@1.0", "PkgName": p,
             "InstalledVersion": "1.0", "Severity": s}
            for v, p, s in vulns
        ],
    }],
}
json.dump(doc, open(path, "w"))
PY
}

count_vulns() {
  python3 -c "
import json
d = json.load(open('$1'))
print(sum(len(r.get('Vulnerabilities') or []) for r in d['Results']))"
}

# The bug this script exists for: summing per-platform files reported four
# findings on an image that has two.
@test "a finding present on both platforms counts once" {
  write_report amd64.json 'alpine:3.19 (alpine 3.19)' '[["CVE-1","musl","HIGH"],["CVE-2","zlib","CRITICAL"]]'
  write_report arm64.json 'alpine:3.19 (alpine 3.19)' '[["CVE-1","musl","HIGH"],["CVE-2","zlib","CRITICAL"]]'

  run python3 "$SCRIPT" out.json amd64.json arm64.json
  [ "$status" -eq 0 ]

  run count_vulns out.json
  [ "$output" = "2" ]
}

# The reason the scan runs per platform at all: for an arm64 cluster, an
# amd64-only scan checks an image that never ships.
@test "a finding present on only one platform survives" {
  write_report amd64.json 'alpine:3.19 (alpine 3.19)' '[["CVE-1","musl","HIGH"]]'
  write_report arm64.json 'alpine:3.19 (alpine 3.19)' '[["CVE-1","musl","HIGH"],["CVE-ARM","openssl","CRITICAL"]]'

  python3 "$SCRIPT" out.json amd64.json arm64.json
  run python3 -c "
import json
ids = sorted(v['VulnerabilityID'] for r in json.load(open('out.json'))['Results'] for v in r['Vulnerabilities'])
print(','.join(ids))"
  [ "$output" = "CVE-1,CVE-ARM" ]
}

@test "the same CVE against two packages stays two findings" {
  write_report amd64.json 'alpine:3.19 (alpine 3.19)' '[["CVE-1","musl","HIGH"],["CVE-1","zlib","HIGH"]]'

  python3 "$SCRIPT" out.json amd64.json
  run count_vulns out.json
  [ "$output" = "2" ]
}

@test "different targets stay separate results" {
  write_report amd64.json 'alpine:3.19 (alpine 3.19)' '[["CVE-1","musl","HIGH"]]'
  write_report arm64.json 'usr/bin/app' '[["CVE-2","app","HIGH"]]'

  python3 "$SCRIPT" out.json amd64.json arm64.json
  run python3 -c "
import json
print(len(json.load(open('out.json'))['Results']))"
  [ "$output" = "2" ]
}

@test "top-level report metadata is preserved" {
  write_report amd64.json 'alpine:3.19 (alpine 3.19)' '[["CVE-1","musl","HIGH"]]'

  python3 "$SCRIPT" out.json amd64.json
  run python3 -c "
import json
d = json.load(open('out.json'))
print(f\"{d['SchemaVersion']},{d['ArtifactName']}\")"
  [ "$output" = "2,example:latest" ]
}

@test "a report with no findings yields an empty but valid report" {
  write_report amd64.json 'alpine:3.19 (alpine 3.19)' '[]'
  write_report arm64.json 'alpine:3.19 (alpine 3.19)' '[]'

  run python3 "$SCRIPT" out.json amd64.json arm64.json
  [ "$status" -eq 0 ]
  run count_vulns out.json
  [ "$output" = "0" ]
}

# The gate reads the merged file with a plain jq expression; keep the shape it
# expects even when Trivy emits no Results at all.
@test "a report without a Results key does not break the gate expression" {
  python3 -c "import json;json.dump({'SchemaVersion':2},open('a.json','w'))"

  run python3 "$SCRIPT" out.json a.json
  [ "$status" -eq 0 ]
  run bash -c "jq '[.Results[]? | (.Vulnerabilities // []) + (.Secrets // []) + (.Misconfigurations // []) | length] | add // 0' out.json"
  [ "$output" = "0" ]
}

@test "secrets and misconfigurations are merged and deduped too" {
  python3 - <<'PY'
import json
def doc(path):
    json.dump({"SchemaVersion": 2, "Results": [{
        "Target": "t", "Class": "secret", "Type": "",
        "Secrets": [{"RuleID": "aws-key", "Category": "AWS", "Title": "AWS key",
                     "StartLine": 3, "EndLine": 3}],
        "Misconfigurations": [{"ID": "DS002", "AVDID": "AVD-DS-0002",
                               "Namespace": "ns", "Query": "q"}],
    }]}, open(path, "w"))
doc("a.json"); doc("b.json")
PY
  python3 "$SCRIPT" out.json a.json b.json
  run python3 -c "
import json
r = json.load(open('out.json'))['Results'][0]
print(f\"{len(r['Secrets'])},{len(r['Misconfigurations'])}\")"
  [ "$output" = "1,1" ]
}

# Found by the 2026-08-25 audit: keying a misconfiguration on the rule alone
# collapsed two violations of the same rule at different places in one file
# into one, under-counting the gate and losing an annotation.
@test "two violations of one rule at different lines stay two findings" {
  python3 - <<'PY'
import json
json.dump({"SchemaVersion": 2, "Results": [{
    "Target": "Dockerfile", "Class": "config", "Type": "dockerfile",
    "Misconfigurations": [
        {"ID": "DS002", "AVDID": "AVD-DS-0002", "Namespace": "ns", "Query": "q",
         "CauseMetadata": {"StartLine": 3, "EndLine": 3}},
        {"ID": "DS002", "AVDID": "AVD-DS-0002", "Namespace": "ns", "Query": "q",
         "CauseMetadata": {"StartLine": 42, "EndLine": 42}},
    ]}]}, open("a.json", "w"))
PY
  run python3 "$SCRIPT" out.json a.json
  [ "$status" -eq 0 ]
  run python3 -c "
import json
print(len(json.load(open('out.json'))['Results'][0]['Misconfigurations']))"
  [ "$output" = "2" ]
}

# The same violation seen on both architectures is still ONE finding — that is
# what the merge exists for.
@test "the same violation on two platforms collapses to one" {
  python3 - <<'PY'
import json
doc = {"SchemaVersion": 2, "Results": [{
    "Target": "Dockerfile", "Class": "config", "Type": "dockerfile",
    "Misconfigurations": [
        {"ID": "DS002", "AVDID": "AVD-DS-0002", "Namespace": "ns", "Query": "q",
         "CauseMetadata": {"StartLine": 3, "EndLine": 3}}]}]}
json.dump(doc, open("a.json", "w"))
json.dump(doc, open("b.json", "w"))
PY
  run python3 "$SCRIPT" out.json a.json b.json
  [ "$status" -eq 0 ]
  run python3 -c "
import json
print(len(json.load(open('out.json'))['Results'][0]['Misconfigurations']))"
  [ "$output" = "1" ]
}

# Without CauseMetadata there is no location to key on; the rule identity must
# still dedupe rather than fall back to keeping everything.
@test "a misconfiguration without CauseMetadata still dedupes" {
  python3 - <<'PY'
import json
json.dump({"SchemaVersion": 2, "Results": [{
    "Target": "t", "Class": "config", "Type": "dockerfile",
    "Misconfigurations": [
        {"ID": "X", "AVDID": "A", "Namespace": "n", "Query": "q"},
        {"ID": "X", "AVDID": "A", "Namespace": "n", "Query": "q"},
    ]}]}, open("a.json", "w"))
PY
  run python3 "$SCRIPT" out.json a.json
  [ "$status" -eq 0 ]
  run python3 -c "
import json
print(len(json.load(open('out.json'))['Results'][0]['Misconfigurations']))"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Audit L-6: die Identitaet entscheidet, WAS ein Duplikat ist — sie sagt nichts
# darueber, ob das Duplikat dasselbe AUSSAGT. Zwei Plattform-Berichte koennten
# denselben CVE am selben Paket melden und sich in Severity oder FixedVersion
# unterscheiden; der zweite fiel stillschweigend weg, und das Gate entschied
# dann an einer Severity, die nur eine Plattform gesehen hat.
#
# Gemessen tritt das nicht auf: trivy 0.74.0 gegen node:10-alpine, amd64 und
# arm64, ergab 76 Schwachstellen je Plattform, 76 gemeinsame Identitaeten und
# null Abweichungen. Deshalb gemeldet statt abgebrochen — dieselbe Antwort wie
# beim Regelkonflikt in merge-sarif-runs.py.

# $1=Pfad, $2=Severity, $3=FixedVersion
write_one_vuln() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, sev, fixed = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"SchemaVersion": 2, "ArtifactName": "example:latest",
  "Results": [{"Target": "example (alpine 3.19)", "Class": "os-pkgs", "Type": "alpine",
    "Vulnerabilities": [{"VulnerabilityID": "CVE-2024-1", "PkgID": "musl@1.2",
      "PkgName": "musl", "InstalledVersion": "1.2.4",
      "Severity": sev, "FixedVersion": fixed, "Status": "fixed"}]}]},
  open(path, "w"))
PY
}

@test "a dropped duplicate that disagrees is reported, not swallowed" {
  write_one_vuln a.json HIGH 1.2.5
  write_one_vuln b.json CRITICAL 1.2.6

  run python3 "$SCRIPT" out.json a.json b.json
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Der Fund bleibt einer — dedupliziert wird weiterhin.
  [ "$(jq '.Results[0].Vulnerabilities | length' out.json)" -eq 1 ]
  # Der erste gewinnt, wie bisher.
  [ "$(jq -r '.Results[0].Vulnerabilities[0].Severity' out.json)" = "HIGH" ]
  # Neu: es steht dran, und zwar mit beiden Werten.
  [[ "$output" == *"::warning::"* ]] || { echo "$output"; false; }
  [[ "$output" == *"CVE-2024-1"* ]]
  [[ "$output" == *"'HIGH' vs 'CRITICAL'"* ]] || { echo "$output"; false; }
  [[ "$output" == *"'1.2.5' vs '1.2.6'"* ]]
  # Die Singularform muss stimmen: `kind[:-1]` ergaebe "Vulnerabilitie".
  [[ "$output" == *"trivy vulnerability"* ]] || { echo "$output"; false; }
}

@test "identical duplicates stay silent" {
  write_one_vuln a.json HIGH 1.2.5
  write_one_vuln b.json HIGH 1.2.5

  run python3 "$SCRIPT" out.json a.json b.json
  [ "$status" -eq 0 ]
  [ "$(jq '.Results[0].Vulnerabilities | length' out.json)" -eq 1 ]
  # Eine Warnung bei jedem gewoehnlichen Multi-Plattform-Scan waere Laerm, der
  # die echten Faelle zudeckt.
  [[ "$output" != *"::warning::"* ]] || { echo "$output"; false; }
}

@test "an unrelated field differing stays silent" {
  # `Layer` unterscheidet sich zwischen Plattformen regelmaessig und aendert am
  # Bericht nichts — nur die Felder in MATERIAL_FIELDS zaehlen.
  python3 - <<'PY'
import json
def doc(layer):
    return {"SchemaVersion": 2, "ArtifactName": "example:latest",
      "Results": [{"Target": "t", "Class": "os-pkgs", "Type": "alpine",
        "Vulnerabilities": [{"VulnerabilityID": "CVE-1", "PkgID": "p@1",
          "PkgName": "p", "InstalledVersion": "1", "Severity": "LOW",
          "Layer": {"Digest": layer}}]}]}
json.dump(doc("sha256:aaa"), open("a.json", "w"))
json.dump(doc("sha256:bbb"), open("b.json", "w"))
PY
  run python3 "$SCRIPT" out.json a.json b.json
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]] || { echo "$output"; false; }
}

@test "a diverging misconfiguration is reported too" {
  python3 - <<'PY'
import json
def doc(status):
    return {"SchemaVersion": 2, "ArtifactName": "example:latest",
      "Results": [{"Target": "Dockerfile", "Class": "config", "Type": "dockerfile",
        "Misconfigurations": [{"ID": "DS002", "AVDID": "AVD-DS-0002",
          "Namespace": "builtin.dockerfile.DS002", "Query": "data.x",
          "Severity": "HIGH", "Status": status,
          "CauseMetadata": {"StartLine": 3, "EndLine": 3}}]}]}
json.dump(doc("FAIL"), open("a.json", "w"))
json.dump(doc("PASS"), open("b.json", "w"))
PY
  run python3 "$SCRIPT" out.json a.json b.json
  [ "$status" -eq 0 ]
  [ "$(jq '.Results[0].Misconfigurations | length' out.json)" -eq 1 ]
  [[ "$output" == *"trivy misconfiguration DS002"* ]] || { echo "$output"; false; }
  [[ "$output" == *"'FAIL' vs 'PASS'"* ]]
}
