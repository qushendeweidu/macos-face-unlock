#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/FaceUnlock.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FaceUnlock "$APP/Contents/MacOS/FaceUnlock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null

rm -rf dist/FaceUnlock

echo "Built: $APP"
echo "Install: /Applications/FaceUnlock.app"
echo "Data:  ~/Library/Application Support/FaceUnlock"
echo "Logs:  ~/Library/Logs/FaceUnlock"
