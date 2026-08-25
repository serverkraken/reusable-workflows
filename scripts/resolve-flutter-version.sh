#!/usr/bin/env bash
# Resolve the release version for release-flutter-android.yml.
#
# Usage: resolve-flutter-version.sh <input_version> <create_release> <run_number>
#
# Prints GH-Actions output lines on stdout (pipe into $GITHUB_OUTPUT):
#   bare=<X.Y.Z[-suffix]>
#   tag=v<bare>
#
# Rules:
# - <input_version> non-empty: leading `v` is stripped, the result must start
#   with an X.Y.Z core — otherwise hard error (the caller asked for exactly
#   this version, so an unusable value must not be silently replaced).
# - <input_version> empty: only allowed with create_release=true. Derives
#   <latest>-rc.<run_number> where <latest> is the newest reachable EXACT
#   version tag (vX.Y.Z or X.Y.Z). Rolling major/minor tags (v0, v0.40) and
#   non-version tags (archive/*) are excluded via `git describe --match`;
#   without the filter a rolling tag like v0 yields the non-semver "0-rc.N"
#   (strassenfuchs run 30762809021). If no exact version tag exists the
#   fallback is 0.0.0-rc.<run_number> — a manual build must not die on the
#   adopter's tag zoo.
set -euo pipefail

INPUT_VERSION="${1:-}"
CREATE_RELEASE="${2:-}"
RUN_NUMBER="${3:-}"

# Beide Muster sind an BEIDEN Enden verankert. Frueher stand hier nur
# `^[0-9]+\.[0-9]+\.[0-9]+` - der Anfang war gebunden, das Ende nicht, und
# damit bestand alles, was mit X.Y.Z BEGINNT (Audit I-17). Gemessen am alten
# Stand:
#
#   1.2.3.4                 -> tag=v1.2.3.4
#   1.2.3abc                -> tag=v1.2.3abc
#   "1.2.3 && echo PWNED"   -> tag=v1.2.3 && echo PWNED
#   "1.2.3\nEXTRA=injected" -> zwei Zeilen in GITHUB_OUTPUT
#
# Der letzte Fall ist der schwerwiegende: der Aufrufer schreibt die Ausgabe mit
# `echo "$OUT" >> "$GITHUB_OUTPUT"` weiter (release-flutter-android.yml:190),
# ein Zeilenumbruch im `version`-Input schiebt also beliebige Step-Outputs
# unter.
#
# SEMVER_FULL laesst SemVer-Prerelease und -Build-Metadaten zu, denn der
# Auto-Pfad erzeugt selbst `X.Y.Z-rc.<n>`.
SEMVER_CORE='^[0-9]+\.[0-9]+\.[0-9]+$'
SEMVER_FULL='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

V="${INPUT_VERSION#v}"
if [[ -z "$V" ]]; then
  if [[ "$CREATE_RELEASE" != "true" ]]; then
    echo "::error::version is required unless create_release=true" >&2
    exit 1
  fi
  # `|| echo "0.0.0"` faengt zwei verschiedene Lagen: "das Repo hat keine
  # passenden Tags" (normal, der Fallback ist genau dafuer da) und "git konnte
  # gar nicht antworten" (ein kaputter Checkout). Der Fallback BLEIBT in beiden
  # Faellen - dieser Pfad soll laut Kontrakt einen manuellen Build nicht
  # sterben lassen -, aber die zweite Lage wird jetzt benannt statt verschwiegen
  # (Audit I-12). Ein manueller Build, der still `0.0.0-rc.N` baut, weil der
  # Checkout kaputt ist, sieht sonst aus wie ein Repo vor seinem ersten Tag.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "::warning::not a git repository — cannot read tags; falling back to 0.0.0" >&2
    LATEST="0.0.0"
  else
    LATEST=$(git describe --tags --abbrev=0 \
      --match 'v[0-9]*.[0-9]*.[0-9]*' \
      --match '[0-9]*.[0-9]*.[0-9]*' \
      2>/dev/null || echo "0.0.0")
  fi
  # Strip a leading v and any +build / -prerelease suffix so the rc
  # identifier attaches to a clean X.Y.Z core.
  LATEST="${LATEST#v}"; LATEST="${LATEST%%+*}"; LATEST="${LATEST%%-*}"
  if [[ ! "$LATEST" =~ $SEMVER_CORE ]]; then
    # --match globs are not anchored semver; belt-and-braces for tags like
    # v1.x that still slip through. Never hard-fail the auto path.
    LATEST="0.0.0"
  fi
  V="${LATEST}-rc.${RUN_NUMBER}"
  echo "Auto-derived manual build version: $V" >&2
fi

if [[ ! "$V" =~ $SEMVER_FULL ]]; then
  # Zeilenumbrueche im Wert escapen, bevor er ins Log geht: sonst ist die
  # Fehlermeldung selbst mehrzeilig, und ihre Folgezeilen sehen aus wie
  # `key=value`. Das ist zwar stderr und kein GITHUB_OUTPUT, aber eine
  # Fehlermeldung, die man mit der Eingabe formen kann, ist eine schlechte
  # Fehlermeldung.
  echo "::error::resolved version does not look like semver: ${V//$'\n'/\\n}" >&2
  exit 1
fi

echo "bare=$V"
echo "tag=v$V"
