#!/bin/bash
# Builds SmartTube.app (universal: Apple Silicon + Intel) and SmartTube.dmg into ./dist
# Usage: Packaging/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
BUILD="$(date +%Y%m%d%H%M)"
DIST=dist
APP="$DIST/SmartTube.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$DIST"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SmartTube" "$APP/Contents/MacOS/SmartTube"
cp -R Sources/SmartTube/Resources/nsigsolver "$APP/Contents/Resources/nsigsolver"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"

# Icon
ICONSET="$DIST/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z $s $s Packaging/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d Packaging/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature (no Apple developer account needed)
codesign --force --deep --sign - "$APP"

# DMG with Applications shortcut
STAGE="$DIST/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname SmartTube -srcfolder "$STAGE" -ov -format UDZO "$DIST/SmartTube.dmg" >/dev/null
rm -rf "$STAGE"
echo "Built $APP and $DIST/SmartTube.dmg"
