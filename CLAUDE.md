# Whir — agent & contributor guide

Whir is a macOS menu-bar app (+ a `whir` CLI) that estimates the API-equivalent
**usage value** of your Claude Code and Codex sessions, computed 100% locally
from the log files those tools already write. `AGENTS.md` is a symlink to this
file, so Claude Code and Codex read the same guide.

## Non-negotiable constraints

These are the product. A change that breaks one is wrong, no matter how useful:

- **Network: the price table only.** `WhirCore` and the `whir` CLI make zero
  network calls. The app makes exactly one kind: `PricingUpdater` fetches
  `pricing.json` from this repo (raw.githubusercontent.com) at most daily —
  off-switchable in Settings, cached to Application Support, and the request
  carries no user or usage data. No telemetry, no update ping, no "phone home,"
  and no other endpoint, ever. (`ITSAppUsesNonExemptEncryption = NO` holds
  because that fetch uses only Apple's TLS — exempt encryption.)
- **No credentials, no keychain.** Never read the keychain, OAuth tokens, or
  `~/.codex/auth.json`. The trust story is "we structurally can't leak secrets."
- **Read-only, metadata only.** Read token counts, model names, timestamps, and
  project paths — never prompt text, generated code, or tool output.
- **No third-party dependencies.** `Package.swift` has none. Keep it that way;
  reach for the standard library first.

## Build / test / run

```sh
swift build                     # build core + CLI + app
swift test                      # XCTest + Swift Testing; run before claiming done
swift run whir --all            # totals, all time (CLI is the dev oracle)
swift run whir --month 2026-06
swift run whir --history --by day --last 14
swift run whir --history --detail 2026-05    # model/project drilldown
swift run whir --system         # CPU / RAM / disk

xcodegen generate               # regenerate Whir.xcodeproj from project.yml
```

- `Whir.xcodeproj` is **generated** (gitignored). Edit `project.yml`, not the
  project; run `xcodegen generate` after adding/removing source files.
- The App Store build uses `project.yml` (team `33S36XZ32U`, bundle
  `com.whir.Whir`). `CURRENT_PROJECT_VERSION` must increase for every upload.

## Layout

```
Sources/WhirCore/   parsing, incremental cache, history, pricing, system stats (the logic)
Sources/whir/       CLI — a dev oracle over WhirCore
Sources/WhirApp/    SwiftUI menu-bar app (Whir.app)
Tests/WhirCoreTests/ cost, incremental, history, dedup tests
project.yml         XcodeGen spec for the Mac App Store target
scripts/ store/ Casks/  packaging + distribution
```

Everything is named `Whir*`: the `WhirCore` library, the `WhirApp` target, the
`whir` CLI.

## Invariants & gotchas (hard-won — don't relearn these)

- **Incremental cache.** Each file's aggregate carries an `inode` + `mtime` +
  byte `offset` cursor; a rescan reads only new bytes. Reset a file from 0 when
  the inode changes, it shrank (`size < offset`), or size is unchanged but
  `mtime` moved (in-place same-length edit). `offset` only advances past
  **newline-terminated** lines, so a mid-write final line is re-read once
  complete. If you change what's stored per file, **bump `ScanCache.version`
  and `HistoryCache.version`** or you'll read stale caches.
- **Codex fork double-counting.** A forked session replays its parent's entire
  `token_count` history (re-stamped) before its own turns. Detect via
  `session_meta.forked_from_id` and skip the replayed value-prefix
  (`CodexPrefixSkipper`, only on the offset-0 scan). Also drop
  consecutive-duplicate `token_count` snapshots (`lastTokenFP`). See
  `CodexFork.swift`; covered by `CodexForkTests` + `CodexDedupSwiftTests`.
- **Log-scan performance: never `String.contains` on a per-line hot path.**
  Profiling ~2 GB of logs showed Swift's Unicode-aware `String.contains` was
  ~90s while JSON parsing was ~1.4% of the cost. Use `LineReader.nextRaw()` +
  the byte-level `RawLine.contains(_ needle:)` and only build a `String` for
  matched lines. Do **not** "optimize" by swapping `JSONSerialization` for
  `JSONDecoder` — it isn't the bottleneck.
- **Pricing is an estimate.** Costs are derived from stored token sums at read
  time under `Pricing.swift`, stamped with `Pricing.asOf`. Subscription quotas
  aren't token-denominated, so the headline is *usage value*, not a bill —
  label it honestly. `costByProject`/`ProjectAgg` store cost at scan-time
  pricing, so the caches invalidate on a `Pricing.asOf` change (intentional).
  The active table is the compiled-in one unless a **newer** local
  `pricing.json` override exists (fetched by the app from the repo root). That
  repo-root file is auto-synced from LiteLLM's community price table by CI
  (`scripts/sync_pricing.py` + `.github/workflows/sync-pricing.yml`) — edit the
  script, not the JSON; a test enforces the file stays parseable and covers the
  built-in model families. Engines capture `asOf` at scan start and stamp
  caches with it, so a mid-scan price update can't persist mixed-price
  aggregates. A model missing from the table is `priced == false` — render it
  as "—", never as $0.00.
- **Defensive JSON.** Logs vary by tool version; parse with the tolerant
  `obj.str/dict/int` helpers and skip records that don't match, never assume a
  shape.

## Platform & state

- **Deployment floor: macOS 14** (`Package.swift` `.macOS(.v14)`,
  `project.yml` 14.0). Decided deliberately as the sweet spot.
- App models use the **`@Observable`** macro (not `ObservableObject`); views use
  `@State` / `@Bindable`. `UsageModel` is a computed projection of
  `HistoryModel.shared` — no manual change-forwarding glue.
- **macOS 26-only features are deferred, not adopted**: on-device Foundation
  Models, Control Center controls, Spotlight actions. If you add one, gate it
  behind `@available` as an additive extra — do not raise the floor.

## Working style (applies to any agent editing this repo)

- Make the **smallest change** that solves the task; match the surrounding
  code's style, naming, and comment density (comments explain *why*, not *what*).
- **Verify before claiming done**: `swift build` + `swift test` must pass. If
  you touch the parser, cache, or cost model, add/extend a test that locks in
  the invariant.
- **Don't commit or push unless asked.** When you do, keep commits small and
  scoped; never commit `.idea/`, `.build/`, or the generated `Whir.xcodeproj`.
- Prefer editing existing files over adding new ones; don't introduce a
  dependency, a new network call (the price-table fetch is the only one), or a
  credential read to "make it easier."
- Sentence case for user-facing strings; no emoji in the UI.
