#!/usr/bin/env bash
# onboard-render.sh — render adopter-template files into a target workspace.
#
# Usage:
#   onboard-render.sh <catalog-path> <target-path> <release-type> <current-version> <pin-version>
#
# Writes six files into <target>:
#   .github/workflows/{ci,release,prerelease,cleanup}.yml
#   release-please-config.json
#   .release-please-manifest.json
#
# Substitutions:
#   YAML templates: literal "@v1" → "@<pin-version>"
#   Config tmpl:    "{{RELEASE_TYPE}}" → <release-type>
#   Manifest tmpl:  "{{VERSION}}"      → <current-version>

set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "::error::usage: $0 <catalog> <target> <release-type> <current-version> <pin-version>" >&2
  exit 2
fi

CATALOG="$1"
TARGET="$2"
RELEASE_TYPE="$3"
CURRENT_VERSION="$4"
PIN_VERSION="$5"

TEMPLATES="$CATALOG/docs/adopter-templates"

mkdir -p "$TARGET/.github/workflows"

# YAML workflow templates — replace @v1 with @<pin>.
# Uses an explicit non-identifier-or-EOL guard instead of \b because BSD/macOS
# sed silently ignores \b, which would let @v10 / @v1.0.0 match incorrectly.
for name in ci release prerelease cleanup; do
  src="$TEMPLATES/${name}.yml"
  dst="$TARGET/.github/workflows/${name}.yml"
  if [[ ! -f "$src" ]]; then
    echo "::error::template missing: $src" >&2
    exit 1
  fi
  sed -E "s/@v1([^a-zA-Z0-9._]|$)/@${PIN_VERSION}\1/g" "$src" > "$dst"
done

# release-please-config.json.tmpl
src="$TEMPLATES/release-please-config.json.tmpl"
dst="$TARGET/release-please-config.json"
if [[ ! -f "$src" ]]; then
  echo "::error::template missing: $src" >&2
  exit 1
fi
sed "s|{{RELEASE_TYPE}}|${RELEASE_TYPE}|g" "$src" > "$dst"

# release-please-manifest.json.tmpl
src="$TEMPLATES/release-please-manifest.json.tmpl"
dst="$TARGET/.release-please-manifest.json"
if [[ ! -f "$src" ]]; then
  echo "::error::template missing: $src" >&2
  exit 1
fi
sed "s|{{VERSION}}|${CURRENT_VERSION}|g" "$src" > "$dst"
