#!/bin/bash
# Regenerates the Fillet app icon (flat "graph paper iso" design, concept 02):
#   flat.py        -> svg/final-*.svg
#   asset catalog  -> App/Resources/Assets.xcassets/AppIcon.appiconset/*.png
#   make_icon.py   -> AppIcon.icon (Icon Composer, Liquid Glass) here AND in App/Resources/
#   previews       -> final-1024.png, final-preview.png, final-liquid-glass.png
# Needs python3, rsvg-convert (brew install librsvg), ImageMagick (magick), Xcode (ictool).
# The earlier glossy round lives in icon.py (+ concepts.png); the flat round's
# contact sheet is flat-sheet.sh -> concepts-flat.png.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
SET="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FONT=/System/Library/Fonts/Helvetica.ttc
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

python3 flat.py >/dev/null

# --- iOS / iPadOS: full-bleed opaque square (system applies the mask)
rsvg-convert -w 1024 -h 1024 svg/final-ios.svg -o "$TMP/ios.png"
magick "$TMP/ios.png" -background "#f5efe0" -alpha remove -alpha off -strip PNG24:"$SET/icon-ios-1024.png"
cp "$SET/icon-ios-1024.png" final-1024.png

# --- macOS: 824 px rounded rect + margin + template shadow; <= 64 px uses the
#     simplified artwork (no grid / hidden edges, heavier outline, bigger part),
#     16 px an even heavier "tiny" cut
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  size=${spec%%:*}; scale=${spec##*:}; px=$((size * scale))
  src=svg/final-macos.svg
  [ "$px" -le 64 ] && src=svg/final-macos-small.svg
  [ "$px" -le 16 ] && src=svg/final-macos-tiny.svg
  name="icon_${size}x${size}"; [ "$scale" = 2 ] && name="${name}@2x"
  rsvg-convert -w "$px" -h "$px" "$src" -o "$TMP/m.png"
  magick "$TMP/m.png" -strip PNG32:"$SET/$name.png"
done

# --- Icon Composer bundle (layers: fillet [glass] / outline / paper+grid; dark = navy paper)
python3 make_icon.py AppIcon.icon --fillet-glass
rm -rf "$ROOT/App/Resources/AppIcon.icon"
cp -R AppIcon.icon "$ROOT/App/Resources/AppIcon.icon"

# --- renders + preview sheet
for r in Default Dark ClearLight ClearDark; do
  if [ -x "$IC" ]; then
    "$IC" AppIcon.icon --export-image --output-file "$TMP/lg-$r.png" --platform iOS --rendition "$r" \
      --width 1024 --height 1024 --scale 1 >/dev/null 2>&1 </dev/null || true
  fi
done
[ -f "$TMP/lg-Default.png" ] && cp "$TMP/lg-Default.png" final-liquid-glass.png

magick -size 1024x1024 xc:none -alpha set -fill white -draw "roundrectangle 0,0,1023,1023,230,230" "$TMP/mask.png"
magick "$TMP/ios.png" -alpha set "$TMP/mask.png" -compose DstIn -composite -resize 600x600 "$TMP/big.png"
macrow() {  # $1 = background colour, $2 = out
  magick -size 600x200 xc:"$1" \
    "$SET/icon_128x128.png" -geometry +24+36 -composite \
    "$SET/icon_32x32.png" -geometry +200+84 -composite \
    "$SET/icon_16x16.png" -geometry +260+92 -composite \
    \( "$SET/icon_32x32.png" -filter point -resize 128x128 \) -geometry +310+36 -composite \
    \( "$SET/icon_16x16.png" -filter point -resize 128x128 \) -geometry +450+36 -composite \
    "$2"
}
macrow "#ececec" "$TMP/row-l.png"
macrow "#1e1e1e" "$TMP/row-d.png"
lg=()
for r in Default Dark ClearLight ClearDark; do
  [ -f "$TMP/lg-$r.png" ] && lg+=("$TMP/lg-$r.png")
done
magick "${lg[@]}" -resize 130x130 -background "#9a9a9a" -splice 10x10 +append -gravity southeast -splice 10x10 "$TMP/lg.png"
magick -size 1260x700 xc:"#f4f4f6" -font "$FONT" -fill "#111" -pointsize 24 \
  "$TMP/big.png" -geometry +20+60 -composite -annotate +20+40 "iOS / iPadOS 1024 (system mask)" \
  "$TMP/row-l.png" -geometry +640+60 -composite \
  "$TMP/row-d.png" -geometry +640+260 -composite \
  -annotate +640+40 "macOS 128 / 32 / 16 (+ 32, 16 zoomed)" \
  "$TMP/lg.png" -geometry +640+500 -composite \
  -annotate +640+490 "Liquid Glass: Default / Dark / Clear (ictool)" \
  final-preview.png
echo "done"
