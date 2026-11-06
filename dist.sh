#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# 分发打包：Developer ID 优先（可公证），退而用 Apple Development（只能自己用），最后 ad-hoc。
# 公证需要先建凭据（只需一次）：
#   xcrun notarytool store-credentials perch --apple-id <AppleID> --team-id <TEAMID> --password <App专用密码>

APP_NAME="Perch"
BUNDLE_ID="com.perch.desktop"
APP="build/$APP_NAME.app"
DIST="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-perch}"

DEVID_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
SIGN_ID="${DEVID_ID:-${DEV_ID:-}}"

if [ -n "$DEVID_ID" ]; then
  echo "==> 签名身份: Developer ID"
elif [ -n "$DEV_ID" ]; then
  echo "==> 签名身份: $DEV_ID"
else
  echo "==> 签名身份: ad-hoc"
fi

./dev.sh -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
cp .build/release/Perch "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名 app"
if [ -n "$DEVID_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVID_ID" --identifier "$BUNDLE_ID" "$APP"
elif [ -n "$DEV_ID" ]; then
  codesign --force --options runtime --sign "$DEV_ID" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP" 2>&1 | tail -1

echo "==> 打包 zip"
rm -f "$DIST/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"

HAS_NOTARY=no
if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  HAS_NOTARY=yes
fi

if [ -n "$DEVID_ID" ] && [ "$HAS_NOTARY" = "yes" ]; then
  echo "==> 公证 app profile=${NOTARY_PROFILE}"
  xcrun notarytool submit "$DIST/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> 装订"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$DIST/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"
elif [ -n "$DEVID_ID" ]; then
  echo "!! 没有 notarytool 凭据 profile=${NOTARY_PROFILE} ，跳过公证"
  echo "   建一次即可： xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <AppleID> --team-id <TEAMID> --password <App专用密码>"
else
  echo "!! 当前不是 Developer ID 签名：可以自己本机用，别人下载会被 Gatekeeper 拦（需右键打开），也无法公证"
fi

echo "==> 打 dmg"
rm -f "$DIST/$APP_NAME.dmg"
STAGE=".cache/dmgstage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null 2>&1; then
  echo "   dmg ok (hdiutil)"
else
  # 受限环境里 hdiutil create 需要 raw device 权限，改用 makehybrid + convert
  rm -f .cache/$APP_NAME.iso
  if hdiutil makehybrid -o .cache/$APP_NAME.iso -hfs -udf -default-volume-name "$APP_NAME" "$STAGE" >/dev/null 2>&1 \
     && hdiutil convert .cache/$APP_NAME.iso -format UDZO -o "$DIST/$APP_NAME.dmg" >/dev/null 2>&1; then
    echo "   dmg ok (makehybrid)"
  else
    echo "   !! dmg 生成失败，zip 依然可用"
    rm -f "$DIST/$APP_NAME.dmg"
  fi
  rm -f .cache/$APP_NAME.iso
fi
rm -rf "$STAGE"

if [ -f "$DIST/$APP_NAME.dmg" ] && [ -n "$DEVID_ID" ]; then
  echo "==> 签名 dmg"
  codesign --force --sign "$DEVID_ID" --timestamp "$DIST/$APP_NAME.dmg"
  if [ "$HAS_NOTARY" = "yes" ]; then
    echo "==> 公证 dmg"
    xcrun notarytool submit "$DIST/$APP_NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/$APP_NAME.dmg"
  fi
fi

echo
echo "产物："
ls -lh "$DIST"
