#!/usr/bin/env bats

# release-please ordnet Konfiguration und Manifest ueber DENSELBEN Schluessel zu.
# Stimmen sie nicht ueberein, ist die Ausgangsversion der Komponente verloren:
# das konfigurierte Paket hat keinen Manifest-Eintrag und faengt bei 0.0.0 an,
# und der vorhandene Eintrag gehoert zu keinem konfigurierten Paket.
#
# Der Fund (A-2): das Template fuer den Einzelkomponenten-Fall schrieb den
# Schluessel fest als ".", das Manifest-Template nimmt `.path`. Bei einer
# einzelnen Komponente AUSSERHALB des Wurzelverzeichnisses liefen die beiden
# damit auseinander:
#
#   release-please-config.json    "."
#   .release-please-manifest.json "services/api"
#
# Im Regelfall (Komponente im Wurzelverzeichnis) ist `.path` gleich "." — dort
# aendert sich nichts. Die Monorepo-Variante schluesselte laengst nach `.path`.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  WORK="$(mktemp -d)"
}

teardown() { rm -rf "$WORK"; }

_render_with_component() {  # <pfad>
  local prof="$WORK/profile.json" target="$WORK/out/demo"
  mkdir -p "$target"
  cat > "$prof" <<EOF
{
  "schema_version": 1,
  "target_repo": "serverkraken/demo",
  "default_branch": "main",
  "current_version": "1.2.3",
  "monorepo": false,
  "topics": [],
  "components": [
    { "path": "$1", "primary_language": "go", "release_please_type": "go",
      "dockerfiles": [],
      "release_signals": { "goreleaser_config": null, "chart_yaml": null, "flutter_android": false } }
  ]
}
EOF
  bash "$RENDER" "$REPO_ROOT" "$target" "$prof" v4 >/dev/null 2>&1
  CONFIG_KEY="$(jq -r '.packages | keys[]' "$target/release-please-config.json")"
  MANIFEST_KEY="$(jq -r 'keys[]' "$target/.release-please-manifest.json")"
  rm -rf "$WORK/out"
}

@test "einzelne Komponente im Wurzelverzeichnis: beide Schluessel sind ." {
  _render_with_component "."
  [ "$CONFIG_KEY" = "." ]
  [ "$MANIFEST_KEY" = "." ]
}

@test "einzelne Komponente in einem Unterverzeichnis: beide Schluessel gleich" {
  _render_with_component "services/api"
  [ "$CONFIG_KEY" = "services/api" ]
  [ "$MANIFEST_KEY" = "services/api" ]
  [ "$CONFIG_KEY" = "$MANIFEST_KEY" ]
}

@test "auch zwei Ebenen tief bleiben die Schluessel gleich" {
  _render_with_component "services/team-a/api"
  [ "$CONFIG_KEY" = "$MANIFEST_KEY" ]
  [ "$CONFIG_KEY" = "services/team-a/api" ]
}
