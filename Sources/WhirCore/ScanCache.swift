import Foundation

/// Persists per-file aggregates per window to Application Support, so the app
/// can show the last total instantly and only re-read new bytes on refresh.
/// Cost is derived from stored token sums at read time and never persisted, so
/// a pricing change needs no rescan; `version` guards against schema changes.
enum ScanCache {
    static let version = 6   // v6: seenRequestIDs stored as stable FNV-1a hashes (v5: tokensByProject)

    private struct File: Codable {
        var version: Int
        var window: String
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

    static func load(window: Window) -> [String: FileAgg]? {
        guard let data = FileManager.default.contents(atPath: path(for: window)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == version, file.window == window.key
        else { return nil }
        return file.aggs
    }

    static func save(_ aggs: [String: FileAgg], window: Window) {
        let dir = directory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = File(version: version, window: window.key, aggs: aggs)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: URL(fileURLWithPath: path(for: window)), options: .atomic)
    }
}
