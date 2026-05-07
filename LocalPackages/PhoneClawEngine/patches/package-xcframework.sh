#!/usr/bin/env bash
# Package a CLiteRTLM.xcframework from main HEAD engine + Google prebuilts.
# Replaces the in-tree xcframework at PhoneClaw/LocalPackages/.../LiteRTLM.xcframework.
set -euo pipefail

DEVICE=/tmp/v3-dylibs/device
SIM=/tmp/v3-dylibs/sim
HEADERS_SRC=/tmp/LiteRT-LM/c
WORK=/tmp/v3-dylibs/work
OUT=/Users/zxw/AITOOL/PhoneClaw/LocalPackages/PhoneClawEngine/Frameworks/LiteRTLM.xcframework

FRAMEWORK_NAME=CLiteRTLM
BUNDLE_ID=com.google.CLiteRTLM
MIN_IOS=13.0

rm -rf "$WORK"
mkdir -p "$WORK"

package_framework() {
  local arch="$1"     # e.g. "ios-arm64"
  local engine="$2"   # path to libLiteRTLMEngine.dylib
  shift 2
  local extras=("$@")
  local fw="$WORK/$arch/$FRAMEWORK_NAME.framework"
  mkdir -p "$fw/Headers" "$fw/Modules"

  # Main binary (renamed engine)
  cp "$engine" "$fw/$FRAMEWORK_NAME"
  install_name_tool -id "@rpath/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" "$fw/$FRAMEWORK_NAME"

  # Bundled dylibs (sampler + accelerator + constraint provider)
  for x in "${extras[@]}"; do
    [[ -n "$x" && -f "$x" ]] && cp "$x" "$fw/"
  done

  # Headers
  cp "$HEADERS_SRC/engine.h" "$fw/Headers/"

  # Module map: only export engine.h (litert_lm_logging.h moved to runtime/util in main HEAD)
  cat > "$fw/Modules/module.modulemap" <<MODULEMAP
framework module CLiteRTLM {
    header "engine.h"
    export *
}
MODULEMAP

  # Info.plist
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
PLIST

  # Codesign main binary + every bundled dylib
  codesign --force --sign - "$fw/$FRAMEWORK_NAME"
  for x in "${extras[@]}"; do
    [[ -n "$x" && -f "$fw/$(basename $x)" ]] && codesign --force --sign - "$fw/$(basename $x)"
  done

  echo "[OK] $arch framework: $fw"
}

# Device slice — engine + sampler + accelerator + constraint provider
package_framework "ios-arm64" "$DEVICE/libLiteRTLMEngine.dylib" \
  "$DEVICE/libGemmaModelConstraintProvider.dylib" \
  "$DEVICE/libLiteRtMetalAccelerator.dylib" \
  "$DEVICE/libLiteRtTopKMetalSampler.dylib"

# Sim slice — engine + accelerator + constraint provider (no sampler, sim can't run verifier)
package_framework "ios-arm64-simulator" "$SIM/libLiteRTLMEngine.dylib" \
  "$SIM/libGemmaModelConstraintProvider.dylib" \
  "$SIM/libLiteRtMetalAccelerator.dylib"

# Replace the in-tree xcframework
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -framework "$WORK/ios-arm64/$FRAMEWORK_NAME.framework" \
  -framework "$WORK/ios-arm64-simulator/$FRAMEWORK_NAME.framework" \
  -output "$OUT"

echo
echo "=== Done. xcframework at: $OUT"
ls -la "$OUT"/*/CLiteRTLM.framework/ 2>/dev/null
