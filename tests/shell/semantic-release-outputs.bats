#!/usr/bin/env bats
# Tests for the per-path release fold in .github/workflows/semantic-release.yml
# ("Collect per-path release outputs" step).
#
# release-please-action emits one output per released path with a
# `<path>--` prefix (bare names for the root package "."). Because
# workflow_call outputs must be declared statically, that dynamic set is
# folded into two JSON strings at runtime:
#   paths_released — JSON array of released paths ("[]" when idle)
#   releases       — JSON object path -> {tag_name, version, major, minor}
#                     ("{}" when idle)
#
# The fold lives inline in the atom (env: JQ_RELEASES block scalar) rather
# than in scripts/*.sh, because the atom checks out the ADOPTER repo at run
# time — a catalog script under scripts/ would not be reachable there. This
# file instead extracts the exact JQ_RELEASES program out of the workflow
# YAML with awk and unit-tests it directly against fixture release-please
# outputs, so the fold logic still gets persisted bats coverage.

setup() {
  BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/semantic-release.yml"
}

# Extracts the JQ_RELEASES: | block scalar body from the workflow YAML.
# Captures lines after the `JQ_RELEASES: |` key while their indentation is
# deeper than the key's own indentation, then strips the common (first
# content line's) indent so the result is a bare jq program.
extract_jq_releases() {
  awk '
    /^[[:space:]]*JQ_RELEASES:[[:space:]]*\|[[:space:]]*$/ {
      match($0, /^[[:space:]]*/)
      key_indent = RLENGTH
      capturing = 1
      content_indent = -1
      next
    }
    capturing {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      match($0, /^[[:space:]]*/)
      indent = RLENGTH
      if (indent <= key_indent) { capturing = 0; next }
      if (content_indent == -1) { content_indent = indent }
      print substr($0, content_indent + 1)
    }
  ' "$WORKFLOW"
}

# Runs the extracted releases fold against a fixture release-please-action
# outputs object (as JSON, matching what `toJSON(steps.release.outputs)`
# would produce).
run_releases_fold() {
  local rp_outputs="$1"
  local jq_program
  jq_program="$(extract_jq_releases)"
  jq -c "$jq_program" <<< "$rp_outputs"
}

# The same one-liner used inline in the atom's `run:` block for
# paths_released — trivial enough to stay inline in the workflow, but still
# exercised here alongside the releases fold for the same fixtures.
run_paths_fold() {
  local rp_outputs="$1"
  jq -c '(.paths_released // "[]") | fromjson' <<< "$rp_outputs"
}

@test "JQ_RELEASES block scalar extraction is non-empty" {
  program="$(extract_jq_releases)"
  [ -n "$program" ]
  [[ "$program" == *"reduce \$paths[]"* ]]
}

@test "idle: no paths released folds to [] / {}" {
  rp_outputs='{}'

  paths="$(run_paths_fold "$rp_outputs")"
  releases="$(run_releases_fold "$rp_outputs")"

  diff <(jq -c -S . <<< "$paths") <(jq -c -S . <<< '[]')
  diff <(jq -c -S . <<< "$releases") <(jq -c -S . <<< '{}')
}

@test "single root package: bare keys (no prefix) fold to path \".\"" {
  rp_outputs='{"paths_released":"[\".\"]","tag_name":"v1.2.3","version":"1.2.3","major":"1","minor":"2"}'

  paths="$(run_paths_fold "$rp_outputs")"
  releases="$(run_releases_fold "$rp_outputs")"

  diff <(jq -c -S . <<< "$paths") <(jq -c -S . <<< '["."]')
  diff <(jq -c -S . <<< "$releases") <(jq -c -S . <<< \
    '{".":{"tag_name":"v1.2.3","version":"1.2.3","major":"1","minor":"2"}}')
}

@test "multi-path monorepo: two prefixed packages fold independently" {
  rp_outputs='{"paths_released":"[\"images/postfix\",\"charts/mailstack\"]","images/postfix--tag_name":"postfix-v1.2.0","images/postfix--version":"1.2.0","images/postfix--major":"1","images/postfix--minor":"2","charts/mailstack--tag_name":"mailstack-v0.3.0","charts/mailstack--version":"0.3.0","charts/mailstack--major":"0","charts/mailstack--minor":"3"}'

  paths="$(run_paths_fold "$rp_outputs")"
  releases="$(run_releases_fold "$rp_outputs")"

  diff <(jq -c -S . <<< "$paths") <(jq -c -S . <<< '["images/postfix","charts/mailstack"]')
  diff <(jq -c -S . <<< "$releases") <(jq -c -S . <<< \
    '{"images/postfix":{"tag_name":"postfix-v1.2.0","version":"1.2.0","major":"1","minor":"2"},"charts/mailstack":{"tag_name":"mailstack-v0.3.0","version":"0.3.0","major":"0","minor":"3"}}')
}

@test "mixed root + subpath: \".--\"-prefixed root keys take priority over bare fallback" {
  rp_outputs='{"paths_released":"[\".\",\"images/postfix\"]",".--tag_name":"v1.2.3",".--version":"1.2.3",".--major":"1",".--minor":"2","images/postfix--tag_name":"postfix-v1.2.0","images/postfix--version":"1.2.0","images/postfix--major":"1","images/postfix--minor":"2"}'

  paths="$(run_paths_fold "$rp_outputs")"
  releases="$(run_releases_fold "$rp_outputs")"

  diff <(jq -c -S . <<< "$paths") <(jq -c -S . <<< '[".","images/postfix"]')
  diff <(jq -c -S . <<< "$releases") <(jq -c -S . <<< \
    '{".":{"tag_name":"v1.2.3","version":"1.2.3","major":"1","minor":"2"},"images/postfix":{"tag_name":"postfix-v1.2.0","version":"1.2.0","major":"1","minor":"2"}}')
}
