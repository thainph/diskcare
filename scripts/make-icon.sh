#!/usr/bin/env bash
# Renders the app icon and builds Resources/AppIcon.icns (16–1024 px, @1x/@2x).
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/make-icon.swift Resources/AppIcon-1024.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
