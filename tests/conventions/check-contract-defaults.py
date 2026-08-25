#!/usr/bin/env python3
"""CI-Gate: die Default-Spalte in docs/contracts.md gegen die Quell-YAML.

Warum getrennt von check-contracts.sh: jenes Gate vergleicht NAMEN — welche
Inputs, Outputs und Secrets es gibt. Die Spalten Typ, `required` und Default
liest es nicht, sie sind dort Dekoration (Audit L-11). Genau darin driftete
`helm-publish.yml`: dokumentiert war `helm_version: 'v3.15.0'`, tatsaechlich
`'v3.16.3'` — ein Adopter, der die Doku liest, plant mit der falschen Fassung.

Geprueft wird der DEKLARIERTE Default, nicht der effektive. Mehrere Atome
deklarieren `''` und fallen intern auf etwas anderes zurueck
(`cleanup-images.package_name` -> Repo-Name, `docker-build.image_name` ->
`github.repository`). Beides zu vermischen hat die Doku schon einmal
uneindeutig gemacht; der Fallback gehoert in die Beschreibungsspalte.

Usage:  check-contract-defaults.py [docs/contracts.md]
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

HEADER = r'^([^\S\n]*)%s:[^\S\n]*$'   # NICHT \s* — das frisst den Zeilenumbruch davor


def parse_block(text: str, header: str) -> dict[str, dict[str, str]]:
    """Die Eintraege unter einem Schluessel wie `inputs:` samt ihrer Felder."""
    m = re.search(HEADER % header, text, re.M)
    if not m:
        return {}
    base = len(m.group(1))
    out: dict[str, dict[str, str]] = {}
    cur: dict[str, str] | None = None
    fold: tuple[str, int] | None = None
    for raw in text[m.end():].splitlines():
        if not raw.strip():
            continue
        indent = len(raw) - len(raw.lstrip())
        if fold:
            # Laufender Block-Skalar: Folgezeilen gehoeren zum Wert.
            if indent > fold[1]:
                cur[fold[0]] = (cur[fold[0]] + " " + raw.strip()).strip()
                continue
            fold = None
        if raw.lstrip().startswith("#"):
            continue
        if indent <= base:
            break
        key = re.match(r'^\s*([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)$', raw)
        if key and indent == base + 2:
            cur = {}
            out[key.group(1)] = cur
            continue
        if cur is None:
            continue
        field = re.match(r'^\s*(description|type|required|default):\s*(.*)$', raw)
        if not field:
            continue
        name, value = field.group(1), field.group(2).strip()
        if value in (">-", ">", "|", "|-", ">+", "|+"):
            cur[name] = ""
            fold = (name, indent)
            continue
        cur[name] = value
    return out


def workflow_call_slice(text: str) -> str:
    """Nur der workflow_call-Block — sonst liest man workflow_dispatch-Inputs."""
    m = re.search(r'^([^\S\n]*)workflow_call:[^\S\n]*$', text, re.M)
    if not m:
        return text
    base = len(m.group(1))
    keep = []
    for raw in text[m.end():].splitlines():
        if raw.strip() and not raw.startswith(" " * (base + 1)):
            break
        keep.append(raw)
    return "\n".join(keep)


def unquote(value: str) -> str:
    value = value.strip().strip("`").strip()
    if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"":
        inner = value[1:-1]
        return inner.replace("''", "'") if value[0] == "'" else inner
    return value


def source_for(heading: str) -> Path | None:
    if heading.startswith("actions/"):
        return Path("actions") / heading.split("/", 1)[1] / "action.yml"
    if heading.endswith((".yml", ".yaml")):
        return Path(".github/workflows") / heading
    return None


def main(argv: list[str]) -> int:
    root = os.environ.get("REPO_ROOT")
    if root:
        os.chdir(root)
    else:
        os.chdir(subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                capture_output=True, text=True, check=True).stdout.strip())

    doc_path = Path(argv[1]) if len(argv) > 1 else Path("docs/contracts.md")
    if not doc_path.is_file():
        print(f"FAIL: {doc_path} nicht gefunden.")
        return 1

    failed = 0
    checked = 0
    source: Path | None = None
    cache: dict[Path, dict[str, dict[str, str]]] = {}

    for lineno, line in enumerate(doc_path.read_text().splitlines(), 1):
        heading = re.match(r'^### `([^`]+)`', line)
        if heading:
            source = source_for(heading.group(1))
            continue
        if source is None or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 5 or cells[0] != "input":
            continue
        name = unquote(cells[1].replace("*", ""))
        documented = unquote(cells[4])
        if documented in ("—", "-", ""):
            documented = ""

        if not source.is_file():
            continue
        if source not in cache:
            text = source.read_text()
            if source.name != "action.yml":
                text = workflow_call_slice(text)
            cache[source] = parse_block(text, "inputs")
        entry = cache[source].get(name)
        if entry is None:
            continue          # Namensdrift meldet check-contracts.sh

        actual = unquote(entry.get("default", ""))
        checked += 1
        if actual != documented:
            print(f"FAIL: {doc_path}:{lineno} {source}:{name} — Default dokumentiert "
                  f"als {documented or '<leer>'!r}, deklariert ist {actual or '<leer>'!r}.")
            failed = 1

    if failed:
        print()
        print("Die Default-Spalte weicht von der Quelle ab. Adopter planen nach dieser")
        print("Spalte. Faellt ein Atom intern auf etwas anderes zurueck, gehoert der")
        print("deklarierte Wert in die Spalte und der Fallback in die Beschreibung.")
        return 1

    print(f"OK: {checked} dokumentierte Input-Defaults stimmen mit der Quelle ueberein.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
