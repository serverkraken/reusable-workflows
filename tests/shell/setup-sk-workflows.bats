#!/usr/bin/env bats

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  SCRIPT="$REPO_ROOT/scripts/setup-sk-workflows.sh"
  TMPDIR="$(mktemp -d)"
  FAKE_BIN="$TMPDIR/bin"
  RELEASE_DIR="$TMPDIR/release"
  INSTALL_DIR="$TMPDIR/install"
  mkdir -p "$FAKE_BIN" "$RELEASE_DIR"

  export PATH="$FAKE_BIN:$PATH"
  export GITHUB_OUTPUT="$TMPDIR/github-output"
  export GITHUB_PATH="$TMPDIR/github-path"
  export INPUT_VERSION=""
  export INPUT_REPOSITORY="serverkraken/reusable-workflows"
  export INPUT_GITHUB_TOKEN=""
  export INPUT_INSTALL_DIR="$INSTALL_DIR"
  export INPUT_BUILD_FROM_SOURCE="false"
  export GITHUB_ACTION_REF=""
  export SK_WORKFLOWS_OS="linux"
  export SK_WORKFLOWS_ARCH="amd64"
  export SK_WORKFLOWS_CATALOG_ROOT="$REPO_ROOT"
}

teardown() {
  rm -rf "$TMPDIR"
}

checksum_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

make_release_assets() {
  local version="${1:-v4.2.0}"
  local arch="${2:-amd64}"
  local staging="$TMPDIR/staging-$arch"
  local asset="sk-workflows_${version}_linux_${arch}.tar.gz"
  mkdir -p "$staging"
  {
    echo "#!/usr/bin/env sh"
    echo "echo release-${version}-${arch}"
  } > "$staging/sk-workflows"
  chmod +x "$staging/sk-workflows"
  tar -C "$staging" -czf "$RELEASE_DIR/$asset" sk-workflows
  checksum="$(checksum_file "$RELEASE_DIR/$asset")"
  echo "$checksum  $asset" > "$RELEASE_DIR/sk-workflows_${version}_checksums.txt"
}

install_fake_curl() {
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
cp "$SK_TEST_RELEASE_DIR/$(basename "$url")" "$out"
EOF
  chmod +x "$FAKE_BIN/curl"
}

install_fake_gh() {
  cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${GH_TOKEN:-}" > "$SK_TEST_GH_TOKEN_FILE"
dir=""
patterns=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern)
      patterns+=("$2")
      shift 2
      ;;
    --dir)
      dir="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
for pattern in "${patterns[@]}"; do
  cp "$SK_TEST_RELEASE_DIR/$pattern" "$dir/$pattern"
done
EOF
  chmod +x "$FAKE_BIN/gh"
}

install_fake_go() {
  cat > "$FAKE_BIN/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$(dirname "$out")"
{
  echo "#!/usr/bin/env sh"
  echo "echo source-build"
} > "$out"
chmod +x "$out"
EOF
  chmod +x "$FAKE_BIN/go"
}

@test "release install via curl verifies checksum and emits outputs" {
  make_release_assets "v4.2.0" "amd64"
  install_fake_curl
  export SK_TEST_RELEASE_DIR="$RELEASE_DIR"
  export INPUT_VERSION="v4.2.0"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -x "$INSTALL_DIR/sk-workflows" ]
  run "$INSTALL_DIR/sk-workflows"
  [ "$status" -eq 0 ]
  [ "$output" = "release-v4.2.0-amd64" ]
  grep -qx "path=$INSTALL_DIR/sk-workflows" "$GITHUB_OUTPUT"
  grep -qx "version=v4.2.0" "$GITHUB_OUTPUT"
  grep -qx "source=release" "$GITHUB_OUTPUT"
  grep -qx "$INSTALL_DIR" "$GITHUB_PATH"
}

@test "release install uses gh when token and gh are available" {
  make_release_assets "v4.2.1" "amd64"
  install_fake_gh
  export SK_TEST_RELEASE_DIR="$RELEASE_DIR"
  export SK_TEST_GH_TOKEN_FILE="$TMPDIR/gh-token"
  export INPUT_VERSION="v4.2.1"
  export INPUT_GITHUB_TOKEN="secret-token"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$SK_TEST_GH_TOKEN_FILE")" = "secret-token" ]
  grep -qx "version=v4.2.1" "$GITHUB_OUTPUT"
  grep -qx "source=release" "$GITHUB_OUTPUT"
}

@test "release install fails on checksum mismatch" {
  make_release_assets "v4.2.2" "amd64"
  install_fake_curl
  export SK_TEST_RELEASE_DIR="$RELEASE_DIR"
  export INPUT_VERSION="v4.2.2"
  echo "000000  sk-workflows_v4.2.2_linux_amd64.tar.gz" > "$RELEASE_DIR/sk-workflows_v4.2.2_checksums.txt"

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "checksum mismatch" ]]
}

@test "version can resolve from GITHUB_ACTION_REF" {
  make_release_assets "v4.3.0" "amd64"
  install_fake_curl
  export SK_TEST_RELEASE_DIR="$RELEASE_DIR"
  export GITHUB_ACTION_REF="v4.3.0"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx "version=v4.3.0" "$GITHUB_OUTPUT"
}

@test "build_from_source uses go and emits source outputs" {
  install_fake_go
  export INPUT_BUILD_FROM_SOURCE="true"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -x "$INSTALL_DIR/sk-workflows" ]
  run "$INSTALL_DIR/sk-workflows"
  [ "$status" -eq 0 ]
  [ "$output" = "source-build" ]
  grep -qx "version=source" "$GITHUB_OUTPUT"
  grep -qx "source=source" "$GITHUB_OUTPUT"
}

@test "missing version fails unless source build is requested" {
  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "version is required" ]]
}
