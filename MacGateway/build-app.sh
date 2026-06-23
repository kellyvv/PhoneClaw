#!/bin/bash
# 把 SwiftPM 可执行打成 PhoneClawGateway.app —— 带 Info.plist (Local Network/Bonjour 权限 + 主窗口 + 菜单栏)。
# 用法: bash build-app.sh   然后 open PhoneClawGateway.app
set -e
cd "$(dirname "$0")"

echo "[1/4] swift build -c release …"
swift build -c release

if [ ! -f "Assets/AppIcon.icns" ] || [ "Assets/MacAppIcon-1024.png" -nt "Assets/AppIcon.icns" ]; then
  echo "[icon] 生成 Mac AppIcon.icns …"
  python3 "Assets/generate_mac_icon.py"
fi

APP="PhoneClawGateway.app"
echo "[2/4] 组装 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp ".build/release/PhoneClawGateway" "$APP/Contents/MacOS/PhoneClawGateway"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
copied_resource_bundle=0
for bundle in ".build/release/"*.bundle ".build/"*/release/*.bundle; do
  if [ -d "$bundle" ]; then
    bundle_name="$(basename "$bundle")"
    if [ ! -d "$APP/Contents/Resources/$bundle_name" ]; then
      cp -R "$bundle" "$APP/Contents/Resources/"
      copied_resource_bundle=1
    fi
  fi
done
if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  echo "error: missing $APP/Contents/Resources/AppIcon.icns" >&2
  exit 1
fi
if [ "$copied_resource_bundle" -eq 0 ]; then
  echo "[warn] 未找到 SwiftPM 资源 bundle; App 将使用主 bundle 内的 AppIcon.icns"
fi
touch "$APP"

echo "[3/4] ad-hoc 签名 (给 TCC/Local Network 一个身份) …"
codesign --force --sign - "$APP"

echo "[4/4] done → $(pwd)/$APP"
echo "运行: open $APP   (首次会弹「本地网络」权限, 点允许)"
