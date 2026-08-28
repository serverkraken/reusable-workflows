#!/usr/bin/env python3
"""Jeder Renovate-Marker im Katalog braucht einen customManager, der ihn greift.

Marker sind reine Kommentare. Fehlt der passende customManager in
.github/renovate.json5, sieht die Datei gewartet aus, wird aber nie
aktualisiert -- genau so blieben TOFU_VERSION, TFLINT_VERSION,
golangci_lint_version und zehn weitere Pins stehen.

Bewusst KEINE Suche ueber rg/grep: ripgrep ueberspringt versteckte
Verzeichnisse, und .github ist eines. Eine Inventur ohne --hidden sieht
ausschliesslich actions/ und meldet ein zu gutes Ergebnis. Deshalb explizite
Pfadlisten.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github" / "renovate.json5"

# Ein Marker zaehlt nur, wenn die Zeile mit dem Kommentarzeichen BEGINNT.
# Damit faellt der Markertext heraus, der in validate.yml als Suchmuster in
# einem run-Block steht ("PATTERN='# renovate: ...'").
MARKER = re.compile(r"^\s*#\s*renovate:\s*datasource=(?P<ds>\S+)\s+depName=(?P<dep>\S+)")
VERSION_KEY = re.compile(r"^\s*[A-Za-z_]+_[Vv]ersion:")
USES_KEY = re.compile(r"^\s*uses:")
COMMENT = re.compile(r"^\s*#")
LOOKAHEAD = 8


def target_files() -> list[pathlib.Path]:
    files = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    files += sorted(ROOT.glob("actions/*/action.yml"))
    return files


def single_quoted_strings(text: str) -> list[str]:
    """Einfach gequotete JSON5-Strings holen, Kommentare uebersprungen.

    Warum kein Regex ueber die ganze Datei: renovate.json5 enthaelt den
    Kommentar "Renovate's migration tool". Dieses Apostroph eroeffnet fuer
    einen naiven Quote-Zaehler einen Schein-String, der die naechste echte
    matchString verschluckt -- konkret die fuer Trivy, die dann faelschlich
    als fehlend gemeldet wird.

    Das JSON5-Escaping wird gleich aufgeloest (\\' -> ', \\\\ -> \\),
    Regex-Escapes wie \\s bleiben erhalten.
    """
    out: list[str] = []
    buf: list[str] | None = None
    i, n = 0, len(text)
    while i < n:
        char = text[i]
        if buf is not None:
            if char == "\\" and i + 1 < n:
                nxt = text[i + 1]
                buf.append(nxt if nxt in "\\'\"" else "\\" + nxt)
                i += 2
                continue
            if char == "'":
                out.append("".join(buf))
                buf = None
                i += 1
                continue
            buf.append(char)
            i += 1
            continue
        if char == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if char == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if char == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if char == "'":
            buf = []
            i += 1
            continue
        i += 1
    return out


def match_patterns() -> list[re.Pattern[str]]:
    patterns: list[re.Pattern[str]] = []
    for raw in single_quoted_strings(CONFIG.read_text(encoding="utf-8")):
        if "renovate:" not in raw:
            continue
        # Renovate nutzt Go-Syntax fuer benannte Gruppen, Python will (?P<...>.
        pattern = raw.replace("(?<", "(?P<")
        try:
            patterns.append(re.compile(pattern))
        except re.error as exc:
            print(f"::error::matchString laesst sich nicht kompilieren: {pattern!r} ({exc})")
            sys.exit(1)
    if not patterns:
        print("::error::keine matchStrings in .github/renovate.json5 gefunden")
        sys.exit(1)
    return patterns


def classify(lines: list[str], idx: int) -> str:
    """Braucht der Marker einen customManager, oder haengt er an einer uses:-Zeile?"""
    for look in lines[idx + 1 : idx + 1 + LOOKAHEAD]:
        if COMMENT.match(look) or not look.strip():
            continue
        if USES_KEY.match(look):
            return "action-pin"
        if VERSION_KEY.match(look):
            return "custom"
    return "custom"


def markers(text: str) -> tuple[list[tuple[int, int, int, str]], int]:
    """((Start, Ende, Zeilennummer, depName) je Marker, Zahl der uses:-Pins).

    Start und Ende umspannen die ganze MARKER-ZEILE, nicht nur ihren Anfang:
    die matchStrings beginnen beim `#`, nicht bei der Einrueckung davor. Ein
    Vergleich auf den Zeilenanfang meldet sonst jeden Marker als ungegriffen --
    auch die, fuer die ein Manager existiert.
    """
    found: list[tuple[int, int, int, str]] = []
    skipped = 0
    lines = text.splitlines(keepends=True)
    offset = 0
    for idx, line in enumerate(lines):
        hit = MARKER.match(line)
        if hit:
            if classify(lines, idx) == "action-pin":
                skipped += 1
            else:
                found.append((offset, offset + len(line), idx + 1, hit.group("dep")))
        offset += len(line)
    return found, skipped


def main() -> int:
    patterns = match_patterns()
    uncovered: list[str] = []
    total = 0
    action_pins = 0

    for path in target_files():
        text = path.read_text(encoding="utf-8")
        starts = {m.start() for pattern in patterns for m in pattern.finditer(text)}
        found, skipped = markers(text)
        action_pins += skipped
        for start, end, lineno, dep in found:
            total += 1
            if not any(start <= s < end for s in starts):
                rel = path.relative_to(ROOT)
                uncovered.append(f"{rel}:{lineno} -> {dep}")

    if uncovered:
        print(
            f"::error::{len(uncovered)} von {total} Renovate-Markern werden von "
            "keinem customManager gegriffen."
        )
        print("Diese Pins sehen gewartet aus, werden aber nie aktualisiert:")
        for entry in uncovered:
            print(f"  - {entry}")
        print("Fix: passenden matchString in .github/renovate.json5 ergaenzen.")
        return 1

    print(
        f"OK: alle {total} Renovate-Marker werden von einem customManager gegriffen "
        f"({action_pins} uses:-Pin(s) uebersprungen - dafuer ist Renovates eingebauter "
        "Actions-Manager zustaendig)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
