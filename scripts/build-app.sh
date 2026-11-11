#!/bin/bash
# Builds Point Finder and packages it as PointFinder.app in the project folder.
#
# Usage: scripts/build-app.sh [--help]

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "Usage: scripts/build-app.sh"
    echo
    echo "Compiles the Swift package in release mode and assembles PointFinder.app"
    echo "next to Package.swift. Open it with: open PointFinder.app"
    exit 0
fi

cd "$(dirname "$0")/.."
swift build -c release --product PointFinder

APP="PointFinder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f ".build/release/PointFinder" "$APP/Contents/MacOS/PointFinder"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Point Finder</string>
    <key>CFBundleDisplayName</key><string>Point Finder</string>
    <key>CFBundleIdentifier</key><string>local.pointfinder</string>
    <key>CFBundleExecutable</key><string>PointFinder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.image</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "Note: ad-hoc signing failed; the app still runs locally."
echo "Built $(pwd)/$APP"
