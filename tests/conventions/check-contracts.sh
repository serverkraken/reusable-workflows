#!/usr/bin/env bash
# CI gate for docs/contracts.md.
#
# Two directions, both required:
#
#   1. Every workflow_call workflow and every composite action MUST have a
#      section in the doc. The source list is built from the FILESYSTEM, not
#      from the doc's own headings — deriving it from the headings made the
#      gate blind in exactly the case that matters: an API nobody documented
#      was also never inspected. It demonstrated this on itself, passing while
#      ten APIs had no section at all.
#   2. For every such section, the documented input/output/secret names must
#      match the names the source YAML actually exposes.

set -euo pipefail

if [[ -n "${REPO_ROOT:-}" ]]; then
  cd "$REPO_ROOT"
else
  cd "$(git rev-parse --show-toplevel)"
fi

DOC_FILE="${DOC_FILE:-docs/contracts.md}"
FAILED=0
CHECKED=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

doc_rows="$tmpdir/doc.tsv"
source_rows="$tmpdir/sources.tsv"
actual_rows="$tmpdir/actual.tsv"
doc_keys="$tmpdir/doc-keys.tsv"
actual_keys="$tmpdir/actual-keys.tsv"

: > "$doc_rows"
: > "$source_rows"
: > "$actual_rows"

trim_cell() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

contract_source_for_heading() {
  local heading="$1"
  case "$heading" in
    actions/*)
      printf '%s/action.yml' "$heading"
      ;;
    *.yml|*.yaml)
      printf '.github/workflows/%s' "$heading"
      ;;
    *)
      return 1
      ;;
  esac
}

basename_for_heading() {
  local source="$1"
  case "$source" in
    actions/*/action.yml) printf 'actions/%s' "$(basename "$(dirname "$source")")" ;;
    *)                    printf '%s' "$(basename "$source")" ;;
  esac
}

extract_action_contracts() {
  local source="$1"
  awk -v file="$source" '
    function emit(kind, key) {
      print file "\t" kind "\t" key "\t" file ":" NR
    }
    /^[^[:space:]#][^:]*:/ {
      key = $0
      sub(/:.*/, "", key)
      if (key == "inputs" || key == "outputs") {
        section = key
      } else {
        section = ""
      }
      next
    }
    section != "" && /^[[:space:]]{2}[^[:space:]#][^:]*:/ {
      key = $0
      sub(/^[[:space:]]{2}/, "", key)
      sub(/:.*/, "", key)
      if (section == "inputs") {
        emit("input", key)
      } else if (section == "outputs") {
        emit("output", key)
      }
    }
  ' "$source"
}

extract_workflow_contracts() {
  local source="$1"
  awk -v file="$source" '
    function emit(kind, key) {
      print file "\t" kind "\t" key "\t" file ":" NR
    }
    /^[^[:space:]#][^:]*:/ {
      top = $0
      sub(/:.*/, "", top)
      if (top != "on") {
        in_call = 0
        section = ""
      }
    }
    /^[[:space:]]{2}workflow_call:/ {
      in_call = 1
      section = ""
      next
    }
    in_call && /^[[:space:]]{4}(inputs|outputs|secrets):/ {
      section = $0
      sub(/^[[:space:]]{4}/, "", section)
      sub(/:.*/, "", section)
      next
    }
    in_call && section != "" && /^[[:space:]]{6}[^[:space:]#][^:]*:/ {
      key = $0
      sub(/^[[:space:]]{6}/, "", key)
      sub(/:.*/, "", key)
      kind = section
      if (kind == "inputs") {
        kind = "input"
      } else if (kind == "outputs") {
        kind = "output"
      } else if (kind == "secrets") {
        kind = "secret"
      }
      emit(kind, key)
    }
  ' "$source"
}

if [[ ! -f "$DOC_FILE" ]]; then
  echo "FAIL: $DOC_FILE not found."
  exit 1
fi

