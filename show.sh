#!/bin/bash
# 从命令行 / 脚本唤起便签面板
# 原理：向 Darwin 通知中心发信号，App 收到后弹出面板
set -euo pipefail

TARGET="${1:-show}"

if ! pgrep -x ContextNotes >/dev/null; then
  echo "ContextNotes 没有在运行，先从菜单栏图标启动它" >&2
  exit 1
fi

case "$TARGET" in
  show|panel) notifyutil -p com.aabananaaa.contextnotes.show ;;
  all|list)   notifyutil -p com.aabananaaa.contextnotes.all ;;
  *) echo "用法: $0 [show|all]" >&2; exit 2 ;;
esac
