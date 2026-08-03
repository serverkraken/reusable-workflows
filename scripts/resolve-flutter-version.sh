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

SEMVER_CORE='^[0-9]+\.[0-9]+\.[0-9]+'

V="${INPUT_VERSION#v}"
if [[ -z "$V" ]]; then
  if [[ "$CREATE_RELEASE" != "true" ]]; then
    echo "::error::version is required unless create_release=true" >&2
    exit 1
  fi
  LATEST=$(git describe --tags --abbrev=0 \
    --match 'v[0-9]*.[0-9]*.[0-9]*' \
    --match '[0-9]*.[0-9]*.[0-9]*' \
    2>/dev/null || echo "0.0.0")
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

if [[ ! "$V" =~ $SEMVER_CORE ]]; then
  echo "::error::resolved version does not look like semver: $V" >&2
  exit 1
fi

echo "bare=$V"
echo "tag=v$V"
