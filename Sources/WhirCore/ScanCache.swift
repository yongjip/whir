import Foundation

/// Persists per-file aggregates per window to Application Support, so the app
/// can show the last total instantly and only re-read new bytes on refresh.
/// Cost is derived from stored token sums at read time, so a pricing change
/// needs no cache invalidation; `version` guards against schema changes.
enum ScanCache {
    static let version = 4   // v4: Codex fork-prefix + consecutive-duplicate-snapshot dedup

    private struct File: Codable {
        var version: Int
        var window: String
        var pricingAsOf: String        // invalidate when the price table changes
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
              file.version == version, file.window == window.key,
              file.pricingAsOf == Pricing.asOf      // pricing changed ⇒ rescan (keeps costByProject consistent)
        else { return nil }
        return file.aggs
    }

    /// `pricingAsOf` must be captured at scan START: if a price update lands
    /// mid-scan, the stamp won't match `Pricing.asOf` on the next load and the
    /// mixed-price aggregates are rescanned instead of persisting.
    static func save(_ aggs: [String: FileAgg], window: Window, pricingAsOf: String) {
        let dir = directory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = File(version: version, window: window.key, pricingAsOf: pricingAsOf, aggs: aggs)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: URL(fileURLWithPath: path(for: window)), options: .atomic)
    }
}
