#!/usr/bin/env python3
"""Gate: jede `key=value`-Behauptung im Abschnitt "Repo Defaults" von
docs/operations.md muss catalog/onboard-defaults.json entsprechen.

Warum es das gibt: beim Schreiben dieses Abschnitts habe ich
`squash_merge_commit_message` als `PR_BODY` dokumentiert - die Quelle sagt
`BLANK`. Ein Adopter haette der Doku geglaubt und sich gewundert, warum der
Squash-Commit keinen Body traegt.

Fuer die Workflow-Inputs faengt check-contract-defaults.py genau diese
Fehlerklasse laengst ab; fuer diese Datei gab es nichts. Das Gate ist bewusst
schmal: es prueft nur, was die Doku ausdruecklich als `key=value` behauptet.
Es verlangt NICHT, dass jeder Schluessel der JSON dokumentiert ist - sonst
wuerde jede neue Einstellung das Gate brechen, bevor jemand sie erklaeren kann.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / "docs" / "operations.md"
CONFIG = ROOT / "catalog" / "onboard-defaults.json"
SECTION = "## Repo Defaults"


def flatten(obj, prefix=""):
    """Alle Blattwerte als key -> value. Der letzte Pfadteil zaehlt, weil die
    Doku die Schluessel ohne ihre JSON-Gruppe nennt (`has_wiki`, nicht
    `repo_settings.has_wiki`)."""
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.update(flatten(v, k))
    elif prefix:
        out[prefix] = obj
    return out


def section_text(doc: str) -> str:
    lines = doc.split("\n")
    starts = [i for i, l in enumerate(lines) if l.strip() == SECTION]
    if not starts:
        sys.exit(f"FEHLER: Abschnitt {SECTION!r} fehlt in {DOC.relative_to(ROOT)}")
    # Doppelte Ueberschrift: genau der Fehler, der dieses Gate ausgeloest hat.
    # Der Abschnitt stand zweimal in der Datei, in zwei Fassungen, die sich in
    # einem Wert widersprachen - und wer die Datei liest, sieht zuerst die eine
    # und glaubt, das sei alles. Ein Gate, das stumm die erste nimmt, haette
    # denselben Fehler gemacht wie ein Leser.
    if len(starts) > 1:
        at = ", ".join(str(i + 1) for i in starts)
        sys.exit(f"FEHLER: Abschnitt {SECTION!r} steht mehrfach in "
                 f"{DOC.relative_to(ROOT)} (Zeilen {at}) — zusammenfuehren")
    start = starts[0]
    end = next((i for i, l in enumerate(lines[start + 1:], start + 1)
                if l.startswith("## ")), len(lines))
    return "\n".join(lines[start:end])


def main() -> int:
    values = flatten(json.loads(CONFIG.read_text()))
    text = section_text(DOC.read_text())

    # nur Behauptungen in Backticks: `key=value`
    claims = re.findall(r"`([a-z_]+)=([A-Za-z_0-9]+)`", text)
    if not claims:
        sys.exit("FEHLER: keine `key=value`-Behauptungen gefunden — Gate liefe ins Leere")

    bad = []
    for key, claimed in claims:
        if key not in values:
            bad.append(f"  {key}={claimed}: kein solcher Schluessel in {CONFIG.name}")
            continue
        actual = values[key]
        actual_s = {True: "true", False: "false", None: "null"}.get(actual, str(actual))
        if claimed != actual_s:
            bad.append(f"  {key}: Doku sagt {claimed!r}, Quelle sagt {actual_s!r}")

    if bad:
        print("FEHLER: docs/operations.md widerspricht catalog/onboard-defaults.json:")
        print("\n".join(bad))
        return 1

    print(f"OK: {len(claims)} dokumentierte Repo-Default-Werte stimmen mit der Quelle ueberein.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
