#!/usr/bin/env bash
# Builds OpenCascade for macOS, iOS and the iOS simulator as one dynamic framework per slice and
# packages them as vendor/OCCT.xcframework (with a dSYM per slice), plus vendor/occt-include for
# CFilletKernel's `occt` header symlink.
#
# OCCT is LGPL 2.1, so Fillet links it as a shared library the user can replace (§6b). Each slice
# is built as OCCT's static libTK*.a, then all of them are linked into ONE dylib
# (@rpath/OCCT.framework/OCCT) rather than OCCT's own shared build of about 40 dylibs.
#
# Fillet's changes to OCCT live in scripts/occt-patches/*.patch. vendor/occt-src is reset to a
# clean V8_0_1 tree and the patches are applied before every build, so a changed patch always
# takes effect and a re-run never applies one twice.
#
# Usage: scripts/build-occt.sh [slice...]   (slices: macos ios ios-sim; default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/occt-src"
WORK="$ROOT/vendor/occt-build"
OUT="$ROOT/vendor/OCCT.xcframework"
PATCHES="$ROOT/scripts/occt-patches"
OCCT_TAG="V8_0_1"
OCCT_VERSION="8.0.1"
IOS_MIN="18.0"
MACOS_MIN="15.0"
JOBS="$(sysctl -n hw.ncpu)"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$OCCT_TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC"
fi

echo "==> reset $SRC to $OCCT_TAG and apply scripts/occt-patches (discards any edits there)"
# The clone is shallow: a tag it doesn't have yet (after bumping OCCT_TAG) has to be fetched.
git -C "$SRC" rev-parse --quiet --verify "refs/tags/$OCCT_TAG" > /dev/null \
  || git -C "$SRC" fetch --quiet --depth 1 origin tag "$OCCT_TAG"
