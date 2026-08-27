#!/usr/bin/env python3
"""Profildaten in string-Eingaengen muessen im Template gequotet sein.

Der Fund (Audit J-10/J-12/J-14/J-18): die Templates interpolierten Werte roh:

    working_directory: {{ $c.path }}

Ein Komponentenverzeichnis namens `true` rendert damit

    working_directory: true

und das ist nach dem Parsen ein **Boolean**, kein String — obwohl der Eingang
des Atoms `type: string` deklariert. Nachgestellt an einem Repo mit den
Komponenten `api/` und `true/`:

    lint-go-api:  "api" -> string
    lint-go-true: true  -> boolean

`actionlint` faengt das nicht (rc=0). Der Manifest-Zeichensatz
(`RelPathPattern = ^[A-Za-z0-9._/-]+$`) schliesst Anfuehrungszeichen und
Backslashes aus — deshalb sind Escaping-Funde wie J-7 und J-21 gegenstandslos,
die TYP-Verwechslung aber nicht: `true`, `false`, `1.0`, `null` sind gueltige
Pfade und zugleich YAML-Skalare.

Geprueft wird nur, was tatsaechlich gefaehrdet ist:

  * Der Schluessel ist ein Eingang eines Atoms mit `type: string`.
    Booleans und Zahlen duerfen NICHT gequotet werden — `sops: "true"` waere
    fuer einen `type: boolean`-Eingang falsch.
  * Der Wert ist ein Go-Template-Ausdruck, kein durchgereichtes
    `${{ ... }}`. Letzteres beginnt im YAML mit `$` und ist damit ohnehin ein
    String.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def input_types() -> dict[str, set[str]]:
    """Eingang -> deklarierte Typen, ueber alle Atome hinweg."""
    types: dict[str, set[str]] = {}
    for wf in sorted((ROOT / ".github/workflows").glob("*.yml")):
        in_inputs = False
        indent = 0
        cur = None
        for line in wf.read_text(encoding="utf-8").splitlines():
            if re.match(r"^\s*inputs:\s*$", line):
                in_inputs, indent, cur = True, len(line) - len(line.lstrip()), None
                continue
            if not in_inputs:
                continue
            if line.strip() and (len(line) - len(line.lstrip())) <= indent:
                in_inputs, cur = False, None
                continue
            m = re.match(r"^\s{6,}(\w+):\s*$", line)
            if m:
                cur = m.group(1)
                continue
            t = re.match(r"^\s+type:\s*(\w+)", line)
            if t and cur:
                types.setdefault(cur, set()).add(t.group(1))
    return types


# Zweiter Prueffall, aus Audit J-20. Die Suche oben trifft `key: {{ ... }}` —
# `branches: [{{ .profile.default_branch }}]` fiel durch die Maschen, weil der
# Wert in einer Flow-Sequenz steht. Der Fund sass also genau im blinden Fleck
# des Gates, das diese Klasse verhindern soll.
#
# Betrifft NICHT nur type=string-Eingaenge: `branches` ist gar kein Eingang,
# sondern ein Trigger-Schluessel. Die Regel ist allgemeiner — ein einzelnes
# Element aus Profildaten in einer Flow-Sequenz gehoert gequotet.
#
# `join` ist ausgenommen, und zwar eng: nur wenn der Ausdruck woertlich damit
# beginnt. join erzeugt ABSICHTLICH mehrere Elemente; ein Quote daraus machte
# eine einzige Zeichenkette und damit einen `needs:`-Eintrag, den es nicht
# gibt. Ein Literalpraefix (`[docker-build{{ ... }}]`) trifft das Muster
# ohnehin nicht.
def check_flow_sequences() -> tuple[list[str], int]:
    bad: list[str] = []
    ok = 0
    total = 0
    for tpl in sorted((ROOT / "docs/adopter-templates").rglob("*.tmpl")):
        for lineno, line in enumerate(tpl.read_text(encoding="utf-8").splitlines(), 1):
            m = re.match(r"^\s*([\w-]+):\s+\[(\{\{.*\}\})\]\s*$", line)
            if not m:
                continue
            key, expr = m.groups()
            inner = expr[2:-2].strip()
            total += 1
            if inner.startswith("join "):
                continue
            if "strings.Quote" in inner or "data.ToJSON" in inner:
                ok += 1
                continue
            bad.append(
                f"  {tpl.relative_to(ROOT)}:{lineno}: {key} steht ungequotet "
                f"in einer Flow-Sequenz: {expr}"
            )
    # Gegenprobe wie oben: findet das Muster gar keine Stelle, passt es nicht
    # mehr auf die Templates und Gruen waere bedeutungslos.
    if total == 0:
        bad.append(
            "  (keine einzige Flow-Sequenz-Interpolation gefunden — das Muster "
            "passt nicht mehr auf die Templates, dieser Teil prueft nichts)"
        )
    return bad, ok


def main() -> int:
    types = input_types()
    if not types:
        print("FEHLER: keine Eingabe-Typen gefunden — das Gate wuerde nichts pruefen", file=sys.stderr)
        return 1

    offenders: list[str] = []
    checked = 0
    for tpl in sorted((ROOT / "docs/adopter-templates").rglob("*.tmpl")):
        for lineno, line in enumerate(tpl.read_text(encoding="utf-8").splitlines(), 1):
            m = re.match(r"^\s*([\w-]+):\s+(\{\{.*\}\})\s*$", line)
            if not m:
                continue
            key, expr = m.groups()
            if "string" not in types.get(key, set()):
                continue
            if "`${{" in expr:
                # Durchgereichte GitHub-Expression: rendert zu ${{ ... }},
                # beginnt also mit '$' und ist immer ein String.
                continue
            if "strings.Quote" in expr or "data.ToJSON" in expr:
                # strings.Quote ist STRIKT STAERKER als Handquoting, nicht
                # schwaecher: es erzeugt denselben gequoteten Skalar und
                # behandelt zusaetzlich das eine Zeichen, an dem `key: "{{ }}"`
                # zerbricht — ein Anfuehrungszeichen im Wert selbst.
                #
                # Die Flow-Sequenz-Pruefung oben akzeptiert es laengst; hier
                # fehlte es nur. Aufgefallen bei J-15, als e2e.yml.tmpl von
                # Handquoting auf strings.Quote umgestellt wurde und dieses
                # Gate die staerkere Schreibweise abwies.
                continue
            checked += 1
            offenders.append(
                f"  {tpl.relative_to(ROOT)}:{lineno}: {key} ist type=string, "
                f"aber der Wert steht ungequotet: {expr}"
            )

    if offenders:
        print("FEHLER: ungequotete Profildaten in string-Eingaengen:", file=sys.stderr)
        print("\n".join(offenders), file=sys.stderr)
        print(
            '\nSchreibweise: `key: "{{ ... }}"`. Ein Pfad namens `true` wird sonst '
            "beim Parsen zu einem Boolean.",
            file=sys.stderr,
        )
        return 1

    # Gegenprobe gegen ein Gate, das nichts sieht: es MUSS Stellen dieser Form
    # geben. Findet die Suche gar keine, stimmt das Muster nicht mehr mit den
    # Templates ueberein — dann ist Gruen bedeutungslos.
    quoted = 0
    for tpl in sorted((ROOT / "docs/adopter-templates").rglob("*.tmpl")):
        for line in tpl.read_text(encoding="utf-8").splitlines():
            m = re.match(r'^\s*([\w-]+):\s+"(\{\{.*\}\})"\s*$', line)
            if m and "string" in types.get(m.group(1), set()) and "`${{" not in m.group(2):
                quoted += 1
    if quoted == 0:
        print(
            "FEHLER: keine einzige gequotete Interpolation gefunden — das Muster "
            "passt nicht mehr auf die Templates, das Gate prueft nichts",
            file=sys.stderr,
        )
        return 1

    seq_bad, seq_ok = check_flow_sequences()
    if seq_bad:
        print("FEHLER: ungequotete Profildaten in einelementigen Flow-Sequenzen:", file=sys.stderr)
        print("\n".join(seq_bad), file=sys.stderr)
        print(
            "\nSchreibweise: `key: [{{ ... | strings.Quote }}]`. Unquotiert wird der "
            "Wert zum YAML-Skalar seines Aussehens: `[true]` ist ein Boolean, "
            "`[x,y]` sind ZWEI Elemente.",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: {quoted} Profildaten-Interpolationen in string-Eingaengen "
        f"und {seq_ok} in Flow-Sequenzen, alle gequotet."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
