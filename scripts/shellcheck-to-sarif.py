#!/usr/bin/env python3
"""Wandelt `shellcheck -f json1` in SARIF 2.1.0.

shellcheck kann kein SARIF. Statt ein weiteres fremdes Binary in den Katalog
zu holen, macht dieses Skript die Umwandlung — dasselbe Muster wie
scripts/merge-sarif-runs.py und scripts/merge-trivy-json.py.

Eingabe auf stdin, Ausgabe auf stdout.
"""
import argparse
import json
import sys

# SARIF kennt nur error/warning/note. shellchecks info und style haben dort
# keine Entsprechung; ohne diese Abbildung lehnt die CodeQL-Action den Upload
# ab, statt die Funde anzuzeigen.
LEVELS = {"error": "error", "warning": "warning", "info": "note", "style": "note"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool-version", default="unknown")
    args = ap.parse_args()

    raw = sys.stdin.read()
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        # Bewusst laut: eine leere oder kaputte Ausgabe bedeutet, dass
        # shellcheck gar nicht gelaufen ist. Als leeres SARIF durchgereicht
        # saehe das aus wie "null Funde".
        print(f"shellcheck-Ausgabe ist kein gueltiges JSON: {exc}", file=sys.stderr)
        return 1

    comments = doc.get("comments")
    if comments is None:
        print("shellcheck-Ausgabe hat kein Feld 'comments'", file=sys.stderr)
        return 1

    rules: list[dict] = []
    rule_index: dict[str, int] = {}
    results: list[dict] = []

    for c in comments:
        rule_id = f"SC{c['code']}"
        if rule_id not in rule_index:
            rule_index[rule_id] = len(rules)
            rules.append({
                "id": rule_id,
                "name": rule_id,
                "shortDescription": {"text": c.get("message", rule_id)},
                "helpUri": f"https://www.shellcheck.net/wiki/{rule_id}",
                "properties": {"tags": ["shell"]},
            })
        results.append({
            "ruleId": rule_id,
            "ruleIndex": rule_index[rule_id],
            "level": LEVELS.get(c.get("level", "warning"), "warning"),
            "message": {"text": c.get("message", "")},
            "locations": [{
                "physicalLocation": {
                    "artifactLocation": {"uri": c["file"]},
                    "region": {
                        "startLine": c.get("line", 1),
                        "startColumn": c.get("column", 1),
                        "endLine": c.get("endLine", c.get("line", 1)),
                        "endColumn": c.get("endColumn", c.get("column", 1)),
                    },
                },
            }],
        })

    sarif = {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {"driver": {
                "name": "ShellCheck",
                "version": args.tool_version,
                "informationUri": "https://www.shellcheck.net",
                "rules": rules,
            }},
            "results": results,
        }],
    }
    json.dump(sarif, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
