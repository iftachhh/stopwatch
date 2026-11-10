#!/bin/bash
# Builds a universal (Apple silicon + Intel) Stopwatch.app and packages it as a drag-to-Applications disk image
# in build/Stopwatch-<version>.dmg. The version comes from CFBundleShortVersionString in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Stopwatch.app"
BIN="StopwatchMenuBar"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Stopwatch-$VERSION.dmg"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$BIN" "$APP/Contents/MacOS/$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Liquid Glass icon (Assets.car) on macOS 26+, plus an .icns fallback for older systems
xcrun actool icon/HourglassGlass.icon --compile "$APP/Contents/Resources" --app-icon HourglassGlass \
    --platform macosx --minimum-deployment-target 12.0 --output-partial-info-plist /dev/null >/dev/null
# ponytail: ad-hoc signature only; a Developer ID signature + notarization removes the first-launch warning
codesign --force --sign - "$APP"

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Stopwatch" -srcfolder "$STAGING" -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

echo "Built $DMG"
