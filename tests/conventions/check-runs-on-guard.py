#!/usr/bin/env python3
"""tests/conventions/check-runs-on-guard.py

CI gate: every job that resolves its runner from a `runs_on*` input must
reject an empty value before it does anything else.

WHY THIS EXISTS
---------------
A `runs_on` that is valid JSON but selects nothing does NOT fail the job.
GitHub schedules it on an arbitrary runner of the default group and lets it
work. Measured on run 33050121217, where `cleanup-images` was called with
`runs_on: '[]'` and landed on `serverkraken-runner-arm64-5qq4z-l8h98` — a real
self-hosted runner, with an EMPTY label list — holding `packages: write`.

That run was a failure-path test asserting the opposite, so the gap had been
sitting in the catalog while a green check claimed it was covered.

The division of labour is exact:

  * `${{ fromJSON(inputs.runs_on) }}` in `runs-on:` already rejects MALFORMED
    JSON — the job never starts, and the guard is never reached.
  * `[]`, `[ ]`, `[""]`, `"ubuntu-latest"`, `null`, `{}` are all well-formed
    JSON. Only the first two-and-a-bit are silently wrong; the guard is what
    turns them into a red job.

The guard cannot prevent the job from being SCHEDULED — by the time any step
runs, the runner is already allocated, and a workflow_call cannot gate that
without forcing an extra job on every adopter. What it prevents is the job
doing WORK on a runner nobody chose.

WHY PURE BASH AND NOT jq
------------------------
14 of the 25 atoms never touch `jq`. Making the guard depend on it would add a
new requirement to adopter runners in the one step that must never itself be
the reason a job goes red. `fromJSON` has already done the JSON parsing, so
the guard only has to answer "is it an array, and does it name anything".

WHAT IS ENFORCED
----------------
For every job whose `runs-on:` is `${{ fromJSON(<expr>) }}` with `runs_on` in
<expr>:

  1. the first step is `- name: Reject an empty runs_on`
  2. its `env:` binds `RUNS_ON` to `${{ <the very same expr> }}`

Rule 2 is the one with teeth. `docker-build`'s matrix job picks its runner with
a ternary over two inputs; a guard that checked `inputs.runs_on_amd64` there
would be green while validating a value the job does not use.

Jobs that pass `runs_on*` straight through to another reusable workflow are NOT
checked here — they have no `runs-on:` of their own, and the callee's guard is
what runs. Adding one to the forwarder would validate the same value twice.
"""
import re
import sys
from pathlib import Path

JOB_RE = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
RUNSON_RE = re.compile(r"^    runs-on:\s*\$\{\{\s*fromJSON\((.+)\)\s*\}\}\s*$")
STEP_RE = re.compile(r"^      - name:\s*(.+?)\s*$")
ENV_RE = re.compile(r"^          RUNS_ON:\s*(.+?)\s*$")

GUARD_NAME = "Reject an empty runs_on"


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
    checked = 0

    for path in sorted(Path(".github/workflows").glob("*.yml")):
        text = path.read_text()
        if "workflow_call:" not in text:
            continue
        lines = text.split("\n")

        for name, s, e in jobs_of(lines):
            expr = None
            steps_at = None
            for i in range(s, e):
                if (m := RUNSON_RE.match(lines[i])) and "runs_on" in m.group(1):
                    expr = m.group(1).strip()
                if lines[i] == "    steps:":
                    steps_at = i
                    break
            if expr is None or steps_at is None:
                continue

            checked += 1
            where = f"{path}:{steps_at + 1} job `{name}`"

            # 1. the FIRST step must be the guard
            first = next((STEP_RE.match(lines[i]) for i in range(steps_at + 1, e)
                          if STEP_RE.match(lines[i])), None)
            if first is None or first.group(1) != GUARD_NAME:
                got = first.group(1) if first else "<no steps>"
                failures.append(
                    f"{where}: resolves its runner from `{expr}` but its first "
                    f"step is `{got}`, not `{GUARD_NAME}`")
                continue

            # 2. the guard must validate the value this job actually uses
            bound = next((m.group(1) for i in range(steps_at + 1, e)
                          if (m := ENV_RE.match(lines[i]))), None)
            want = "${{ " + expr + " }}"
            if bound != want:
                failures.append(
                    f"{where}: guard validates `{bound}` but the job runs on "
                    f"`{want}` — it would pass while the real value is empty")

    if failures:
        print("runs_on guard missing or mis-bound:\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print(f"\n{len(failures)} job(s) affected. See the header of "
              f"{__file__} for what the guard is for.", file=sys.stderr)
        return 1

    print(f"runs_on guard: {checked} job(s) checked, all guarded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
