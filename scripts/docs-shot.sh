#!/bin/bash
# Docs screenshots of the real iPad app, headless. See scripts/docs-shot.md.
#
#   scripts/docs-shot.sh [--build] [--keep-app] <spec.json> [simulator]
#   scripts/docs-shot.sh --setup      (once: makes "Fillet Docs 1".."4" and warms them up)
#
# simulator: a UDID, "Fillet Docs N", or just N (default 1). Runs DocsScreenshotUITests on it
# with the spec and prints the PNGs it wrote. Never opens Simulator.app: the device boots headless.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DD="$ROOT/build/dd-docs"
LOGS="$ROOT/build/docs-shots/logs"
BUNDLE_ID=app.fillet.Fillet

build=0
keep_app=0
setup=0
args=()
for a in "$@"; do
    case "$a" in
        --build) build=1 ;;
        --keep-app) keep_app=1 ;;
        --setup) setup=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) args+=("$a") ;;
    esac
done
# Setup: the four docs simulators (12.9" iPad Pro, 6th generation, newest iOS), each warmed up
# with one run: on a just-made simulator the document browser can't open files for a while.
if [ $setup = 1 ]; then
    RUNTIME=$(xcrun simctl list runtimes available | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -V | tail -1)
    for n in 1 2 3 4; do
        if ! xcrun simctl list devices available | grep -qF "    Fillet Docs $n ("; then
            echo "Fillet Docs $n: $(xcrun simctl create "Fillet Docs $n" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-6th-generation-8GB "$RUNTIME")"
        fi
    done
    for n in 1 2 3 4; do "$0" "$ROOT/scripts/docs-shot-samples/warmup.json" $n; done
    exit 0
fi
[ ${#args[@]} -ge 1 ] || { echo "usage: scripts/docs-shot.sh [--build] [--keep-app] <spec.json> [simulator]" >&2; exit 2; }
SPEC=$(cd "$(dirname "${args[0]}")" && pwd)/$(basename "${args[0]}")
[ -f "$SPEC" ] || { echo "No spec at $SPEC" >&2; exit 2; }
plutil -convert json -o /dev/null "$SPEC" 2>/dev/null || { echo "$SPEC isn't valid JSON" >&2; exit 2; }
SIM=${args[1]:-1}

# The simulator: UDID, name, or number of a "Fillet Docs N" device.
case "$SIM" in
    [0-9]) NAME="Fillet Docs $SIM" ;;
    *-*-*-*-*) NAME="" ;;
    *) NAME="$SIM" ;;
