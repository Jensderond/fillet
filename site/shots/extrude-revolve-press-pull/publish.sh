#!/bin/bash
# Crops the raw captures (build/docs-shots/extrude-revolve-press-pull/) to the tool strip,
# viewport and inspector, and writes web-sized PNGs to src/assets/screens/extrude-revolve-press-pull/.
# Run the specs first: scripts/docs-shot-any.sh site/shots/extrude-revolve-press-pull/<name>.json
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
RAW="$ROOT/build/docs-shots/extrude-revolve-press-pull"
OUT="$ROOT/site/src/assets/screens/extrude-revolve-press-pull"
mkdir -p "$OUT"
for name in extrude-editing cut-pocket revolve-axis press-pull-face; do
  magick "$RAW/$name.png" -crop 2015x1533+717+314 +repage -resize 1600x \
    -strip -define png:compression-level=9 "$OUT/$name.png"
  echo "$OUT/$name.png $(magick identify -format '%wx%h' "$OUT/$name.png")"
done
