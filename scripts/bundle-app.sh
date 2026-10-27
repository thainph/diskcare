#!/usr/bin/env bash
# Builds DiskCare.app (menu bar app with the `diskcare` CLI inside) for Apple silicon.
#
# Environment:
#   VERSION        marketing version (default: DiskCareVersion.current)
#   BUILD_NUMBER   CFBundleVersion (default: 1)
#   ARCH           arm64 (default) or x86_64
#   SIGN_IDENTITY  "Developer ID Application: …" to sign with hardened runtime; ad-hoc when unset
#   OUTPUT_DIR     where DiskCare.app is written (default: .build)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/DiskCareCore/Support/Version.swift)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH="${ARCH:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-.build}"

swift build -c release --arch "$ARCH" --product DiskCareApp
swift build -c release --arch "$ARCH" --product diskcare
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

APP="$OUTPUT_DIR/DiskCare.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiskCareApp" "$APP/Contents/MacOS/DiskCare"
cp "$BIN_DIR/diskcare" "$APP/Contents/Resources/diskcare"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.diskcare.app</string>
    <key>CFBundleName</key><string>DiskCare</string>
    <key>CFBundleDisplayName</key><string>DiskCare</string>
    <key>CFBundleExecutable</key><string>DiskCare</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>DiskCare ${VERSION}</string>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    # Hardened runtime + timestamp are required for notarization. Sign the nested CLI first.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/diskcare"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP" >/dev/null
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION build $BUILD_NUMBER, $ARCH)"