esac
if [ -n "$NAME" ]; then
    UDID=$(xcrun simctl list devices available | grep -F "    $NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
    [ -n "$UDID" ] || { echo "No simulator named “$NAME” (see scripts/docs-shot.md to create it)" >&2; exit 2; }
else
    UDID=$SIM
    NAME=$(xcrun simctl list devices | grep -F "($UDID)" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/')
fi

# The agent server's port: the spec's "port", else 790N for "Fillet Docs N" (simulators share the
# Mac's network, so parallel runs need their own ports), else 7900.
spec_value() { plutil -extract "$1" raw -o - "$SPEC" 2>/dev/null || true; }
PORT=$(spec_value port)
if [ -z "$PORT" ]; then
    case "$NAME" in "Fillet Docs "[0-9]) PORT=790${NAME#Fillet Docs } ;; *) PORT=7900 ;; esac
fi
# "appPort": true forces no port, so the app picks its own the way it does for a user (7878, then
# 7879…7888) and the popover shows a real address. The spec's "mcp" steps can't reach it then.
if [ "$(spec_value appPort)" = "true" ]; then PORT=; fi
APPEARANCE=$(spec_value appearance)
FIXTURE=$(spec_value fixture)
if [ -n "$FIXTURE" ] && [ "${FIXTURE:0:1}" != / ]; then FIXTURE="$(dirname "$SPEC")/$FIXTURE"; fi
if [ -n "$FIXTURE" ] && [ ! -f "$FIXTURE" ]; then echo "No fixture at $FIXTURE" >&2; exit 2; fi
# "fixtures": more files for the app's Documents (several designs in the browser, a STEP to import).
FIXTURES=()
[ -n "$FIXTURE" ] && FIXTURES+=("$FIXTURE")
i=0
while f=$(plutil -extract "fixtures.$i" raw -o - "$SPEC" 2>/dev/null); do
    [ "${f:0:1}" != / ] && f="$(dirname "$SPEC")/$f"
    [ -f "$f" ] || { echo "No fixture at $f" >&2; exit 2; }
    FIXTURES+=("$f"); i=$((i + 1))
done

# Build for testing once; again when sources changed or with --build. One build at a time
# (parallel runs wait for it).
LOCK="$ROOT/build/dd-docs.lock"
mkdir -p "$ROOT/build" "$LOGS"
until mkdir "$LOCK" 2>/dev/null; do sleep 2; done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
XCTESTRUN=$(ls "$DD"/Build/Products/FilletUITests_iphonesimulator*.xctestrun 2>/dev/null | head -1 || true)
if [ $build = 0 ] && [ -n "$XCTESTRUN" ]; then
    changed=$(find "$ROOT/App/Sources" "$ROOT/App/UITests" "$ROOT/App/Resources" "$ROOT/Sources" "$ROOT/Package.swift" "$ROOT/App/project.yml" \
        -newer "$XCTESTRUN" -type f -print -quit 2>/dev/null || true)
    [ -n "$changed" ] && { echo "Sources changed ($changed): rebuilding"; build=1; }
else
    build=1
fi
if [ $build = 1 ]; then
    (cd "$ROOT/App" && xcodegen generate --quiet)
    echo "Building for testing into build/dd-docs (log: build/docs-shots/logs/build.log)…"
    started=$(date +%s)
    if ! xcodebuild -project "$ROOT/App/Fillet.xcodeproj" -scheme FilletUITests -destination "id=$UDID" \
        -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing \
        > "$LOGS/build.log" 2>&1; then
        grep -E 'error:' "$LOGS/build.log" | head -20 >&2
        echo "Build failed: see $LOGS/build.log" >&2
        exit 1
    fi
    echo "Built in $(( $(date +%s) - started )) s"
    XCTESTRUN=$(ls "$DD"/Build/Products/FilletUITests_iphonesimulator*.xctestrun | head -1)
    touch "$XCTESTRUN"
fi
rmdir "$LOCK"; trap - EXIT

# The simulator: booted headless (simctl, never Simulator.app), light or dark, 9:41 status bar.
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl ui "$UDID" appearance "${APPEARANCE:-light}"
# 9:41 on Tue 9 Jan 2007 in the simulator's (the Mac's) time zone; simctl only takes UTC with milliseconds.
TIME=$(date -u -r "$(date -j -f '%Y-%m-%d %H:%M:%S' '2007-01-09 09:41:00' +%s)" +%Y-%m-%dT%H:%M:%S.000Z)
xcrun simctl status_bar "$UDID" override --time "$TIME" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode notSupported --batteryState charged --batteryLevel 100

# A clean app (no files, Recents or settings from earlier runs), with the fixture in its Documents.
APP="$DD/Build/Products/Debug-iphonesimulator/Fillet.app"
if [ $keep_app = 0 ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" > /dev/null 2>&1 || true
fi
xcrun simctl install "$UDID" "$APP"
if [ ${#FIXTURES[@]} -gt 0 ]; then
    CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
    mkdir -p "$CONTAINER/Documents"
    cp "${FIXTURES[@]}" "$CONTAINER/Documents/"
fi

stamp=$(date +%Y%m%d-%H%M%S)
log="$LOGS/$(basename "$SPEC" .json)-${UDID:0:8}-$stamp.log"
result="$ROOT/build/docs-shots/results/$(basename "$SPEC" .json)-${UDID:0:8}-$stamp.xcresult"
echo "Running $(basename "$SPEC") on ${NAME:-$UDID} ($UDID), agent port ${PORT:-chosen by the app}…"
started=$(date +%s)
set +e
TEST_RUNNER_FILLET_DOCS_SPEC="$SPEC" TEST_RUNNER_FILLET_UITEST_MCP_PORT="$PORT" \
    xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
    -only-testing:FilletUITests/DocsScreenshotUITests/testDocsShots -resultBundlePath "$result" \
    > "$log" 2>&1
status=$?
set -e
echo "--- $(( $(date +%s) - started )) s, log: $log"
grep -E 'error: |: error|Test Case .*failed' "$log" | head -10 >&2 || true
shots=$(grep -oE 'DOCS-SHOT: .*' "$log" | sed 's/^DOCS-SHOT: //' | awk '!seen[$0]++' || true)
if [ -n "$shots" ]; then echo "$shots"; fi
# Failed runs keep their result bundle (screen recording, UI tree, crash logs); passed runs don't.
if [ $status != 0 ]; then echo "The run failed (exit $status): see $log and $result" >&2; exit $status; fi
rm -rf "$result"
