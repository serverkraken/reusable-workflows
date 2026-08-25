#!/usr/bin/env bats
# Tests for scripts/version-badges.sh — renders one SVG badge per
# release-please package and rewrites the README block between
# <!-- version-badges:start --> and <!-- version-badges:end -->.

load 'lib/assertions'

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/version-badges.sh"
  WORK="$(mktemp -d)"
  cat > "$WORK/.release-please-manifest.json" <<'EOF'
{
  ".": "1.4.0",
  "images/postfix": "1.4.1",
  "charts/mailstack": "1.4.2"
}
EOF
  cat > "$WORK/release-please-config.json" <<'EOF'
{
  "packages": {
    ".": {"release-type": "go", "include-component-in-tag": false},
    "images/postfix": {"release-type": "simple", "package-name": "postfix", "include-component-in-tag": true},
    "charts/mailstack": {"release-type": "helm", "package-name": "mailstack", "include-component-in-tag": true}
  }
}
EOF
  cat > "$WORK/README.md" <<'EOF'
# mailstack

Intro text.

<!-- version-badges:start -->
stale content
<!-- version-badges:end -->

Outro text.
EOF
}

teardown() {
  rm -rf "$WORK"
}

run_script() {
  run bash "$SCRIPT" --manifest "$WORK/.release-please-manifest.json" \
    --config "$WORK/release-please-config.json" \
    --readme "$WORK/README.md" --badges-dir "$WORK/docs/badges" \
    --repo serverkraken/mailstack "$@"
}

@test "writes one SVG per package, named by label" {
  run_script
  [ "$status" -eq 0 ]
  [ -f "$WORK/docs/badges/mailstack.svg" ]     # root → repo name
  [ -f "$WORK/docs/badges/postfix.svg" ]
  [ -f "$WORK/docs/badges/chart.svg" ]         # helm package → "chart"
  [[ "$output" == *"badges=3"* ]]
  [[ "$output" == *"changed=true"* ]]
}

@test "SVG carries label, version, kind colour and the kraken glyph, no external refs" {
  run_script
  grep -q '>postfix<' "$WORK/docs/badges/postfix.svg"
  grep -q '>v1.4.1<' "$WORK/docs/badges/postfix.svg"
  grep -q 'fill="#1E9E9E"' "$WORK/docs/badges/postfix.svg"      # image → teal
  grep -q 'fill="#E07A2E"' "$WORK/docs/badges/mailstack.svg"    # root → orange
  grep -q 'fill="#6A4DB8"' "$WORK/docs/badges/chart.svg"        # chart → violet
  grep -q 'fill="#0E1A26"' "$WORK/docs/badges/postfix.svg"      # label ground
  grep -q 'aria-label="postfix: v1.4.1"' "$WORK/docs/badges/postfix.svg"
  # glyph: at least a handful of 1.6-unit pixel rects
  [ "$(grep -o 'width="1.6" height="1.6"' "$WORK/docs/badges/postfix.svg" | wc -l | tr -d ' ')" -ge 10 ]
  # no external references or active content (xmlns is the only URL allowed)
  refute_grep -E 'href=|src=|url\(|@import|<script|<style|<image|<foreignObject' "$WORK/docs/badges/postfix.svg"
  refute_grep -E 'href=|src=|url\(|<script' "$WORK/docs/badges/chart.svg"
}

