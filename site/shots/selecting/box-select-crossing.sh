#!/bin/bash
# Captures the crossing box mid-drag. XCUITest can't screenshot while a finger is down, so this
# runs box-select-crossing.json (its drag holds the finger still for 14 s) and grabs frames with
# `simctl io screenshot` during the hold. Writes build/docs-shots/selecting/box-crossing-frame.png.
set -uo pipefail
R=$(cd "$(dirname "$0")/../../.." && pwd)
OUT=$R/build/docs-shots/selecting
TMP=$(mktemp -d)
"$R/scripts/docs-shot-any.sh" "$R/site/shots/selecting/box-select-crossing.json" > "$TMP/run.log" 2>&1 &
PID=$!
N=""
while [ -z "$N" ] && kill -0 $PID 2>/dev/null; do N=$(grep -o "Fillet Docs [0-9]" "$TMP/run.log" | head -1 | grep -o "[0-9]$"); sleep 1; done
UDID=$(xcrun simctl list devices | grep -F "    Fillet Docs $N (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
i=0
while kill -0 $PID 2>/dev/null; do
    if grep -q ": drag" "$R"/build/docs-shots/logs/box-select-crossing-"${UDID:0:8}"-*.log 2>/dev/null; then
        i=$((i+1)); xcrun simctl io "$UDID" screenshot "$TMP/f$(printf %03d $i).png" >/dev/null 2>&1
    else sleep 0.5; fi
done
wait $PID; cat "$TMP/run.log"
# A frame from the middle of the hold: the box has reached its end and the preview has settled.
pick=$(ls "$TMP"/f*.png | sed -n "$(( ($(ls "$TMP"/f*.png | wc -l) + 1) * 2 / 3 ))p")
cp "$pick" "$OUT/box-crossing-frame.png" && echo "$OUT/box-crossing-frame.png (from $pick)"
