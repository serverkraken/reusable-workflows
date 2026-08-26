#!/usr/bin/env python3
"""Merge Trivy JSON reports from several platforms into one report.

Scanning a multi-arch image runs Trivy once per platform, so the findings land
in one file each. Everything downstream — the step summary's severity counts,
the findings table, the annotations, the gate — wants a single report covering
what actually ships.

Two things this gets right that concatenating files would not:

* A finding present on both architectures is ONE finding. Summing per-platform
  files double-counts it, which inflates both the gate number and the summary.
* A finding present on only one architecture must survive. That is the whole
  reason the scan runs per platform: for an arm64 cluster the amd64-only scan
  was checking an image that never ships.

Results are keyed by (Target, Class, Type) so a package tree that only exists on
one platform still gets its own entry.

Usage:
    merge-trivy-json.py <output.json> <input.json> [<input.json> ...]
"""

from __future__ import annotations

import json
import sys

# Trivy groups findings into these arrays per Result. Each needs its own notion
# of identity for dedup.
FINDING_KEYS = ("Vulnerabilities", "Secrets", "Misconfigurations")

IDENTITY_FIELDS = {
    "Vulnerabilities": ("VulnerabilityID", "PkgID", "PkgName", "InstalledVersion"),
    "Secrets": ("RuleID", "Category", "Title", "StartLine", "EndLine"),
    # Location included on purpose. Keying a misconfiguration on the rule alone
    # collapses two violations of the same rule at different places in one file
    # into one, which under-counts the gate and loses an annotation. Secrets
    # already carry StartLine/EndLine for the same reason; misconfigurations
    # keep theirs under CauseMetadata, so that is pulled out below.
    "Misconfigurations": ("ID", "AVDID", "Namespace", "Query", "_where"),
}


def _where(finding: dict):
    """The location of a misconfiguration, as Trivy records it.

    Trivy keeps it under CauseMetadata rather than on the finding itself, so it
    has to be lifted out before it can take part in the identity.
    """
    cause = finding.get("CauseMetadata") or {}
    where = [cause.get("StartLine"), cause.get("EndLine"), cause.get("Resource")]
    return where if any(v is not None for v in where) else None


# Felder, deren Abweichung den Bericht inhaltlich aendert (Audit L-6).
#
# Die Identitaet oben entscheidet, WAS ein Duplikat ist. Sie sagt nichts
# darueber, ob das Duplikat dasselbe AUSSAGT: zwei Plattform-Scans koennten
# denselben CVE am selben Paket melden und sich in Severity oder FixedVersion
# unterscheiden. Der zweite fiel bisher stillschweigend weg, und das Gate
# entschied dann an einer Severity, die nur eine der beiden Plattformen sah.
#
# Gemessen tritt das im tatsaechlichen Anwendungsfall nicht auf: trivy 0.74.0
# gegen node:10-alpine, linux/amd64 und linux/arm64, ergab 76 Schwachstellen je
# Plattform, 76 gemeinsame Identitaeten und null Abweichungen in Severity,
# FixedVersion und Status. Das ist ein Bild von einem Image, kein Beweis —
# dieselbe Lage wie beim Regelkonflikt in merge-sarif-runs.py, und deshalb
# dieselbe Antwort: gemeldet statt abgebrochen. Ein Abbruch wuerde Scans an
# einem Ereignis brechen, das noch nie beobachtet wurde; Stillschweigen macht
# aus einem Fehlbericht einen unsichtbaren Fehlbericht.
# Kein `kind[:-1]`: daraus wuerde "Vulnerabilitie".
SINGULAR = {
    "Vulnerabilities": "vulnerability",
    "Secrets": "secret",
    "Misconfigurations": "misconfiguration",
}

MATERIAL_FIELDS = {
    "Vulnerabilities": ("Severity", "FixedVersion", "Status"),
    "Secrets": ("Severity",),
    "Misconfigurations": ("Severity", "Status", "Resolution"),
}


def _label(kind: str, finding: dict) -> str:
    """Wie ein Fund in einer Meldung heisst — die ID, die ein Mensch wiedererkennt."""
    # `ID` vor `AVDID`: bei Fehlkonfigurationen ist das die kurze Kennung
    # ("DS002"), die trivy auch in seiner eigenen Tabelle zeigt — danach sucht
    # jemand im Log. `AVDID` ("AVD-DS-0002") bleibt der Rueckfall.
    # Die Reihenfolge ist kollisionsfrei: Schwachstellen tragen kein `ID`,
    # Secrets tragen `RuleID`.
    for field in ("VulnerabilityID", "RuleID", "ID", "AVDID"):
        value = finding.get(field)
        if value:
            return str(value)
    return kind


def _identity(kind: str, finding: dict) -> str:
    fields = IDENTITY_FIELDS[kind]
    key = [_where(finding) if f == "_where" else finding.get(f) for f in fields]
    if not any(v is not None for v in key):
        # Nothing recognisable to key on — fall back to the whole object rather
        # than collapsing unrelated findings into one.
        return json.dumps(finding, sort_keys=True)
    return json.dumps([kind, *key], sort_keys=True)


def _result_key(result: dict) -> str:
    return json.dumps(
        [result.get("Target"), result.get("Class"), result.get("Type")],
        sort_keys=True,
    )


def merge(documents: list[dict]) -> dict:
    if not documents:
        raise SystemExit("no reports to merge")

    merged = dict(documents[0])
    merged_results: list[dict] = []
    by_key: dict[str, dict] = {}
    # ident -> der BEHALTENE Fund, nicht nur seine Identitaet: nur so laesst
    # sich ein spaeteres Duplikat inhaltlich mit ihm vergleichen (Audit L-6).
    seen: dict[str, dict[str, dict]] = {}

    for doc in documents:
        for result in doc.get("Results") or []:
            key = _result_key(result)
            target = by_key.get(key)
            if target is None:
                target = {k: v for k, v in result.items() if k not in FINDING_KEYS}
                for kind in FINDING_KEYS:
                    if kind in result:
                        target[kind] = []
                by_key[key] = target
                seen[key] = {}
                merged_results.append(target)

            for kind in FINDING_KEYS:
                findings = result.get(kind)
                if not findings:
                    continue
                target.setdefault(kind, [])
                for finding in findings:
                    ident = _identity(kind, finding)
                    kept = seen[key].get(ident)
                    if kept is not None:
                        differing = [
                            f
                            for f in MATERIAL_FIELDS.get(kind, ())
                            if kept.get(f) != finding.get(f)
                        ]
                        if differing:
                            detail = ", ".join(
                                f"{f}: {kept.get(f)!r} vs {finding.get(f)!r}"
                                for f in differing
                            )
                            print(
                                f"::warning::trivy {SINGULAR.get(kind, kind)} {_label(kind, finding)} "
                                f"in {result.get('Target')} differs between reports "
                                f"({detail}); keeping the first",
                                file=sys.stderr,
                            )
                        continue
                    seen[key][ident] = finding
                    target[kind].append(finding)

    merged["Results"] = merged_results
    return merged


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

    total = sum(
        len(result.get(kind) or [])
        for result in merged["Results"]
        for kind in FINDING_KEYS
    )
    print(f"merged {len(inputs)} report(s) -> {total} finding(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
