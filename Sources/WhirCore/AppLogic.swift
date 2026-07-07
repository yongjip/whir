import Foundation

// Pure UI-decision helpers, kept in the core so they're unit-testable — the
// app is an executable target and can't be @testable-imported by tests.

/// Readability of the configured log roots, so the UI can tell "no usage yet"
/// apart from "couldn't find/read the folders" (and stop showing a confident $0).
public struct RootsStatus: Equatable {
    public let claudeReadable: Bool
    public let codexReadable: Bool
    public init(claudeReadable: Bool, codexReadable: Bool) {
        self.claudeReadable = claudeReadable
        self.codexReadable = codexReadable
    }
    public var anyReadable: Bool { claudeReadable || codexReadable }
}

public func rootsStatus(claudeProjects: String = homePath(".claude/projects"),
                        codexSessions: String? = nil) -> RootsStatus {
    let fm = FileManager.default
    func readableDir(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue && fm.isReadableFile(atPath: path)
    }
    // Resolve the Codex root the same way the adapter does ($CODEX_HOME/default).
    let codexRoot = CodexAdapter(root: codexSessions).root
    return RootsStatus(claudeReadable: readableDir(claudeProjects),
                       codexReadable: readableDir(codexRoot))
}

/// API-equivalent value as a multiple of the monthly subscription. nil when the
/// subscription isn't meaningfully set (< $1) so the UI shows the "set it"
/// prompt instead of a runaway multiplier over a rounded-to-$0 baseline.
public func roiMultiplier(total: Double, subscription: Double) -> Double? {
    guard subscription >= 1 else { return nil }
    return total / subscription
}

/// Keep a selection only if it still exists in the current set (else the
/// drilldown shows a stale header over empty tables after a refresh).
public func validSelection(_ selected: String?, in keys: [String]) -> String? {
    guard let k = selected, keys.contains(k) else { return nil }
    return k
}

/// Sum bucket totals on or after `cutoff` (a "yyyy-MM-dd" key), skipping the
/// "unknown" bucket. Day keys are fixed-width, so lexicographic `>=` is
/// chronological — this gives a true trailing *calendar* window, not "the last N
/// days that happened to have usage" (which over-counts for intermittent users).
public func sumFrom(cutoff: String, _ buckets: [(key: String, total: Double)]) -> Double {
    buckets.reduce(0) { $0 + ($1.key != "unknown" && $1.key >= cutoff ? $1.total : 0) }
}
