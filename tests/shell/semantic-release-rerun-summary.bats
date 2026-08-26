#!/usr/bin/env bats

# Der `Summary`-Schritt aus semantic-release.yml, gegen den ausgelieferten
# run-Rumpf. Eine Kopie im Test wuerde nur beweisen, dass die Kopie stimmt.
#
# Der Fund (F-1): `release_created` ist auch dann false, wenn der Release fuer
# DIESEN Commit schon existiert — etwa nach "Re-run all jobs" auf einem Lauf,
# der NACH dem Tag gescheitert ist. Alle nachgelagerten Jobs haengen an
# `release_created`, werden dann uebersprungen, und uebersprungen zaehlt fuer
# GitHub als Erfolg. Der Lauf meldete `✓ no release (nothing to bump)` und war
# gruen — obwohl Image, Scan und Publish aus dem gescheiterten Versuch fehlen.
#
# Unterschieden wird nicht ueber run_attempt: ein Neustart eines ohnehin
# erfolgreichen Laufs ist harmlos. Das Kennzeichen ist, ob der Commit bereits
# ein Release-Tag traegt.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORK="$(mktemp -d)"

  python3 - "$REPO_ROOT/.github/workflows/semantic-release.yml" > "$WORK/body.sh" <<'PY'
import sys

lines = open(sys.argv[1]).read().splitlines()
needle = "- name: Summary"
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

  # git-Stub: gibt zurueck, was `git tag --points-at HEAD` liefern soll.
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_TAG:-}" ]] && echo "$STUB_TAG"
exit 0
EOF
  chmod +x "$WORK/bin/git"

  export GITHUB_STEP_SUMMARY="$WORK/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  export REPO="serverkraken/demo" MAJ="" MIN="" HTML_URL="" TAG=""
}

teardown() { rm -rf "$WORK"; }

_run_body() { PATH="$WORK/bin:$PATH" run bash "$WORK/body.sh"; }

@test "kein Release und kein Tag am Commit: 'nothing to bump' bleibt richtig" {
  RELEASED=false STUB_TAG="" _run_body
  [ "$status" -eq 0 ]
  run cat "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"nothing to bump"* ]]
  [[ "$output" != *"existiert bereits"* ]]
}

@test "kein Release, aber der Commit traegt schon ein Release-Tag: Warnung statt Haken" {
  RELEASED=false STUB_TAG="v1.4.2" _run_body
  [ "$status" -eq 0 ]
  # Die Warnung geht nach stdout und wird von GitHub als Annotation gelesen.
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"v1.4.2"* ]]
  [[ "$output" == *"SKIPPED"* ]]
  run cat "$GITHUB_STEP_SUMMARY"
  [[ "$output" != *"nothing to bump"* ]]
  [[ "$output" == *"v1.4.2"* ]]
}

@test "erfolgreicher Release bleibt unberuehrt" {
  RELEASED=true TAG="v1.5.0" STUB_TAG="v1.5.0" _run_body
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
  run cat "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"released v1.5.0"* ]]
}
