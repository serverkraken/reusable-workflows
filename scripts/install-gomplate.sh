#!/usr/bin/env bash
# install-gomplate.sh — fetch a pinned gomplate release into $DEST (default /usr/local/bin/gomplate).
#
# Idempotent: if the desired version is already installed at $DEST, skip the
# download. Re-running is a no-op when the version matches — safe to call as
# a setup step on every action invocation.
#
# Used by:
#   - .github/workflows/validate.yml      bats setup
#   - .github/workflows/onboard.yml       before render step
#   - actions/onboard-drift/action.yml    before drift step (render-and-compare)

set -euo pipefail

# renovate: datasource=github-releases depName=hairyhenderson/gomplate
VERSION="${GOMPLATE_VERSION:-v3.11.7}"
DEST="${DEST:-/usr/local/bin/gomplate}"

if [[ -x "$DEST" ]]; then
  # gomplate's --version output: "gomplate version 3.11.7"
  # Match the numeric tail of $VERSION (strip leading "v") against the existing binary.
  want="${VERSION#v}"
  if "$DEST" --version 2>/dev/null | grep -qE "version ${want}\b"; then
    echo "gomplate ${VERSION} already installed at $DEST — skipping download"
    exit 0
  fi
fi

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "::error::unsupported arch: $ARCH" >&2; exit 1 ;;
esac

URL="https://github.com/hairyhenderson/gomplate/releases/download/${VERSION}/gomplate_${OS}-${ARCH}"

curl -fsSL "$URL" -o "$DEST"
chmod +x "$DEST"
"$DEST" --version
