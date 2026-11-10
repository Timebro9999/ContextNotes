#!/bin/bash
# 构建 ContextNotes.app（无需 Xcode，命令行工具即可）
set -euo pipefail
cd "$(dirname "$0")"

APP="ContextNotes.app"
BIN="$APP/Contents/MacOS/ContextNotes"
ARCH="$(uname -m)"

# 关键：必须显式指定部署目标。
# Swift 6.x 工具链默认会把最低系统版本编成比本机更高的版本（例如 28.0），
# 这样 LaunchServices 会判定该 app「无法在本机运行」，拒绝登记：
#   - open 报 -10825
#   - tccutil 报 -10814 找不到 bundle
#   - 系统设置里添加辅助功能时显示 🚫
DEPLOY_TARGET="13.0"

# 图标是生成产物，首次构建时自动生成
if [ ! -f Assets/AppIcon.icns ] || [ ! -f Assets/AppIconLight.png ]; then
  echo "==> 生成图标"
  mkdir -p Assets design tools
  swift tools/make-appicon.swift >/dev/null 2>&1 || true
  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns 2>/dev/null || true
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> 拷贝图标"
if [ -f Assets/AppIcon.icns ]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    ⚠️  缺少 Assets/AppIcon.icns，运行 swift tools/make-appicon.swift 生成"
fi
# 运行时按明暗切换用
for f in AppIconLight.png AppIconDark.png AppIconClearLight.png AppIconClearDark.png; do
  [ -f "Assets/$f" ] && cp "Assets/$f" "$APP/Contents/Resources/$f"
done

echo "==> 编译（target ${ARCH}-apple-macos${DEPLOY_TARGET}）"
swiftc \
  -O \
  -swift-version 5 \
  -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  Sources/*.swift \
  -o "$BIN"

echo "==> 签名"
# 优先用自签名证书：DR 基于证书根而不是 cdhash，
# 所以重新编译后辅助功能授权不会失效。
SIGN_ID="ContextNotes Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1
  echo "    已用「${SIGN_ID}」签名（稳定身份）"
else
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
  echo "    ⚠️  未找到「${SIGN_ID}」，退回 ad-hoc 签名（重编译会掉权限）"
  echo "    运行 ./make-signing-identity.sh 可一次性创建"
fi

echo "==> 重新登记到 LaunchServices"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$(pwd)/$APP" >/dev/null 2>&1 || true

echo "==> 校验最低系统版本"
MINOS=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
echo "    Mach-O minos = ${MINOS:-未知}"

echo "==> 完成：$(pwd)/$APP"
echo "    启动：open $APP"