current_heading=""
current_source=""
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  heading="$(printf '%s\n' "$line" | sed -n 's/^### `\([^`]*\)`.*/\1/p')"
  if [[ -n "$heading" ]]; then
    current_heading="$heading"
    if current_source="$(contract_source_for_heading "$heading")"; then
      printf '%s\t%s\t%s:%s\n' "$current_source" "$current_heading" "$DOC_FILE" "$lineno" >> "$source_rows"
    else
      current_source=""
    fi
    continue
  fi

  [[ "$line" == \|* ]] || continue

  row="${line#|}"
  IFS='|' read -r kind name _rest <<< "$row"
  kind="$(trim_cell "$kind")"
  name="$(trim_cell "$name")"

  case "$kind" in
    input|output|secret)
      ;;
    *)
      continue
      ;;
  esac

  name="${name//\`/}"
  name="${name//\*/}"
  name="$(trim_cell "$name")"

  if [[ -z "$current_source" ]]; then
    echo "FAIL: $DOC_FILE:$lineno documents $kind '$name' under unmapped section '$current_heading'."
    FAILED=1
    continue
  fi

  printf '%s\t%s\t%s\t%s:%s\n' "$current_source" "$kind" "$name" "$DOC_FILE" "$lineno" >> "$doc_rows"
done < "$DOC_FILE"

sort -u "$source_rows" -o "$source_rows"

# --- Richtung 1: jede Quelle im Repo braucht eine Sektion -------------------
expected_sources="$tmpdir/expected.tsv"
documented_sources="$tmpdir/documented.tsv"
: > "$expected_sources"

for source in .github/workflows/*.yml .github/workflows/*.yaml; do
  [[ -f "$source" ]] || continue
  # Nur workflow_call-Atome tragen einen Vertrag. Die Self-CI-Workflows dieses
  # Repos (validate, release, nightly, ...) laufen auf push/schedule und haben
  # keine Adopter-Schnittstelle, die dokumentiert werden koennte.
  awk '
    /^on:[[:space:]]*$/ { in_on = 1; next }
    /^[^[:space:]#]/    { in_on = 0 }
    in_on && /^[[:space:]]+workflow_call:[[:space:]]*$/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$source" || continue
  printf '%s\n' "$source" >> "$expected_sources"
done

for source in actions/*/action.yml; do
  [[ -f "$source" ]] || continue
  printf '%s\n' "$source" >> "$expected_sources"
done

sort -u "$expected_sources" -o "$expected_sources"
cut -f1 "$source_rows" | sort -u > "$documented_sources"

while IFS= read -r source; do
  [[ -n "$source" ]] || continue
  echo "FAIL: $source exposes a contract, but $DOC_FILE has no section for it (expected a heading '### \`$(basename_for_heading "$source")\`')."
  FAILED=1
done < <(comm -23 "$expected_sources" "$documented_sources")

while IFS=$'\t' read -r source heading line_ref; do
  [[ -n "$source" ]] || continue
  CHECKED=$((CHECKED + 1))

  if [[ ! -f "$source" ]]; then
    echo "FAIL: $line_ref documents '$heading', but $source does not exist."
    FAILED=1
    continue
  fi

  case "$source" in
    actions/*/action.yml)
      extract_action_contracts "$source" >> "$actual_rows"
      ;;
    .github/workflows/*.yml|.github/workflows/*.yaml)
      extract_workflow_contracts "$source" >> "$actual_rows"
      ;;
  esac
done < "$source_rows"

sort -u "$doc_rows" -o "$doc_rows"
sort -u "$actual_rows" -o "$actual_rows"
cut -f1-3 "$doc_rows" | sort -u > "$doc_keys"
cut -f1-3 "$actual_rows" | sort -u > "$actual_keys"

while IFS=$'\t' read -r source kind name; do
  [[ -n "$source" ]] || continue
  line_ref="$(awk -F '\t' -v source="$source" -v kind="$kind" -v name="$name" '
    $1 == source && $2 == kind && $3 == name { print $4; exit }
  ' "$doc_rows")"
  echo "FAIL: $line_ref documents $kind '$name', but $source has no such contract."
  FAILED=1
done < <(comm -23 "$doc_keys" "$actual_keys")

while IFS=$'\t' read -r source kind name; do
  [[ -n "$source" ]] || continue
  line_ref="$(awk -F '\t' -v source="$source" -v kind="$kind" -v name="$name" '
    $1 == source && $2 == kind && $3 == name { print $4; exit }
  ' "$actual_rows")"
  echo "FAIL: $source exposes $kind '$name' at $line_ref, but $DOC_FILE does not document it."
  FAILED=1
done < <(comm -13 "$doc_keys" "$actual_keys")

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "Contract documentation drift found. Update $DOC_FILE or the source YAML."
  exit 1
fi

echo "OK: $CHECKED contract sections checked ($(wc -l < "$expected_sources" | tr -d ' ') sources in repo), all documented names match source YAML."
