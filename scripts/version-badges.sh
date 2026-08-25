#!/usr/bin/env bash
# version-badges.sh — render one static SVG badge per release-please package
# and rewrite the README block between
#   <!-- version-badges:start -->  and  <!-- version-badges:end -->
# with a badge line plus a Component | Version | Tag table.
#
# Everything is generated from the repo itself (.release-please-manifest.json
# and, when present, release-please-config.json): no shields.io, no external
# requests, no fonts — the badges render inside private repos via GitHub's
# own image proxy. Output is deterministic, so re-running on an unchanged
# manifest produces byte-identical files.
#
# Usage:
#   version-badges.sh --manifest <path> [--config <path>] --readme <path>
#                     --badges-dir <dir> --repo <owner/name>
#
# stdout (GITHUB_OUTPUT-compatible):
#   badges=<n>            number of badges rendered
#   changed=<true|false>  whether README or any badge file changed
#   files=<a,b,c>         badge files (paths as given by --badges-dir)
#
# Exit 1 when the README lacks the two markers (the README is never touched
# in that case) or when inputs are missing.
set -euo pipefail

MANIFEST="" CONFIG="" README="" BADGES_DIR="" REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --readme) README="$2"; shift 2 ;;
    --badges-dir) BADGES_DIR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 1 ;;
  esac
done
for v in MANIFEST README BADGES_DIR REPO; do
  [[ -n "${!v}" ]] || { echo "::error::--$(echo "$v" | tr '[:upper:]' '[:lower:]' | tr _ -) is required" >&2; exit 1; }
done
[[ -f "$MANIFEST" ]] || { echo "::error::manifest not found: $MANIFEST" >&2; exit 1; }
[[ -f "$README" ]] || { echo "::error::README not found: $README" >&2; exit 1; }
[[ -n "$CONFIG" && ! -f "$CONFIG" ]] && CONFIG=""

START='<!-- version-badges:start -->'
END='<!-- version-badges:end -->'
if [[ "$(grep -cF "$START" "$README")" -ne 1 || "$(grep -cF "$END" "$README")" -ne 1 ]]; then
  echo "::error::$README must contain exactly one '$START' and one '$END' marker; add them where the badges should appear" >&2
  exit 1
fi

# Counting is not enough (audit I-8). The rewrite below is an awk pass that
# starts skipping at the START marker and stops at the END marker, and BOTH
# rules require the marker to begin in column 1 (`index($0, m) == 1`). Two
# arrangements pass the count check and still destroy the file:
#
#   END before START      everything after START is skipped to EOF
#   END indented          same — the stop rule never fires
#
# Both were reproduced against a README with content after the block: exit 0,
# badges written, and the text below the marker gone. In an adopter repo that
# is their README, and the run is green.
#
# Validated with awk rather than grep so the check matches the rewrite rule
# character for character; a stricter test (`grep -x`) would reject a marker
# with trailing content on the same line, which the rewrite handles fine.
read -r start_ln end_ln <<<"$(awk -v s="$START" -v e="$END" '
  index($0, s) == 1 && !sl { sl = NR }
  index($0, e) == 1 && !el { el = NR }
  END { print sl + 0, el + 0 }
' "$README")"

if [[ "$start_ln" == "0" || "$end_ln" == "0" ]]; then
  echo "::error::$README: the version-badges markers must each start at the beginning of a line (indented markers are silently skipped by the rewrite and would truncate the file)" >&2
  exit 1
fi
if (( end_ln < start_ln )); then
  echo "::error::$README: '$END' is on line $end_ln, before '$START' on line $start_ln; in that order the rewrite would delete everything after the start marker" >&2
  exit 1
fi

