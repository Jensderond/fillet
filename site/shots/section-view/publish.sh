#!/bin/zsh
# Crops the Section view captures into the images the guide publishes.
# Run the specs first (scripts/docs-shot-any.sh site/shots/section-view/<name>.json),
# then: site/shots/section-view/publish.sh
# Crop boxes are in pixels of the 2732×2048 landscape captures.
set -euo pipefail
here=${0:A:h}
raw=$here/../../../build/docs-shots/section-view
out=$here/../../src/assets/screens/section-view
film=$here/../../../build/video/section/out/Fillet-Section-View.mp4
mkdir -p $out

# The cut part with its handles, no app chrome.
magick $raw/section-handles.png -crop 1236x840+540+540 +repage $out/cut.png

# The Section view panel, with a gutter on the left for the numbered pins.
magick $raw/section-handles.png -crop 622x1209+2104+328 +repage \
  -background 'rgb(246,247,249)' -gravity east -extent 712x1209 $out/panel.png

# The handles, close up.
magick $raw/section-handles.png -crop 765x409+684+821 +repage $out/handles-closeup.png

# The 2D section view drawing.
magick $raw/section-2d.png -crop 1612x376+239+943 +repage $out/2d.png

# The pill that stays after Done.
magick $raw/section-pill.png -crop 680x118+20+330 +repage $out/pill.png

# The plane picker bar: its plane buttons and Cancel.
if [[ -f $raw/section-plane-bar.png ]]; then
  magick $raw/section-plane-bar.png -crop ${PLANE_BAR_CROP:-600x136+650+327} +repage $out/plane-bar.png
fi

# The demo film, re-encoded for the web, and its poster.
if [[ -f $film ]]; then
  ffmpeg -v error -y -i $film -vf scale=1280:-2 -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p \
    -c:a aac -b:a 96k -movflags +faststart $out/film.mp4
  ffmpeg -v error -y -ss 12 -i $film -frames:v 1 -vf scale=1280:-2 $out/film-poster.jpg
fi
ls -la $out
