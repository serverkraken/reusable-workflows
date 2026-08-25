#!/usr/bin/env bash
# tests/conventions/check-run-interpolation.sh
#
# CI gate against GitHub Actions script injection.
#
# A `${{ … }}` expression inside a `run:` body is pasted into the shell SOURCE
# before bash parses it. Any caller-controlled value can therefore close the
# surrounding quoting and append its own commands — on this catalog's
# long-lived self-hosted runners, in jobs holding `packages: write` and
# `id-token: write`. The fix is always the same: pass the value through `env:`
# and reference `$VAR`, which expands AFTER parsing, so shell metacharacters
# arrive as literal data.
#
# Found by the 2026-08-25 external audit in five places at once
# (docker-build.yml ×3, lint-rust.yml, onboard.yml), one of which — `clippy_args`
# — let a caller turn a real lint failure into a green job. This gate exists so
# the sixth is caught in review rather than in production.
#
# Flagged prefixes are the ones an adopter or an event payload can steer:
#   inputs.*        — the workflow_call / workflow_dispatch contract
#   matrix.*        — frequently derived from inputs
#   github.event.*  — branch names, PR titles, issue bodies
#
# Deliberately NOT flagged: `steps.*`, `needs.*`, `env.*`, `runner.*`,
# `secrets.*` and the remaining `github.*` context. Those are either produced
# inside the workflow or masked by the runner. When one of them demonstrably
# carries caller data it should be moved to `env:` too, but blanket-flagging
# them would bury this gate in false positives and get it ignored.
#
# Bats fixtures invoke this from a temp dir; CI invokes it from the repo root.

set -euo pipefail

shopt -s nullglob

fail=0

scan() {
  local file="$1"
  python3 - "$file" <<'PY'
import re
import sys

path = sys.argv[1]
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except OSError:
    sys.exit(0)

# `run: |` / `run: >` opens a block scalar; it ends at the first non-blank line
# indented no deeper than the `run:` key itself. A single-line `run: cmd` is
# covered by the same regex because the pattern below also matches it.
risky = re.compile(r"\$\{\{\s*(?:inputs|matrix|github\.event)\.[^}]*\}\}")
block_open = re.compile(r"^(\s*)-?\s*run:\s*[|>]")
inline = re.compile(r"^\s*-?\s*run:\s*(.*)$")

found = []
in_block = False
indent = 0
for number, line in enumerate(lines, 1):
    opened = block_open.match(line)
    if opened:
        in_block = True
        indent = len(opened.group(1))
        continue
    if in_block:
        stripped = line.strip()
        if stripped and (len(line) - len(line.lstrip())) <= indent:
            in_block = False
        else:
            for hit in risky.finditer(line):
                found.append((number, hit.group(0)))
            continue
    single = inline.match(line)
    if single and not opened:
        for hit in risky.finditer(single.group(1)):
            found.append((number, hit.group(0)))

for number, expr in found:
    print(f"{path}:{number}: {expr}")
sys.exit(1 if found else 0)
PY
}

for file in .github/workflows/*.yml .github/workflows/*.yaml \
            actions/*/action.yml actions/*/action.yaml; do
  [ -e "$file" ] || continue
  if ! scan "$file"; then
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'

Caller-controlled expression interpolated into a `run:` body.

The value is pasted into the shell source before bash parses it, so a crafted
input can append its own commands. Pass it through `env:` instead:

    env:
      MY_VALUE: ${{ inputs.my_value }}
    run: |
      echo "$MY_VALUE"

If word splitting is intended (a flag list), keep the variable unquoted and
add a `# shellcheck disable=SC2086` — the value still cannot introduce shell
operators that way.
EOF
  exit 1
fi

echo "check-run-interpolation: no caller-controlled expressions in run bodies"
