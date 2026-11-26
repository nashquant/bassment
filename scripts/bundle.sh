#!/bin/bash
# Builds build/Timbre.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Timbre.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Timbre "$APP/Contents/MacOS/Timbre"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.timbre</string>
  <key>CFBundleName</key><string>Timbre</string>
  <key>CFBundleExecutable</key><string>Timbre</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSAudioCaptureUsageDescription</key><string>O Timbre captura o áudio do sistema para aplicar EQ e efeitos.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
