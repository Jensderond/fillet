#!/bin/bash
# Crops the published stills from the fillet-round run's last screenshot (r2/fillet-too-big.png).
# Crops are in points of the 1366x1024 screen (2 px per pt), like the clips in clip.py.
set -euo pipefail
R=$(cd "$(dirname "$0")/../../.." && pwd)
IN=$R/build/docs-shots/fillet-chamfer-shell/r2/fillet-too-big.png
OUT=$R/site/src/assets/screens/fillet-chamfer-shell
c() { echo "crop=$(($3*2)):$(($4*2)):$(($1*2)):$(($2*2))"; }
# Desktop: model and inspector.
ffmpeg -v error -y -i "$IN" -vf "$(c 470 95 896 470),scale=1600:-2:flags=lanczos" "$OUT/fail.png"
# Phone: the inspector over the model, with a hairline between.
ffmpeg -v error -y -i "$IN" -filter_complex \
  "[0]split[a][b];[a]$(c 1048 160 318 352),scale=720:-2:flags=lanczos,pad=iw:ih+6:0:0:color=0xD9D6CF[i];[b]$(c 478 160 570 385),scale=720:-2:flags=lanczos[m];[i][m]vstack" \
  "$OUT/fail-phone.png"
# The red step in the timeline.
ffmpeg -v error -y -i "$IN" -vf "$(c 210 928 380 72)" "$OUT/fail-timeline.png"
for f in fail fail-phone fail-timeline; do echo "$OUT/$f.png $(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$OUT/$f.png")"; done
