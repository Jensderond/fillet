#!/bin/zsh
# Records the Section view demo (FILLET_DEMO=section) on the iPad Pro 12.9" (6th gen) simulator,
# paced to the music's beat grid (FILLET_DEMO_BPM, 112.5 by default).
#
#   docs/video/section/record.sh [output.mp4]      # UDID=… picks another simulator, BPM=… another tempo
#
# Writes the take, its beat log (<take>.beats.txt: every action with wall-clock time) and the
# time the recording was started (<take>.start.txt).
set -euo pipefail
UDID=${UDID:-A482C0F1-DB9B-4728-9E92-82C9195172C1}
BPM=${BPM:-112.5}
BUNDLE=app.fillet.Fillet
ROOT=${0:A:h:h:h:h}
OUT=${1:-$ROOT/build/video/section/raw/take.mp4}
mkdir -p ${OUT:h}

cd $ROOT
if [[ -z ${SKIP_BUILD:-} ]]; then
  xcodebuild -project App/Fillet.xcodeproj -scheme Fillet -configuration Debug -destination "id=$UDID" \
    -derivedDataPath build/dd-sim129 CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build -quiet
fi

xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl ui $UDID appearance light
xcrun simctl ui $UDID content_size large
xcrun simctl status_bar $UDID override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode notSupported
xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
xcrun simctl install $UDID build/dd-sim129/Build/Products/Debug-iphonesimulator/Fillet.app
LOG=$(xcrun simctl get_app_container $UDID $BUNDLE data)/tmp/fillet-demo/beats.txt
rm -f $LOG  # an earlier take's "beat end" would stop this one at once
sleep 2

xcrun simctl io $UDID recordVideo --codec=h264 --force $OUT &
REC=$!
sleep 1.5
python3 -c 'import time; print(f"{time.time():.3f}")' > ${OUT:r}.start.txt
SIMCTL_CHILD_FILLET_DEMO=section SIMCTL_CHILD_FILLET_DEMO_BPM=$BPM xcrun simctl launch $UDID $BUNDLE >/dev/null
for i in {1..160}; do
  sleep 0.5
  [[ -f $LOG ]] && grep -q "beat end " $LOG && break
done
sleep 1.0
kill -INT $REC
wait $REC || true
cp $LOG ${OUT:r}.beats.txt
echo "recorded $OUT"
