#!/usr/bin/env bash
set -euo pipefail

INPUT_VERSION="${INPUT_VERSION:-}"
INPUT_REPOSITORY="${INPUT_REPOSITORY:-serverkraken/reusable-workflows}"
INPUT_GITHUB_TOKEN="${INPUT_GITHUB_TOKEN:-}"
INPUT_INSTALL_DIR="${INPUT_INSTALL_DIR:-}"
INPUT_BUILD_FROM_SOURCE="${INPUT_BUILD_FROM_SOURCE:-false}"

install_dir="$INPUT_INSTALL_DIR"
if [[ -z "$install_dir" ]]; then
  install_dir="${RUNNER_TEMP:-/tmp}/sk-workflows/bin"
fi
mkdir -p "$install_dir"

emit_outputs() {
  local binary="$1"
  local version="$2"
  local source="$3"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "path=$binary"
      echo "version=$version"
      echo "source=$source"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$install_dir" >> "$GITHUB_PATH"
  fi
}

catalog_root() {
  if [[ -n "${SK_WORKFLOWS_CATALOG_ROOT:-}" ]]; then
    cd "$SK_WORKFLOWS_CATALOG_ROOT"
    pwd
    return
  fi
  if [[ -n "${GITHUB_ACTION_PATH:-}" ]]; then
    cd "$GITHUB_ACTION_PATH/../.."
    pwd
    return
  fi
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
}

if [[ "$INPUT_BUILD_FROM_SOURCE" == "true" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "::error::build_from_source=true but no 'go' toolchain found" >&2
    exit 1
  fi
  binary="$install_dir/sk-workflows"
  (
    cd "$(catalog_root)"
    go build -trimpath -o "$binary" ./cmd/sk-workflows
  )
  chmod +x "$binary"
  emit_outputs "$binary" "source" "source"
  exit 0
fi

version="$INPUT_VERSION"
if [[ -z "$version" && "${GITHUB_ACTION_REF:-}" == v* ]]; then
  version="$GITHUB_ACTION_REF"
fi
if [[ -z "$version" ]]; then
  echo "::error::version is required unless the action is used from a v* tag or build_from_source=true" >&2
  exit 1
fi

os_name="${SK_WORKFLOWS_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
arch_name="${SK_WORKFLOWS_ARCH:-$(uname -m)}"
case "$os_name" in
  linux) os_name="linux" ;;
  *)
    echo "::error::unsupported OS for release install: $os_name" >&2
    exit 1
    ;;
esac
case "$arch_name" in
  x86_64 | amd64) arch_name="amd64" ;;
  aarch64 | arm64) arch_name="arm64" ;;
  *)
    echo "::error::unsupported architecture for release install: $arch_name" >&2
    exit 1
    ;;
esac

asset="sk-workflows_${version}_${os_name}_${arch_name}.tar.gz"
checksums="sk-workflows_${version}_checksums.txt"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -n "$INPUT_GITHUB_TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN="$INPUT_GITHUB_TOKEN" gh release download "$version" \
    --repo "$INPUT_REPOSITORY" \
    --pattern "$asset" \
    --pattern "$checksums" \
    --dir "$tmp"
else
  base_url="https://github.com/${INPUT_REPOSITORY}/releases/download/${version}"
  curl_args=(-fsSL)
  curl_config=""
  if [[ -n "$INPUT_GITHUB_TOKEN" ]]; then
    # Feed the Authorization header through `--config -` (stdin) instead of
    # argv: header arguments are visible to every user on the runner via the
    # process list for the lifetime of the download.
    curl_args+=(--config -)
    curl_config="header = \"Authorization: Bearer $INPUT_GITHUB_TOKEN\""
  fi
  curl "${curl_args[@]}" -o "$tmp/$asset" "$base_url/$asset" <<< "$curl_config"
  curl "${curl_args[@]}" -o "$tmp/$checksums" "$base_url/$checksums" <<< "$curl_config"
fi

expected="$(awk -v file="$asset" '$2 == file {print $1}' "$tmp/$checksums")"
if [[ -z "$expected" ]]; then
  echo "::error::checksum for $asset not found in $checksums" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
fi
if [[ "$actual" != "$expected" ]]; then
  echo "::error::checksum mismatch for $asset" >&2
  exit 1
fi

# In ein FRISCHES Verzeichnis entpacken, nicht direkt nach $install_dir
# (Audit H-18).
#
# $install_dir liegt per Vorgabe unter ${RUNNER_TEMP:-/tmp}/sk-workflows/bin,
# und /tmp bleibt auf selbst-gehosteten Runnern zwischen Jobs bestehen — das
# weiss dieses Repo an anderer Stelle laengst ("Clean digest dir (self-hosted
# runners persist /tmp between jobs)").
#
# `set -e` faengt ein abbrechendes tar. Es faengt NICHT ein Archiv, das sauber
# entpackt und `sk-workflows` trotzdem nicht enthaelt — etwa nach einem Release
# mit umbenanntem oder unvollstaendigem Asset. Nachgestellt:
#
#   tar rc=0, chmod rc=0, gemeldet wird version=<neu>,
#   ausgefuehrt wird das ALTE Binary von der vorigen Installation.
#
# Die Pruefsumme schuetzt davor nicht: sie belegt, dass das Archiv dem
# entspricht, was veroeffentlicht wurde — nicht, dass darin das Erwartete liegt.
#
# Besonders tueckisch ist die Asymmetrie: auf einem frischen Runner faellt es
# sofort auf (kein Binary), auf einem persistenten laeuft still die alte
# Version weiter.
# Das Staging-Verzeichnis liegt bewusst INNERHALB von $install_dir und nicht
# unter $tmp: nur so ist das abschliessende `mv` ein Rename im selben
# Dateisystem und damit atomar. Ueber Dateisystemgrenzen waere es ein Kopieren,
# und ein Abbruch mittendrin hinterliesse ein halbes, ausfuehrbares Binary -
# also wieder ein falscher Erfolg, nur eine Ebene tiefer.
extract="$install_dir/.sk-extract.$$"
rm -rf "$extract"
mkdir -p "$extract"
trap 'rm -rf "$tmp" "$extract"' EXIT
tar -xzf "$tmp/$asset" -C "$extract"

staged="$extract/sk-workflows"
if [[ ! -f "$staged" ]]; then
  {
    echo "::error::$asset extracted without a sk-workflows binary."
    echo "The checksum matched, so the published asset itself is wrong —"
    echo "re-releasing is the fix, not re-running. Contents were:"
    tar -tzf "$tmp/$asset" 2>/dev/null | sed 's/^/  /' | head -20
  } >&2
  exit 1
fi

binary="$install_dir/sk-workflows"
chmod +x "$staged"
mv -f "$staged" "$binary"   # atomarer Rename, siehe oben
rm -rf "$extract"
emit_outputs "$binary" "$version" "release"
