#!/usr/bin/env bats

# `app_version: true` renders an extra-files entry so release-please keeps a
# chart's appVersion in step with its version.
#
# release-please resolves extra-files paths relative to the PACKAGE. Spelling
# them from the repo root produced charts/mailstack/charts/mailstack/Chart.yaml,
# which release-please logged as "did not exist" and skipped — silently, with a
# green release and an appVersion frozen two minor versions back. Every test
# here asserts the path the way release-please reads it: package + entry.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RENDER="$REPO_ROOT/scripts/onboard-render.sh"
  TARGET="$(mktemp -d)"
}

teardown() {
  rm -rf "$TARGET"
}

# Writes a monorepo profile with one chart component.
# $1 = component path, $2 = release_signals.chart_yaml (JSON: null or a string)
seed_chart_profile() {
  python3 - "$TARGET/profile.json" "$1" "$2" <<'PY'
import json, sys
out, path, chart_yaml = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
profile = {
    "schema_version": 1,
    "target_repo": "serverkraken/example",
    "default_branch": "main",
    "current_version": "1.0.0",
    "monorepo": True,
    "manifest_sha256": "sha256:fixture",
    "topics": [], "warnings": [], "legacy_ci": [], "gitops_consumers": [],
    "workflows": {},
    "release": {},
    "components": [
        {"path": ".", "role": "service", "primary_language": "go",
         "release_please_type": "go", "languages": ["go"], "version": "1.0.0",
         "cgo": False, "unittest": False, "dockerfiles": [],
         "release_signals": {"goreleaser_config": None, "chart_yaml": None,
                             "flutter_android": False}},
        {"path": path, "role": "chart", "primary_language": "helm",
         "release_please_type": "helm", "languages": ["helm"], "version": "1.0.0",
         "cgo": False, "unittest": False, "dockerfiles": [], "app_version": True,
         "release_signals": {"goreleaser_config": None, "chart_yaml": chart_yaml,
                             "flutter_android": False}},
    ],
}
json.dump(profile, open(out, "w"))
PY
}

# Prints "<package path>/<extra-files path>" — what release-please opens.
resolved_path() {
  python3 - "$TARGET/release-please-config.json" "$1" <<'PY'
import json, sys
cfg, pkg = json.load(open(sys.argv[1])), sys.argv[2]
entry = cfg["packages"][pkg].get("extra-files")
if not entry:
    print("NO-EXTRA-FILES"); raise SystemExit(0)
print(f"{pkg}/{entry[0]['path']}")
PY
}

# The mailstack shape: a manifest-declared chart component. Detection leaves
# release_signals.chart_yaml null there, so the Chart.yaml sits at the
# component's own root.
@test "manifest-declared chart resolves to its own Chart.yaml" {
  seed_chart_profile "charts/mailstack" "null"
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 0 ]

  run resolved_path "charts/mailstack"
  [ "$output" = "charts/mailstack/Chart.yaml" ]
}

# The regression itself: the entry must not repeat the package path.
@test "the extra-files entry is package-relative, not repo-root" {
  seed_chart_profile "charts/mailstack" "null"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"

  run python3 -c "
import json
p = json.load(open('$TARGET/release-please-config.json'))['packages']['charts/mailstack']['extra-files'][0]['path']
print('repeats-package-path' if p.startswith('charts/mailstack') else p)"
  [ "$output" = "Chart.yaml" ]
}

# A detected chart names its Chart.yaml explicitly and may keep it below the
# component root; the entry has to keep that sub-path, minus the package prefix.
@test "a chart nested inside its component keeps the sub-path" {
  seed_chart_profile "services/api" '"services/api/deploy/chart/Chart.yaml"'
  run "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  [ "$status" -eq 0 ]

  run resolved_path "services/api"
  [ "$output" = "services/api/deploy/chart/Chart.yaml" ]
}

@test "without app_version no extra-files entry is emitted" {
  seed_chart_profile "charts/mailstack" "null"
  python3 -c "
import json
p = '$TARGET/profile.json'
d = json.load(open(p))
for c in d['components']:
    c.pop('app_version', None)
json.dump(d, open(p, 'w'))"

  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"
  run resolved_path "charts/mailstack"
  [ "$output" = "NO-EXTRA-FILES" ]
}

@test "the rendered config stays valid JSON with the entry present" {
  seed_chart_profile "charts/mailstack" "null"
  "$RENDER" "$REPO_ROOT" "$TARGET" "$TARGET/profile.json" "v4"

  run python3 -c "
import json
d = json.load(open('$TARGET/release-please-config.json'))
print(','.join(sorted(d['packages'])))"
  [ "$output" = ".,charts/mailstack" ]
}
