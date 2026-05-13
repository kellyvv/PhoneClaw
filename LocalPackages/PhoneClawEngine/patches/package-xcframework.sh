#!/usr/bin/env bash
# Package LiteRT-LM iOS binaries as App Store-compliant xcframeworks.
#
# The app's deployment target is iOS 17. Keep every framework Info.plist and
# Mach-O LC_BUILD_VERSION on that same floor; App Store Connect rejects bundles
# when a nested framework advertises a lower MinimumOSVersion than its binary.
set -euo pipefail

DEVICE=${DEVICE:-/tmp/v3-dylibs/device}
SIM=${SIM:-/tmp/v3-dylibs/sim}
HEADERS_SRC=${HEADERS_SRC:-/tmp/LiteRT-LM/c}
WORK=${WORK:-/tmp/v3-dylibs/work}
OUT_DIR=${OUT_DIR:-/Users/zxw/AITOOL/PhoneClaw/LocalPackages/PhoneClawEngine/Frameworks}

MIN_IOS=${MIN_IOS:-17.0}
IOS_SDK_VERSION=${IOS_SDK_VERSION:-$(xcrun --sdk iphoneos --show-sdk-version)}
SIM_SDK_VERSION=${SIM_SDK_VERSION:-$(xcrun --sdk iphonesimulator --show-sdk-version)}

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT_DIR"

write_framework_plist() {
  local fw="$1"
  local name="$2"
  local bundle_id="$3"

  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
PLIST
}

set_build_version() {
  local platform="$1"
  local sdk_version="$2"
  local binary="$3"
  local tmp="$binary.vtool"

  xcrun vtool \
    -set-build-version "$platform" "$MIN_IOS" "$sdk_version" \
    -replace \
    -output "$tmp" \
    "$binary"
  mv "$tmp" "$binary"
}

create_engine_slice() {
  local arch="$1"
  local platform="$2"
  local sdk_version="$3"
  local engine="$4"
  local fw="$WORK/$arch/CLiteRTLM.framework"

  mkdir -p "$fw/Headers" "$fw/Modules"
  cp "$engine" "$fw/CLiteRTLM"

  install_name_tool -id "@rpath/CLiteRTLM.framework/CLiteRTLM" "$fw/CLiteRTLM"
  install_name_tool \
    -change "@rpath/libGemmaModelConstraintProvider.dylib" \
    "@rpath/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider" \
    "$fw/CLiteRTLM" 2>/dev/null || true
  install_name_tool \
    -change "libGemmaModelConstraintProvider.dylib" \
    "@rpath/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider" \
    "$fw/CLiteRTLM" 2>/dev/null || true
  set_build_version "$platform" "$sdk_version" "$fw/CLiteRTLM"

  cp "$HEADERS_SRC/engine.h" "$fw/Headers/"
  cat > "$fw/Modules/module.modulemap" <<MODULEMAP
framework module CLiteRTLM {
    header "engine.h"
    export *
}
MODULEMAP

  write_framework_plist "$fw" "CLiteRTLM" "com.google.CLiteRTLM"
  codesign --force --sign - "$fw"
  echo "[OK] $arch CLiteRTLM.framework"
}

create_plugin_slice() {
  local arch="$1"
  local platform="$2"
  local sdk_version="$3"
  local name="$4"
  local bundle_id="$5"
  local source="$6"
  local install_name="$7"
  local fw="$WORK/$arch/$name.framework"

  mkdir -p "$fw"
  cp "$source" "$fw/$name"
  install_name_tool -id "$install_name" "$fw/$name"
  set_build_version "$platform" "$sdk_version" "$fw/$name"
  write_framework_plist "$fw" "$name" "$bundle_id"
  codesign --force --sign - "$fw"
  echo "[OK] $arch $name.framework"
}

create_xcframework() {
  local name="$1"
  shift
  local out="$OUT_DIR/$name.xcframework"

  rm -rf "$out"
  xcodebuild -create-xcframework "$@" -output "$out"
  echo "[OK] $out"
}

create_engine_slice "ios-arm64" "ios" "$IOS_SDK_VERSION" "$DEVICE/libLiteRTLMEngine.dylib"
create_engine_slice "ios-arm64-simulator" "iossimulator" "$SIM_SDK_VERSION" "$SIM/libLiteRTLMEngine.dylib"
create_xcframework "LiteRTLM" \
  -framework "$WORK/ios-arm64/CLiteRTLM.framework" \
  -framework "$WORK/ios-arm64-simulator/CLiteRTLM.framework"

create_plugin_slice \
  "ios-arm64" "ios" "$IOS_SDK_VERSION" \
  "GemmaModelConstraintProvider" "com.google.GemmaModelConstraintProvider" \
  "$DEVICE/libGemmaModelConstraintProvider.dylib" \
  "@rpath/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider"
create_plugin_slice \
  "ios-arm64-simulator" "iossimulator" "$SIM_SDK_VERSION" \
  "GemmaModelConstraintProvider" "com.google.GemmaModelConstraintProvider" \
  "$SIM/libGemmaModelConstraintProvider.dylib" \
  "@rpath/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider"
create_xcframework "GemmaModelConstraintProvider" \
  -framework "$WORK/ios-arm64/GemmaModelConstraintProvider.framework" \
  -framework "$WORK/ios-arm64-simulator/GemmaModelConstraintProvider.framework"

create_plugin_slice \
  "ios-arm64" "ios" "$IOS_SDK_VERSION" \
  "LiteRtMetalAccelerator" "com.google.LiteRtMetalAccelerator" \
  "$DEVICE/libLiteRtMetalAccelerator.dylib" \
  "@rpath/libLiteRtMetalAccelerator.dylib"
create_plugin_slice \
  "ios-arm64-simulator" "iossimulator" "$SIM_SDK_VERSION" \
  "LiteRtMetalAccelerator" "com.google.LiteRtMetalAccelerator" \
  "$SIM/libLiteRtMetalAccelerator.dylib" \
  "@rpath/libLiteRtMetalAccelerator.dylib"
create_xcframework "LiteRtMetalAccelerator" \
  -framework "$WORK/ios-arm64/LiteRtMetalAccelerator.framework" \
  -framework "$WORK/ios-arm64-simulator/LiteRtMetalAccelerator.framework"

create_plugin_slice \
  "ios-arm64" "ios" "$IOS_SDK_VERSION" \
  "LiteRtTopKMetalSampler" "com.google.LiteRtTopKMetalSampler" \
  "$DEVICE/libLiteRtTopKMetalSampler.dylib" \
  "@rpath/libLiteRtTopKMetalSampler.dylib"
create_xcframework "LiteRtTopKMetalSampler" \
  -framework "$WORK/ios-arm64/LiteRtTopKMetalSampler.framework"

echo
echo "=== Done. xcframeworks at: $OUT_DIR"
find "$OUT_DIR" -maxdepth 2 -name '*.framework' -print | sort
