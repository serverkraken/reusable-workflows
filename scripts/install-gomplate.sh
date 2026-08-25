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

# SHA-256 der offiziellen Release-Assets, festgenagelt IM SKRIPT (Audit I-1).
#
# Vorher lief der Download ohne jede Pruefung: `curl ... -o "$DEST"` gefolgt von
# `chmod +x`. Dieses Skript laeuft unter anderem in onboard.yml, also in einem
# Job mit einem App-Token, das in Adopter-Repos schreiben darf. Ein
# ausgetauschtes Release-Asset haette dort beliebigen Code ausgefuehrt.
#
# Bewusst hier gepinnt statt die mitgelieferte checksums-Datei zu laden: die
# kaeme aus derselben Quelle wie das Binary. Wer das Asset austauschen kann,
# tauscht die Pruefsumme daneben mit aus. Ein Wert im Repo schuetzt zusaetzlich
# gegen ein nachtraeglich neu bespieltes Tag.
#
# Beim Versionswechsel MUSS diese Tabelle mitgezogen werden. Renovate hebt oben
# nur VERSION an; fehlt der passende Eintrag, bricht das Skript ab, statt
# ungeprueft zu installieren. Ein rotes Setup ist die richtige Antwort darauf.
#
# Quelle: checksums-<version>_sha256.txt des jeweiligen Releases.
declare -A GOMPLATE_SHA256=(
  ["v3.11.7 linux-amd64"]="adfa5c7412610dde5fadea07a6b25e7cfa2db462a55b128bdce2ec8fcff22136"
  ["v3.11.7 linux-arm64"]="539b333da0a964d075eb1b99d80b3b20b3cd7024e144aa14931aeddd99a9ad8f"
  ["v3.11.7 darwin-amd64"]="b5fc55a3de030dad9eca555319d1b3ac59bef299d31e1f4e7606ebcf36a386e1"
  ["v3.11.7 darwin-arm64"]="2d503c4467a51a5aa91084a36117d8caa2f69faa78fd58c958ddd72bd81c5d18"
)

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

PLATFORM="${OS}-${ARCH}"
EXPECTED="${GOMPLATE_SHA256[${VERSION} ${PLATFORM}]:-}"
if [[ -z "$EXPECTED" ]]; then
  echo "::error::no pinned SHA-256 for gomplate ${VERSION} on ${PLATFORM}; add it to GOMPLATE_SHA256 in $0 (source: checksums-${VERSION}_sha256.txt of that release) rather than installing unverified" >&2
  exit 1
fi

URL="https://github.com/hairyhenderson/gomplate/releases/download/${VERSION}/gomplate_${PLATFORM}"

# In eine temporaere Datei laden, pruefen, dann erst an den Zielort schieben
# (Audit I-18). Vorher ging der Download direkt nach $DEST: ein Abbruch
# mittendrin hinterliess dort ein halbes Binary, das beim naechsten Lauf
# ausfuehrbar war und dessen `--version` scheiterte - also wurde erneut
# heruntergeladen, wieder direkt darueber. Das temporaere Ziel liegt im selben
# Verzeichnis wie $DEST, damit `mv` ein Rename innerhalb desselben Dateisystems
# bleibt und damit atomar.
DEST_DIR=$(dirname "$DEST")
TMP=$(mktemp "${DEST_DIR}/.gomplate.XXXXXX")
trap 'rm -f "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$TMP" | cut -d' ' -f1)
else
  ACTUAL=$(shasum -a 256 "$TMP" | cut -d' ' -f1)
fi

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "::error::gomplate ${VERSION} (${PLATFORM}) checksum mismatch — refusing to install" >&2
  echo "::error::  expected ${EXPECTED}" >&2
  echo "::error::  actual   ${ACTUAL}" >&2
  exit 1
fi

chmod +x "$TMP"
mv "$TMP" "$DEST"
trap - EXIT
"$DEST" --version
