#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 用 App Store Connect API Key 自动申请并安装 Developer ID Application 证书。
# 用法: ./tools/create_devid_cert.sh <KEY_ID> <ISSUER_ID> <AuthKey_XXX.p8>
KEY_ID="${1:?需要 KEY_ID}"
ISSUER="${2:?需要 ISSUER_ID}"
P8="${3:?需要 .p8 路径}"

WORK=".cache/cert"; rm -rf "$WORK"; mkdir -p "$WORK"

echo "==> 生成本地私钥与 CSR"
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$WORK/devid.key" -out "$WORK/devid.csr" \
  -subj "/CN=Perch Developer ID" 2>/dev/null
CSR=$(python3 -c "import json,sys;print(json.dumps(open('$WORK/devid.csr').read()))")
echo "   CSR 已生成"

echo "==> 申请 Developer ID Application 证书"
TOKEN=$(python3 tools/asc_jwt.py "$KEY_ID" "$ISSUER" "$P8")
BODY=$(cat <<JSON
{"data":{"type":"certificates","attributes":{"certificateType":"DEVELOPER_ID_APPLICATION","csrContent":$CSR}}}
JSON
)
RESP=$(curl -sS -X POST "https://api.appstoreconnect.apple.com/v1/certificates" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "$BODY")
echo "$RESP" > "$WORK/resp.json"

if echo "$RESP" | grep -q '"errors"'; then
  echo "!! 申请失败："
  python3 -c "import json;d=json.load(open('$WORK/resp.json'));[print('   ',e.get('code'),e.get('title'),'-',e.get('detail')) for e in d['errors']]"
  echo "   （常见原因：Key 权限不足需要 Admin/App Manager；或该类型证书数量已达上限）"
  exit 1
fi

echo "==> 保存证书并导入钥匙串"
python3 - "$WORK" <<'PY'
import base64, json, subprocess, sys
work = sys.argv[1]
d = json.load(open(f"{work}/resp.json"))
content = d["data"]["attributes"]["certificateContent"]
der = base64.b64decode(content)
open(f"{work}/devid.cer", "wb").write(der)
print("   证书:", d["data"]["attributes"].get("name", "?"), d["data"]["attributes"].get("certificateType", "?"))
PY

security import "$WORK/devid.cer" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import "$WORK/devid.key" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -T /usr/bin/security

echo "==> 验证身份"
security find-identity -v -p codesigning | sed "s/[A-F0-9]\{40\}/<HASH>/" | grep -i "Developer ID" || {
  echo "!! 没找到 Developer ID 身份，证书与私钥可能未配对"; exit 1; }

echo
echo "完成。接着跑 ./dist.sh 就会用 Developer ID 签名；公证凭据："
echo "  xcrun notarytool store-credentials perch --key '$P8' --key-id '$KEY_ID' --issuer '$ISSUER'"
