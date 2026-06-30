# Whir — Privacy Policy

_Last updated: 2026-07-01_

Whir is a macOS menu-bar app that estimates the API-equivalent **usage value** of
your local AI coding activity (Claude Code and Codex). It is designed to be
private by construction.

## What Whir reads

Whir reads only the local log files those tools already write on your Mac:

- `~/.claude/projects/**` (Claude Code)
- `~/.codex/sessions/**` (Codex)

From those files it uses only **token counts, model names, timestamps, and
project folder names** to compute cost estimates. It does **not** read your
prompts, your code, tool output, conversation content, or any authentication
tokens (e.g. it never reads `~/.codex/auth.json`).

## What Whir does NOT do

- **No data collection.** Whir has no account, no server, and no analytics.
- **No network.** Whir makes no network connections. Nothing leaves your Mac.
- **No keychain / credential access.** Whir never reads the macOS keychain or any
  stored credentials.
- **No third parties.** No data is shared with anyone, because no data is
  collected or transmitted.

All processing happens entirely on your device. The numbers Whir shows are
computed locally and stored only in a local cache on your own Mac
(`~/Library/Application Support/Whir`).

## Data retention & deletion

Whir stores nothing off-device. To remove all of Whir's local data, delete the
app and its `~/Library/Application Support/Whir` folder.

## Contact

Questions about this policy: **yongjip@gmail.com**
