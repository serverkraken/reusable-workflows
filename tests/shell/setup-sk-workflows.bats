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
printf '%s\n' "$*" >> "${SK_TEST_CURL_ARGV_LOG:-/dev/null}"
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
    --config)
      # `--config -` feeds curl options via stdin; capture them so tests can
      # assert the Authorization header arrives without touching argv.
      if [[ "$2" == "-" ]]; then
        cat >> "${SK_TEST_CURL_CONFIG_LOG:-/dev/null}"
      fi
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
  # Das Staging-Verzeichnis liegt in $install_dir, und das ueberlebt auf
  # selbst-gehosteten Runnern den Job. Bleibt es liegen, waechst es mit jedem
  # Lauf - also aufgeraeumt, nicht nur im Fehlerfall ueber den trap.
  [ -z "$(ls -A "$INSTALL_DIR" | grep '^\.sk-extract' || true)" ]
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

@test "release install via curl keeps the token out of curl argv" {
  make_release_assets "v4.2.4" "amd64"
  install_fake_curl
  export SK_TEST_RELEASE_DIR="$RELEASE_DIR"
  export SK_TEST_CURL_ARGV_LOG="$TMPDIR/curl-argv"
  export SK_TEST_CURL_CONFIG_LOG="$TMPDIR/curl-config"
  export INPUT_VERSION="v4.2.4"
  export INPUT_GITHUB_TOKEN="secret-token"

  # Hermetic PATH without gh so the curl fallback runs even on hosts that
  # have gh installed. bash is needed because the fake curl's `env` shebang
  # resolves it via PATH.
  tools="$TMPDIR/tools"
  mkdir -p "$tools"
  # gzip: GNU tar on Linux execs it as a child for -z (bsdtar on macOS
  # decompresses in-process, so its absence only shows up in CI).
  for t in bash awk chmod dirname mkdir mktemp rm tar tr uname cp mv basename cat gzip; do
    ln -s "$(command -v "$t")" "$tools/$t"
  done
  for t in sha256sum shasum; do
    command -v "$t" >/dev/null 2>&1 && ln -s "$(command -v "$t")" "$tools/$t"
  done

  run env PATH="$FAKE_BIN:$tools" bash "$SCRIPT"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx "version=v4.2.4" "$GITHUB_OUTPUT"
  grep -qx "source=release" "$GITHUB_OUTPUT"
  # The token must never appear in curl argv (visible in the process list on
  # shared runners) — it has to travel via the stdin --config channel.
  run grep -c "secret-token" "$SK_TEST_CURL_ARGV_LOG"
  [ "$output" = "0" ]
  grep -q 'header = "Authorization: Bearer secret-token"' "$SK_TEST_CURL_CONFIG_LOG"
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

# Audit H-18: ein Archiv, das sauber entpackt und `sk-workflows` trotzdem nicht
# enthaelt, darf nicht als erfolgreiche Installation durchgehen.
#
# $install_dir liegt per Vorgabe unter $RUNNER_TEMP bzw. /tmp, und das bleibt auf
# selbst-gehosteten Runnern zwischen Jobs bestehen. Vor dem Fix blieb deshalb das
# Binary der VORIGEN Installation stehen: `tar` rc=0, `chmod` rc=0, und
# emit_outputs meldete die NEUE Version fuer ein altes Binary.
#
# Die Pruefsumme faengt das nicht ab: sie belegt, dass das Archiv dem entspricht,
# was veroeffentlicht wurde - nicht, dass darin das Erwartete liegt.
make_release_asset_without_binary() {
  local version="$1"
  local staging="$TMPDIR/staging-empty"
  local asset="sk-workflows_${version}_linux_amd64.tar.gz"
  mkdir -p "$staging"
  echo "versehentlich nur die README veroeffentlicht" > "$staging/README.md"
  tar -C "$staging" -czf "$RELEASE_DIR/$asset" README.md
  local checksum
  checksum="$(checksum_file "$RELEASE_DIR/$asset")"
  echo "$checksum  $asset" > "$RELEASE_DIR/sk-workflows_${version}_checksums.txt"
}

@test "release asset without the binary fails instead of keeping a stale one" {
  make_release_asset_without_binary "v4.9.0"
  install_fake_curl
  export SK_TEST_RELEASE_DIR="$RELEASE_DIR"
  export INPUT_VERSION="v4.9.0"

  # Ein persistenter Runner: die vorige Installation liegt noch da.
  mkdir -p "$INSTALL_DIR"
  {
    echo "#!/usr/bin/env sh"
    echo "echo release-v4.0.0-amd64"
  } > "$INSTALL_DIR/sk-workflows"
  chmod +x "$INSTALL_DIR/sk-workflows"

  run bash "$SCRIPT"

  # 1. Der Lauf scheitert - und sagt auch, woran.
  [ "$status" -ne 0 ]
  [[ "$output" == *"without a sk-workflows binary"* ]] || { echo "$output"; false; }

  # 2. Entscheidend: die neue Version wird NICHT als installiert gemeldet.
  #    Genau das tat der alte Code, waehrend das alte Binary liegen blieb.
  ! grep -qx "version=v4.9.0" "$GITHUB_OUTPUT"
  ! grep -qx "source=release" "$GITHUB_OUTPUT"

  # 3. Das alte Binary ist unangetastet - der Fix raeumt nichts weg, was er
  #    nicht ersetzen konnte; er verschweigt es nur nicht mehr.
  run "$INSTALL_DIR/sk-workflows"
  [ "$output" = "release-v4.0.0-amd64" ]
}
