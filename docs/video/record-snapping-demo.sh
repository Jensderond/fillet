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
  sleep 2
  xcrun simctl io $UDID recordVideo --codec=h264 --force $OUT/$name.mp4 &
  local rec=$!
  sleep 1.5
  python3 -c 'import time; print(f"{time.time():.3f}")' > $OUT/$name.start.txt
  env SIMCTL_CHILD_FILLET_DEMO=snapping "$@" xcrun simctl launch $UDID $BUNDLE >/dev/null
  local log=$(xcrun simctl get_app_container $UDID $BUNDLE data)/tmp/fillet-demo/beats.txt
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

# Each take from its "story" beat (the splash is cut) to its "end" beat, side by side, labelled.
python3 - $OUT <<'EOF'
import re, subprocess, sys
out = sys.argv[1]
def span(name):
    start = float(open(f"{out}/{name}.start.txt").read())
    beats = {m[0]: float(m[1]) for m in re.findall(r"beat (\S+) t=\S+ epoch=([\d.]+)", open(f"{out}/{name}.beats.txt").read())}
    return beats["story"] - start, beats["end"] - beats["story"] + 0.6
(b0, bd), (a0, ad) = span("before"), span("after")
d = max(bd, ad)
font = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
def take(i, s, label):
    return (f"[{i}:v]trim=start={s:.3f}:duration={d:.3f},setpts=PTS-STARTPTS,fps=30,scale=-2:960,"
            f"tpad=stop_mode=clone:stop_duration=2,trim=duration={d:.3f},pad=iw+40:1080:20:100:color=0xF4F1E8,"
            f"drawtext=fontfile='{font}':text='{label}':fontsize=44:fontcolor=0x1F2A44:x=(w-tw)/2:y=34[v{i}]")
graph = ";".join([take(0, b0, "Before"), take(1, a0, "After  -  snaps to the part"),
                  "[v0][v1]hstack,pad=1920:1080:(ow-iw)/2:0:color=0xF4F1E8[v]"])
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", f"{out}/before.mp4", "-i", f"{out}/after.mp4",
                "-filter_complex", graph, "-map", "[v]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
                f"{out}/Fillet-Snapping.mp4"], check=True)
print(f"wrote {out}/Fillet-Snapping.mp4 ({d:.1f} s)")
EOF
