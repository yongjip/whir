#!/usr/bin/env bash
# Build + assemble the .app bundle for direct distribution.
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/package.sh
# Without DEVELOPER_ID it ad-hoc signs (runs locally, but won't pass Gatekeeper
# on other Macs — that needs a Developer ID + notarization; see scripts/notarize.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Whir.app"
swift build -c release --product WhirApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WhirApp "$APP/Contents/MacOS/Whir"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true

if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements Whir.entitlements --sign "$DEVELOPER_ID" "$APP"
    echo "signed with Developer ID: $DEVELOPER_ID (hardened runtime)"
else
    codesign --force --sign - "$APP"
    echo "ad-hoc signed (local only). Set DEVELOPER_ID for distribution."
fi

codesign --verify --deep --strict "$APP" && echo "built $APP"