@test "README block is replaced with badges line and table, outside text untouched" {
  run_script
  grep -q '^# mailstack$' "$WORK/README.md"
  grep -q '^Intro text.$' "$WORK/README.md"
  grep -q '^Outro text.$' "$WORK/README.md"
  refute_grep -q 'stale content' "$WORK/README.md"
  block="$(sed -n '/<!-- version-badges:start -->/,/<!-- version-badges:end -->/p' "$WORK/README.md")"
  expected='<!-- version-badges:start -->
![mailstack: v1.4.0](docs/badges/mailstack.svg) ![postfix: v1.4.1](docs/badges/postfix.svg) ![chart: v1.4.2](docs/badges/chart.svg)

| Component | Version | Tag |
|---|---|---|
| mailstack | 1.4.0 | [v1.4.0](https://github.com/serverkraken/mailstack/releases/tag/v1.4.0) |
| postfix | 1.4.1 | [postfix-v1.4.1](https://github.com/serverkraken/mailstack/releases/tag/postfix-v1.4.1) |
| chart | 1.4.2 | [mailstack-v1.4.2](https://github.com/serverkraken/mailstack/releases/tag/mailstack-v1.4.2) |
<!-- version-badges:end -->'
  [ "$block" = "$expected" ]
}

@test "second run is idempotent and reports changed=false" {
  run_script
  [ "$status" -eq 0 ]
  before="$(cat "$WORK/README.md" "$WORK"/docs/badges/*.svg | shasum)"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=false"* ]]
  after="$(cat "$WORK/README.md" "$WORK"/docs/badges/*.svg | shasum)"
  [ "$before" = "$after" ]
}

@test "badge image paths are relative to the README's directory" {
  mkdir -p "$WORK/docs"
  mv "$WORK/README.md" "$WORK/docs/README.md"
  run bash "$SCRIPT" --manifest "$WORK/.release-please-manifest.json" \
    --config "$WORK/release-please-config.json" \
    --readme "$WORK/docs/README.md" --badges-dir "$WORK/docs/badges" \
    --repo serverkraken/mailstack
  [ "$status" -eq 0 ]
  grep -q '](badges/postfix.svg)' "$WORK/docs/README.md"
}

@test "missing markers fail loudly without touching the README" {
  printf '# no markers\n' > "$WORK/README.md"
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"version-badges:start"* ]]
  [ "$(cat "$WORK/README.md")" = "# no markers" ]
  [ ! -d "$WORK/docs/badges" ]
}

@test "single-package repo without config falls back to repo name and v-tag" {
  printf '{".": "4.14.1"}\n' > "$WORK/.release-please-manifest.json"
  rm "$WORK/release-please-config.json"
  run bash "$SCRIPT" --manifest "$WORK/.release-please-manifest.json" \
    --readme "$WORK/README.md" --badges-dir "$WORK/docs/badges" \
    --repo serverkraken/reusable-workflows
  [ "$status" -eq 0 ]
  [ -f "$WORK/docs/badges/reusable-workflows.svg" ]
  grep -q '| reusable-workflows | 4.14.1 | \[v4.14.1\](https://github.com/serverkraken/reusable-workflows/releases/tag/v4.14.1) |' "$WORK/README.md"
}

@test "labels are sanitised for file names" {
  cat > "$WORK/.release-please-manifest.json" <<'EOF'
{ "services/api v2": "0.1.0" }
EOF
  rm "$WORK/release-please-config.json"
  run bash "$SCRIPT" --manifest "$WORK/.release-please-manifest.json" \
    --readme "$WORK/README.md" --badges-dir "$WORK/docs/badges" \
    --repo serverkraken/x
  [ "$status" -eq 0 ]
  [ -f "$WORK/docs/badges/api-v2.svg" ]
}

# === Markerstellung und Manifestfehler (Audit I-7, I-8) ===
#
# Die bestehende Pruefung ZAEHLT die Marker. Der Umschreibvorgang ist ein
# awk-Lauf, der beim Startmarker anfaengt zu ueberspringen und beim Endmarker
# aufhoert - und beide Regeln verlangen den Marker in SPALTE 1
# (`index($0, m) == 1`). Zwei Anordnungen bestehen die Zaehlung und zerstoeren
# die Datei trotzdem. Beide gegen den Stand davor nachgestellt: exit 0, Badges
# geschrieben, Text unterhalb des Blocks weg.

@test "Endmarker vor Startmarker wird abgewiesen, statt den Rest zu loeschen" {
  cat > "$WORK/README.md" <<'EOF'
# demo

<!-- version-badges:end -->
<!-- version-badges:start -->

WICHTIGER TEXT
EOF
  cp "$WORK/README.md" "$WORK/README.orig"
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"before"* ]]
  # Die README darf nicht angefasst worden sein - ein Abbruch, der die Datei
  # halb umgeschrieben hinterlaesst, waere kein Fortschritt.
  diff "$WORK/README.md" "$WORK/README.orig"
}

@test "eingerueckter Endmarker wird abgewiesen" {
  # Zaehlt genau einmal, wird vom Umschreibvorgang aber nie getroffen: das
  # Ueberspringen endet dann erst am Dateiende.
  cat > "$WORK/README.md" <<'EOF'
# demo

<!-- version-badges:start -->
  <!-- version-badges:end -->

WICHTIGER TEXT
EOF
  cp "$WORK/README.md" "$WORK/README.orig"
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"beginning of a line"* ]]
  diff "$WORK/README.md" "$WORK/README.orig"
}

@test "ein Marker mit Text dahinter bleibt erlaubt" {
  # Gegenprobe zur Spaltenpruefung: der Umschreibvorgang kommt mit Text hinter
  # dem Marker zurecht, also darf die Validierung ihn nicht abweisen.
  cat > "$WORK/README.md" <<'EOF'
# demo

<!-- version-badges:start --> (automatisch gepflegt)
<!-- version-badges:end -->

WICHTIGER TEXT
EOF
  run_script
  [ "$status" -eq 0 ]
  grep -q "WICHTIGER TEXT" "$WORK/README.md"
}

@test "beschaedigtes Manifest schreibt den Block NICHT leer" {
  # `done < <(jq ...)`: der Exit-Status einer Prozesssubstitution ist fuer
  # `set -e` unsichtbar. Vorher lief die Schleife null Mal und der Block wurde
  # durch eine leere Tabelle ersetzt - badges=0, changed=true, exit 0.
  printf '{".": "1.4.0"\n' > "$WORK/.release-please-manifest.json"
  cp "$WORK/README.md" "$WORK/README.orig"
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be read"* ]]
  diff "$WORK/README.md" "$WORK/README.orig"
}

@test "leeres, aber gueltiges Manifest laesst die README in Ruhe" {
  # Kein Fehler - aber auch kein Grund, eine bestehende Tabelle durch eine
  # leere zu ersetzen.
  printf '{}\n' > "$WORK/.release-please-manifest.json"
  cp "$WORK/README.md" "$WORK/README.orig"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=false"* ]]
  diff "$WORK/README.md" "$WORK/README.orig"
}
