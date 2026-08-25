#!/usr/bin/env bats

# Der `Run kube-linter (SARIF)`-Schritt aus kube-lint.yml, gegen das echte
# kube-linter.
#
# Getestet wird der AUSGELIEFERTE run-Rumpf: er wird aus der YAML gezogen und
# ausgefuehrt. Eine Kopie im Test wuerde nur beweisen, dass die Kopie stimmt.
#
# Der Fund (F-3): `|| true` warf jeden Exit-Code weg. Ein Absturz - falscher
# Pfad, kaputte Konfig - hinterliess eine 0-Byte-Datei, der Zaehlschritt las
# daraus `findings_count=0`, das Gate war zufrieden und der Job gruen. Ein
# Cluster-Manifest-Lint, der nichts geprueft hat, sieht dann aus wie einer ohne
# Beanstandungen.
#
# An kube-linter 0.8.3 gemessen:
#
#   keine Funde        rc=0   SARIF 0 Byte
#   Funde              rc=1   SARIF ~27 KB
#   Pfad gibt es nicht rc=1   SARIF 0 Byte
#   kaputte Konfig     rc=1   SARIF 0 Byte
#
# Der Exit-Code allein trennt also nicht - erst rc zusammen mit der Ausgabe.

setup() {
  if ! command -v kube-linter >/dev/null 2>&1; then
    skip "kube-linter nicht installiert"
  fi
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORK="$(mktemp -d)"

  python3 - "$REPO_ROOT/.github/workflows/kube-lint.yml" > "$WORK/body.sh" <<'PY'
import sys

lines = open(sys.argv[1]).read().splitlines()
needle = "- name: Run kube-linter (SARIF)"
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
  [ -s "$WORK/body.sh" ]

  mkdir -p "$WORK/manifests"
  cat > "$WORK/manifests/dep.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad
spec:
  replicas: 1
  selector: {matchLabels: {app: bad}}
  template:
    metadata:
      labels: {app: bad}
    spec:
      containers:
        - name: bad
          image: nginx:latest
EOF
}

teardown() {
  rm -rf "$WORK"
}

# `bash -e` ist Absicht: GitHub startet run-Bloecke so. Eine erste Fassung
# dieses Harness rief `bash` ohne -e auf und war deshalb gruen, waehrend der
# echte Schritt in CI abbrach - der Test gab falsche Sicherheit.
run_body() {
  ( cd "$WORK" && MANIFESTS_PATH="$1" CFG_ARGS="$2" bash -e "$WORK/body.sh" )
}

@test "ein nicht existierender Pfad ist ein Fehler, keine 'null Funde'" {
  run run_body "$WORK/gibtsnicht" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not lint anything"* ]]
}

@test "eine kaputte Konfiguration ist ein Fehler" {
  echo 'invalid: [yaml' > "$WORK/bad.yaml"
  run run_body "$WORK/manifests" "--config $WORK/bad.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not lint anything"* ]]
}

@test "echte Funde lassen den Schritt weiterlaufen und schreiben SARIF" {
  # Gegenprobe: kube-linter beendet bei Funden ebenfalls mit rc=1. Wuerde der
  # Schritt darauf abbrechen, koennte das Gate nie greifen und die SARIF nie
  # hochgeladen werden.
  run run_body "$WORK/manifests" ""
  [ "$status" -eq 0 ]
  [ -s "$WORK/kube-linter.sarif" ]
  [ "$(jq '[.runs[].results[]] | length' "$WORK/kube-linter.sarif")" -gt 0 ]
}

@test "null Funde bleiben null Funde" {
  # Zweite Gegenprobe: der legitime Leerfall darf nicht als Absturz gelten.
  # Ohne aktive Checks beendet kube-linter mit rc=0 und schreibt 0 Byte.
  cat > "$WORK/nochecks.yaml" <<'EOF'
checks:
  doNotAutoAddDefaults: true
EOF
  run run_body "$WORK/manifests" "--config $WORK/nochecks.yaml"
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/kube-linter.sarif" ]
}
