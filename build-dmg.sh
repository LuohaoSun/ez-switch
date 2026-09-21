#!/bin/bash
# 构建可直接发布的 DMG。磁盘映像内包含 EZSwitch.app 和 /Applications 快捷方式，
# 用户打开后可以把应用拖入 Applications。
#
#   ./build-dmg.sh             重新构建应用并生成 DMG
#   ./build-dmg.sh --skip-build 复用 dist/EZSwitch.app 生成 DMG
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME=EZSwitch
DISPLAY_NAME="EZ Switch"
PLIST=Resources/Info.plist
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")
DIST_DIR=dist
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGING_DIR="$DIST_DIR/dmg-staging"

if [[ "${1:-}" != "--skip-build" ]]; then
    ./build-app.sh
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "缺少应用包：$APP_BUNDLE" >&2
    echo "请先运行 ./build-app.sh，或不要使用 --skip-build。" >&2
    exit 1
fi

echo "==> 准备 DMG 内容"
rm -rf "$STAGING_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$STAGING_DIR"
ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> 生成 $DMG_NAME"
hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "==> 校验磁盘映像"
hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

echo "完成：$PWD/$DMG_PATH"
echo "校验：$PWD/$DMG_PATH.sha256"
