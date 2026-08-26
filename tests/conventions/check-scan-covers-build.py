#!/usr/bin/env python3
"""Gate: wer `docker-build.yml` aufruft und danach `trivy-image.yml`, muss
Trivy dieselbe Plattform-Liste geben.

Warum es das gibt (Audit F-2): Trivy waehlt fuer eine Multi-Arch-Referenz EINE
Plattform, per Vorgabe linux/amd64. `docker-build.yml` und `release.yml` haben
beide `platforms` mit Default `linux/amd64,linux/arm64` — der Regelfall ist
also multi-arch. Wer die Liste nicht weiterreicht, veroeffentlicht arm64
ungeprueft.

Das Atom kann das laengst, und die drei Adopter-Templates reichen es weiter.
Genau EIN Aufrufer tat es nicht: `release.yml`, der als Vertrag angeboten wird.
Die Multi-Plattform-Verdrahtung selbst ist in integration.yml abgedeckt
(test-trivy-image-cve scannt bewusst zwei Plattformen, nachdem drei Fehler
darin bis in ein Adopter-Release gelaufen waren) — was fehlte, war die Regel,
dass JEDER Aufrufer die gebaute Liste weiterreicht.

Das Gate ist bewusst schmal: es prueft nur Workflows in .github/workflows/, die
BEIDE Atome aufrufen. Ein Aufruf von trivy-image ohne eigenen docker-build
(etwa ein Scan eines fremden Images) geht es nichts an.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WF = ROOT / ".github" / "workflows"
BUILD = "docker-build.yml"
SCAN = "trivy-image.yml"


def job_blocks(text: str):
    """Grobe Zerlegung in Jobs: eine Zeile mit zwei Leerzeichen Einzug und
    Doppelpunkt beginnt einen Job. Reicht fuer diese Dateien und kommt ohne
    YAML-Abhaengigkeit aus — dasselbe Vorgehen wie check-summary-coverage.sh."""
    blocks, name, buf = [], None, []
    for line in text.splitlines():
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
            if name:
                blocks.append((name, "\n".join(buf)))
            name, buf = line.strip().rstrip(":"), []
        elif name:
            buf.append(line)
    if name:
        blocks.append((name, "\n".join(buf)))
    return blocks


def main() -> int:
    bad = []
    checked = 0
    for path in sorted(WF.glob("*.yml")):
        text = path.read_text()
        if BUILD not in text or SCAN not in text:
            continue
        for name, body in job_blocks(text):
            if SCAN not in body:
                continue
            checked += 1
            if "platforms:" not in body:
                bad.append(f"  {path.name} job {name!r} ruft {SCAN} ohne `platforms:`")
    if bad:
        print("FEHLER: Multi-Arch gebaut, aber nicht vollstaendig gescannt:")
        print("\n".join(bad))
        print("\n  Trivy scannt sonst nur linux/amd64; jede weitere gebaute "
              "Architektur geht ungeprueft raus.")
        return 1
    if checked == 0:
        print("FEHLER: kein trivy-image-Aufruf gefunden — das Gate liefe ins Leere")
        return 1
    print(f"OK: {checked} trivy-image-Aufrufe neben einem docker-build, alle mit platforms.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
