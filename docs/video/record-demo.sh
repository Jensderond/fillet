#!/bin/zsh
# Records the paced demo (FILLET_DEMO=1) on the iPad Pro 12.9" (6th gen) simulator.
#
#   docs/video/record-demo.sh [output.mp4]
#
# Builds the Debug app for the simulator, prepares a clean status bar and light
# appearance, launches the demo with SIMCTL_CHILD_FILLET_DEMO=1, records until
# the demo logs its last beat, and copies the beat log next to the recording
# (beats carry wall-clock times; the recording start time is written alongside).
set -euo pipefail
UDID=A482C0F1-DB9B-4728-9E92-82C9195172C1
BUNDLE=app.fillet.Fillet
ROOT=${0:A:h:h:h}
OUT=${1:-$ROOT/build/video/raw/demo.mp4}
mkdir -p ${OUT:h}

cd $ROOT
xcodebuild -project App/Fillet.xcodeproj -scheme Fillet -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/dd-sim129 build -quiet

xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl ui $UDID appearance light
xcrun simctl ui $UDID content_size large
xcrun simctl status_bar $UDID override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode notSupported
xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
xcrun simctl install $UDID build/dd-sim129/Build/Products/Debug-iphonesimulator/Fillet.app
sleep 2

xcrun simctl io $UDID recordVideo --codec=h264 --force $OUT &
REC=$!
sleep 1.5
python3 -c 'import time; print(f"{time.time():.3f}")' > ${OUT:r}.start.txt
SIMCTL_CHILD_FILLET_DEMO=1 xcrun simctl launch $UDID $BUNDLE >/dev/null

DATA=$(xcrun simctl get_app_container $UDID $BUNDLE data)
LOG=$DATA/tmp/fillet-demo/beats.txt
for i in {1..240}; do
  sleep 0.5
  [[ -f $LOG ]] && grep -q "beat end" $LOG && break
done
sleep 1.0
kill -INT $REC
wait $REC || true
cp $LOG ${OUT:r}.beats.txt
echo "recorded $OUT"
