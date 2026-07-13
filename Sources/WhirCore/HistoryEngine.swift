import Foundation

/// All-time, hour-bucketed cache (separate from the menu-bar month cache).
enum HistoryCache {
    static let version = 7   // v7: ProjectAgg.cost removed — cost computed at read time, not scan time
    private struct File: Codable { var version: Int; var aggs: [String: HourAgg] }
    private static func path() -> String {
        (ScanCache.directory() as NSString).appendingPathComponent("history.json")
    }
    static func load() -> [String: HourAgg]? {
        guard let data = FileManager.default.contents(atPath: path()),
              let f = try? JSONDecoder().decode(File.self, from: data),
              f.version == version
        else { return nil }
        return f.aggs
    }
    static func save(_ aggs: [String: HourAgg]) {
        try? FileManager.default.createDirectory(atPath: ScanCache.directory(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(File(version: version, aggs: aggs)) else { return }
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
    /// Pass the previous snapshot to resume from its in-memory aggregates — the
    /// app's periodic refresh then skips the multi-MB cache decode; disk is only
    /// read cold (launch, CLI). When nothing changed, the encode + write are
    /// skipped too, so an idle refresh does no JSON work and no disk writes.
    @discardableResult
    public func refresh(claudeProjects: String = homePath(".claude/projects"),
                        codexSessions: String? = nil,
                        resumingFrom prior: HistorySnapshot? = nil) async -> HistorySnapshot {
        var aggs = prior?.aggs ?? HistoryCache.load() ?? [:]
        let claudeChanged = await ClaudeHistory.update(&aggs, root: claudeProjects)
        let codexChanged = await CodexHistory.update(&aggs, root: codexSessions ?? codexRoot())
        if claudeChanged || codexChanged {
            HistoryCache.save(aggs)
            // Hand the scan's transient allocation burst back to the OS immediately,
            // rather than leaving it resident-but-reclaimable for macOS to notice later.
            malloc_zone_pressure_relief(nil, 0)
        }
        return HistorySnapshot(aggs: aggs)
    }
}
