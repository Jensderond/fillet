#!/bin/bash
# Regenerates the Fillet app icon: SVG sources (icon.py) -> PNGs in the asset
# catalog + docs/icon previews. Needs python3, rsvg-convert (brew install
# librsvg) and ImageMagick (magick).
set -euo pipefail
cd "$(dirname "$0")"
SET=../../App/Resources/Assets.xcassets/AppIcon.appiconset
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 icon.py

# iOS / iPadOS: full-bleed opaque square, the system applies the mask.
rsvg-convert -w 1024 -h 1024 svg/fillet-ios.svg -o "$TMP/ios.png"
magick "$TMP/ios.png" -background "#1236a6" -alpha remove -alpha off -strip PNG24:"$SET/icon-ios-1024.png"
cp "$SET/icon-ios-1024.png" final-1024.png

# macOS: rounded rect + margin + shadow baked in. <= 64 px uses the
# simplified "small" artwork (no grid / construction lines, bigger part).
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  size=${spec%%:*}; scale=${spec##*:}; px=$((size * scale))
  src=svg/fillet-macos.svg; [ "$px" -le 64 ] && src=svg/fillet-macos-small.svg
  name="icon_${size}x${size}"; [ "$scale" = 2 ] && name="${name}@2x"
  rsvg-convert -w "$px" -h "$px" "$src" -o "$TMP/m.png"
  magick "$TMP/m.png" -strip PNG32:"$SET/$name.png"
done
cp "$SET/icon_512x512@2x.png" final-macos-1024.png

# Icon Composer bundle (Liquid Glass, iOS/macOS 26+): fill gradient lives in
# AppIcon.icon/icon.json; the two layers are rendered here.
rsvg-convert -w 1024 -h 1024 svg/layer-background.svg -o AppIcon.icon/Assets/background.png
rsvg-convert -w 1024 -h 1024 svg/layer-part.svg -o AppIcon.icon/Assets/part.png
IC=/Applications/Xcode.app/Contents/Applications/Icon\ Composer.app/Contents/Executables/ictool
if [ -x "$IC" ]; then
  "$IC" AppIcon.icon --export-image --output-file final-liquid-glass.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
fi

# Contact sheet of the explored concepts (+ the final).
magick -size 1024x1024 xc:none -alpha set -fill white -draw "roundrectangle 0,0,1023,1023,230,230" "$TMP/mask.png"
args=()
for n in concept-a-blueprint concept-b-printbed concept-c-profile concept-d-light concept-e-extrude alt-navy fillet-ios; do
  rsvg-convert -w 1024 -h 1024 "svg/$n.svg" -o "$TMP/$n.png"
  magick "$TMP/$n.png" -alpha set "$TMP/mask.png" -compose DstIn -composite -resize 360x360 "$TMP/$n-m.png"
  args+=(-label "$n" "$TMP/$n-m.png")
done
magick montage "${args[@]}" -tile 4x2 -geometry 360x360+28+28 -background "#f4f4f6" -font /System/Library/Fonts/Helvetica.ttc -pointsize 22 concepts.png
echo "done"
