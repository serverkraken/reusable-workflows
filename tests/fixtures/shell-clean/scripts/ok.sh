#!/usr/bin/env bash
# Fixture: haelt den lint-shell-Happy-Path sauber, auch bei -S style.
set -euo pipefail

greet() {
  local name="$1"
  printf 'hello %s\n' "$name"
}

greet "${1:-world}"
