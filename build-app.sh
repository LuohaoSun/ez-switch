#!/bin/bash
# 构建 EZSwitch.app 并（可选）安装到 /Applications。
#
#   ./build-app.sh            只构建，产物在 dist/EZSwitch.app
#   ./build-app.sh --install  构建后安装到 /Applications 并重启、验证服务
#
# 两个关键点：
#  1. Package.swift 显式把链接 SDK 标为 27.0，同时保持 macOS 13 最低版本；否则
#     SwiftPM 会写入 sdk 13.0，系统按老 SDK 应用渲染，新窗口外观不会生效。
#  2. ad-hoc 签名必须重新做（改过二进制的 bundle 签名会失效，系统会拒绝启动）。
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME=EZSwitch
OLD_APP_NAME=ModelRouter
BUNDLE_ID=local.sunluohao.ezswitch
INSTALL_DIR=/Applications
DIST=dist/$APP_NAME.app

echo "==> swift build -c release"
swift build -c release

echo "==> 组装 $DIST"
rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"
cp .build/release/$APP_NAME "$DIST/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$DIST/Contents/Info.plist"
cp Resources/AppIcon.icns "$DIST/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc 签名"
codesign --force -s - "$DIST" 2>&1 | tail -1

echo "==> 构建信息"
vtool -show-build "$DIST/Contents/MacOS/$APP_NAME" | grep -E "minos|sdk"

if [[ "${1:-}" != "--install" ]]; then
    echo "完成：$PWD/$DIST"
    exit 0
fi

echo "==> 安装到 $INSTALL_DIR/$APP_NAME.app"
pkill -f "$APP_NAME.app" || true
pkill -f "$OLD_APP_NAME.app" || true
sleep 1
rm -rf "$INSTALL_DIR/$APP_NAME.app" "$INSTALL_DIR/$OLD_APP_NAME.app"
cp -R "$DIST" "$INSTALL_DIR/$APP_NAME.app"
codesign --force -s - "$INSTALL_DIR/$APP_NAME.app" 2>&1 | tail -1

echo "==> 启动并验证"
open "$INSTALL_DIR/$APP_NAME.app"
CONFIG_PATH="$HOME/Library/Application Support/EZSwitch/config.json"
if [[ ! -f "$CONFIG_PATH" ]]; then
  CONFIG_PATH="$HOME/Library/Application Support/ModelRouter/config.json"
fi
PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["port"])' "$CONFIG_PATH" 2>/dev/null || echo 8788)
echo -n "GET 127.0.0.1:$PORT/v1/models → "
for _ in {1..20}; do
  if RESPONSE=$(curl -sS --max-time 1 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null); then
    printf '%s' "$RESPONSE" | head -c 200
    break
  fi
  sleep 0.25
done
echo
echo "完成：已安装 $INSTALL_DIR/$APP_NAME.app (bundle id: ${BUNDLE_ID})"
