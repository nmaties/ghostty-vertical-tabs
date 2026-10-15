#!/usr/bin/env bash
# Builds "Ghostty Vertical Tabs.app" into ./build (universal binary).
# Signs ad hoc by default. Set CODESIGN_IDENTITY to sign with your own certificate, which
# keeps the Accessibility and Automation permissions across rebuilds, e.g.:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/GhosttyVerticalTabs"

APP="build/Ghostty Vertical Tabs.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GhosttyVerticalTabs"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Resources/GhosttyVerticalTabs.entitlements --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