git -C "$SRC" checkout --quiet --force "$OCCT_TAG"
git -C "$SRC" clean --quiet -fd
for patch in "$PATCHES"/*.patch; do
  [ -e "$patch" ] || continue
  echo "    $(basename "$patch")"
  git -C "$SRC" apply "$patch"
done
# What each slice was built from, so packaging can refuse a slice left over from other patches.
STAMP="$OCCT_TAG $(cat "$PATCHES"/*.patch 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"

SLICES=("$@")
[ ${#SLICES[@]} -eq 0 ] && SLICES=(macos ios ios-sim)

# Writes the framework's Info.plist for a slice to $2.
write_info_plist() {
  local slice="$1" plist="$2" platform min_key min
  case "$slice" in
    macos)   platform=MacOSX;          min_key=LSMinimumSystemVersion; min="$MACOS_MIN" ;;
    ios)     platform=iPhoneOS;        min_key=MinimumOSVersion;       min="$IOS_MIN" ;;
    ios-sim) platform=iPhoneSimulator; min_key=MinimumOSVersion;       min="$IOS_MIN" ;;
  esac
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>OCCT</string>
	<key>CFBundleIdentifier</key>
	<string>app.fillet.OCCT</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>OCCT</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$OCCT_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$OCCT_VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platform</string>
	</array>
	<key>$min_key</key>
	<string>$min</string>
</dict>
</plist>
EOF
  plutil -lint -s "$plist"
}

build_slice() {
  local slice="$1"
  local build="$WORK/$slice/build" install="$WORK/$slice/install"
  local -a platform_args
  local sdk target
  # -all_load also pulls in code the app never calls (TKService's Cocoa windows), so the dylib
  # links the system frameworks that code needs.
  local -a system_libs

  case "$slice" in
    macos)   platform_args=(-DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN")
             sdk=macosx;          target="arm64-apple-macos$MACOS_MIN"
             system_libs=(-framework Foundation -framework AppKit -framework CoreGraphics -lobjc) ;;
    ios)     platform_args=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN")
             sdk=iphoneos;        target="arm64-apple-ios$IOS_MIN"
             system_libs=(-framework Foundation -framework UIKit -framework CoreGraphics -lobjc) ;;
    ios-sim) platform_args=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN")
             sdk=iphonesimulator; target="arm64-apple-ios$IOS_MIN-simulator"
             system_libs=(-framework Foundation -framework UIKit -framework CoreGraphics -lobjc) ;;
    *) echo "unknown slice $slice" >&2; exit 1 ;;
  esac

  echo "==> [$slice] configure"
  cmake -S "$SRC" -B "$build" -G "Unix Makefiles" \
    "${platform_args[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install" \
    -DBUILD_LIBRARY_TYPE=Static \
    -DBUILD_RELEASE_DISABLE_EXCEPTIONS=OFF \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_MODULE_Deprecated=OFF \
    -DBUILD_DOC_Overview=OFF \
    -DBUILD_GTEST=OFF \
    -DUSE_TK=OFF -DUSE_TCL=OFF -DUSE_FREETYPE=OFF -DUSE_FREEIMAGE=OFF \
    -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF -DUSE_VTK=OFF \
    -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_TBB=OFF -DUSE_FFMPEG=OFF -DUSE_OPENVR=OFF \
    > "$WORK/$slice.configure.log"

  echo "==> [$slice] build"
  cmake --build "$build" --parallel "$JOBS" > "$WORK/$slice.build.log" 2>&1
  cmake --install "$build" > "$WORK/$slice.install.log"

  echo "==> [$slice] link OCCT.framework"
  local fw="$WORK/$slice/OCCT.framework" bin_dir res_dir
  local -a libs
  # Every libTK*.a goes in whole (-all_load), so the order doesn't matter. Except OCCT's OpenGL ES
  # renderer, which the iOS build makes despite USE_GLES2=OFF: nothing Fillet uses depends on it,
  # and it would need the deprecated OpenGLES framework.
  while IFS= read -r lib; do libs+=("$lib"); done < <(find "$install" -name 'libTK*.a' ! -name 'libTKOpenGles.a' | sort)
  rm -rf "$fw" "$fw.dSYM" "$fw.stamp" "$WORK/$slice/libOCCT.a"
  if [ "$slice" = macos ]; then
    # macOS frameworks are versioned: the files live in Versions/A, the top level has symlinks.
    bin_dir="$fw/Versions/A"; res_dir="$bin_dir/Resources"
    mkdir -p "$res_dir"
    ln -s A "$fw/Versions/Current"
    for name in OCCT Headers Resources; do ln -s "Versions/Current/$name" "$fw/$name"; done
  else
    bin_dir="$fw"; res_dir="$fw"
    mkdir -p "$fw"
  fi
  xcrun --sdk "$sdk" clang++ -dynamiclib -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -install_name @rpath/OCCT.framework/OCCT \
    -current_version "$OCCT_VERSION" -compatibility_version "$OCCT_VERSION" \
    -Wl,-headerpad_max_install_names \
    -Wl,-all_load "${libs[@]}" \
    "${system_libs[@]}" \
    -o "$bin_dir/OCCT"
  cp -R "$(dirname "$(find "$install" -name Standard.hxx | head -1)")" "$bin_dir/Headers"
  write_info_plist "$slice" "$res_dir/Info.plist"

  echo "==> [$slice] dSYM"
  dsymutil "$bin_dir/OCCT" -o "$fw.dSYM"
  echo "$STAMP" > "$fw.stamp"
}

mkdir -p "$WORK"
for s in "${SLICES[@]}"; do build_slice "$s"; done

# Package every slice that has been built (so slices can be rebuilt individually), as long as it
# was built from the same OCCT tag and patches as this run.
echo "==> package $OUT"
args=()
for s in macos ios ios-sim; do
  fw="$WORK/$s/OCCT.framework"
  [ -d "$fw" ] || continue
  if [ "$(cat "$fw.stamp" 2>/dev/null)" != "$STAMP" ]; then
    echo "The $s slice was built from other OCCT sources or patches; rebuild it: scripts/build-occt.sh $s" >&2
    exit 1
  fi
  args+=(-framework "$fw" -debug-symbols "$fw.dSYM")
  headers="${headers:-$fw/Headers}"
done
rm -rf "$OUT"
xcodebuild -create-xcframework "${args[@]}" -output "$OUT"

# Headers are identical across slices; expose one copy to the CFilletKernel target.
rm -rf "$ROOT/vendor/occt-include"
cp -R "$headers/" "$ROOT/vendor/occt-include"
echo "done: $OUT"
