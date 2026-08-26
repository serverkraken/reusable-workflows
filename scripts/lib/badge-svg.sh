#!/usr/bin/env bash
# badge-svg.sh — die gemeinsame Badge-Darstellung des Katalogs.
#
# Herausgeloest aus version-badges.sh, damit derselbe Look auch fuer Badges
# gilt, die NICHT aus dem release-please-Manifest kommen (Go-Version, Lizenz).
# Vorher waren das shields.io-Bilder — also ein externer Request pro
# README-Aufruf, ein anderes Design, und in privaten Repos die Repo-Kennung an
# einen Fremdanbieter.
#
# Diese Datei wird gesourct und aendert an der Darstellung NICHTS. Die 13 Tests
# in tests/shell/version-badges.bats gelten unveraendert weiter; einer davon
# prueft Label, Wert, Farbe, Glyphe und die Abwesenheit externer Referenzen.
#
# Nutzung:
#   source "$(dirname "$0")/lib/badge-svg.sh"
#   badge_svg "chart" "v1.12.0" chart

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
