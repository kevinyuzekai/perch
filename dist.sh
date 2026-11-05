#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# 分发打包：优先 Developer ID（可公证），退而用 Apple Development（只能自己用），最后 ad-hoc。
# 公证需要先建凭据（只需一次）：
#   xcrun notarytool store-credentials perch --apple-id <你的AppleID> --team-id <TEAMID> --password <App专用密码>

APP_NAME="Perch"
BUNDLE_ID="com.perch.desktop"
APP="build/$APP_NAME.app"
DIST="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-perch}"

pick_identity() {
  local id
  id=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true
  if [ -n "${id:-}" ]; then echo "developer-id"
    return; fi
  id=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"') || true
  if [ -n "${id:-}" ]; then echo "$id"; return; fi
  echo ""
}

IDENTITY=$(pick_identity)
echo "==> 签名身份: ${IDENTITY:-<ad-hoc>}"

./dev.sh -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
cp .build/release/Perch "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名"
if [ "$IDENTITY" = "developer-id" ]; then
  REAL_ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
  codesign --force --options runtime --timestamp --sign "$REAL_ID" --identifier "$BUNDLE_ID" "$APP"
elif [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -2

echo "==> 打包 zip"
rm -f "$DIST/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"

if [ "$IDENTITY" = "developer-id" ]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> 公证 profile=${NOTARY_PROFILE}"
    xcrun notarytool submit "$DIST/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> 装订"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$DIST/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"
  else
    echo "!! 没有 notarytool 凭据 profile=${NOTARY_PROFILE} ，跳过公证"
    echo "   建一次即可： xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <AppleID> --team-id <TEAMID> --password <App专用密码>"
  fi
else
  echo "!! 当前不是 Developer ID 签名：可以自己本机用，别人下载会被 Gatekeeper 拦（需右键打开），也无法公证"
fi

echo "==> 打 dmg（失败就只留 zip）"
rm -f "$DIST/$APP_NAME.dmg"
rm -rf .cache/dmgroot && mkdir -p .cache/dmgroot && cp -R "$APP" .cache/dmgroot/
if hdiutil create -volname "$APP_NAME" -srcfolder .cache/dmgroot -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null 2>&1; then
  echo "   dmg ok"
else
  echo "   !! dmg 生成失败（受限环境会挡 hdiutil），zip 依然可用"
  rm -f "$DIST/$APP_NAME.dmg"
fi
rm -rf .cache/dmgroot

echo
echo "产物："
ls -lh "$DIST"
