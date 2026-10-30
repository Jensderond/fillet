#!/bin/zsh
# Quality checks on the Section view film (build/video/section/out/Fillet-Section-View.mp4):
#   - contact sheets in build/video/section/qc/: one frame a second (contact-sheet.png), one a
#     beat (beats-sheet.png, labelled bar.beat), and the frames either side of every cut (cuts-sheet.png)
#   - a spectrogram of the soundtrack (spectrum.png)
#   - loudness (EBU R128 integrated, LRA, true peak), clipping, stream properties
set -euo pipefail
ROOT=${0:A:h:h:h:h}
FILM=$ROOT/build/video/section/out/Fillet-Section-View.mp4
QC=$ROOT/build/video/section/qc
rm -rf $QC && mkdir -p $QC/s $QC/b $QC/c
FONT=/System/Library/Fonts/SFNS.ttf
label() { magick $1 -font $FONT -pointsize 15 -fill white -undercolor '#1D2B45CC' -annotate +6+20 " $2 " $1 }

ffmpeg -v error -i $FILM -vf "fps=1,scale=384:-1" $QC/s/f%03d.png
for f in $QC/s/f*.png; do n=${${f:t:r}#f}; label $f "$((10#$n - 1)) s"; done
magick montage -font $FONT $QC/s/f*.png -tile 8x -geometry +4+4 -background '#E9EDF2' $QC/contact-sheet.png

# 112.5 bpm at 30 fps: a beat is 16 frames.
ffmpeg -v error -i $FILM -vf "select='not(mod(n\,16))',scale=384:-1" -fps_mode passthrough $QC/b/b%03d.png
for f in $QC/b/b*.png; do n=$((10#${${f:t:r}#b} - 1)); label $f "$((n / 4)).$((n % 4))"; done
magick montage -font $FONT $QC/b/b*.png -tile 8x -geometry +4+4 -background '#E9EDF2' $QC/beats-sheet.png

# Either side of every cut (bars 2, 5, 6, 7, 9, 11, 12, 13, 14, 15, 16, 17): frames n-1, n, n+1.
i=0
for bar in 2 5 6 7 9 11 12 13 14 15 16 17; do
  n=$((bar * 64))
  for k in -1 0 1; do
    i=$((i + 1))
    ffmpeg -v error -i $FILM -vf "select=eq(n\,$((n + k))),scale=384:-1" -frames:v 1 -fps_mode passthrough $QC/c/$(printf %03d $i).png
    label $QC/c/$(printf %03d $i).png "bar $bar, frame $((n + k))"
  done
done
magick montage -font $FONT $QC/c/*.png -tile 6x -geometry +4+4 -background '#E9EDF2' $QC/cuts-sheet.png

ffmpeg -v error -y -i $FILM -lavfi "showspectrumpic=s=1600x500:legend=1:scale=log:fscale=log:stop=16000" $QC/spectrum.png
echo "sheets and spectrum in ${QC#$ROOT/}"

ffprobe -v error -show_entries stream=codec_name,profile,width,height,r_frame_rate,pix_fmt,sample_rate,channels,bit_rate \
  -show_entries format=duration,size -of compact $FILM
ffmpeg -hide_banner -nostats -i $FILM -af ebur128=peak=true -f null - 2>&1 | sed -n '/Summary/,$p' | grep -E "I:|LRA:|Peak:"
ffmpeg -hide_banner -nostats -i $FILM -af astats=measure_perchannel=none -f null - 2>&1 \
  | grep -E "Peak level dB|Number of clipped|Flat factor" | sed 's/^.*\] //'
