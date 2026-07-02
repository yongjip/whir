import Foundation

/// Coordinates cached + incremental scanning.
///   - `cachedReport` returns instantly from the last saved aggregates (no file reads).
///   - `refresh` reads only newly-appended bytes, updates the cache, and returns the new total.
public struct UsageEngine {
    public init() {}

    /// Instant: build a report from the cache without touching the log files.
    public func cachedReport(window: Window) -> UsageReport? {
        guard let aggs = ScanCache.load(window: window) else { return nil }
        return UsageReport.build(from: aggs)
    }

    /// Incremental: scan new bytes for both providers, persist, and return the total.
    @discardableResult
    public func refresh(window: Window,
                        claudeProjects: String = homePath(".claude/projects"),
                        codexSessions: String? = nil) -> UsageReport {
        let pricingAsOf = Pricing.asOf   // capture at start; see ScanCache.save
        var aggs = ScanCache.load(window: window) ?? [:]
        ClaudeAdapter(root: claudeProjects).update(&aggs, window: window)
        CodexAdapter(root: codexSessions).update(&aggs, window: window)
        ScanCache.save(aggs, window: window, pricingAsOf: pricingAsOf)
        return UsageReport.build(from: aggs)
    }
}

/// The current month as "yyyy-MM" — the default window.
public func currentMonthKey(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
}
