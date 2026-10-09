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
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

echo "Built $APP"
