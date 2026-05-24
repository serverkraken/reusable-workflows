#!/usr/bin/env bats
# tests/shell/onboard-drift.bats
#
# Drift detection contract:
#   - clean             — lock hashes match working tree + lock.catalog_version == current
#   - modified          — at least one hash mismatch (working tree edited)
#   - behind            — lock.catalog_version != current_version env
#   - behind+modified   — both
#   - no-lock           — .github/onboard.lock.json absent (adopter pre-Phase-3)
#
# Plus reproducibility: re-rendering a fixture at the locked catalog version
# must produce byte-identical files — drift-check relies on this so the lock
# stays comparable against what a re-render would emit.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  DRIFT="$REPO_ROOT/scripts/onboard-drift.sh"
  DETECT="$REPO_ROOT/scripts/onboard-detect.sh"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  FIX="$REPO_ROOT/tests/fixtures/onboard"

  source "$REPO_ROOT/scripts/lib/hash-lib.sh"

  TARGET=$(mktemp -d)
  profile=$("$DETECT" --profile-json "$FIX/go-repo")
  echo "$profile" > "$TARGET/profile.json"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v3"
  rm "$TARGET/profile.json"
  # Copy fixture source into target so detect could re-run there if a future
  # test needs it. Drift script itself only reads lock + file hashes.
  cp -R "$FIX/go-repo/." "$TARGET/" 2>/dev/null || true
}

teardown() {
  rm -rf "$TARGET"
}

@test "drift: clean state reports clean" {
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
}

@test "drift: hand-edit on ci.yml reports modified" {
  echo "# tampered" >> "$TARGET/.github/workflows/ci.yml"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=modified"* ]]
  [[ "$output" == *"ci.yml"* ]]
}

@test "drift: lock.catalog_version < current reports behind" {
  jq '.catalog_version = "v1"' "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=behind"* ]]
}

@test "drift: behind + modified reports behind+modified" {
  jq '.catalog_version = "v1"' "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"
  echo "# tampered" >> "$TARGET/.github/workflows/release.yml"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=behind+modified"* ]]
  [[ "$output" == *"release.yml"* ]]
}

@test "drift: missing rendered file is reported as modified with (missing) suffix" {
  rm "$TARGET/.github/workflows/cleanup.yml"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=modified"* ]]
  [[ "$output" == *"cleanup.yml(missing)"* ]]
}

@test "drift: missing lock file reports no-lock" {
  rm "$TARGET/.github/onboard.lock.json"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=no-lock"* ]]
}

@test "drift: re-render at locked catalog_version is byte-reproducible" {
  before=$(jq -r '.files' "$TARGET/.github/onboard.lock.json")
  re=$(mktemp -d)
  "$DETECT" --profile-json "$FIX/go-repo" > "$re/profile.json"
  "$RENDER" "$REPO_ROOT" "$re" "$re/profile.json" "v3"
  for f in $(jq -r 'keys[]' <<< "$before"); do
    expected=$(jq -r --arg k "$f" '.[$k]' <<< "$before")
    actual="sha256:$(sha256_of "$re/$f")"
    [ "$expected" = "$actual" ]
  done
  rm -rf "$re"
}

@test "drift: missing TARGET dir errors out cleanly" {
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "/nonexistent/path" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "drift: clean state stays clean when re-render matches lock files" {
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
  # render_error field is present and empty
  [[ "$output" == *"render_error="* ]]
  # Negative: render_error= followed by nothing-but-newline (no error reason captured)
  echo "$output" | grep -E "^render_error=$" >/dev/null
}

@test "drift: clean state flips to stale-lock when catalog template evolves" {
  # Simulate template evolution: clone the catalog to a scratch dir, edit a
  # template in the scratch copy so re-render would produce different output,
  # then run drift against the unchanged TARGET with the scratch catalog as
  # the catalog-source argument.
  scratch_catalog=$(mktemp -d)
  cp -R "$REPO_ROOT/." "$scratch_catalog/"
  # Append a benign marker to ci.yml.tmpl so the rendered ci.yml diverges.
  echo "# stale-lock-test marker $(date +%s%N)" \
    >> "$scratch_catalog/docs/adopter-templates/skeletons/ci.yml.tmpl"
  CATALOG_CURRENT_VERSION=v3 run "$DRIFT" "$TARGET" "$scratch_catalog"
  rm -rf "$scratch_catalog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=stale-lock"* ]]
  # The diverged file should appear in the modified list.
  [[ "$output" == *"ci.yml"* ]]
  # render_error stays empty (render succeeded; just produced different content).
  echo "$output" | grep -E "^render_error=$" >/dev/null
}

@test "drift: render failure keeps status=clean and sets render_error" {
  # Force render-failure by stripping gomplate (and other render-time tools)
  # from PATH. The script still needs core tools (bash, jq, mktemp, etc.) for
  # the lock-comparison phase, so we build a minimal PATH that has those but
  # NOT gomplate.
  fake_path=$(mktemp -d)
  for tool in bash jq mktemp sha256sum cat awk grep cut tr head find sort cmp basename dirname date sed rm; do
    cmd=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$cmd" "$fake_path/$tool"
  done
  CATALOG_CURRENT_VERSION=v3 PATH="$fake_path" run "$DRIFT" "$TARGET" "$REPO_ROOT"
  rm -rf "$fake_path"
  [ "$status" -eq 0 ]
  # Status stays clean (no false-positive stale-lock when render fails).
  [[ "$output" == *"status=clean"* ]]
  # render_error captures the failure phase.
  [[ "$output" =~ render_error=(detect|render)-failed: ]]
}
