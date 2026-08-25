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
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  rm "$TARGET/profile.json"
  # Copy fixture source into target so detect could re-run there if a future
  # test needs it. Drift script itself only reads lock + file hashes.
  cp -R "$FIX/go-repo/." "$TARGET/" 2>/dev/null || true
}

teardown() {
  rm -rf "$TARGET"
}

@test "drift: clean state reports clean" {
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
}

@test "drift: hand-edit on ci.yml reports modified" {
  echo "# tampered" >> "$TARGET/.github/workflows/ci.yml"
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=modified"* ]]
  [[ "$output" == *"ci.yml"* ]]
}

@test "drift: lock.catalog_version < current reports behind" {
  jq '.catalog_version = "v1"' "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=behind"* ]]
}

@test "drift: behind + modified reports behind+modified" {
  jq '.catalog_version = "v1"' "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"
  echo "# tampered" >> "$TARGET/.github/workflows/release.yml"
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=behind+modified"* ]]
  [[ "$output" == *"release.yml"* ]]
}

@test "drift: missing rendered file is reported as modified with (missing) suffix" {
  rm "$TARGET/.github/workflows/cleanup.yml"
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=modified"* ]]
  [[ "$output" == *"cleanup.yml(missing)"* ]]
}

@test "drift: missing lock file reports no-lock" {
  rm "$TARGET/.github/onboard.lock.json"
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=no-lock"* ]]
}

@test "drift: re-render at locked catalog_version is byte-reproducible" {
  before=$(jq -r '.files' "$TARGET/.github/onboard.lock.json")
  re=$(mktemp -d)
  "$DETECT" --profile-json "$FIX/go-repo" > "$re/profile.json"
  "$RENDER" "$REPO_ROOT" "$re" "$re/profile.json" "v4"
  for f in $(jq -r 'keys[]' <<< "$before"); do
    expected=$(jq -r --arg k "$f" '.[$k]' <<< "$before")
    actual="sha256:$(sha256_of "$re/$f")"
    [ "$expected" = "$actual" ]
  done
  rm -rf "$re"
}

@test "drift: missing TARGET dir errors out cleanly" {
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "/nonexistent/path" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "drift: clean state stays clean when re-render matches lock files" {
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
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
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$scratch_catalog"
  rm -rf "$scratch_catalog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=stale-lock"* ]]
  # The diverged file should appear in the modified list.
  [[ "$output" == *"ci.yml"* ]]
  # render_error stays empty (render succeeded; just produced different content).
  echo "$output" | grep -E "^render_error=$" >/dev/null
}

@test "drift: net-new conditional template flips clean lock to stale-lock" {
  # Simulate an adopter onboarded BEFORE ci-android.yml existed: render the
  # flutter-app fixture at the current catalog, then delete the rendered
  # ci-android.yml and strip its lock entry. Every lock-tracked file still
  # matches the working tree, so lock-comparison says clean — but the
  # re-render now emits a file the lock has no key for. Drift must surface
  # that as stale-lock so the sweep delivers the new file.
  android=$(mktemp -d)
  "$DETECT" --profile-json "$FIX/flutter-app" > "$android/profile.json"
  "$RENDER" "$REPO_ROOT" "$android" "$android/profile.json" "v4"
  rm "$android/profile.json"
  # Copy fixture source so the drift re-render can re-detect the profile.
  cp -R "$FIX/flutter-app/." "$android/" 2>/dev/null || true
  rm "$android/.github/workflows/ci-android.yml"
  jq 'del(.files[".github/workflows/ci-android.yml"])' \
    "$android/.github/onboard.lock.json" > "$android/.github/onboard.lock.json.new"
  mv "$android/.github/onboard.lock.json.new" "$android/.github/onboard.lock.json"

  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$android" "$REPO_ROOT"
  rm -rf "$android"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=stale-lock"* ]]
  [[ "$output" == *".github/workflows/ci-android.yml"* ]]
  # render_error stays empty (render succeeded; lock is just incomplete).
  echo "$output" | grep -E "^render_error=$" >/dev/null
}

@test "drift: render failure reports status=error, not clean" {
  # Force render-failure by stripping gomplate (and other render-time tools)
  # from PATH. The script still needs core tools (bash, jq, mktemp, etc.) for
  # the lock-comparison phase, so we build a minimal PATH that has those but
  # NOT gomplate.
  fake_path=$(mktemp -d)
  for tool in bash jq mktemp sha256sum cat awk grep cut tr head find sort cmp basename dirname date sed rm; do
    cmd=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$cmd" "$fake_path/$tool"
  done
  CATALOG_CURRENT_VERSION=v4 PATH="$fake_path" run "$DRIFT" "$TARGET" "$REPO_ROOT"
  rm -rf "$fake_path"
  [ "$status" -eq 0 ]
  # Frueher meldete dieser Pfad status=clean und legte den Grund in
  # render_error ab. Der woechentliche Sweep greppt nur auf ^status=, verwarf
  # den Grund also — betroffene Repos blieben unbegrenzt gruen und ungeprueft.
  # Ein Render-Fehler ist kein sauberer Befund.
  [[ "$output" == *"status=error"* ]]
  [[ "$output" != *"status=clean"* ]]
  # Kein falsch-positives stale-lock: der Vergleich hat gar nicht stattgefunden.
  [[ "$output" != *"status=stale-lock"* ]]
  # render_error nennt weiterhin die Phase.
  [[ "$output" =~ render_error=(detect|render)-failed: ]]
}

