# Direct distribution — notarized DMG + Homebrew (recommended primary channel)

No sandbox, no folder-grant onboarding: the app reads `~/.claude` / `~/.codex`
directly. This is what comparable tools ship. Needs an Apple Developer ID
(part of the $99/yr program) for signing + notarization so it passes Gatekeeper.

## Files (in repo)
- `Resources/Info.plist` — bundle metadata (LSUIElement agent app).
- `scripts/package.sh` — build + assemble `dist/Whir.app`, sign.
- `scripts/notarize.sh` — notarize, staple, build `dist/Whir.dmg`.
- `Casks/whir.rb` — Homebrew cask (fill in yongjip + DMG sha256).

## Release steps
1. **One-time**: store notary credentials (app-specific password from appleid.apple.com):
   ```sh
   xcrun notarytool store-credentials whir-notary \
     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
   ```
2. **Build + sign** with your Developer ID Application cert:
   ```sh
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/package.sh
   ```
3. **Notarize + DMG**:
   ```sh
   scripts/notarize.sh        # prints the DMG sha256
   ```
4. **Publish**: create a GitHub release `v0.1.0`, upload `dist/Whir.dmg`.
5. **Homebrew**: put `Casks/whir.rb` in a tap repo
   (`yongjip/homebrew-tap`), set yongjip + the sha256 from step 3. Users then:
   ```sh
   brew install --cask yongjip/tap/whir
   ```

## Still TODO (nice-to-have, not blocking)
- App icon (`Resources/AppIcon.icns`) — `package.sh` picks it up if present.
- Auto-update via Sparkle (appcast + EdDSA key) for in-app updates.
- Launch-at-login toggle via `SMAppService`.

## Verified locally (without a Developer ID)
`scripts/package.sh` (ad-hoc) builds a launchable `dist/Whir.app`. The
Developer-ID signing + notarization steps require your Apple account.
