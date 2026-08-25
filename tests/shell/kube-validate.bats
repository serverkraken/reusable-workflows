#!/usr/bin/env bats

load 'lib/assertions'
# Unit tests for scripts/kube-validate.sh. Stubs kustomize + kubeconform on
# PATH so the orchestration logic is tested without the real binaries.

setup() {
  TESTDIR="$(mktemp -d)"
  BINDIR="$TESTDIR/bin"
  mkdir -p "$BINDIR"
  ARGLOG="$TESTDIR/arglog"; : > "$ARGLOG"

  cat > "$BINDIR/kubeconform" <<'EOF'
#!/usr/bin/env bash
echo "kubeconform $*" >> "$ARGLOG"
exit "${KUBECONFORM_EXIT:-0}"
EOF
  cat > "$BINDIR/kustomize" <<'EOF'
#!/usr/bin/env bash
# Ignore SIGPIPE: the kubeconform stub exits without draining stdin, so when
# piped (kustomize build | kubeconform) it may close the read end before this
# producer finishes writing. Real kubeconform reads stdin fully, so this race
# is a test-double artifact — without the trap it flakes under `pipefail`.
trap '' PIPE
echo "kustomize $*" >> "$ARGLOG"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n'
exit "${KUSTOMIZE_EXIT:-0}"
EOF
  chmod +x "$BINDIR/kubeconform" "$BINDIR/kustomize"
  export PATH="$BINDIR:$PATH" ARGLOG
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/kube-validate.sh"
  TREE="$TESTDIR/tree"
}
teardown() { rm -rf "$TESTDIR"; }

@test "validates a standalone top-level yaml via kubeconform" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "kubeconform .*$TREE/argo/app.yaml" "$ARGLOG"
}

@test "builds and validates a kustomization tree" {
  mkdir -p "$TREE/apps/web"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n' > "$TREE/apps/web/kustomization.yaml"
  MANIFESTS_PATHS="$TREE/apps" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "kustomize build $TREE/apps/web" "$ARGLOG"
}

@test "fails when kubeconform rejects a manifest" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/bad.yaml"
  KUBECONFORM_EXIT=1 MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when kustomize build errors (pipefail catches the producer)" {
  mkdir -p "$TREE/apps/web"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n' > "$TREE/apps/web/kustomization.yaml"
  KUSTOMIZE_EXIT=1 MANIFESTS_PATHS="$TREE/apps" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "iterates every newline-separated root" {
  mkdir -p "$TREE/apps/web" "$TREE/argo"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n' > "$TREE/apps/web/kustomization.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  MANIFESTS_PATHS=$'%s\n%s' run bash -c 'MANIFESTS_PATHS="'"$TREE/apps"$'\n'"$TREE/argo"'" bash "$0"' "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "kustomize build $TREE/apps/web" "$ARGLOG"
  grep -q "kubeconform .*$TREE/argo/app.yaml" "$ARGLOG"
}

@test "STRICT=false omits -strict and does not abort under errexit" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  STRICT=false MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  refute_grep -q -- "-strict" "$ARGLOG"
}

@test "SKIP_KINDS and SCHEMA_LOCATIONS flow into kubeconform argv" {
  mkdir -p "$TREE/argo"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n' > "$TREE/argo/app.yaml"
  SKIP_KINDS="Secret" SCHEMA_LOCATIONS=$'default\nhttps://example.test/{{.ResourceKind}}.json' \
    MANIFESTS_PATHS="$TREE/argo" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- "-skip Secret" "$ARGLOG"
  grep -q -- "-schema-location default" "$ARGLOG"
  grep -q -- "-schema-location https://example.test" "$ARGLOG"
}

@test "missing root faellt durch, statt Erfolg zu melden" {
  # Hiess bis zum F-4/I-13-Fix "missing root warns and does not fail" und
  # schrieb damit fest, dass ein Tippfehler in manifests_paths ein gruenes
  # Gate ergibt. Gemessen: der Lauf endete mit "all manifests valid", rc=0 —
  # ohne eine einzige Validierung.
  MANIFESTS_PATHS="$TREE/does-not-exist" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  [[ "$output" != *"alle gueltig"* ]]
}

@test "ein leerer Root faellt durch — null Validierungen sind kein Erfolg" {
  mkdir -p "$TREE/leer"
  MANIFESTS_PATHS="$TREE/leer" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nichts validiert"* ]]
}

@test "standalone .yml wird gefunden, nicht nur .yaml" {
  # Ein Repo, das durchgaengig `.yml` benutzt, validierte null Dateien und
  # meldete Erfolg. Nachgestellt mit einem absichtlich kaputten Deployment:
  # es kam nie bei kubeconform an.
  mkdir -p "$TREE/ymlonly"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: a}\n' > "$TREE/ymlonly/cm.yml"
  MANIFESTS_PATHS="$TREE/ymlonly" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cm.yml"* ]]
  [[ "$output" == *"1 Manifest"* ]]
}

@test "kustomization.yml und Kustomization werden gefunden" {
  # kustomize akzeptiert drei Dateinamen; gesucht wurde nur einer.
  for name in kustomization.yml Kustomization; do
    rm -rf "$TREE/k-$name"; mkdir -p "$TREE/k-$name"
    printf 'resources: []\n' > "$TREE/k-$name/$name"
    MANIFESTS_PATHS="$TREE/k-$name" run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "fehlgeschlagen fuer $name: $output"; return 1; }
    [[ "$output" == *"kustomize build"* ]] || { echo "kein build fuer $name"; return 1; }
  done
}

@test "die Erfolgsmeldung nennt die Anzahl der Validierungen" {
  # "all manifests valid" liess offen, ob ueberhaupt etwas geprueft wurde.
  mkdir -p "$TREE/zaehlung"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: a}\n' > "$TREE/zaehlung/a.yaml"
  MANIFESTS_PATHS="$TREE/zaehlung" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *" validiert, alle gueltig"* ]]
  [[ "$output" == *"1 Manifest"* ]]
}
