import Foundation

/// A per-million-token price table: the compiled-in default, or one parsed from
/// a local `pricing.json` override. Rows are matched by longest prefix, so
/// dated snapshot suffixes still resolve.
public struct PricingTable {
    public let asOf: String                      // "yyyy-MM-dd"
    let claude: [(String, Pricing.Claude)]
    let openai: [(String, Pricing.OpenAI)]

    /// Defensive parse of a pricing.json payload; nil when the shape is
    /// unusable (unknown version, bad asOf, or no valid Claude rows).
    /// Malformed rows are skipped, never guessed at.
    public static func parse(_ data: Data) -> PricingTable? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj.int("version") == 1,
              let asOf = obj.str("asOf"), Pricing.dayDate(asOf) != nil else { return nil }
        var claude: [(String, Pricing.Claude)] = []
        for row in obj["claude"] as? [[String: Any]] ?? [] {
            guard let p = row.str("prefix"), !p.isEmpty,
                  let i = row.num("input"), let o = row.num("output") else { continue }
            claude.append((p, Pricing.Claude(input: i, output: o)))
        }
        var openai: [(String, Pricing.OpenAI)] = []
        for row in obj["openai"] as? [[String: Any]] ?? [] {
            guard let p = row.str("prefix"), !p.isEmpty,
                  let i = row.num("input"), let c = row.num("cachedInput"),
                  let o = row.num("output") else { continue }
            openai.append((p, Pricing.OpenAI(input: i, cachedInput: c, output: o,
                                             estimate: (row["estimate"] as? Bool) ?? true)))
        }
        guard !claude.isEmpty else { return nil }
        return PricingTable(asOf: asOf, claude: claude, openai: openai)
    }

    /// Longest-prefix match so a more specific row (e.g. a dated snapshot or a
    /// `-mini` variant) wins over its family prefix.
    func claudePrice(_ m: String) -> Pricing.Claude? {
        claude.filter { m.hasPrefix($0.0) }.max { $0.0.count < $1.0.count }?.1
    }
    func openAIPrice(_ m: String) -> Pricing.OpenAI? {
        openai.filter { m.hasPrefix($0.0) }.max { $0.0.count < $1.0.count }?.1
    }
}

/// Per-million-token prices. Estimates only — provider list/subscription quota
/// is not token-denominated; this computes API-equivalent *usage value*.
///
/// The table ships compiled in and can be overridden by a newer local
/// `pricing.json` (Application Support/Whir). The app's PricingUpdater is the
/// only thing that fetches that file; WhirCore and the CLI just read it.
/// Surface `asOf` in any UI as "prices as of …".
public enum Pricing {

    public struct Claude {
        public let input: Double      // $/1M
        public let output: Double
        // cache read = 0.1×input, cache write 5m = 1.25×input, cache write 1h = 2×input
    }

    public struct OpenAI {
        public let input: Double
        public let cachedInput: Double
        public let output: Double      // reasoning tokens are billed within output
        public let estimate: Bool      // true = rough/unverified tier
    }

    /// Compiled-in table — the floor; an override can only move forward in time.
    static let builtIn = PricingTable(
        asOf: "2026-07-02",
        claude: [
            ("claude-fable-5",  Claude(input: 10, output: 50)),
            ("claude-opus-4",   Claude(input: 5, output: 25)),
            ("claude-sonnet-5", Claude(input: 3, output: 15)),   // list price ($2/$10 intro runs through 2026-08-31)
            ("claude-sonnet-4", Claude(input: 3, output: 15)),
            ("claude-haiku-4",  Claude(input: 1, output: 5)),
        ],
        openai: [
            ("gpt-5.5",             OpenAI(input: 5.0,  cachedInput: 0.50,  output: 30,  estimate: false)),
            ("gpt-5.4-mini",        OpenAI(input: 0.75, cachedInput: 0.075, output: 4.5, estimate: false)),   // corrected via LiteLLM (was a rough 0.25/2 guess)
            ("gpt-5.4",             OpenAI(input: 2.5,  cachedInput: 0.25,  output: 15,  estimate: false)),
            ("gpt-5.3-codex-spark", OpenAI(input: 0.50, cachedInput: 0.05,  output: 4,  estimate: true)),
        ])

    // The active table. Lock-guarded: lookups run on scan threads while the app
    // may adopt a freshly fetched table on the main thread.
    private static let tableLock = NSLock()
    private static var overrideTable: PricingTable?
    static var active: PricingTable { tableLock.withLock { overrideTable ?? builtIn } }

    public static var asOf: String { active.asOf }

    /// Models that are internal/non-billable and must be excluded from usage value.
    public static let excludedModels: Set<String> = ["codex-auto-review", "<synthetic>"]

    /// The price table can drift (compiled-in, and the fetch is off-switchable).
    /// True once `asOf` is older than 90 days — the UI surfaces a hint.
    public static func isStale(now: Date = Date()) -> Bool {
        guard let d = dayDate(asOf) else { return true }   // unparseable → warn loudly
        return now.timeIntervalSince(d) > 90 * 24 * 3600
    }

    public static func claudePrice(_ model: String?) -> Claude? {
        guard let m = model else { return nil }
        return active.claudePrice(m)
    }

    public static func openAIPrice(_ model: String?) -> OpenAI? {
        guard let m = model else { return nil }
        return active.openAIPrice(m)
    }

    // MARK: - local override (the app's PricingUpdater writes it; core/CLI only read)

    /// Where the fetched price table is cached (Application Support/Whir).
    /// Note: the sandboxed app resolves this inside its container, the CLI to
    /// the real ~/Library — each falls back to the built-in table when absent.
    public static func overrideURL() -> URL {
        URL(fileURLWithPath: ScanCache.directory()).appendingPathComponent("pricing.json")
    }

    /// Adopt the local pricing.json when it parses and is newer than the active
    /// table. Call once at startup (app + CLI); returns true if it applied.
    @discardableResult
    public static func loadOverride(from url: URL = overrideURL()) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let table = PricingTable.parse(data) else { return false }
        return apply(table)
    }

    /// Newer-asOf-wins ("yyyy-MM-dd" compares lexicographically). A shifted
    /// `asOf` invalidates the scan caches, so the next refresh re-prices
    /// everything consistently.
    @discardableResult
    public static func apply(_ table: PricingTable) -> Bool {
        tableLock.lock(); defer { tableLock.unlock() }
        guard table.asOf > (overrideTable ?? builtIn).asOf else { return false }
        overrideTable = table
        return true
    }

    /// Strict "yyyy-MM-dd" parse (also validates pricing.json asOf fields).
    static func dayDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}
