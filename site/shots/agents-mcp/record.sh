#!/bin/zsh
# Runs a spec on a free docs simulator and records the simulator's screen while it runs.
#   site/shots/agents-mcp/record.sh <spec.json> <out.mp4>
#   REDUCE_TRANSPARENCY=1 site/shots/agents-mcp/record.sh …
#     turns on Reduce Transparency once the design is open (so the Agents popover is opaque and the
#     inspector doesn't show through it). Give the spec a few seconds of "wait" after its first idle.
#     It is set only once the first step runs: with it on, the launch browser loses its "Browse"
#     button and the harness can't open the fixture. Afterwards the setting is removed again.
# The recording covers the whole run (reinstall, launch, steps). Cut it by hand with ffmpeg: fps=30 first
# (simctl records a variable frame rate), find the taps with select='gt(scene,0.005)',showinfo, trim,
# overlay touch.png (96 px) at each tap's pixel point for ~0.5 s, then crop the desktop and phone cuts.
set -uo pipefail
here=${0:A:h}
root=${here:h:h:h}
spec=${1:A}; out=${2:A}
typeset -A udids=(1 24746C17-A294-44FA-978A-95BE26DE248B 2 47A8752B-EFC3-4984-8917-8E2696E6D7A1
                  3 4B388507-3A2C-436A-A591-D133A0025C7B 4 23E437AD-0F85-4A84-9C71-9D9C63F610CB)
locks=$root/build/docs-shots/locks
# Take a free simulator the same way scripts/docs-shot-any.sh does.
n=
while [[ -z $n ]]; do
  for i in 1 2 3 4; do
    if [[ -f $locks/sim$i/pid ]] && ! kill -0 $(cat $locks/sim$i/pid 2>/dev/null) 2>/dev/null; then rm -rf $locks/sim$i; fi
    if mkdir $locks/sim$i 2>/dev/null; then echo $$ > $locks/sim$i/pid; n=$i; break; fi
  done
  [[ -z $n ]] && sleep 5
done
udid=${udids[$n]}
watcher=
cleanup() {
  [[ -n $watcher ]] && kill $watcher 2>/dev/null
  if [[ ${REDUCE_TRANSPARENCY:-0} == 1 ]]; then
    xcrun simctl spawn $udid defaults delete com.apple.Accessibility EnhancedBackgroundContrastEnabled 2>/dev/null
    for note in com.apple.accessibility.cache.enhance.background.contrast com.apple.accessibility.reduce.transparency.status; do
      xcrun simctl spawn $udid notifyutil -p $note; done
  fi
  rm -rf $locks/sim$n
}
trap cleanup EXIT INT TERM
echo "Fillet Docs $n"
started=$(date +%s)
if [[ ${REDUCE_TRANSPARENCY:-0} == 1 ]]; then
  ( until tlog=$(/bin/ls -t $root/build/docs-shots/logs/${spec:t:r}-${udid[1,8]}-*.log 2>/dev/null | head -1) &&
          [[ -n $tlog ]] && (( $(stat -f %m $tlog) >= started )) && grep -q "DOCS-STEP 1:" $tlog; do sleep 0.3; done
    xcrun simctl spawn $udid defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool YES
    for note in com.apple.accessibility.cache.enhance.background.contrast com.apple.accessibility.reduce.transparency.status; do
      xcrun simctl spawn $udid notifyutil -p $note; done ) &
  watcher=$!
fi
xcrun simctl io $udid recordVideo --codec=h264 --force $out 2>/dev/null &
rec=$!
$root/scripts/docs-shot.sh $spec $n; rc=$?
# Background jobs ignore SIGINT; signal simctl itself so it finalises the file.
pkill -INT -f "recordVideo.*$out"; wait $rec
echo "recorded $out (Fillet Docs $n)"
exit $rc
