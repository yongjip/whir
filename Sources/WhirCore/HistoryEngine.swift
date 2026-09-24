import Foundation

/// All-time, hour-bucketed cache (separate from the menu-bar month cache).
enum HistoryCache {
    static let version = 9   // v9: local hour buckets are tied to the time zone that produced them
    private struct File: Codable { var version: Int; var timeZoneID: String; var aggs: [String: HourAgg] }
    private static func path() -> String {
        (ScanCache.directory() as NSString).appendingPathComponent("history.json")
    }
    static func load(timeZoneID: String = TimeZone.autoupdatingCurrent.identifier,
                     from url: URL? = nil) -> [String: HourAgg]? {
        let target = url ?? URL(fileURLWithPath: path())
        guard let data = try? Data(contentsOf: target),
              let f = try? JSONDecoder().decode(File.self, from: data),
              f.version == version, f.timeZoneID == timeZoneID
        else { return nil }
        return f.aggs
    }
    static func save(_ aggs: [String: HourAgg],
                     timeZoneID: String = TimeZone.autoupdatingCurrent.identifier,
                     to url: URL? = nil) {
        let target = url ?? URL(fileURLWithPath: path())
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(File(version: version, timeZoneID: timeZoneID, aggs: aggs)) else { return }
        try? data.write(to: target, options: .atomic)
    }
}

/// Immutable snapshot of all-time hour buckets; re-roll to any granularity in memory.
public struct HistorySnapshot {
    let aggs: [String: HourAgg]
    let timeZoneID: String
    init(aggs: [String: HourAgg], timeZoneID: String = TimeZone.autoupdatingCurrent.identifier) {
        self.aggs = aggs
        self.timeZoneID = timeZoneID
    }
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
        let zoneID = TimeZone.autoupdatingCurrent.identifier
        return HistoryCache.load(timeZoneID: zoneID).map { HistorySnapshot(aggs: $0, timeZoneID: zoneID) }
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
        let zoneID = TimeZone.autoupdatingCurrent.identifier
        let zone = TimeZone(identifier: zoneID) ?? .current
        var aggs = (prior?.timeZoneID == zoneID ? prior?.aggs : nil)
            ?? HistoryCache.load(timeZoneID: zoneID) ?? [:]
        let claudeChanged = await ClaudeHistory.update(&aggs, root: claudeProjects, timeZone: zone)
        let codexChanged = await CodexHistory.update(&aggs, root: codexSessions ?? codexRoot(), timeZone: zone)
        if claudeChanged || codexChanged {
            HistoryCache.save(aggs, timeZoneID: zoneID)
            // Hand the scan's transient allocation burst back to the OS immediately,
            // rather than leaving it resident-but-reclaimable for macOS to notice later.
            malloc_zone_pressure_relief(nil, 0)
        }
        return HistorySnapshot(aggs: aggs, timeZoneID: zoneID)
    }
}
