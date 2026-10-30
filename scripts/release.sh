#!/usr/bin/env bash
# Builds the Mac release: Fillet.app (Release, arm64 only, signed with a Developer ID, the hardened
# runtime and the app's entitlements) with OpenCascade in Contents/Frameworks/OCCT.framework, the
# fillet-mcp helper embedded in Contents/Helpers and the updater in Contents/XPCServices, notarized
# and packed as build/release/Fillet-<version>.dmg with the drawing-sheet window from docs/dmg.
#
# Signing identity: $FILLET_SIGN_IDENTITY, else the first "Developer ID Application" identity in the
# keychain. Notarization uses the notarytool keychain profile $FILLET_NOTARY_PROFILE (default
# "fillet"): an Apple ID, app-specific password and team ID of the team the Developer ID belongs to.
#
#   xcrun notarytool store-credentials fillet --apple-id <apple id> --team-id <team id>
#
# The app is notarized first and its ticket stapled, so the app in the DMG opens offline. The DMG is
# then signed, notarized and stapled itself: a downloaded image without a ticket still trips Gatekeeper.
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
OCCT="$APP/Contents/Frameworks/OCCT.framework"
ENTITLEMENTS="$ROOT/App/Fillet.entitlements"
PROFILE="${FILLET_NOTARY_PROFILE:-fillet}"

cd "$ROOT"
IDENTITY="${FILLET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F '"' '/"Developer ID Application: / && !found { print $2; found = 1 }')}"
[[ "$IDENTITY" == "Developer ID Application: "* ]] \
  || { echo "No \"Developer ID Application\" identity in the keychain (set FILLET_SIGN_IDENTITY); only a Developer ID build can be notarized" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" > /dev/null 2>&1 \
  || { echo "No notarytool keychain profile '$PROFILE'; create it with" >&2
       echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id <team id>" >&2; exit 1; }
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
[ -f "$OCCT/OCCT" ] || { echo "Fillet.app has no Frameworks/OCCT.framework" >&2; exit 1; }

echo "==> Building fillet-mcp"
swift build -c release --product fillet-mcp
BIN="$(swift build -c release --product fillet-mcp --show-bin-path)/fillet-mcp"
[ "$(lipo -archs "$BIN")" = "arm64" ] || { echo "fillet-mcp is not arm64 only" >&2; exit 1; }

echo "==> Embedding and signing"
# The app and the helper turn library validation off, so a user can swap in their own OCCT build
# (LGPL): it would otherwise only load libraries signed by our Team ID. Only here: the entitlements
# file is shared with the iPad app.
APP_ENTITLEMENTS="$DD/Fillet-release.entitlements"
HELPER_ENTITLEMENTS="$DD/fillet-mcp.entitlements"
cp "$ENTITLEMENTS" "$APP_ENTITLEMENTS"
plutil -create xml1 "$HELPER_ENTITLEMENTS"
for f in "$APP_ENTITLEMENTS" "$HELPER_ENTITLEMENTS"; do
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$f"
done
mkdir -p "$APP/Contents/Helpers"
cp "$BIN" "$HELPER"
# The helper links @rpath/OCCT.framework like the app; find it in Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$HELPER"
# Notarization needs the hardened runtime and a secure timestamp on everything nested.
SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
# OCCT (LGPL) first, so it can be replaced; Xcode signed it on embedding, re-sign it the same way.
"${SIGN[@]}" "$OCCT"
# The helper on its own: hardened runtime but no sandbox, so headless mode can open and save
# .fillet files anywhere.
"${SIGN[@]}" --entitlements "$HELPER_ENTITLEMENTS" \
  --identifier app.fillet.fillet-mcp "$HELPER"
# The updater likewise: not sandboxed, so it can replace Fillet.app.
"${SIGN[@]}" "$UPDATER"
# Then the app with its entitlements. No --deep: OCCT, the helper and the updater keep their own
# signatures.
"${SIGN[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --strict "$OCCT"
codesign --verify --strict "$HELPER"
codesign --verify --strict "$UPDATER"
codesign --verify --strict --deep "$APP"
# A valid signature can still be refused at load time (library validation, see above). The helper
# is signed like the app, so it starting (and loading OCCT) shows the app can too.
"$HELPER" --help > /dev/null || { echo "fillet-mcp can't load OCCT.framework (see above)" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

echo "==> Notarizing the app"
WORK="$(mktemp -d -t fillet-release)"
trap 'rm -rf "$WORK"' EXIT
# notarytool takes a zip, not a bundle; the ticket is stapled to the app itself.
ditto -c -k --keepParent "$APP" "$WORK/Fillet.zip"
notarize "$WORK/Fillet.zip"
xcrun stapler staple "$APP"

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

echo "==> Notarizing the DMG"
"${SIGN[@]}" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> Checking Gatekeeper"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "==> $DMG ($(du -h "$DMG" | awk '{ print $1 }'))"
shasum -a 256 "$DMG" | awk -v name="$(basename "$DMG")" '{ print "SHA-256  " $1 "  " name }'
