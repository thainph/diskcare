#!/usr/bin/env bash
# Builds DiskCare.app (menu bar app) into .build/DiskCare.app, ad-hoc signed for local use.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product DiskCareApp
swift build -c release --product diskcare

APP=.build/DiskCare.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskCareApp "$APP/Contents/MacOS/DiskCare"
cp .build/release/diskcare "$APP/Contents/Resources/diskcare"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.diskcare.app</string>
    <key>CFBundleName</key><string>DiskCare</string>
    <key>CFBundleDisplayName</key><string>DiskCare</string>
    <key>CFBundleExecutable</key><string>DiskCare</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