@test "drift: lock-tracked file the renderer no longer emits reports stale-lock" {
  # Ein Adopter, der einen Workflow traegt, den der Katalog fallengelassen hat.
  # Der Lock-Vergleich sieht nichts (Datei da, Hash stimmt), und der Render-
  # Vergleich uebersprang den Pfad frueher mangels Gegenstueck — die Datei
  # feuerte im Adopter weiter, und Drift meldete clean.
  echo "# a workflow the catalog dropped" > "$TARGET/.github/workflows/legacy.yml"
  legacy_hash="sha256:$(sha256_of "$TARGET/.github/workflows/legacy.yml")"
  lock="$TARGET/.github/onboard.lock.json"
  jq --arg h "$legacy_hash" \
     '.files[".github/workflows/legacy.yml"] = $h' "$lock" > "$lock.new"
  mv "$lock.new" "$lock"

  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=stale-lock"* ]]
  [[ "$output" == *"legacy.yml"* ]]
  # Der Render lief durch — der Befund kommt aus dem Vergleich, nicht aus einem
  # Fehler.
  echo "$output" | grep -E "^render_error=$" >/dev/null
}

@test "drift: mutated .release-please-manifest.json does NOT count as modified" {
  # Simulate release-please updating the manifest after a release.
  echo '{".":"0.32.0"}' > "$TARGET/.release-please-manifest.json"
  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # Should still report clean — manifest is skipped from the lock-compare loop.
  [[ "$output" == *"status=clean"* ]]
  # And modified should NOT mention the manifest.
  [[ "$output" != *"release-please-manifest"* ]]
}

@test "drift: divergent manifest in render-compare does NOT count as stale-lock" {
  # Mutate working-tree manifest AND update lock to record the new hash so the
  # lock-compare loop sees match. The render-compare loop then re-renders the
  # original initial-state manifest, which would byte-diverge from the
  # working-tree's "1.2.3" content. With the skip, the manifest is excluded
  # → no divergence detected → stays clean (instead of stale-lock).
  echo '{".":"1.2.3"}' > "$TARGET/.release-please-manifest.json"
  new_hash="sha256:$(sha256_of "$TARGET/.release-please-manifest.json")"
  jq --arg h "$new_hash" '.files[".release-please-manifest.json"] = $h' \
    "$TARGET/.github/onboard.lock.json" > "$TARGET/.github/onboard.lock.json.new"
  mv "$TARGET/.github/onboard.lock.json.new" "$TARGET/.github/onboard.lock.json"

  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$TARGET" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=clean"* ]]
  [[ "$output" != *"release-please-manifest"* ]]
}

@test "drift: adopter manifest present reports error (Bash engine cannot evaluate it)" {
  # The Bash engine has no parser for the adopter manifest
  # (.github/onboard.yml) — internal/manifest is Go-CLI-only. A manifest
  # repo must short-circuit to status=error with an explanatory render_error
  # pointing at use_go_cli, rather than silently staying "clean" while the
  # render-and-compare step's failure hides in render_error unnoticed.
  manifest_target=$(mktemp -d)
  cp -R "$FIX/drift-clean/." "$manifest_target/"
  mkdir -p "$manifest_target/.github"
  cat > "$manifest_target/.github/onboard.yml" <<'YAML'
schema: 1
YAML

  CATALOG_CURRENT_VERSION=v4 run "$DRIFT" "$manifest_target" "$REPO_ROOT"
  rm -rf "$manifest_target"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=error"* ]]
  echo "$output" | grep -E '^render_error=.*use_go_cli' >/dev/null
}

# === Drift ohne GitHub-Token (Audit H-5/H-10, Nachtrag) ===
#
# Seit H-5/H-10 ist ein fehlgeschlagener Metadaten-Aufruf beim ONBOARDING
# fatal - dort wuerde sonst geraten und `.release-please-manifest.json` mit
# 0.0.0 geseedet, obwohl das Repo laengst auf 1.10.0 steht.
#
# Drift ist der andere Fall: es vergleicht ein bereits onboardetes Repo mit dem,
# was dort eingecheckt ist, und laeuft in Jobs, die gar kein Token minten. Beim
# ersten Anlauf habe ich diese Unterscheidung uebersehen und den harten Abbruch
# auch fuer Drift eingebaut - self-ci meldete prompt
# `expected status=clean, got status=error` im Job onboard-drift-happy.
#
# Der Go-Pfad trennt an derselben Stelle: die Toleranz sitzt in
# godetect.tolerantMetadata, das nur `drift` umschliesst.

@test "drift: ohne gueltigen GitHub-Token wird nicht status=error" {
  # `gh` ist im PATH, antwortet aber auf alles mit einem Fehler - genau die
  # Lage eines Jobs, der kein Token mintet.
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh: no authentication token" >&2
exit 1
GHEOF
  chmod +x "$bin/gh"

  run env PATH="$bin:$PATH" TARGET_REPO=owner/repo \
    bash "$DRIFT" "$FIX/drift-clean" "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"status=error"* ]]
}

@test "onboard-detect bricht ohne Token weiterhin ab, wenn NICHT drift fragt" {
  # Gegenprobe: die Toleranz darf nicht auf den Onboarding-Pfad durchschlagen.
  # Ohne ONBOARD_METADATA_OPTIONAL bleibt der Abbruch.
  local bin="$BATS_TEST_TMPDIR/bin2"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh: no authentication token" >&2
exit 1
GHEOF
  chmod +x "$bin/gh"

  run env PATH="$bin:$PATH" TARGET_REPO=owner/repo \
    bash "$DETECT" --profile-json "$FIX/go-repo"

  [ "$status" -ne 0 ]
}
