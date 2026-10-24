#!/usr/bin/env bash
# Builds OpenCascade as static libraries for macOS, iOS and the iOS simulator,
# merges each slice into one libOCCT.a and packages them as vendor/OCCT.xcframework.
#
# Usage: scripts/build-occt.sh [slice...]   (slices: macos ios ios-sim; default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/occt-src"
WORK="$ROOT/vendor/occt-build"
OUT="$ROOT/vendor/OCCT.xcframework"
OCCT_TAG="V8_0_1"
IOS_MIN="18.0"
MACOS_MIN="15.0"
JOBS="$(sysctl -n hw.ncpu)"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$OCCT_TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC"
fi

SLICES=("$@")
[ ${#SLICES[@]} -eq 0 ] && SLICES=(macos ios ios-sim)

build_slice() {
  local slice="$1"
  local build="$WORK/$slice/build" install="$WORK/$slice/install"
  local -a platform_args

  case "$slice" in
    macos)   platform_args=(-DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN") ;;
    ios)     platform_args=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN") ;;
    ios-sim) platform_args=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN") ;;
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

  echo "==> [$slice] merge static libs"
  local libs
  libs=$(find "$install" -name 'libTK*.a')
  libtool -static -no_warning_for_no_symbols -o "$WORK/$slice/libOCCT.a" $libs
}

mkdir -p "$WORK"
for s in "${SLICES[@]}"; do build_slice "$s"; done

# Package every slice that has been built (so slices can be rebuilt individually).
echo "==> package $OUT"
rm -rf "$OUT"
args=()
for s in macos ios ios-sim; do
  lib="$WORK/$s/libOCCT.a"
  [ -f "$lib" ] || continue
  headers="$(dirname "$(find "$WORK/$s/install" -name Standard.hxx | head -1)")"
  args+=(-library "$lib" -headers "$headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT"

# Headers are identical across slices; expose one copy to the CFilletKernel target.
rm -rf "$ROOT/vendor/occt-include"
cp -R "$headers" "$ROOT/vendor/occt-include"
echo "done: $OUT"
