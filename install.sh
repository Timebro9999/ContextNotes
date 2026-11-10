#!/bin/bash
# 构建并安装到 /Applications，然后重挂登录自启
set -euo pipefail
cd "$(dirname "$0")"

DEST="/Applications/ContextNotes.app"
PLIST="$HOME/Library/LaunchAgents/com.aabananaaa.contextnotes.plist"
UID_NUM=$(id -u)

./build.sh

echo "==> 停止正在运行的实例"
pkill -x ContextNotes 2>/dev/null || true
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
sleep 1

echo "==> 安装到 $DEST"
rm -rf "$DEST"
cp -R ContextNotes.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# 删掉构建目录里的副本，避免同一个 bundle id 出现两份、LaunchServices 认错
rm -rf ContextNotes.app

echo "==> 重新登记"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST" >/dev/null 2>&1 || true

echo "==> 重挂登录自启"
./install-login-item.sh >/dev/null

echo "==> 启动（LaunchAgent 已被 bootstrap，会自动拉起；不再重复 open）"
sleep 2
echo "✅ 已安装：$DEST"
echo "   运行状态：$(pgrep -x ContextNotes >/dev/null && echo "运行中 PID $(pgrep -x ContextNotes)" || echo 未运行)"
