#!/bin/bash
# Builds build/Stopwatch.app for this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Stopwatch.app"
BIN="StopwatchMenuBar"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Liquid Glass icon (Assets.car) on macOS 26+, plus an .icns fallback for older systems
xcrun actool icon/HourglassGlass.icon --compile "$APP/Contents/Resources" --app-icon HourglassGlass \
    --platform macosx --minimum-deployment-target 12.0 --output-partial-info-plist /dev/null >/dev/null

echo "Built $APP"
