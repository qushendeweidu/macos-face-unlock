#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/FaceUnlock.app"
VERSION="${1:-v0.1.1}"
DMG="dist/FaceUnlock-${VERSION}.dmg"

if [ ! -d "$APP" ]; then
    echo "Missing $APP. Run ./scripts/build_app.sh first."
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if command -v SetFile >/dev/null 2>&1; then
    cp Resources/AppIcon.icns "$STAGING/.VolumeIcon.icns"
    SetFile -a C "$STAGING"
fi

hdiutil create \
    -volname "FaceUnlock" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo "Built: $DMG"
shasum -a 256 "$DMG"
