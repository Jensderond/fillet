#!/bin/bash
# Crops and scales the captures into site/src/assets/screens/selecting (1600 px wide).
# Run after: scripts/docs-shot-any.sh selection-next.json and ./box-select-crossing.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../../.." && pwd)
IN=$R/build/docs-shots/selecting
OUT=$R/site/src/assets/screens/selecting
mkdir -p "$OUT"
# sips -c <height> <width> --cropOffset <y> <x>, in pixels (2 px per point).
# The right of the viewport and the inspector (the browser is hidden in the spec).
sips -c 1160 1692 --cropOffset 320 1040 "$IN/selection-next.png" --out "$OUT/selection-next.png" >/dev/null
sips -c 1160 1692 --cropOffset 320 1040 "$IN/selection-distance.png" --out "$OUT/selection-distance.png" >/dev/null
# The viewport alone, with the Box select bar.
sips -c 1286 1584 --cropOffset 314 508 "$IN/box-crossing-frame.png" --out "$OUT/box-select-crossing.png" >/dev/null
for f in "$OUT"/*.png; do
    [ "$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')" -gt 1600 ] && sips --resampleWidth 1600 "$f" >/dev/null
    sips -g pixelWidth -g pixelHeight "$f" | tail -2 | tr '\n' ' '; echo " $f"; done
