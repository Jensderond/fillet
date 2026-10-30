#!/bin/bash
# Crops the holes guide's published screenshots from the raw captures. To regenerate:
#   scripts/docs-shot-any.sh site/shots/holes/plate.json     (hole-placing, hole-preset-menu, hole-positions)
#   scripts/docs-shot-any.sh site/shots/holes/sizes.json     (sizes-full)
#   scripts/docs-shot-any.sh site/shots/holes/pattern.json   (pattern-full)
#   site/shots/holes/crop.sh
# Offsets are pixels in the 2732x2048 captures (2 px per point).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
RAW="$ROOT/build/docs-shots/holes"
OUT="$ROOT/site/src/assets/screens/holes"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

crop() { # src out x y w h [width]
    sips -c "$6" "$5" --cropOffset "$4" "$3" "$RAW/$1" -o "$TMP/o.png" >/dev/null
    if [ -n "${7:-}" ]; then sips --resampleWidth "$7" "$TMP/o.png" >/dev/null; fi
    cp "$TMP/o.png" "$OUT/$2"
}

crop hole-placing.png     hole-placing.png        503  312 2229 1360 1800  # viewport + inspector, down to Extent
crop hole-preset-menu.png preset-menu.png        1783  631  948  638       # the Preset menu, fit and size
crop hole-placing.png     clearance-parameter.png   0  700  503  380       # browser: Parameters
crop hole-placing.png     clearance-diameter.png 2097  800  635  593       # inspector: hint, Type, Diameter, Bore
crop hole-positions.png   positions.png          2097  975  635  720       # inspector: Positions
crop sizes-full.png       hole-sizes.png         2097  800  635  825       # inspector: Type … Point angle
crop pattern-full.png     pattern-row.png         503  312 2229 1250 1800  # viewport + Pattern inspector, down to Spacing
# Phone crops (Figure phoneSrc): just the part, so it stays readable at 390px.
crop hole-placing.png     hole-placing-phone.png  640  640 1400 1020       # the plate with its two crosses
crop pattern-full.png     pattern-row-phone.png   680  715 1330  885       # the plate with four holes
