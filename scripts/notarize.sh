#!/usr/bin/env bash
# Build a drag-to-install DMG from dist/Whir.app, notarize it, and staple it.
#
# Requires a Developer ID Application cert + notary credentials (both need your
# Apple Developer account — see store/DIRECT.md). One-time credential setup:
#   xcrun notarytool store-credentials whir-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Then, after producing a Developer-ID-signed dist/Whir.app (see store/DIRECT.md):
#   scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Whir.app"
DMG="dist/Whir.dmg"
STAGE="dist/dmg"
PROFILE="${NOTARY_PROFILE:-whir-notary}"
[ -d "$APP" ] || { echo "missing $APP — build it first (see store/DIRECT.md)"; exit 1; }

# Refuse to ship an unsigned/ad-hoc app — it can't be notarized.
if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "error: $APP is not signed with a Developer ID Application cert." >&2
    echo "       Notarization requires it — see store/DIRECT.md." >&2
    exit 1
fi

# Build a drag-to-install DMG: the app + an /Applications alias to drop it into.
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Whir" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# Notarize the DMG and staple the ticket so first launch works offline.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "$DMG  (sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1))"
echo "→ upload to a GitHub release v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"), then set version + sha256 in Casks/whir.rb"
