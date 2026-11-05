#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Perch.app"
BUNDLE_ID="com.perch.desktop"

./dev.sh -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Perch "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 本地没有可用证书时退回 ad-hoc 签名（能跑，但每次重建都会丢 TCC 授权）
LOCAL_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)

if [ -n "${LOCAL_IDENTITY:-}" ]; then
  codesign --force --options runtime --sign "$LOCAL_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign - "$APP"
  echo "!! 未找到签名证书，已用 ad-hoc 签名（权限每次重建都要重新授权）"
fi

echo "built: $(pwd)/$APP"
