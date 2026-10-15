#!/usr/bin/env bash
# Builds a Developer ID signed, notarized and stapled "Ghostty Vertical Tabs.app" and zips it
# for a GitHub release, so people can install it without a signing certificate of their own.
#
# One-time setup:
#   xcrun notarytool store-credentials <profile-name> --apple-id <you@example.com> --team-id <TEAMID>
#   cp scripts/signing.env.example scripts/signing.env   # then fill it in
#
# Usage: ./scripts/release.sh            (writes build/GhosttyVerticalTabs-<version>.zip)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f scripts/signing.env ]] && source scripts/signing.env
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE in scripts/signing.env}"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then export CODESIGN_IDENTITY="$SIGN_IDENTITY"; fi

./scripts/build-app.sh

APP="build/Ghostty Vertical Tabs.app"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q "^Authority=Developer ID Application" <<<"$SIGNATURE"; then
    echo "The app isn't signed with a Developer ID Application certificate; notarization needs one." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/GhosttyVerticalTabs-$VERSION.zip"

# Notarize, staple the ticket to the app, then zip the stapled app for distribution.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl -a -vv "$APP"
echo "Ready: $ZIP"
