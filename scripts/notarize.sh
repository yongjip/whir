#!/usr/bin/env bash
# Notarize + staple the packaged .app, then build a DMG.
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials whir-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
# Then: scripts/package.sh && scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Whir.app"
PROFILE="${NOTARY_PROFILE:-whir-notary}"
[ -d "$APP" ] || { echo "missing $APP — run scripts/package.sh first"; exit 1; }

ditto -c -k --keepParent "$APP" dist/Whir.zip
xcrun notarytool submit dist/Whir.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

hdiutil create -volname "Whir" -srcfolder "$APP" -ov -format UDZO dist/Whir.dmg
echo "dist/Whir.dmg  (sha256: $(shasum -a 256 dist/Whir.dmg | cut -d' ' -f1))"
