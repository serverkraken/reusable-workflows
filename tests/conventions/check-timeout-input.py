#!/usr/bin/env python3
"""tests/conventions/check-timeout-input.py

CI gate: every job whose runner a caller can override must let the caller
override its timeout as well.

WHY THIS EXISTS
---------------
Until v4.30 most atoms accepted `runs_on` but hard-coded `timeout-minutes`.
An adopter moving a job to a slower runner (ubuntu-latest, a busy ARM64 node)
could pick the runner but not give it the time it needed. v4.31.0 added a
`timeout_minutes*` input to every such job; this gate keeps a new job or a
refactor from silently dropping that again.

THE RULE
--------
Scope is the same as check-runs-on-guard.py: a job (not a `uses:` call) in a
`workflow_call` workflow whose `runs-on` resolves from a `runs_on*` input.
For each such job:

  1. it must set `timeout-minutes` — without it GitHub applies 360 minutes;
  2. the value must be `${{ inputs.timeout_minutes... }}`;
  3. unless the line directly above is `# timeout-fixed: <reason>`, for
     housekeeping jobs that run seconds and would only add input noise.
     The reason must not be empty.

Workflows without runner inputs (onboard.yml: an operational tool, not an
adopter API) are outside the scope, just as they are for the runs_on guard.
That `inputs.timeout_minutes*` is actually declared is checked by actionlint.
"""

import re
import sys
from pathlib import Path

JOB_RE = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
RUNSON_RE = re.compile(r"^    runs-on:.*\binputs\.runs_on")
TIMEOUT_RE = re.compile(r"^    timeout-minutes:\s*(.+?)\s*$")
INPUT_RE = re.compile(r"^\$\{\{\s*inputs\.timeout_minutes[a-z0-9_]*\s*\}\}$")
FIXED_RE = re.compile(r"^    # timeout-fixed:\s*(.*?)\s*$")


def jobs_of(lines):
    """Yield (name, start, end) for every top-level job block."""
    try:
        start = lines.index("jobs:")
    except ValueError:
        return
    marks = [(i, m.group(1)) for i in range(start + 1, len(lines))
             if (m := JOB_RE.match(lines[i]))]
    marks.append((len(lines), None))
    for (s, name), (e, _) in zip(marks, marks[1:]):
        yield name, s, e


def main() -> int:
    failures = []
    checked = fixed = 0

    for path in sorted(Path(".github/workflows").glob("*.yml")):
        text = path.read_text()
        if "workflow_call:" not in text:
            continue
        lines = text.split("\n")

        for name, s, e in jobs_of(lines):
            # Job-level keys only: stop at the steps list.
            head_end = next((i for i in range(s, e) if lines[i] == "    steps:"), e)
            head = range(s, head_end)
            if not any(RUNSON_RE.match(lines[i]) for i in head):
                continue

            checked += 1
            where = f"{path}:{s + 1} job `{name}`"
            at = next((i for i in head if TIMEOUT_RE.match(lines[i])), None)
            if at is None:
                failures.append(
                    f"{where}: no `timeout-minutes` — GitHub would allow 360 "
                    f"minutes; use `${{{{ inputs.timeout_minutes }}}}`")
                continue

            value = TIMEOUT_RE.match(lines[at]).group(1)
            if INPUT_RE.match(value):
                continue

            marker = FIXED_RE.match(lines[at - 1]) if at > 0 else None
            if marker and marker.group(1):
                fixed += 1
                continue
            if marker:
                failures.append(f"{where}: `# timeout-fixed:` has no reason")
                continue
            failures.append(
                f"{where}: `timeout-minutes: {value}` is fixed although the "
                f"runner is overridable — read it from an "
                f"`inputs.timeout_minutes*` input, or mark the line with "
                f"`# timeout-fixed: <reason>`")

    if failures:
        print("timeout not overridable:\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print(f"\n{len(failures)} job(s) affected. See the header of "
              f"{__file__}.", file=sys.stderr)
        return 1

    print(f"timeout input: {checked} job(s) checked, "
          f"{checked - fixed} overridable, {fixed} fixed with a reason.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
