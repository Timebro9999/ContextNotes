#!/bin/bash
# 创建自签名代码签名身份，让辅助功能授权能跨重新编译保留。
#
# 为什么需要：ad-hoc 签名的"指定要求"(DR) 是 cdhash，每次编译都变，
# macOS 因此认为每次构建都是新程序，辅助功能授权随之失效。
# 换成证书签名后 DR 变成 certificate root = H"..."，恒定不变。
#
# 幂等：已存在同名身份时不会重复创建。
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="ContextNotes Local Signing"
SIGN_DIR="signing"
KC="$HOME/Library/Keychains/login.keychain-db"
P12PASS="cnlocal-temp"

mkdir -p "$SIGN_DIR"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "✅ 身份「${IDENTITY}」已存在，跳过创建"
else
  echo "==> 生成自签名证书"

  cat > "$SIGN_DIR/codesign.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = ContextNotes Local Signing
O  = Local Development

[v3]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
CNF

  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$SIGN_DIR/contextnotes.key" \
    -out    "$SIGN_DIR/contextnotes.crt" \
    -config "$SIGN_DIR/codesign.cnf" 2>/dev/null

  echo "==> 打包 PKCS#12（必须指定旧版算法，macOS security 不认 OpenSSL 3 的默认值）"
  openssl pkcs12 -export \
    -inkey "$SIGN_DIR/contextnotes.key" \
    -in    "$SIGN_DIR/contextnotes.crt" \
    -out   "$SIGN_DIR/contextnotes.p12" \
    -passout "pass:$P12PASS" \
    -name "$IDENTITY" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES

  echo "==> 导入登录钥匙串"
  security import "$SIGN_DIR/contextnotes.p12" -k "$KC" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

  echo "==> 设为信任（codeSign 策略，用户域）"
  # 注意 -p 的值必须写成 codeSign（大小写敏感）
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$SIGN_DIR/contextnotes.crt"

  rm -f "$SIGN_DIR/contextnotes.p12"
  chmod 600 "$SIGN_DIR/contextnotes.key"
fi

echo
echo "==> 当前可用签名身份"
security find-identity -v -p codesigning | grep -F "$IDENTITY" || {
  echo "❌ 身份仍然不可见，检查钥匙串信任设置"; exit 1;
}

echo
echo "✅ 完成。之后 ./build.sh 会自动使用该身份签名。"
echo "   重新授权一次辅助功能后，以后再编译都不会掉权限。"
