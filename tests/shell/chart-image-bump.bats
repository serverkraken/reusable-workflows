#!/usr/bin/env bats
# Unit tests for scripts/chart-image-bump.py — the script a release run uses to
# pin a chart's own image tags to the versions it just built.
#
# The central promise is a MINIMAL diff: the chart is a reviewed, heavily
# commented file, and a release that reflows it would make every chart PR
# unreadable. `yq -i` was rejected for exactly that reason (84 diff lines for
# one changed tag on mailstack's values.yaml), so the line-precision below is
# the feature, not an implementation detail.

setup() {
  BUMP="$BATS_TEST_DIRNAME/../../scripts/chart-image-bump.py"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  cat > "$VALUES" <<'EOF'
---
# Leading comment that must survive.
global:
  imageTag: ""

images:
  tools:
    repository: ghcr.io/acme/app/tools
    tag: v1.0.0            # inline comment must survive
  postfix:
    repository: ghcr.io/acme/app/postfix
    tag: v1.0.0

other:
  tag: v0.0.1
EOF
}

bump() {
  "$BUMP" "$VALUES" 'images.{name}.tag' "$1" "$2"
}

@test "bumps only components that actually released" {
  run bump '{"images/postfix":{"version":"1.2.3"}}' \
           '{"images/postfix":["acme/app/postfix"],"images/tools":["acme/app/tools"]}'
  [ "$status" -eq 0 ]
  grep -q 'tag: v1.2.3' "$VALUES"
  # tools did not release — its pin stays put
  grep -qE '^    tag: v1\.0\.0 ' "$VALUES"
}

@test "one component can carry several images" {
  run bump '{".":{"version":"2.0.0"}}' '{".":["acme/app/tools","acme/app/postfix"]}'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'tag: v2.0.0' "$VALUES")" -eq 2 ]
}

@test "changes exactly one line per image and keeps comments" {
  cp "$VALUES" "$BATS_TEST_TMPDIR/before.yaml"
  run bump '{"images/postfix":{"version":"9.9.9"}}' '{"images/postfix":["acme/app/postfix"]}'
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/before.yaml" "$VALUES"
  # 4 lines = the standard unified-diff envelope of a single changed line
  [ "${#lines[@]}" -eq 4 ]
  grep -q 'tag: v1.0.0            # inline comment must survive' "$VALUES"
  grep -q '^# Leading comment that must survive.$' "$VALUES"
}

@test "targets the nested key, not the first key of that name" {
  run bump '{"images/tools":{"version":"3.0.0"}}' '{"images/tools":["acme/app/tools"]}'
  [ "$status" -eq 0 ]
  # `other.tag` shares the leaf name and must not be touched
  grep -q '^  tag: v0.0.1$' "$VALUES"
}

@test "a path missing from the values file fails loudly" {
  run bump '{"images/ghost":{"version":"1.0.0"}}' '{"images/ghost":["acme/app/ghost"]}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  # A silent skip would leave the chart deploying the old image while the
  # release run stayed green.
}

@test "re-running with the same versions is a no-op" {
  bump '{"images/postfix":{"version":"1.0.0"}}' '{"images/postfix":["acme/app/postfix"]}'
  cp "$VALUES" "$BATS_TEST_TMPDIR/first.yaml"
  run bump '{"images/postfix":{"version":"1.0.0"}}' '{"images/postfix":["acme/app/postfix"]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=false"* ]]
  diff "$BATS_TEST_TMPDIR/first.yaml" "$VALUES"
}

@test "empty releases input changes nothing" {
  cp "$VALUES" "$BATS_TEST_TMPDIR/before.yaml"
  run bump '{}' '{"images/postfix":["acme/app/postfix"]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=false"* ]]
  diff "$BATS_TEST_TMPDIR/before.yaml" "$VALUES"
}
