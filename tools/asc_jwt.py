#!/usr/bin/env python3
"""用 App Store Connect API Key(.p8) 生成 ES256 JWT。用法:
   asc_jwt.py <key_id> <issuer_id> <p8_path>
输出: JWT 字符串
"""
import base64
import subprocess
import sys
import time


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    if der[0] != 0x30:
        raise ValueError("不是 DER SEQUENCE")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)

    def read_int(buf, pos):
        if buf[pos] != 0x02:
            raise ValueError("不是 DER INTEGER")
        length = buf[pos + 1]
        start = pos + 2
        return int.from_bytes(buf[start:start + length], "big"), start + length

    r, i = read_int(der, i)
    s, i = read_int(der, i)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def main() -> None:
    key_id, issuer, p8 = sys.argv[1], sys.argv[2], sys.argv[3]
    now = int(time.time())
    header = '{"alg":"ES256","kid":"%s","typ":"JWT"}' % key_id
    payload = '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' % (issuer, now, now + 900)
    signing_input = b64u(header.encode()) + "." + b64u(payload.encode())
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", p8],
        input=signing_input.encode(), capture_output=True, check=True).stdout
    print(signing_input + "." + b64u(der_to_raw(der)))


if __name__ == "__main__":
    main()
