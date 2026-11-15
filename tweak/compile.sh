#!/bin/bash
# Compile KAlertXC.dylib for iOS with plain clang (no Theos required).
# Intended for a macOS GitHub Actions runner, but works on any macOS with Xcode CLT.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT_DIR:-$HERE/out}"
mkdir -p "$OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"

build_arch() {
  local arch="$1"
  echo "==> compiling $arch"
  xcrun --sdk iphoneos clang \
    -arch "$arch" \
    -isysroot "$SDK" \
    -miphoneos-version-min=14.0 \
    -dynamiclib \
    -fobjc-arc \
    -O2 \
    -Wno-deprecated-declarations \
    -framework Foundation \
    -framework UIKit \
    -framework CoreLocation \
    -framework CoreGraphics \
    -framework CoreMedia \
    -framework CoreVideo \
    -install_name "@executable_path/Frameworks/KAlertXC.dylib" \
    -o "$OUT/KAlertXC.$arch.dylib" \
    "$HERE/KAlertXC.m"
}

build_arch arm64
build_arch arm64e

echo "==> creating fat binary"
xcrun lipo -create \
  "$OUT/KAlertXC.arm64.dylib" \
  "$OUT/KAlertXC.arm64e.dylib" \
  -output "$OUT/KAlertXC.dylib"

echo "==> result"
xcrun lipo -info "$OUT/KAlertXC.dylib"
ls -l "$OUT/KAlertXC.dylib"
