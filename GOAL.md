# Goal

**Show me, at a glance, what my AI coding habit actually costs — in one clean number, computed entirely on my machine, without touching a single credential.**

## What we're building

A macOS menu-bar app that aggregates **estimated usage value** (tokens × API price) across local AI coding agents — Claude Code and Codex first — into one minimal view. The hero number answers a question no one else answers cleanly: *"I'm on flat subscriptions; how much would this have cost on the API?"*

Name: **Whir** (verified clear of macOS/dev-tool/trademark collisions; bundle id `com.whir.Whir`).

## Why it's different

We don't win on features or provider count — that race is lost to free OSS (CodexBar, 53 providers) and the data is free on disk. We win on three things, all defensible by *posture*, not feature:

1. **Restraint.** One number, a few rows, nothing else. The anti-CodexBar. "Too cluttered" is the most common note on every competitor; we make minimalism the product.
2. **Credential-free trust.** Read-only local logs only. We never read the keychain, never touch OAuth tokens, never make a network call for the core. *"We never ask for your keychain"* — a promise the incumbents structurally can't make (CodexBar reads Claude's OAuth from the keychain).
3. **The ROI reframe.** Usage value vs. flat subscription cost: *"you pay $X/mo → you used $Y of value."* Turns cost-anxiety into "am I getting my money's worth." Nobody shows this.

## Scope

**Now:** coding agents with local logs — Claude Code (`~/.claude/projects`) + Codex (`~/.codex/sessions`). Estimated usage value as the headline metric.

**Later:** Cursor / Gemini CLI / Copilot adapters · today/5h/weekly windows · ROI multiplier (subscription input) · live menu-bar indicator.

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

- ✅ Parser core (`whir-core`) — Claude + Codex adapters, cache-aware cost model, verified against the ccusage-style oracle to the cent.
- ⬜ Next: SwiftUI `MenuBarExtra` app rendering the aggregated-cost popover.
