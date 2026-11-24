#!/bin/zsh
# Builds JackeryBar.app and packs it into build/JackeryBar-<version>.dmg
# (drag-to-Applications window). Ad-hoc signed: no Apple Developer account needed.
set -euo pipefail
cd "${0:A:h}/.."
./build.sh
APP=build/JackeryBar.app
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=build/JackeryBar-$VER.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/JackeryBar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "JackeryBar $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
