#!/usr/bin/env bash
# onboard-sweep-drift-status.sh <owner/repo> <current_major>
# Clones the adopter to a tmpdir, runs scripts/onboard-drift.sh against the
# clone, emits the status value (e.g. "clean", "behind", "stale-lock") to
# stdout. Used by .github/workflows/onboard-sweep.yml's enumerate job to
# bucket onboarded repos into update vs skipped.
#
# Requires GH_TOKEN env var with read access to the target repo.
# When env var ONBOARD_SWEEP_TARGET_PATH is set, skips the clone and runs
# drift against that path directly — used by bats tests to avoid network.
set -euo pipefail

TARGET="${1:-}"
CURRENT="${2:-}"

if [[ -z "$TARGET" || -z "$CURRENT" ]]; then
  echo "::error::usage: $0 <owner/repo> <current_major>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${ONBOARD_SWEEP_TARGET_PATH:-}" ]]; then
  # Test mode — caller already prepared the target tree.
  target_path="$ONBOARD_SWEEP_TARGET_PATH"
else
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN env var required to clone $TARGET" >&2
    exit 1
  fi
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  # Der Token steckte in der Klon-URL und damit im ARGV von git (Audit H-16):
  # auf einem self-hosted Runner ist argv ueber `ps` fuer jeden Prozess auf
  # demselben Host lesbar. Zweiter Weg nach draussen: git schreibt die
  # Remote-URL in .git/config des Klons, der Token lag also auch auf Platte.
  #
  # GIT_CONFIG_COUNT/KEY/VALUE (git >= 2.31) setzen dieselbe Konfiguration ueber
  # die UMGEBUNG. Die steht nicht in argv, und sie wird nicht in den Klon
  # uebernommen — die Remote-URL bleibt token-frei. `-c` waere kein Ersatz
  # gewesen: -c-Argumente stehen genauso in argv.
  #
  # `tr -d '\n'` statt `base64 -w0`: -w gibt es in BSD-base64 nicht, und die
  # bats-Suite laeuft auch auf macOS.
  auth=$(printf '%s' "x-access-token:${GH_TOKEN}" | base64 | tr -d '\n')
  if ! GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
       GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${auth}" \
       git clone --depth=1 --quiet \
       "https://github.com/${TARGET}.git" \
       "$tmpdir/target" 2>/dev/null; then
    # Clone failure → emit "error" so the caller can bucket it as skipped.
    echo "error"
    exit 0
  fi
  target_path="$tmpdir/target"
fi

output=$(CATALOG_CURRENT_VERSION="$CURRENT" \
  "$SCRIPT_DIR/onboard-drift.sh" "$target_path" "$CATALOG_ROOT")
echo "$output" | grep '^status=' | cut -d= -f2-
