#!/usr/bin/env python3
"""Gate: die README muss die Zahl der Atome nennen, die den Katalog zur Laufzeit
am SCHWEBENDEN Major-Tag auschecken — und sie muss stimmen.

Warum es das gibt (Audit D-11): die Pin-Tabelle sagte fuer `@v4.2.3` schlicht
"unveraenderlich". Das gilt fuer die Workflow-DATEI, nicht fuer die
Composite-Actions und Skripte, die sie zur Laufzeit nachlaedt — die kommen vom
schwebenden `v4`. Ein Adopter, der exakt pinnt, fuehrt also mitlaufenden Code
aus. Das Verhalten ist eine bewusste Entscheidung (Sicherheitsfixes erreichen
gepinnte Adopter, Composite-Actions bleiben zum Major kohaerent) — falsch war
nur das Versprechen.

Eine Zahl in der Doku veraltet still. Dieses Gate haelt sie an die Quelle
gebunden: gezaehlt wird der Marker `renovate-marker: catalog-major-ref`, der in
jedem betroffenen Atom ueber dem hartkodierten Major steht.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
README = ROOT / "README.md"
WF = ROOT / ".github" / "workflows"
MARKER = "renovate-marker: catalog-major-ref"


def main() -> int:
    actual = sum(1 for p in WF.glob("*.yml") if MARKER in p.read_text())
    if actual == 0:
        print(f"FEHLER: kein Workflow traegt {MARKER!r} — das Gate liefe ins Leere")
        return 1

    text = README.read_text()
    m = re.search(r"\*\*Ein Pin friert die Workflow-Datei ein[^*]*?\*\*\s*(\d+)\s+Atome", text, re.S)
    if not m:
        print("FEHLER: README nennt die Zahl der betroffenen Atome nicht mehr.\n"
              "  Der Absatz nach der Pin-Tabelle muss erklaeren, dass ein Pin die\n"
              "  Workflow-Datei einfriert, nicht die nachgeladenen Skripte.")
        return 1

    documented = int(m.group(1))
    if documented != actual:
        print(f"FEHLER: README sagt {documented} Atome, es sind {actual}.\n"
              f"  Gezaehlt wird der Marker {MARKER!r} in .github/workflows/*.yml.")
        return 1

    print(f"OK: {actual} Atome checken den Katalog am schwebenden Major aus, "
          f"die README nennt dieselbe Zahl.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
