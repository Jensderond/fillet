#!/usr/bin/env bash
# Builds the Mac release: Fillet.app (Release, arm64 only, ad-hoc signed with the hardened runtime
# and the app's entitlements) with the fillet-mcp helper embedded in Contents/Helpers and the
# updater in Contents/XPCServices, packed as build/release/Fillet-<version>.dmg with the
# drawing-sheet window from docs/dmg.
#
# Installed copies update themselves from the newest GitHub release tagged v<version> with this
# DMG attached (Fillet ▸ Check for Updates…), checked against the SHA-256 GitHub lists for it.
# Needs xcodegen and uv (dmgbuild runs through uv).
#
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
# The version must match MARKETING_VERSION in App/project.yml.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/build/dd-release"
APP="$DD/Build/Products/Release/Fillet.app"
HELPER="$APP/Contents/Helpers/fillet-mcp"
UPDATER="$APP/Contents/XPCServices/FilletUpdater.xpc"
ENTITLEMENTS="$ROOT/App/Fillet.entitlements"

cd "$ROOT"
grep -q "MARKETING_VERSION: \"$VERSION\"" App/project.yml \
  || { echo "App/project.yml's MARKETING_VERSION is not \"$VERSION\"" >&2; exit 1; }

echo "==> Generating the Xcode project"
(cd App && xcodegen generate --quiet)

echo "==> Building Fillet.app (Release, arm64)"
rm -rf "$APP"
xcodebuild -project App/Fillet.xcodeproj -scheme Fillet -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath "$DD" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=YES \
  -quiet build

SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$SHORT" = "$VERSION" ] || { echo "Built version is $SHORT, not $VERSION" >&2; exit 1; }
[ -d "$UPDATER" ] || { echo "Fillet.app has no FilletUpdater.xpc" >&2; exit 1; }

echo "==> Building fillet-mcp"
swift build -c release --product fillet-mcp
BIN="$(swift build -c release --product fillet-mcp --show-bin-path)/fillet-mcp"
[ "$(lipo -archs "$BIN")" = "arm64" ] || { echo "fillet-mcp is not arm64 only" >&2; exit 1; }

echo "==> Embedding and signing"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN" "$HELPER"
# The helper first, on its own: hardened runtime but no sandbox, so headless mode can open and
# save .fillet files anywhere.
codesign --force --sign - --options runtime --identifier app.fillet.fillet-mcp "$HELPER"
# The updater likewise: not sandboxed, so it can replace Fillet.app.
codesign --force --sign - --options runtime "$UPDATER"
# Then the app with its entitlements. No --deep: the helper and the updater keep their own signatures.
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$HELPER"
codesign --verify --strict "$UPDATER"
codesign --verify --strict --deep "$APP"

echo "==> Making the DMG"
# dmgbuild lays out the window (docs/dmg/background.tiff, the icons, an Applications link) by
# writing the .DS_Store itself; scripts/dmg-settings.py has the layout.
OUT="$ROOT/build/release"
DMG="$OUT/Fillet-$VERSION.dmg"
mkdir -p "$OUT"
rm -f "$DMG"
uv run --quiet --no-project --with dmgbuild==1.6.7 dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" -D background="$ROOT/docs/dmg/background.tiff" Fillet "$DMG" \
  2> >(grep -v 'is deprecated' >&2) >/dev/null

echo "==> $DMG ($(du -h "$DMG" | awk '{ print $1 }'))"
shasum -a 256 "$DMG" | awk -v name="$(basename "$DMG")" '{ print "SHA-256  " $1 "  " name }'
