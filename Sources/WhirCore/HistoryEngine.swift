import Foundation

/// All-time, hour-bucketed cache (separate from the menu-bar month cache).
enum HistoryCache {
    static let version = 4   // v4: Codex fork-prefix dedup (drops replayed parent usage)
    private struct File: Codable { var version: Int; var pricingAsOf: String; var aggs: [String: HourAgg] }
    private static func path() -> String {
        (ScanCache.directory() as NSString).appendingPathComponent("history.json")
    }
    static func load() -> [String: HourAgg]? {
        guard let data = FileManager.default.contents(atPath: path()),
              let f = try? JSONDecoder().decode(File.self, from: data),
              f.version == version, f.pricingAsOf == Pricing.asOf
        else { return nil }
        return f.aggs
    }
    static func save(_ aggs: [String: HourAgg]) {
        try? FileManager.default.createDirectory(atPath: ScanCache.directory(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(File(version: version, pricingAsOf: Pricing.asOf, aggs: aggs)) else { return }
        try? data.write(to: URL(fileURLWithPath: path()), options: .atomic)
    }
}

/// Immutable snapshot of all-time hour buckets; re-roll to any granularity in memory.
public struct HistorySnapshot {
    let aggs: [String: HourAgg]
    public func series(_ g: Granularity) -> [SeriesPoint] { buildSeries(aggs, g) }
    public func grouped(_ g: Granularity, by: GroupBy) -> [GroupedPoint] { buildGroupedSeries(aggs, g, by) }
    public func detail(for bucketKey: String, _ g: Granularity) -> BucketDetail { buildDetail(aggs, bucketKey, g) }
    public var isEmpty: Bool { aggs.values.allSatisfy { $0.buckets.isEmpty } }
}

public struct HistoryEngine {
    public init() {}

    private func codexRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return (env as NSString).appendingPathComponent("sessions")
        }
        return homePath(".codex/sessions")
    }

    /// Instant: roll up the cached buckets (no file reads).
    public func cachedSnapshot() -> HistorySnapshot? {
        HistoryCache.load().map { HistorySnapshot(aggs: $0) }
    }

    /// Incremental all-time scan (reads only new bytes), persists, returns the snapshot.
    @discardableResult
    public func refresh(claudeProjects: String = homePath(".claude/projects"),
                        codexSessions: String? = nil) -> HistorySnapshot {
        var aggs = HistoryCache.load() ?? [:]
        let keyer = HourKeyer()
        ClaudeHistory.update(&aggs, root: claudeProjects, keyer: keyer)
        CodexHistory.update(&aggs, root: codexSessions ?? codexRoot(), keyer: keyer)
        HistoryCache.save(aggs)
        return HistorySnapshot(aggs: aggs)
    }
}
