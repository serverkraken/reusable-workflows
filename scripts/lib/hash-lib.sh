#!/usr/bin/env bash
# scripts/lib/hash-lib.sh — portable sha256 helper.
#
# Sourced by scripts/onboard-render.sh and scripts/onboard-drift.sh.
# Linux ships sha256sum; macOS ships shasum -a 256. Both emit
# "<hex> <filename>" — we take the first field.
#
# Pure source-only library: no top-level statements, no shell-option changes.

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | cut -d' ' -f1
  else
    shasum -a 256 "$file" | cut -d' ' -f1
  fi
}
