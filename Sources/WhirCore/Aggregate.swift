import Foundation

public enum Provider: String, Codable { case claude = "Claude Code", codex = "Codex" }

/// A time window. Cache files are keyed by `.key`.
public enum Window: Equatable {
    case month(String)   // "2026-06"
    case all
    public var key: String {
        switch self { case .month(let m): return m; case .all: return "all" }
    }
}

/// Token sums for one model. Cost is derived from these at report time (not
/// stored), so a pricing change is reflected without rescanning.
public struct ModelTokens: Codable {
    public var input = 0
    public var output = 0          // includes reasoning (Codex)
    public var cachedInput = 0     // Codex (subset of a turn's input)
    public var cacheRead = 0       // Claude
    public var cacheWrite5m = 0    // Claude
    public var cacheWrite1h = 0    // Claude
    public init() {}
    public var total: Int { input + output + cachedInput + cacheRead + cacheWrite5m + cacheWrite1h }
    /// All cache-related tokens (Codex cached input + Claude cache read/write).
    public var cacheAll: Int { cachedInput + cacheRead + cacheWrite5m + cacheWrite1h }
}

func + (a: ModelTokens, b: ModelTokens) -> ModelTokens {
    var r = ModelTokens()
    r.input = a.input + b.input
    r.output = a.output + b.output
    r.cachedInput = a.cachedInput + b.cachedInput
    r.cacheRead = a.cacheRead + b.cacheRead
    r.cacheWrite5m = a.cacheWrite5m + b.cacheWrite5m
    r.cacheWrite1h = a.cacheWrite1h + b.cacheWrite1h
    return r
}

/// Per-file accumulated state — the unit of incremental caching. The window
/// total is the sum across all files, so a re-read only resets one file.
public struct FileAgg: Codable {
    public var provider: Provider
    public var inode: String                   // file identity; change ⇒ re-read from 0
    public var mtime: Double                     // last-seen mtime; detects same-length in-place edits
    public var offset: Int                      // byte offset after last newline-terminated line processed
    public var models: [String: ModelTokens]
    public var costByProject: [String: Double]  // Claude only (scan-time pricing; cache invalidates on pricing change)
    public var seenRequestIDs: Set<String>      // Claude dedup
    public var lastModel: String?               // Codex: carry turn_context model across a resume
    public var lastTokenFP: String?             // Codex: drop consecutive duplicate token_count snapshots

    public init(provider: Provider) {
        self.provider = provider
        inode = ""; mtime = 0; offset = 0
        models = [:]; costByProject = [:]; seenRequestIDs = []; lastModel = nil; lastTokenFP = nil
    }
}

// MARK: - cost (pure, derived from token sums)

/// Cost for one model's token sums under current pricing.
public func cost(provider: Provider, model: String, tokens t: ModelTokens)
    -> (usd: Double, priced: Bool, estimate: Bool) {
    switch provider {
    case .claude:
        guard let p = Pricing.claudePrice(model) else { return (0, false, false) }
        let usd = Double(t.input) / 1e6 * p.input
            + Double(t.output) / 1e6 * p.output
            + Double(t.cacheRead) / 1e6 * (p.input * 0.1)
            + Double(t.cacheWrite5m) / 1e6 * (p.input * 1.25)
            + Double(t.cacheWrite1h) / 1e6 * (p.input * 2.0)
        return (usd, true, false)
    case .codex:
        guard let p = Pricing.openAIPrice(model) else { return (0, false, false) }
        let billable = max(t.input - t.cachedInput, 0)
        let usd = Double(billable) / 1e6 * p.input
            + Double(t.cachedInput) / 1e6 * p.cachedInput
            + Double(t.output) / 1e6 * p.output
        return (usd, true, p.estimate)
    }
}

/// Build a ModelTokens from a Claude transcript `usage` block.
public func claudeTokens(_ u: [String: Any]) -> ModelTokens {
    var t = ModelTokens()
    t.input = u.int("input_tokens")
    t.output = u.int("output_tokens")
    t.cacheRead = u.int("cache_read_input_tokens")
    let cc = u.dict("cache_creation")
    let w5 = cc?.int("ephemeral_5m_input_tokens") ?? 0
    let w1 = cc?.int("ephemeral_1h_input_tokens") ?? 0
    t.cacheWrite5m = (w5 == 0 && w1 == 0) ? u.int("cache_creation_input_tokens") : w5
    t.cacheWrite1h = w1
    return t
}

// MARK: - back-compat pure helpers (used by unit tests)

public func claudeCost(model: String?, usage: [String: Any]) -> Double? {
    guard let model, Pricing.claudePrice(model) != nil else { return nil }
    return cost(provider: .claude, model: model, tokens: claudeTokens(usage)).usd
}
public func codexCost(model: String?, input: Int, cachedInput: Int, output: Int) -> Double? {
    guard let model, Pricing.openAIPrice(model) != nil else { return nil }
    var t = ModelTokens(); t.input = input; t.cachedInput = cachedInput; t.output = output
    return cost(provider: .codex, model: model, tokens: t).usd
}

// MARK: - report (assembled from per-file aggregates)

public struct UsageReport {
    public struct ModelLine {
        public let provider: Provider
        public let model: String
        public let tokens: ModelTokens
        public let cost: Double
        public let priced: Bool
        public let estimate: Bool
    }
    public var models: [ModelLine] = []
    public var costByProject: [String: Double] = [:]
    public var filesScanned = 0

    public var totalCost: Double { models.reduce(0) { $0 + $1.cost } }
    public func cost(for p: Provider) -> Double {
        models.filter { $0.provider == p }.reduce(0) { $0 + $1.cost }
    }
    public var hasEstimates: Bool { models.contains { $0.estimate } }

    public static func build(from aggs: [String: FileAgg]) -> UsageReport {
        var tokensByKey: [String: (Provider, String, ModelTokens)] = [:]
        var proj: [String: Double] = [:]
        for fa in aggs.values {
            for (model, t) in fa.models {
                let key = fa.provider.rawValue + "|" + model
                if let ex = tokensByKey[key] {
                    tokensByKey[key] = (ex.0, ex.1, ex.2 + t)
                } else {
                    tokensByKey[key] = (fa.provider, model, t)
                }
            }
            for (p, c) in fa.costByProject { proj[p, default: 0] += c }
        }
        var r = UsageReport()
        r.filesScanned = aggs.count
        r.costByProject = proj
        for (_, v) in tokensByKey {
            let (usd, priced, est) = WhirCore.cost(provider: v.0, model: v.1, tokens: v.2)
            r.models.append(ModelLine(provider: v.0, model: v.1, tokens: v.2,
                                      cost: usd, priced: priced, estimate: est))
        }
        return r
    }
}
