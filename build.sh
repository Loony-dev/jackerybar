#!/bin/zsh
# Builds JackeryBar.app (universal: Apple Silicon + Intel).
#   ./build.sh            build into build/JackeryBar.app
#   ./build.sh --install  build and install into ~/Applications (restarts the app)
set -euo pipefail
cd "${0:A:h}"

APP=build/JackeryBar.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 \
    -o build/obj/JackeryBar-$arch Sources/Core/*.swift Sources/UI/*.swift
done
lipo -create build/obj/JackeryBar-arm64 build/obj/JackeryBar-x86_64 -output "$APP/Contents/MacOS/JackeryBar"
rm -rf build/obj

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.loony.jackerybar</string>
  <key>CFBundleName</key><string>JackeryBar</string>
  <key>CFBundleExecutable</key><string>JackeryBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>uk</string>
  <key>CFBundleLocalizations</key><array><string>uk</string><string>en</string></array>
  <key>NSLocalNetworkUsageDescription</key><string>JackeryBar connects to an MQTT broker on your local network to read your Jackery station.</string>
</dict></plist>
PLIST

cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Localized system strings (local-network permission prompt).
mkdir -p "$APP/Contents/Resources/uk.lproj" "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/uk.lproj/InfoPlist.strings" <<'STR'
"NSLocalNetworkUsageDescription" = "JackeryBar підключається до MQTT-брокера в локальній мережі, щоб отримувати дані станції Jackery.";
STR
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STR'
"NSLocalNetworkUsageDescription" = "JackeryBar connects to an MQTT broker on your local network to read your Jackery station.";
STR

codesign --force --sign - "$APP" >/dev/null
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x JackeryBar 2>/dev/null || true
  rm -rf ~/Applications/JackeryBar.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/JackeryBar.app"
else
  echo "Built $APP"
fi
