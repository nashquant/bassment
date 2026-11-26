#!/bin/bash
# Builds build/Bassment.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Bassment.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Bassment "$APP/Contents/MacOS/Bassment"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.bassment</string>
  <key>CFBundleName</key><string>Bassment</string>
  <key>CFBundleExecutable</key><string>Bassment</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSAudioCaptureUsageDescription</key><string>Bassment captures system audio to apply EQ and effects.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
