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
    /// When nothing changed, the cache encode + write are skipped (the file on
    /// disk already matches), so a no-op refresh stays allocation- and IO-free.
    @discardableResult
    public func refresh(window: Window,
                        claudeProjects: String = homePath(".claude/projects"),
                        codexSessions: String? = nil) async -> UsageReport {
        var aggs = ScanCache.load(window: window) ?? [:]
        let claudeChanged = await ClaudeAdapter(root: claudeProjects).update(&aggs, window: window)
        let codexChanged = await CodexAdapter(root: codexSessions).update(&aggs, window: window)
        if claudeChanged || codexChanged {
            ScanCache.save(aggs, window: window)
            // Hand the scan's transient allocation burst back to the OS immediately,
            // rather than leaving it resident-but-reclaimable for macOS to notice later.
            malloc_zone_pressure_relief(nil, 0)
        }
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
