#!/usr/bin/env python3
"""Merge several SARIF files into one file carrying exactly one run.

Why this exists: scanning a multi-arch image means one Trivy invocation per
platform, so one SARIF per platform. Uploading them together (a directory, or
any file with several runs) is refused by the CodeQL action:

    The CodeQL Action does not support uploading multiple SARIF runs with the
    same category. Please update your workflow to upload a single run per
    category.

Splitting by platform into separate categories would fragment one image's alert
list in two, so the merge happens here instead: the platforms describe the same
image and belong in one list.

The part that has to be right is `ruleIndex`. It is an index into the run's
`tool.driver.rules`, so concatenating results from a second file while its rules
land at different positions would point every one of those alerts at the wrong
CVE. Each result is re-indexed via its `ruleId`.

Usage:
    merge-sarif-runs.py <output.sarif> <input.sarif> [<input.sarif> ...]
"""

from __future__ import annotations

import json
import sys


def _result_key(result: dict) -> str:
    """Identity of a finding, for collapsing the same one seen on two platforms.

    Includes the locations: the same CVE reported against two different packages
    is two findings, and must not collapse into one.
    """
    return json.dumps(
        [
            result.get("ruleId"),
            result.get("level"),
            (result.get("message") or {}).get("text"),
            result.get("locations"),
        ],
        sort_keys=True,
    )


def merge(documents: list[dict]) -> dict:
    runs = [run for doc in documents for run in doc.get("runs") or []]
    if not runs:
        raise SystemExit("no SARIF runs found in the inputs")

    base = runs[0]
    driver = ((base.get("tool") or {}).get("driver")) or {}

    merged_rules: list[dict] = []
    rule_index: dict[str, int] = {}
    merged_results: list[dict] = []
    seen: set[str] = set()

    for run in runs:
        rules = (((run.get("tool") or {}).get("driver")) or {}).get("rules") or []
        for rule in rules:
            rule_id = rule.get("id")
            if rule_id is None:
                raise SystemExit("SARIF rule without an id: cannot merge safely")
            if rule_id not in rule_index:
                rule_index[rule_id] = len(merged_rules)
                merged_rules.append(rule)

        for result in run.get("results") or []:
            rule_id = result.get("ruleId")
            if rule_id is None:
                # Without a ruleId the result cannot be re-indexed, and guessing
                # would point the alert at an unrelated rule.
                raise SystemExit("SARIF result without a ruleId: cannot merge safely")
            if rule_id not in rule_index:
                raise SystemExit(f"SARIF result references unknown rule {rule_id!r}")
            key = _result_key(result)
            if key in seen:
                continue
            seen.add(key)
            merged = dict(result)
            merged["ruleIndex"] = rule_index[rule_id]
            merged_results.append(merged)

    merged_run = dict(base)
    merged_tool = dict(base.get("tool") or {})
    merged_driver = dict(driver)
    merged_driver["rules"] = merged_rules
    merged_tool["driver"] = merged_driver
    merged_run["tool"] = merged_tool
    merged_run["results"] = merged_results

    out = dict(documents[0])
    out["runs"] = [merged_run]
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    output, inputs = argv[1], argv[2:]

    documents = []
    for path in inputs:
        with open(path, encoding="utf-8") as handle:
            documents.append(json.load(handle))

    merged = merge(documents)
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(merged, handle, indent=2)
        handle.write("\n")

    run = merged["runs"][0]
    print(
        f"merged {len(inputs)} file(s) -> {len(run['results'])} result(s), "
        f"{len(run['tool']['driver']['rules'])} rule(s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
