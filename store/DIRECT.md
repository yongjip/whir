# Direct distribution — notarized DMG + Homebrew

No sandbox, no folder-grant onboarding: the app reads `~/.claude` / `~/.codex`
directly. Needs an Apple **Developer ID** (part of the $99/yr program) for
signing + notarization so it passes Gatekeeper on other Macs.

## Files (in repo)
- `Resources/Info.plist` — bundle metadata (LSUIElement agent app).
- `scripts/package.sh` — build + assemble `dist/Whir.app` (swift build), sign.
- `scripts/notarize.sh` — build a drag-to-install DMG, notarize it, staple it.
- `Casks/whir.rb` — Homebrew cask (fill in the DMG sha256 per release).

## Prerequisites (need your Apple Developer account — one-time)

1. **Developer ID Application certificate** (distinct from the App Store certs).
   In Xcode → Settings → Accounts → your team → Manage Certificates → `+` →
   *Developer ID Application*. Confirm it's installed:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **Notary credentials** — an app-specific password from appleid.apple.com,
   stored once in the keychain (team `33S36XZ32U`):
   ```sh
   xcrun notarytool store-credentials whir-notary \
     --apple-id you@example.com --team-id 33S36XZ32U --password <app-specific-password>
   ```

## Release steps

1. **Produce a Developer-ID-signed `dist/Whir.app`.** Two options:
   - **Complete (recommended — the Shortcuts / App Intent works):** build via
     Xcode so the AppIntents metadata and the full Info.plist are included.
     Product → Archive → Distribute App → **Developer ID** → export, then copy
     the exported `Whir.app` to `dist/Whir.app`.
   - **Quick (no Shortcuts action):** `swift build` can't generate AppIntents
     metadata, so the Shortcuts action is absent, but the core app is fine:
     ```sh
     DEVELOPER_ID="Developer ID Application: Yongjip Kim (33S36XZ32U)" scripts/package.sh
     ```
2. **DMG + notarize + staple:**
   ```sh
   scripts/notarize.sh        # builds the DMG, notarizes it, prints the sha256
   ```
3. **Publish:** create a GitHub release `v0.1.0`, upload `dist/Whir.dmg`.
4. **Homebrew:** put `Casks/whir.rb` in a tap repo (`yongjip/homebrew-tap`) and
   set `version` + the `sha256` printed in step 2. Users then:
   ```sh
   brew install --cask yongjip/tap/whir
   ```

## Gatekeeper reality (macOS 15+ / 26)
Since Sequoia, users can **no longer Control-click to bypass** an un-notarized
app — they'd have to dig into System Settings → Privacy & Security. So for direct
distribution notarizing + stapling isn't optional; without it first-run is a hard
block for most users. A notarized + stapled DMG launches normally.

## Verified locally (without a Developer ID)
`scripts/package.sh` (ad-hoc) builds a launchable `dist/Whir.app`, and the DMG
layout in `notarize.sh` (app + `/Applications` alias) builds and mounts. The
Developer-ID signing + notarization steps require your Apple account.

## Still TODO (nice-to-have, not blocking)
- Auto-update via Sparkle (appcast + EdDSA key) for in-app updates.
- Desktop / Notification Centre widget (needs an App Group).
