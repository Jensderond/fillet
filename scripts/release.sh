#!/usr/bin/env bash
# Builds the Mac release: Fillet.app (Release, arm64 only, ad-hoc signed with the hardened runtime
# and the app's entitlements) with the fillet-mcp helper embedded in Contents/Helpers.
#
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
# The version must match MARKETING_VERSION in App/project.yml.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/build/dd-release"
APP="$DD/Build/Products/Release/Fillet.app"
HELPER="$APP/Contents/Helpers/fillet-mcp"
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
# Then the app with its entitlements. No --deep: the helper keeps its own signature.
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$HELPER"
codesign --verify --strict --deep "$APP"

echo "==> $APP ($SHORT)"
