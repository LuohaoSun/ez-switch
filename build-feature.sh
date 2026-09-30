#!/bin/bash
# Build a separate app bundle for the Responses→Chat experiment. Does not install.
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh
PREVIEW=dist/EZSwitch-ChatPreview.app
if [[ -d "$PREVIEW" ]]; then
    mv "$PREVIEW" "dist/EZSwitch-ChatPreview-previous-$(date +%Y%m%d%H%M%S).app"
fi
ditto dist/EZSwitch.app "$PREVIEW"
PLIST="$PREVIEW/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.sunluohao.ezswitch.chat-preview "$PLIST"
plutil -replace CFBundleName -string 'EZ Switch Preview' "$PLIST"
plutil -replace CFBundleDisplayName -string 'EZ Switch Preview' "$PLIST"
plutil -replace CFBundleShortVersionString -string 0.1.7 "$PLIST"
plutil -replace CFBundleVersion -string 8 "$PLIST"
codesign --force -s - "$PREVIEW"
codesign --verify --deep "$PREVIEW"
echo "Feature build: $PWD/$PREVIEW"
