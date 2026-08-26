#!/usr/bin/env python3
"""Gate: jeder Job, der `ref: ${{ inputs.ref }}` auscheckt, braucht davor den
Fork-Guard gegen `pull_request_target`.

Warum es das gibt (Audit D-9): `pull_request_target` ist das einzige Ereignis,
bei dem Secrets bereitstehen UND der Aufrufer eine fremde Revision auschecken
kann. Diese Kombination — "pwn request" — baut Code aus einem Fork mit den
Registry-Zugangsdaten des Adopters, signiert ihn mit dessen cosign-Identitaet
und attestiert ihn. Ein veroeffentlichtes, signiertes Schadimage laesst sich
nicht zurueckholen.

Warum als Gate und nicht nur als Riegel: beim Einbau ist mir eine der vier
Stellen durchgerutscht, weil ihr Checkout hinter einer `if`-Bedingung stand und
mein Suchmuster sie nicht traf. Genau das faengt dieses Gate.

Gezaehlt wird pro JOB, nicht pro Datei: ein Job mit Checkout, aber ohne Riegel
davor, faellt durch.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WF = ROOT / ".github" / "workflows"
REF_LINE = "ref: ${{ inputs.ref }}"
GUARD = "github.event_name == 'pull_request_target'"


def checkout_positions(body: str):
    """Nur ECHTE Checkouts, nicht das Weiterreichen an ein anderes Atom.

    `docker-build-multi.yml` gibt `ref` per `with:` an docker-build.yml weiter —
    dort greift der Riegel, hier waere er sinnlos. Die erste Fassung dieses
    Gates hat auf die blosse Zeile gematcht und genau das faelschlich gemeldet.
    Gezaehlt wird deshalb nur, wenn die Zeile innerhalb weniger Zeilen NACH
    einem `uses: actions/checkout` steht.
    """
    lines = body.splitlines()
    out = []
    for i, line in enumerate(lines):
        if "uses: actions/checkout" not in line:
            continue
        for j in range(i + 1, min(i + 6, len(lines))):
            if REF_LINE in lines[j]:
                out.append(j)
                break
    return out


def jobs_of(text: str):
    """(name, body) je Job. Eine Zeile mit zwei Leerzeichen Einzug und
    Doppelpunkt beginnt einen Job — dasselbe Vorgehen wie in
    check-scan-covers-build.py."""
    out, name, buf = [], None, []
    for line in text.splitlines():
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
            if name:
                out.append((name, "\n".join(buf)))
            name, buf = line.strip().rstrip(":"), []
        elif name:
            buf.append(line)
    if name:
        out.append((name, "\n".join(buf)))
    return out


def main() -> int:
    bad, checked = [], 0
    for path in sorted(WF.glob("*.yml")):
        text = path.read_text()
        if REF_LINE not in text:
            continue
        for name, body in jobs_of(text):
            positions = checkout_positions(body)
            if not positions:
                continue
            checked += 1
            # Der Riegel muss VOR dem ersten solchen Checkout stehen.
            lines = body.splitlines()
            guard_at = next((i for i, l in enumerate(lines) if GUARD in l), None)
            if guard_at is None or guard_at > positions[0]:
                bad.append(f"  {path.name} job {name!r}")
    if bad:
        print("FEHLER: Checkout einer aufrufer-bestimmten Revision ohne Fork-Guard:")
        print("\n".join(bad))
        print("\n  Auf pull_request_target stehen Secrets bereit, waehrend die Revision\n"
              "  aus einem Fork stammen kann. Der gebaute Artefakt wird gepusht UND\n"
              "  signiert — das laesst sich nicht zurueckholen.")
        return 1
    if checked == 0:
        print("FEHLER: kein Job checkt inputs.ref aus — das Gate liefe ins Leere")
        return 1
    print(f"OK: {checked} Jobs checken inputs.ref aus, alle mit Fork-Guard davor.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
