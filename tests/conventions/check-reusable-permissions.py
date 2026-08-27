#!/usr/bin/env python3
"""tests/conventions/check-reusable-permissions.py

CI gate: a caller that grants `permissions:` to a reusable-workflow job must
grant at least what the called workflow declares.

WHY THIS EXISTS
---------------
Grant too little and GitHub does not fail the job — it refuses the ENTIRE
workflow run at startup:

    conclusion: startup_failure

with no job, no log, no annotation and nothing in the Actions UI that names
the cause. `actionlint` does not catch it either, because both files are valid
on their own; the defect only exists in the RELATION between them.

Measured on runs 33074131069 and 33074876898: the nightly called
`goreleaser.yml` with

    permissions:
      contents: write

while `goreleaser.yml` declares `contents: write` AND `packages: write`. Every
one of the nightly's 51 jobs stopped existing because of one missing line.

It is easy to get wrong precisely because it usually works: `self-ci.yml` grants
`contents: write` to `version-badges.yml`, which declares exactly that. The two
sets match by luck of the atom, not by any rule the author had to follow.

WHAT IS ENFORCED
----------------
For every job with `uses: ./.github/workflows/<x>.yml` that ALSO declares
`permissions:`, every scope `<x>.yml` declares at workflow level must be
granted at least as strongly. Order is `none` < `read` < `write`.

A job that omits `permissions:` entirely is NOT checked: it inherits the
caller workflow's defaults, which is a different (and legitimate) choice.
"""
import re
import sys
from pathlib import Path

WF = Path(".github/workflows")
RANK = {"none": 0, "read": 1, "write": 2}
JOB_RE = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
USES_RE = re.compile(r"^    uses:\s*\./\.github/workflows/([A-Za-z0-9._-]+)\s*$")


def declared_permissions(path: Path):
    """Workflow-level `permissions:` of a called workflow."""
    out = {}
    lines = path.read_text().split("\n")
    for i, line in enumerate(lines):
        if line != "permissions:":
            continue
        for j in range(i + 1, len(lines)):
            m = re.match(r"^  ([a-z-]+):\s*([a-z]+)\s*$", lines[j])
            if not m:
                if lines[j].startswith("  ") or not lines[j].strip():
                    continue      # comment or blank inside the block
                break
            out[m.group(1)] = m.group(2)
        break
    return out


def granted_permissions(lines, start, end):
    """Job-level `permissions:` of a calling job, or None when absent."""
    for i in range(start, end):
        if lines[i] != "    permissions:":
            continue
        out = {}
        for j in range(i + 1, end):
            m = re.match(r"^      ([a-z-]+):\s*([a-z]+)\s*$", lines[j])
            if not m:
                if lines[j].startswith("      ") or not lines[j].strip():
                    continue
                break
            out[m.group(1)] = m.group(2)
        return out
    return None


def main() -> int:
    failures = []
    checked = 0

    for path in sorted(WF.glob("*.yml")):
        lines = path.read_text().split("\n")
        if "jobs:" not in lines:
            continue
        start = lines.index("jobs:")
        marks = [(i, m.group(1)) for i in range(start + 1, len(lines))
                 if (m := JOB_RE.match(lines[i]))]
        marks.append((len(lines), None))

        for (s, name), (e, _) in zip(marks, marks[1:]):
            called = next((m.group(1) for i in range(s, e)
                           if (m := USES_RE.match(lines[i]))), None)
            if called is None:
                continue
            grants = granted_permissions(lines, s, e)
            if grants is None:
                continue          # inherits the caller's defaults — fine
            target = WF / called
            if not target.exists():
                continue
            needs = declared_permissions(target)
            checked += 1

            for scope, level in sorted(needs.items()):
                have = grants.get(scope, "none")
                if RANK.get(have, 0) < RANK.get(level, 0):
                    failures.append(
                        f"{path}:{s + 1} job `{name}` calls {called} and grants "
                        f"`{scope}: {have}`, but {called} declares "
                        f"`{scope}: {level}` — the whole RUN fails at startup")

    if failures:
        print("reusable-workflow permission grants too narrow:\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print(f"\n{len(failures)} grant(s) affected. This does not fail the job "
              f"— it aborts the entire run with `startup_failure` and no "
              f"annotation. See the header of {__file__}.", file=sys.stderr)
        return 1

    print(f"reusable permissions: {checked} caller job(s) checked, all sufficient.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
