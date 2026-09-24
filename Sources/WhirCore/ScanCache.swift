import Foundation

/// Persists per-file aggregates per window to Application Support, so the app
/// can show the last total instantly and only re-read new bytes on refresh.
/// Cost is derived from stored token sums at read time and never persisted, so
/// a pricing change needs no rescan; `version` guards against schema changes.
enum ScanCache {
    static let version = 7   // v7: month windows use local event time and track the time zone

    private struct File: Codable {
        var version: Int
        var window: String
        var timeZoneID: String
        var aggs: [String: FileAgg]
    }

    static func directory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: homePath("Library/Application Support"))
        return base.appendingPathComponent("Whir", isDirectory: true).path
    }

    private static func path(for window: Window) -> String {
        (directory() as NSString).appendingPathComponent("cache-\(window.key).json")
    }

    static func load(window: Window,
                     timeZoneID: String = TimeZone.autoupdatingCurrent.identifier,
                     from url: URL? = nil) -> [String: FileAgg]? {
        let target = url ?? URL(fileURLWithPath: path(for: window))
        guard let data = try? Data(contentsOf: target),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == version, file.window == window.key,
              (window == .all || file.timeZoneID == timeZoneID)
        else { return nil }
        return file.aggs
    }

    static func save(_ aggs: [String: FileAgg], window: Window,
                     timeZoneID: String = TimeZone.autoupdatingCurrent.identifier,
                     to url: URL? = nil) {
        let target = url ?? URL(fileURLWithPath: path(for: window))
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let file = File(version: version, window: window.key, timeZoneID: timeZoneID, aggs: aggs)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: target, options: .atomic)
    }
}
