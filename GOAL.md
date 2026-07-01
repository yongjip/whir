# Goal

**Show me, at a glance, what my AI coding habit actually costs — in one clean number, computed entirely on my machine, without touching a single credential.**

## What we're building

A macOS menu-bar app that aggregates **estimated usage value** (tokens × API price) across local AI coding agents — Claude Code and Codex first — into one minimal view. The hero number answers a question no one else answers cleanly: *"I'm on flat subscriptions; how much would this have cost on the API?"*

Name: **Whir** (verified clear of macOS/dev-tool/trademark collisions; bundle id `com.whir.Whir`).

## Why it's different

Whir doesn't compete on feature count or number of providers — the raw data is already on disk and other tools cover breadth. Its focus is three things, defensible by *posture*, not by feature list:

1. **Restraint.** One number, a few rows, nothing else — minimalism as the product, not a settings screen.
2. **Credential-free trust.** Read-only local logs only — never the keychain, never OAuth tokens, no network call for the core. A privacy claim a skeptic can verify by inspection.
3. **The ROI reframe.** Usage value vs. flat subscription cost: *"you pay $X/mo → you used $Y of value."* Turns cost-anxiety into "am I getting my money's worth."

## Scope

**Now:** coding agents with local logs — Claude Code (`~/.claude/projects`) + Codex (`~/.codex/sessions`). Estimated usage value as the headline metric.

**Later:** Cursor / Gemini CLI / Copilot adapters · live CPU-driven menu-bar indicator · desktop widget.

## Non-goals

- Competing on provider count.
- Reading credentials, prompts, code, or transcripts — ever.
- A cloud account, sync, or server for the core.
- Pretending estimates are bills. Usage value ≠ what you actually pay; label it honestly.

## How we'll know it's working

- A heavy Claude/Codex user installs it and immediately sees a number that feels *right* and *surprising* (the ROI reveal).
- The privacy claim is provable, not asserted — the app reads only metadata, and a skeptic can verify it.
- It's the menu-bar item people keep, not the novelty they disable.

## Status

- ✅ Parser core (`WhirCore`) — Claude + Codex adapters, incremental cache, cost model, verified against a ccusage-style oracle to the cent.
- ✅ SwiftUI `MenuBarExtra` app — today's number, history + drilldown, ROI, system monitor, launch-at-login, Shortcuts (App Intent).
- ✅ Packaged for the Mac App Store (in review) and direct distribution.
- ⬜ Next: more agent adapters (Cursor / Gemini CLI / Copilot); optional desktop widget.
