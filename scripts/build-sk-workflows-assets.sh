#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <version> <out-dir>" >&2
}

version="${1:-}"
out_dir="${2:-}"

if [[ -z "$version" || -z "$out_dir" ]]; then
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

checksum_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
  else
    shasum -a 256 "$file"
  fi
}

build_asset() {
  local goos="$1"
  local goarch="$2"
  local asset="sk-workflows_${version}_${goos}_${goarch}.tar.gz"
  local staging="$tmp/${goos}_${goarch}"

  mkdir -p "$staging"
  (
    cd "$repo_root"
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
      go build -trimpath -ldflags="-s -w" -o "$staging/sk-workflows" ./cmd/sk-workflows
  )
  tar -C "$staging" -czf "$out_dir/$asset" sk-workflows
  echo "built $out_dir/$asset"
}

build_asset linux amd64
build_asset linux arm64

checksums="sk-workflows_${version}_checksums.txt"
(
  cd "$out_dir"
  : > "$checksums"
  for asset in sk-workflows_"$version"_*.tar.gz; do
    checksum_file "$asset" >> "$checksums"
  done
  echo "built $out_dir/$checksums"
)
