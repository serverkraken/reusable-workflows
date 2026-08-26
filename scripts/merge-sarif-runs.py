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

`artifactLocation.index` is the same trap one level over (audit L-5): it indexes
into the run's `artifacts`, and the merged run used to keep only the FIRST
input's array. A result carried over from the second file kept its old index and
would name whatever file happened to sit at that position in the first run — an
alert pointing at the wrong file, silently. Artifacts are therefore merged by
`location.uri` and every `artifactLocation.index` inside a result is rewritten,
`parentIndex` included.

Measured note: trivy 0.74.0 emits no `artifacts` array at all (checked against a
`trivy fs --format sarif` run — the key is absent, results reference files by
`uri` only), so this path is dormant for today's scanner. It is implemented
rather than merely guarded because index rewriting is precisely this tool's job,
and a wrong file attribution is not something a warning can make safe.

Usage:
    merge-sarif-runs.py <output.sarif> <input.sarif> [<input.sarif> ...]
"""

from __future__ import annotations

import copy
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


def _artifact_key(artifact: dict) -> str:
    """Identity of an artifact across runs.

    Two platform scans of the same image list the same files, so the URI is the
    identity. Artifacts without a location (permitted by the schema) fall back
    to their full content, which merely means they never collapse — never that
    two different files merge into one.
    """
    location = artifact.get("location") or {}
    uri = location.get("uri")
    if uri is None:
        return "raw:" + json.dumps(artifact, sort_keys=True)
    return "uri:" + json.dumps([uri, location.get("uriBaseId")], sort_keys=True)


def _remap_artifact_indices(node, mapping: dict[int, int]) -> None:
    """Rewrite every `artifactLocation.index` below `node`, in place.

    Only dicts reached through an `artifactLocation` key are touched. SARIF uses
    `index` in other places too (`logicalLocations`, `threadFlowLocation`), and
    those point at different arrays — a blanket rewrite of every key called
    `index` would corrupt them.
    """
    if isinstance(node, list):
        for item in node:
            _remap_artifact_indices(item, mapping)
        return
    if not isinstance(node, dict):
        return
    for key, value in node.items():
        if key == "artifactLocation" and isinstance(value, dict):
            old = value.get("index")
            if isinstance(old, int) and not isinstance(old, bool):
                if old not in mapping:
                    raise SystemExit(
                        f"SARIF result references artifact index {old}, "
                        "which does not exist in the run it came from"
                    )
                value["index"] = mapping[old]
        _remap_artifact_indices(value, mapping)


def merge(documents: list[dict]) -> dict:
    runs = [run for doc in documents for run in doc.get("runs") or []]
    if not runs:
        raise SystemExit("no SARIF runs found in the inputs")

    base = runs[0]
    driver = ((base.get("tool") or {}).get("driver")) or {}

    merged_rules: list[dict] = []
    rule_index: dict[str, int] = {}
    merged_results: list[dict] = []
    merged_artifacts: list[dict] = []
    artifact_index: dict[str, int] = {}
    any_artifacts = False
    seen: set[str] = set()

    for run in runs:
        # Artefakte dieses Runs einsortieren und die Index-Abbildung alt->neu
        # aufbauen, BEVOR die Ergebnisse kopiert werden (Audit L-5).
        run_artifacts = run.get("artifacts") or []
        if run_artifacts:
            any_artifacts = True
        artifact_map: dict[int, int] = {}
        for position, artifact in enumerate(run_artifacts):
            key = _artifact_key(artifact)
            if key not in artifact_index:
                artifact_index[key] = len(merged_artifacts)
                merged_artifacts.append(dict(artifact))
            artifact_map[position] = artifact_index[key]
        # `parentIndex` zeigt ebenfalls in `artifacts` — also mit umschreiben,
        # und zwar erst jetzt, wo die vollstaendige Abbildung steht.
        for position, artifact in enumerate(run_artifacts):
            parent = artifact.get("parentIndex")
            if isinstance(parent, int) and not isinstance(parent, bool):
                if parent not in artifact_map:
                    raise SystemExit(
                        f"SARIF artifact {position} has parentIndex {parent}, "
                        "which does not exist in its run"
                    )
                merged_artifacts[artifact_map[position]]["parentIndex"] = artifact_map[parent]

        rules = (((run.get("tool") or {}).get("driver")) or {}).get("rules") or []
        for rule in rules:
            rule_id = rule.get("id")
            if rule_id is None:
                raise SystemExit("SARIF rule without an id: cannot merge safely")
            if rule_id not in rule_index:
                rule_index[rule_id] = len(merged_rules)
                merged_rules.append(rule)
            elif merged_rules[rule_index[rule_id]] != rule:
                # Dieselbe Regel-ID mit anderem Inhalt: die erste gewinnt, und
                # das kann den Bericht verfaelschen — in `rule` stecken unter
                # anderem `defaultConfiguration.level` und die Severity-Tags,
                # die code-scanning anzeigt (Audit I-2).
                #
                # Gemessen tritt das im tatsaechlichen Anwendungsfall nicht auf:
                # trivy 0.74.0 gegen node:10-alpine, linux/amd64 und
                # linux/arm64, ergab 63 Regeln je Plattform und bei gleicher ID
                # byte-gleichen Inhalt — null Abweichungen. Das ist ein Bild von
                # einem Image, kein Beweis. Deshalb gemeldet statt abgebrochen:
                # ein Abbruch wuerde Scans an einem Ereignis brechen, das noch
                # nie beobachtet wurde, und Stillschweigen macht aus einem
                # Fehlbericht einen unsichtbaren Fehlbericht.
                first = merged_rules[rule_index[rule_id]]
                fields = sorted(
                    k for k in set(first) | set(rule) if first.get(k) != rule.get(k)
                )
                print(
                    f"::warning::SARIF rule {rule_id} differs between runs in "
                    f"{', '.join(fields)}; keeping the first definition",
                    file=sys.stderr,
                )

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
            merged = copy.deepcopy(result)
            merged["ruleIndex"] = rule_index[rule_id]
            # Tiefe Kopie oben, weil das Umschreiben in place geschieht: sonst
            # veraenderte es das Eingabedokument mit, und ein zweiter Aufruf
            # ueber dieselben Daten saehe bereits umgeschriebene Indizes.
            _remap_artifact_indices(merged, artifact_map)
            merged_results.append(merged)

    merged_run = dict(base)
    merged_tool = dict(base.get("tool") or {})
    merged_driver = dict(driver)
    merged_driver["rules"] = merged_rules
    merged_tool["driver"] = merged_driver
    merged_run["tool"] = merged_tool
    merged_run["results"] = merged_results
    # Nur setzen, wenn ueberhaupt ein Eingang Artefakte hatte — sonst bekaeme
    # eine trivy-Ausgabe (die keine hat) hier eine leere Liste angehaengt, die
    # vorher nicht da war.
    if any_artifacts:
        merged_run["artifacts"] = merged_artifacts
    elif "artifacts" in merged_run:
        del merged_run["artifacts"]

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
