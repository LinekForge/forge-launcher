#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MENU_APP="$SCRIPT_DIR/Forge Launcher.app"
ICON_ICNS="$SCRIPT_DIR/menubar/AppIcon.icns"

echo "=== 编译Forge Launcher ==="

# 退出旧的（未运行时跳过，避免 osascript 意外启动 app）
if pgrep -xq "ForgeLauncher"; then
    osascript -e 'tell application "Forge Launcher" to quit' 2>/dev/null || true
    sleep 1
fi

# 构建到临时目录（编译失败时保留旧版）
BUILD_TMP="$SCRIPT_DIR/.build-tmp"
rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP/Contents/MacOS" "$BUILD_TMP/Contents/Resources"
cp "$SCRIPT_DIR/menubar/Info.plist" "$BUILD_TMP/Contents/"
cp "$SCRIPT_DIR/menubar/icon.png" "$BUILD_TMP/Contents/Resources/"
cp "$SCRIPT_DIR/shared/scan-sessions.py" "$BUILD_TMP/Contents/Resources/"
[ -f "$ICON_ICNS" ] && cp "$ICON_ICNS" "$BUILD_TMP/Contents/Resources/"

swiftc \
    "$SCRIPT_DIR/menubar/Models.swift" \
    "$SCRIPT_DIR/menubar/Utilities.swift" \
    "$SCRIPT_DIR/menubar/AuthGuard.swift" \
    "$SCRIPT_DIR/menubar/TerminalAdapter.swift" \
    "$SCRIPT_DIR/menubar/SessionStore.swift" \
    "$SCRIPT_DIR/menubar/SessionDescriptionStore.swift" \
    "$SCRIPT_DIR/menubar/ConfigStore.swift" \
    "$SCRIPT_DIR/menubar/SessionScanner.swift" \
    "$SCRIPT_DIR/menubar/HubClient.swift" \
    "$SCRIPT_DIR/menubar/ChannelDialog.swift" \
    "$SCRIPT_DIR/menubar/HubExtension.swift" \
    "$SCRIPT_DIR/menubar/PopoverController.swift" \
    "$SCRIPT_DIR/menubar/AppDelegate.swift" \
    "$SCRIPT_DIR/menubar/main.swift" \
    -o "$BUILD_TMP/Contents/MacOS/ForgeLauncher" \
    -framework Cocoa \
    -target arm64-apple-macos13.0 \
    -suppress-warnings

# 编译成功——替换旧版并签名
rm -rf "$MENU_APP"
mv "$BUILD_TMP" "$MENU_APP"
xattr -cr "$MENU_APP" 2>/dev/null || true
codesign --force --sign - "$MENU_APP"

echo "  ✓ Forge Launcher.app"

# 部署共享脚本
mkdir -p "$HOME/.claude/自动化/scripts"
cp "$SCRIPT_DIR/shared/scan-sessions.py" "$HOME/.claude/自动化/scripts/scan-sessions.py"
echo "  ✓ scan-sessions.py → ~/.claude/自动化/scripts/"

echo ""
echo "=== 完成 ==="
echo "启动：open \"$MENU_APP\""
echo ""
if [ -d "/Applications/Ghostty.app" ]; then
    echo "💡 终端：检测到 Ghostty，启动后自动使用 Ghostty。"
else
    echo "💡 终端：使用 Terminal.app。推荐装 Ghostty (https://ghostty.org) 获得更好体验。"
    echo "   装了 Ghostty 后，退出菜单栏再重新打开即可自动切换。"
fi
