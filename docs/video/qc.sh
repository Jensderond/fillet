#!/bin/zsh
# Quality checks on the built announcement:
#   - contact sheet docs/video/contact-sheet.png (16:9, one frame a second, timestamped)
#   - loudness (EBU R128 integrated, LRA, true peak) and clipping stats for both cuts
#   - stream properties
set -euo pipefail
ROOT=${0:A:h:h:h}
OUT=$ROOT/build/video/out
TMP=$ROOT/build/video/qc
rm -rf $TMP && mkdir -p $TMP
FONT=/System/Library/Fonts/SFNS.ttf

ffmpeg -v error -i $OUT/Fillet-Announcement-16x9.mp4 -vf "fps=1,scale=384:-1" $TMP/f%03d.png
for f in $TMP/f*.png; do
  n=${${f:t:r}#f}
  magick $f -font $FONT -pointsize 15 -fill white -undercolor '#1D2B45CC' -annotate +6+20 " $((10#$n - 1)) s " $f
done
magick montage -font $FONT $TMP/f*.png -tile 8x -geometry +4+4 -background '#E9EDF2' $ROOT/docs/video/contact-sheet.png
echo "contact sheet: docs/video/contact-sheet.png"

for cut in 16x9 Square; do
  f=$OUT/Fillet-Announcement-$cut.mp4
  echo "== $cut"
  ffprobe -v error -show_entries stream=codec_name,profile,width,height,r_frame_rate,sample_rate,channels \
    -show_entries format=duration,size -of compact $f
  ffmpeg -hide_banner -nostats -i $f -af ebur128=peak=true -f null - 2>&1 | sed -n '/Summary/,$p' | grep -E "I:|LRA:|Peak:"
  ffmpeg -hide_banner -nostats -i $f -af astats=measure_perchannel=none \
    -f null - 2>&1 | grep -E "Peak level dB|Number of clipped|Flat factor" | sed 's/^.*\] //'
done
