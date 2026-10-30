#!/bin/bash
# Records a whole spec run as video (simctl io recordVideo, headless).
#
#   ./record.sh <name>
#
# Runs <name>.json on a free docs simulator (shot.sh), records the screen from launch to the end
# of the run, and writes build/docs-shots/fillet-chamfer-shell/r2/<name>.mov. The step log can
# lag behind the screen, so clip.py takes times read off the frames, not from the log.
# Then: python3 clip.py <name>
set -uo pipefail
R=$(cd "$(dirname "$0")/../../.." && pwd)
NAME=$1
OUT=$R/build/docs-shots/fillet-chamfer-shell/r2
mkdir -p "$OUT"
TMP=$(mktemp -d)
"$R/site/shots/fillet-chamfer-shell/shot.sh" "$R/site/shots/fillet-chamfer-shell/$NAME.json" > "$TMP/run.log" 2>&1 &
PID=$!
N=""
while [ -z "$N" ] && kill -0 $PID 2>/dev/null; do N=$(grep -o "Fillet Docs [0-9]" "$TMP/run.log" | head -1 | grep -o "[0-9]$"); sleep 0.2; done
UDID=$(xcrun simctl list devices | grep -F "    Fillet Docs $N (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
# Wait until the app is up (the wrapper reinstalls it first), then record.
until grep -q "Running " "$TMP/run.log"; do sleep 0.2; done
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/$NAME.mov" > "$TMP/rec.log" 2>&1 &
REC=$!
wait $PID
kill -INT $REC; wait $REC
cat "$TMP/run.log"
ls -la "$OUT/$NAME.mov"