# ---- palette (variant D: ink label, per-kind value colour, kraken glyph) ----
LABEL_BG="#0E1A26"
GLYPH_FG="#E4ECF2"
kind_colour() {
  case "$1" in
    root) echo "#E07A2E" ;;
    chart) echo "#6A4DB8" ;;
    *) echo "#1E9E9E" ;;
  esac
}
FONT="Verdana,Geneva,DejaVu Sans,sans-serif"
CHAR_W=6.5  # px per character at 11px Verdana — deterministic, no font metrics
PAD=5
GLYPH_W=15

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1"; }
text_width() { awk -v n="${#1}" -v c="$CHAR_W" -v p="$PAD" 'BEGIN{printf "%d", int(n*c + 2*p + 0.5)}'; }
sanitize() { sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//' <<<"$1"; }

# 7x7 pixel kraken, 1.6px per pixel: head (rows 0-3), tentacles (rows 4-6).
KRAKEN=(0011100 0111110 0101010 0111110 1010101 1010101 0101010)
glyph_svg() {
  local x0=5 y0=4.4 out="" r c
  for r in 0 1 2 3 4 5 6; do
    for c in 0 1 2 3 4 5 6; do
      if [[ "${KRAKEN[$r]:$c:1}" == "1" ]]; then
        out+="<rect x=\"$(awk -v a="$x0" -v i="$c" 'BEGIN{printf "%.1f", a+i*1.6}')\" y=\"$(awk -v a="$y0" -v i="$r" 'BEGIN{printf "%.1f", a+i*1.6}')\" width=\"1.6\" height=\"1.6\" fill=\"$GLYPH_FG\"/>"
      fi
    done
  done
  printf '%s' "$out"
}

badge_svg() {
  local label="$1" value="$2" kind="$3"
  local lw vw w lx vx
  lw=$(( $(text_width "$label") + GLYPH_W ))
  vw=$(text_width "$value")
  w=$(( lw + vw ))
  lx=$(awk -v g="$GLYPH_W" -v lw="$lw" 'BEGIN{printf "%.1f", (g+2) + (lw-(g+2))/2}')
  vx=$(awk -v lw="$lw" -v vw="$vw" 'BEGIN{printf "%.1f", lw + vw/2}')
  local el ev
  el="$(xml_escape "$label")"; ev="$(xml_escape "$value")"
  cat <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="20" role="img" aria-label="$el: $ev"><title>$el: $ev</title><rect width="$lw" height="20" fill="$LABEL_BG"/><rect x="$lw" width="$vw" height="20" fill="$(kind_colour "$kind")"/>$(glyph_svg)<g fill="#fff" text-anchor="middle" font-family="$FONT" font-size="11"><text x="$lx" y="14" fill="#010101" fill-opacity=".3">$el</text><text x="$lx" y="13">$el</text><text x="$vx" y="14" fill="#010101" fill-opacity=".3">$ev</text><text x="$vx" y="13">$ev</text></g></svg>
EOF
}

# relpath <from-dir> <to-path> — both resolved to absolute; pure bash, no realpath.
abspath() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s' "$d" "$(basename "$1")"; }
relpath() {
  local from to common up="" rest
  from="$(cd "$1" && pwd)"; to="$2"
  common="$from"
  while [[ "${to#"$common"/}" == "$to" && "$common" != "/" ]]; do
    common="$(dirname "$common")"; up+="../"
  done
  rest="${to#"$common"/}"
  [[ "$common" == "/" ]] && rest="${to#/}"
  printf '%s%s' "$up" "$rest"
}

# ---- collect packages -------------------------------------------------------
REPO_NAME="${REPO##*/}"
helm_count=0
if [[ -n "$CONFIG" ]]; then
  helm_count=$(jq -r '[.packages // {} | to_entries[] | select(.value["release-type"] == "helm")] | length' "$CONFIG")
fi

# Das Manifest wird in eine Datei gelesen, BEVOR die Schleife laeuft — nicht
# als `done < <(jq ...)` (Audit I-7). Der Exit-Status einer Prozesssubstitution
# ist fuer `set -e` unsichtbar: bei kaputtem Manifest schrieb jq nichts, die
# Schleife lief null Mal, und der README-Block wurde mit einer LEEREN Tabelle
# ueberschrieben — `badges=0`, `changed=true`, exit 0. Nachgestellt mit einem
# abgeschnittenen `{".": "1.2.3"` und einer README, deren Tabelle danach weg war.
entries_file=$(mktemp)
trap 'rm -f "$entries_file"' EXIT
if ! jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$MANIFEST" > "$entries_file"; then
  echo "::error::$MANIFEST could not be read; refusing to rewrite $README from an empty component list" >&2
  exit 1
fi

# Null Eintraege bei GUELTIGEM Manifest ist kein Fehler, aber auch kein Grund,
# eine bestehende Tabelle durch eine leere zu ersetzen. Die README bleibt, wie
# sie ist.
if [[ ! -s "$entries_file" ]]; then
  echo "::warning::$MANIFEST lists no packages; leaving $README untouched" >&2
  echo "badges=0"
  echo "changed=false"
  printf 'files=\n'
  exit 0
fi

labels=() versions=() kinds=() tags=() files=()
while IFS=$'\t' read -r path version; do
  rtype="" pkgname="" incl=""
  if [[ -n "$CONFIG" ]]; then
    rtype=$(jq -r --arg p "$path" '.packages[$p]["release-type"] // ""' "$CONFIG")
    pkgname=$(jq -r --arg p "$path" '.packages[$p]["package-name"] // ""' "$CONFIG")
    incl=$(jq -r --arg p "$path" '.packages[$p]["include-component-in-tag"] // ""' "$CONFIG")
  fi
  base="${path##*/}"
  component="${pkgname:-$base}"
  if [[ "$path" == "." ]]; then
    kind="root"; label="$REPO_NAME"
    [[ "$incl" == "true" ]] && tag="${component}-v${version}" || tag="v${version}"
  else
    if [[ "$rtype" == "helm" ]]; then
      kind="chart"
      [[ "$helm_count" -le 1 ]] && label="chart" || label="chart-${component}"
    else
      kind="component"; label="$component"
    fi
    [[ "$incl" == "false" ]] && tag="v${version}" || tag="${component}-v${version}"
  fi
  labels+=("$label"); versions+=("$version"); kinds+=("$kind"); tags+=("$tag")
  files+=("$(sanitize "$label").svg")
done < "$entries_file"

# ---- snapshot before, render, snapshot after ---------------------------------
snapshot() {
  {
    cat "$README"
    if [[ -d "$BADGES_DIR" ]]; then cat "$BADGES_DIR"/*.svg 2>/dev/null || true; fi
  } | shasum | cut -d' ' -f1
}
before="$(snapshot)"

mkdir -p "$BADGES_DIR"
for i in "${!labels[@]}"; do
  badge_svg "${labels[$i]}" "v${versions[$i]}" "${kinds[$i]}" > "$BADGES_DIR/${files[$i]}"
done

badges_abs="$(cd "$BADGES_DIR" && pwd)"
readme_dir="$(cd "$(dirname "$README")" && pwd)"
rel="$(relpath "$readme_dir" "$badges_abs")"

block="$(mktemp)"
{
  line=""
  for i in "${!labels[@]}"; do
    line+="![${labels[$i]}: v${versions[$i]}](${rel}/${files[$i]}) "
  done
  printf '%s\n\n' "${line% }"
  printf '| Component | Version | Tag |\n|---|---|---|\n'
  for i in "${!labels[@]}"; do
    printf '| %s | %s | [%s](https://github.com/%s/releases/tag/%s) |\n' "${labels[$i]}" "${versions[$i]}" "${tags[$i]}" "$REPO" "${tags[$i]}"
  done
} > "$block"

tmp="$(mktemp)"
awk -v start="$START" -v end="$END" -v blockfile="$block" '
  index($0, start) == 1 { print; while ((getline l < blockfile) > 0) print l; close(blockfile); skipping = 1; next }
  index($0, end) == 1   { skipping = 0 }
  !skipping { print }
' "$README" > "$tmp"
cat "$tmp" > "$README"
rm -f "$tmp" "$block"

after="$(snapshot)"
changed=false; [[ "$before" != "$after" ]] && changed=true
echo "badges=${#labels[@]}"
echo "changed=$changed"
printf 'files='; (IFS=,; printf '%s\n' "${files[*]/#/$BADGES_DIR/}")
