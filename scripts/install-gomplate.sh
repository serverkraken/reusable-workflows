#!/usr/bin/env bash
# install-gomplate.sh — fetch a pinned gomplate release into $DEST (default /usr/local/bin/gomplate).
#
# Used by .github/workflows/validate.yml so that shell tests (bats) can render
# adopter templates through the catalog's renderer.

set -euo pipefail

# renovate: datasource=github-releases depName=hairyhenderson/gomplate
VERSION="${GOMPLATE_VERSION:-v3.11.7}"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "::error::unsupported arch: $ARCH" >&2; exit 1 ;;
esac

URL="https://github.com/hairyhenderson/gomplate/releases/download/${VERSION}/gomplate_${OS}-${ARCH}"
DEST="${DEST:-/usr/local/bin/gomplate}"

curl -fsSL "$URL" -o "$DEST"
chmod +x "$DEST"
"$DEST" --version
