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

assets=()

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
  assets+=("$asset")
  echo "built $out_dir/$asset"
}

checksums="sk-workflows_${version}_checksums.txt"

# Alles zu dieser Version wegräumen, BEVOR gebaut wird (Audit I-9). Der
# Aufrufer laedt das Verzeichnis pauschal hoch:
#
#   gh release upload "$TAG_NAME" dist/sk-workflows/* --clobber
#
# Ein Archiv aus einem frueheren Lauf, dessen Ziel-Plattform inzwischen nicht
# mehr gebaut wird, wuerde damit als offizielles Release-Asset veroeffentlicht -
# gebaut aus einem anderen Commit, unter dem Namen dieser Version.
#
# Der ausgelieferte Aufrufer ist davon NICHT betroffen: catalog-release.yml
# laeuft auf `ubuntu-latest`, also auf einem ephemeren Runner mit frischem
# Workspace. Das ist eine Eigenschaft des Aufrufers, nicht dieses Skripts - auf
# einem self-hosted Runner oder lokal ueberlebt das Verzeichnis. Ein Skript,
# dessen Korrektheit daran haengt, wo es zufaellig laeuft, ist keins.
rm -f "$out_dir"/sk-workflows_"$version"_*.tar.gz "$out_dir/$checksums"

build_asset linux amd64
build_asset linux arm64

# Die Pruefsummen entstehen aus der Liste des tatsaechlich Gebauten, nicht aus
# einem Glob ueber das Verzeichnis. Sonst beschreibt die Datei, was dort liegt,
# statt was dieser Lauf erzeugt hat - derselbe Fehler eine Ebene tiefer.
(
  cd "$out_dir"
  : > "$checksums"
  for asset in "${assets[@]}"; do
    checksum_file "$asset" >> "$checksums"
  done
  echo "built $out_dir/$checksums"
)

# Was sonst noch im Verzeichnis liegt, wird trotzdem hochgeladen. Das kann
# dieses Skript nicht verhindern, aber es kann es sagen.
shopt -s nullglob
stray=()
for f in "$out_dir"/*; do
  case "${f##*/}" in
    "$checksums") continue ;;
    sk-workflows_"$version"_*.tar.gz) continue ;;
    *) stray+=("${f##*/}") ;;
  esac
done
if (( ${#stray[@]} > 0 )); then
  echo "::warning::$out_dir also contains files this run did not build; the release upload globs the whole directory: ${stray[*]}" >&2
fi
