#!/bin/bash
# Captures the two sketching shots that only exist while a finger is down (a shape in progress,
# snap guides): their spec ends in a drag that holds 25 s, and this grabs the simulator's screen
# during that hold with `xcrun simctl io` (headless; no Simulator.app, no input to the Mac).
#
#   site/shots/sketching/hold-capture.sh drawing-in-progress   # marker shot: pre-drag.png
#   site/shots/sketching/hold-capture.sh snapping-guides       # marker shot: pre-guides.png
#
# Writes build/docs-shots/sketching/<name>-full.png (2732×2048); crop it into
# site/src/assets/screens/sketching/ as before (drawing.png: 2090x1400+0+315 → 1600 wide;
# snapping-guides.png: 1800x1435+0+315 → 1500 wide). sketch-bar.png is the sketch bar cut from
# drawing-in-progress-full.png at full size, about 1530x124+282+94.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
name=$1
case $name in
  drawing-in-progress) marker=pre-drag.png ;;
  snapping-guides) marker=pre-guides.png ;;
  *) echo "unknown shot $name" >&2; exit 1 ;;
esac
OUT="$ROOT/build/docs-shots/sketching"; mkdir -p "$OUT"; rm -f "$OUT/$marker"
log=$(mktemp)
"$ROOT/scripts/docs-shot-any.sh" "$ROOT/site/shots/sketching/$name.json" >"$log" 2>&1 &
run=$!
until grep -q 'docs-shot-any: Fillet Docs' "$log"; do sleep 1; done
n=$(grep -o 'Fillet Docs [0-9]' "$log" | head -1 | awk '{print $3}')
udid=$(xcrun simctl list devices | grep "Fillet Docs $n (" | grep -oE '[0-9A-F-]{36}')
until [ -f "$OUT/$marker" ]; do sleep 0.3; kill -0 $run 2>/dev/null || { cat "$log"; exit 1; }; done
sleep 4  # press + drag, then the hold
xcrun simctl io "$udid" screenshot "$OUT/$name-full.png"
wait $run; cat "$log"
