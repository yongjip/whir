# Whir

**What your AI coding habit actually costs — one clean number in your Mac menu bar, computed entirely on your machine, without touching a single credential.**

Whir reads the local usage logs that Claude Code and Codex already write, and shows the API-equivalent **usage value** of what you ran — live in the menu bar, with history and a system monitor. Local-first: it never reads your keychain, never sees prompts or code, and makes no network calls.

## Features
- **Menu bar** — today's estimated usage value at a glance; click for a Claude/Codex breakdown and last-30-day ROI.
- **History** — usage by **hour / day / week / month**, split by **provider or model**, with a per-period **drilldown** (token table: input / cache / output / cost, by model and by project).
- **ROI** — enter your monthly subscription and see *"N× your $X/mo"* — value vs. what you actually pay.
- **System monitor** — live **CPU / RAM / disk**, RunCat-style.
- **Shortcuts / Spotlight** — an App Intent returns today's usage value for automations (reads the local cache; no folder access needed).
- **Private by design** — read-only on `~/.claude` & `~/.codex` metadata; no keychain, no network, no prompt/code upload.

## Privacy
Whir reads only token counts, model names, timestamps, and project paths. It never reads prompt text, generated code, tool output, auth tokens, or `~/.codex/auth.json`. Nothing is uploaded; there is no account and no server. (The direct build reads the folders directly; the Mac App Store build asks you to grant `~/.claude` / `~/.codex` once.)

## Install
- **Direct (recommended):** download the notarized DMG from Releases, or `brew install --cask yongjip/tap/whir`. See [`store/DIRECT.md`](store/DIRECT.md).
- **Mac App Store:** see [`store/APPSTORE.md`](store/APPSTORE.md).
- **From source:**
  ```sh
  scripts/package.sh && open dist/Whir.app     # builds + ad-hoc signs a local Whir.app
  ```

## For developers — the core + CLI
The app is a thin SwiftUI shell over a SwiftPM core (`WhirCore`) with a CLI used as a dev oracle:

```sh
swift run whir --month 2026-06           # totals for a month
swift run whir --all                      # all time
swift run whir --history --by day --last 14
swift run whir --history --by month --detail 2026-05   # model/project drilldown
swift run whir --system                   # CPU / RAM / disk
swift test                                        # unit, incremental, history, and dedup tests
```
First run is a full scan; an incremental cache (per-file byte-offset cursors) makes later runs ~instant.

### What it reads
| Provider | Source | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | `message.usage` per assistant turn; dedup by `requestId`; `<synthetic>` excluded |
| Codex | `$CODEX_HOME or ~/.codex/sessions/**/rollout-*.jsonl` (+ `archived_sessions/`) | `info.last_token_usage` per `token_count`; model/project from latest `turn_context`; `codex-auto-review` excluded |

### Cost model
- **Claude:** `input + output + cache_read×0.1 + cache_write_5m×1.25 + cache_write_1h×2` (× input price).
- **Codex:** `(input − cached)×input_price + cached×cached_price + output×output_price` (reasoning is within output).
- Prices are **estimates**, stamped with `Pricing.asOf`; subscription quotas aren't token-denominated, so this is *usage value*, not your bill. Tiers marked `*` (mini/spark) are rough.

### Layout
```
Sources/WhirCore/    parsing, cache, history, pricing, system stats
Sources/whir/       CLI (dev oracle)
Sources/WhirApp/     SwiftUI menu-bar app (Whir.app)
Tests/WhirCoreTests/ cost, incremental, history, system tests
project.yml                 XcodeGen spec for the Mac App Store target
scripts/, store/, Casks/    packaging + distribution
```
> Everything is named `Whir*` — the `WhirCore` library, the `WhirApp` target, and the `whir` CLI; bundle id `com.whir.Whir`.

## Roadmap
- Cursor / Gemini CLI / Copilot adapters
- Reactive CPU-driven menu-bar animation
- Desktop / Notification Centre widget
- Sparkle auto-update
- App icon ✓, incremental cache ✓, history + drilldown ✓, ROI ✓, launch-at-login ✓, Shortcuts (App Intent) ✓, MAS + direct packaging ✓
