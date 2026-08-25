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
