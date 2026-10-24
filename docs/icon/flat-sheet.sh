#!/bin/bash
# Renders the flat concept round (flat.py) to concepts-flat.png:
# each concept at 512 px (rounded-rect masked) + 64 px and 32 px previews.
set -euo pipefail
cd "$(dirname "$0")"
python3 flat.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FONT=/System/Library/Fonts/Helvetica.ttc
magick -size 1024x1024 xc:none -alpha set -fill white -draw "roundrectangle 0,0,1023,1023,230,230" "$TMP/mask.png"
cells=()
for svg in svg/flat-*.svg; do
  n=$(basename "$svg" .svg); num=${n:5:2}
  label=$(python3 -c "import flat,sys; print([c[2] for c in flat.CONCEPTS if c[0]=='$num'][0])")
  rsvg-convert -w 1024 -h 1024 "$svg" -o "$TMP/$n.png"
  magick "$TMP/$n.png" -alpha set "$TMP/mask.png" -compose DstIn -composite "$TMP/$n-m.png"
  magick "$TMP/$n-m.png" -resize 512x512 "$TMP/$n-512.png"
  magick "$TMP/$n-m.png" -resize 64x64 "$TMP/$n-64.png"
  magick "$TMP/$n-m.png" -resize 32x32 "$TMP/$n-32.png"
  magick -size 700x590 xc:"#f4f4f6" \
    "$TMP/$n-512.png" -geometry +20+56 -composite \
    -fill "#f4f4f6" -draw "rectangle 548,56 690,300" \
    -fill "#1e1e1e" -draw "roundrectangle 548,320 690,560 16,16" \
    "$TMP/$n-64.png" -geometry +587+90 -composite \
    "$TMP/$n-32.png" -geometry +603+190 -composite \
    "$TMP/$n-64.png" -geometry +587+350 -composite \
    "$TMP/$n-32.png" -geometry +603+460 -composite \
    -font "$FONT" -pointsize 30 -fill "#111" -annotate +22+40 "$num  $label" \
    "$TMP/cell-$num.png"
  cells+=("$TMP/cell-$num.png")
done
magick montage "${cells[@]}" -font "$FONT" -tile 2x -geometry +0+0 -background "#f4f4f6" concepts-flat.png
echo "wrote concepts-flat.png"
