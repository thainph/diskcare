#!/usr/bin/env bash
# Packages an already built DiskCare.app into release artifacts under dist/:
#   DiskCare-<version>-<arch>.dmg, DiskCare-<version>-<arch>.zip,
#   diskcare-cli-<version>-<arch>.tar.gz and SHA256SUMS.txt
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/DiskCareCore/Support/Version.swift)}"
ARCH="${ARCH:-arm64}"
APP="${APP:-.build/DiskCare.app}"
DIST="${DIST:-dist}"
NAME="DiskCare-${VERSION}-${ARCH}"

[[ -d "$APP" ]] || { echo "missing $APP, run scripts/bundle-app.sh first" >&2; exit 1; }
rm -rf "$DIST"
mkdir -p "$DIST"

# zip that preserves the bundle structure and signatures
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

# drag-to-Applications disk image
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "DiskCare" -srcfolder "$STAGING" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
rm -rf "$STAGING"

# standalone CLI
CLI_STAGING="$(mktemp -d)"
cp "$APP/Contents/Resources/diskcare" "$CLI_STAGING/diskcare"
tar -C "$CLI_STAGING" -czf "$DIST/diskcare-cli-${VERSION}-${ARCH}.tar.gz" diskcare
rm -rf "$CLI_STAGING"

(cd "$DIST" && shasum -a 256 ./* > SHA256SUMS.txt)
ls -lh "$DIST"
