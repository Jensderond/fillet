#!/bin/zsh
# Records the body-edge snapping demo (FILLET_DEMO=snapping) twice on the iPad Pro 12.9"
# (6th gen) simulator, before (FILLET_SNAP_BODY_EDGES=0: only the sketch's own shapes snap)
# and after, and puts the two takes side by side with ffmpeg.
#
#   docs/video/record-snapping-demo.sh [output-dir]      # UDID=… picks another simulator
#
# Writes before.mp4, after.mp4 (raw takes with their beat logs) and Fillet-Snapping.mp4.
set -euo pipefail
UDID=${UDID:-A482C0F1-DB9B-4728-9E92-82C9195172C1}
BUNDLE=app.fillet.Fillet
ROOT=${0:A:h:h:h}
OUT=${1:-$ROOT/build/video/snapping}
mkdir -p $OUT

cd $ROOT
xcodebuild -project App/Fillet.xcodeproj -scheme Fillet -configuration Debug -destination "id=$UDID" \
  -derivedDataPath build/dd-sim129 CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build -quiet

xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl ui $UDID appearance light
xcrun simctl ui $UDID content_size large
xcrun simctl status_bar $UDID override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode notSupported
xcrun simctl install $UDID build/dd-sim129/Build/Products/Debug-iphonesimulator/Fillet.app

# record <name> [VAR=value…]: one take, with extra environment for the app.
record() {
  local name=$1; shift
  xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
  local log=$(xcrun simctl get_app_container $UDID $BUNDLE data)/tmp/fillet-demo/beats.txt
  rm -f $log  # an earlier take's "beat end" would stop this one at once
  sleep 2
  xcrun simctl io $UDID recordVideo --codec=h264 --force $OUT/$name.mp4 &
  local rec=$!
  sleep 1.5
  python3 -c 'import time; print(f"{time.time():.3f}")' > $OUT/$name.start.txt
  env SIMCTL_CHILD_FILLET_DEMO=snapping "$@" xcrun simctl launch $UDID $BUNDLE >/dev/null
  for i in {1..120}; do
    sleep 0.5
    [[ -f $log ]] && grep -q "beat end" $log && break
  done
  sleep 1.0
  kill -INT $rec
  wait $rec || true
  cp $log $OUT/$name.beats.txt
  echo "recorded $OUT/$name.mp4"
}
record before SIMCTL_CHILD_FILLET_SNAP_BODY_EDGES=0
record after

# Each take from its "story" beat (the splash is cut) to its "end" beat, side by side on a card
# with the labels (snapping-labels.swift).
swift docs/video/snapping-labels.swift $OUT/labels.png
python3 - $OUT <<'EOF'
import re, subprocess, sys
out = sys.argv[1]
# simctl's first frame comes about 1.65 s after the start time written above (measured from the
# camera flights: they show up in the video that much later than their beats).
LAG = 1.65
def span(name):
    start = float(open(f"{out}/{name}.start.txt").read())
    beats = {m[0]: float(m[1]) for m in re.findall(r"beat (\S+) t=\S+ epoch=([\d.]+)", open(f"{out}/{name}.beats.txt").read())}
    return beats["story"] - start + LAG, beats["end"] - beats["story"] + 0.6
(b0, bd), (a0, ad) = span("before"), span("after")
d = max(bd, ad)
def take(i, s):
    # Portrait 2048×2732 at 720×960; the shorter take holds its last frame.
    return (f"[{i}:v]trim=start={s:.3f}:duration={d:.3f},setpts=PTS-STARTPTS,fps=30,scale=720:960,"
            f"tpad=stop_mode=clone:stop_duration=2,trim=duration={d:.3f}[v{i}]")
graph = ";".join([take(0, b0), take(1, a0), f"[2:v]loop=-1:1,fps=30,trim=duration={d:.3f}[bg]",
                  "[bg][v0]overlay=200:110[l]", "[l][v1]overlay=1000:110,format=yuv420p[v]"])
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", f"{out}/before.mp4", "-i", f"{out}/after.mp4",
                "-i", f"{out}/labels.png", "-filter_complex", graph, "-map", "[v]", "-c:v", "libx264", "-crf", "18",
                "-movflags", "+faststart", f"{out}/Fillet-Snapping.mp4"], check=True)
print(f"wrote {out}/Fillet-Snapping.mp4 ({d:.1f} s)")
EOF
