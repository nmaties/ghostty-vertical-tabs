#!/usr/bin/env bash
# Builds "Ghostty Vertical Tabs.app" into ./build (universal binary).
#
# Signing: a stable signature keeps the Accessibility and Automation permissions across
# rebuilds and reinstalls. The script picks a certificate from your Keychain on its own,
# preferring "Developer ID Application", then "Apple Development". Without either it signs
# ad hoc, and macOS asks for the permissions again after each rebuild.
# Set CODESIGN_IDENTITY to choose one yourself, or CODESIGN_IDENTITY=- to force ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="-"
    identities="$(security find-identity -p codesigning -v 2>/dev/null || true)"
    for kind in "Developer ID Application" "Apple Development"; do
        # Lines look like: 1) <SHA-1> "Developer ID Application: Name (TEAMID)"
        line="$(grep -m1 "\"$kind: " <<<"$identities" || true)"
        if [[ -n "$line" ]]; then
            CODESIGN_IDENTITY="$(awk '{print $2}' <<<"$line")"
            echo "Signing with: $(sed -E 's/.*"(.*)".*/\1/' <<<"$line")"
            break
        fi
    done
    if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
        echo "No signing certificate found; signing ad hoc. macOS will ask for permissions again after each rebuild."
    fi
fi

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/GhosttyVerticalTabs"

APP="build/Ghostty Vertical Tabs.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GhosttyVerticalTabs"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Resources/GhosttyVerticalTabs.entitlements --sign "$CODESIGN_IDENTITY" "$APP"

echo "Built $APP"
