import Foundation

/// Per-million-token prices. Estimates only — provider list/subscription quota
/// is not token-denominated; this computes API-equivalent *usage value*.
/// Keep this table maintained; surface `asOf` in any UI as "prices as of …".
public enum Pricing {
    public static let asOf = "2026-06-30"

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

    /// Matched by prefix, so dated snapshot suffixes still resolve.
    static let claude: [(String, Claude)] = [
        ("claude-opus-4",   Claude(input: 5, output: 25)),
        ("claude-sonnet-4", Claude(input: 3, output: 15)),
        ("claude-haiku-4",  Claude(input: 1, output: 5)),
    ]

    static let openai: [(String, OpenAI)] = [
        ("gpt-5.5",             OpenAI(input: 5.0,  cachedInput: 0.50,  output: 30, estimate: false)),
        ("gpt-5.4-mini",        OpenAI(input: 0.25, cachedInput: 0.025, output: 2,  estimate: true)),
        ("gpt-5.4",             OpenAI(input: 2.5,  cachedInput: 0.25,  output: 15, estimate: false)),
        ("gpt-5.3-codex-spark", OpenAI(input: 0.50, cachedInput: 0.05,  output: 4,  estimate: true)),
    ]

    /// Models that are internal/non-billable and must be excluded from usage value.
    public static let excludedModels: Set<String> = ["codex-auto-review", "<synthetic>"]

    /// The price table ships with the app (no network), so it can drift. True
    /// once `asOf` is older than 90 days — the UI surfaces a "may be outdated" hint.
    public static func isStale(now: Date = Date()) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: asOf) else { return true }   // unparseable → warn loudly
        return now.timeIntervalSince(d) > 90 * 24 * 3600
    }

    public static func claudePrice(_ model: String?) -> Claude? {
        guard let m = model else { return nil }
        return claude.first { m.hasPrefix($0.0) }?.1
    }

    /// Longest-prefix match so `gpt-5.4-mini` wins over `gpt-5.4`.
    public static func openAIPrice(_ model: String?) -> OpenAI? {
        guard let m = model else { return nil }
        return openai
            .filter { m.hasPrefix($0.0) }
            .max { $0.0.count < $1.0.count }?.1
    }
}
