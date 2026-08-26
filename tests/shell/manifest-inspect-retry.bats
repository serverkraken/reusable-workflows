#!/usr/bin/env bats

# Der Schritt "Create manifest list under the version tag and capture digest"
# aus docker-build.yml, gegen den AUSGELIEFERTEN run-Rumpf. Eine Kopie im Test
# wuerde nur beweisen, dass die Kopie stimmt.
#
# Der Fund kommt aus dem Betrieb, nicht aus der Fundliste: am 2026-08-26 brach
# ein Lauf hier mit
#
#   ERROR: ghcr.io/.../test-multi-worker:...: not found
#
# ab. `create` war erfolgreich — der Schritt laeuft unter `bash -e`, sonst waere
# vorher abgebrochen worden — und derselbe Commit lief beim Neustart
# unveraendert durch. Der Tag war erzeugt, nur noch nicht lesbar.
#
# Die Stelle ist die schlechteste denkbare: die Arch-Images sind bereits
# gepusht. Ein Abbruch hinterlaesst einen halben Release.
#
# Begrenzt wiederholt, nicht endlos: bleibt es dabei, soll der echte Fehler
# durchschlagen. In dieser Sitzung wurde schon einmal ein 403 voreilig
# "transient" genannt und fiel beim Rerun identisch wieder durch.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORK="$(mktemp -d)"

  python3 - "$REPO_ROOT/.github/workflows/docker-build.yml" > "$WORK/body.sh" <<'PY'
import sys

lines = open(sys.argv[1]).read().splitlines()
needle = "- name: Create manifest list under the version tag and capture digest"
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

  mkdir -p "$WORK/bin" "$WORK/digests"
  : > "$WORK/digests/abc123"
  export GITHUB_OUTPUT="$WORK/out.txt"; : > "$GITHUB_OUTPUT"
  export IMG="ghcr.io/example/app" TAG="v1.2.3"
  export DOCKER_CALLS="$WORK/calls.txt"; : > "$DOCKER_CALLS"
}

teardown() { rm -rf "$WORK"; }

# docker-Stub: `create` gelingt immer, `inspect` erst ab dem N-ten Aufruf.
_docker_stub() {
  cat > "$WORK/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DOCKER_CALLS"
case "\$*" in
  *"imagetools create"*) exit 0 ;;
  *"imagetools inspect"*)
    n=\$(grep -c 'imagetools inspect' "$DOCKER_CALLS")
    if (( n >= $1 )); then echo "sha256:deadbeef"; exit 0; fi
    echo "ERROR: \$IMG:\$TAG: not found" >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$WORK/bin/docker"
}

_run_body() { cd "$WORK/digests" && PATH="$WORK/bin:$PATH" run bash "$WORK/body.sh"; }

@test "inspect gelingt sofort: keine Wiederholung noetig" {
  _docker_stub 1
  _run_body
  [ "$status" -eq 0 ]
  [[ "$(cat "$GITHUB_OUTPUT")" == *"digest=sha256:deadbeef"* ]]
  [ "$(grep -c 'imagetools inspect' "$DOCKER_CALLS")" -eq 1 ]
}

@test "Tag erst beim dritten Versuch lesbar: Lauf geht durch" {
  _docker_stub 3
  _run_body
  [ "$status" -eq 0 ]
  [[ "$(cat "$GITHUB_OUTPUT")" == *"digest=sha256:deadbeef"* ]]
  [ "$(grep -c 'imagetools inspect' "$DOCKER_CALLS")" -eq 3 ]
}

@test "dauerhaft nicht lesbar: Abbruch mit echter Meldung, nicht endlos" {
  _docker_stub 99
  _run_body
  [ "$status" -ne 0 ]
  [[ "$output" == *"still not readable after 5 attempts"* ]]
  # Der letzte Aufruf laeuft ohne Unterdrueckung, damit die echte Meldung im Log steht.
  [[ "$output" == *"not found"* ]]
}

@test "kein digest= in der Ausgabe, wenn es nie lesbar wurde" {
  _docker_stub 99
  _run_body
  [[ "$(cat "$GITHUB_OUTPUT")" != *"digest="* ]]
}
