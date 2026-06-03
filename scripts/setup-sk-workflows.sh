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
  if [[ -n "$INPUT_GITHUB_TOKEN" ]]; then
    curl_args+=(-H "Authorization: Bearer $INPUT_GITHUB_TOKEN")
  fi
  curl "${curl_args[@]}" -o "$tmp/$asset" "$base_url/$asset"
  curl "${curl_args[@]}" -o "$tmp/$checksums" "$base_url/$checksums"
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

tar -xzf "$tmp/$asset" -C "$install_dir"
binary="$install_dir/sk-workflows"
chmod +x "$binary"
emit_outputs "$binary" "$version" "release"
