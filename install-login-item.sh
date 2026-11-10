#!/bin/bash
# 把 ContextNotes 注册为登录自启项（LaunchAgent）
set -euo pipefail
cd "$(dirname "$0")"
if [ -d "/Applications/ContextNotes.app" ]; then
  APP_PATH="/Applications/ContextNotes.app"
else
  APP_PATH="$(pwd)/ContextNotes.app"
fi
PLIST="$HOME/Library/LaunchAgents/com.aabananaaa.contextnotes.plist"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.aabananaaa.contextnotes</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP_PATH/Contents/MacOS/ContextNotes</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/contextnotes.err.log</string>
	<key>StandardOutPath</key>
	<string>/tmp/contextnotes.out.log</string>
</dict>
</plist>
EOF

UID_NUM=$(id -u)

# 先卸掉旧的
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/com.aabananaaa.contextnotes"

echo "✅ 已注册：$PLIST"
echo "   应用路径：$APP_PATH"
echo "   查看状态：launchctl print gui/$UID_NUM/com.aabananaaa.contextnotes | head -20"
echo "   停止运行：launchctl bootout gui/$UID_NUM $PLIST"
