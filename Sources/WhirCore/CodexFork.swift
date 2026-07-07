import Foundation

/// Codex session forking replays the PARENT session's entire token_count history
/// into the child rollout (re-stamped to fork-creation time) before the child's
/// own turns. Summing that inherited prefix double-counts the parent's usage
/// (the ccusage #897 / CodexBar #627 bug). We detect a fork via
/// session_meta.forked_from_id and skip the leading token_count events that
/// replay the parent — matched by value, in order — counting only new post-fork usage.
enum CodexFork {
    /// `forked_from_id` from the file's session_meta (first line), if present.
    static func forkedFromId(_ path: String) -> String? {
        guard let reader = LineReader(path: path, startOffset: 0),
              let (line, _) = reader.next(), let obj = jsonObject(line) else { return nil }
        if let id = obj.dict("payload")?.str("forked_from_id"), !id.isEmpty { return id }
        if let id = obj.str("forked_from_id"), !id.isEmpty { return id }
        return nil
    }

    /// Ordered (input, cachedInput, output) tuples of the parent's token_count
    /// events — used to recognize the replayed prefix in a fork. Searches all
    /// roots (a fork's parent may live in a different month/archived folder).
    static func parentTokenSeq(forkedFromId id: String, roots: [String]) -> [[Int]]? {
        var parentPath: String?
        for r in roots {
            if let p = files(under: r, suffix: ".jsonl")?.first(where: { $0.contains(id) }) {
                parentPath = p; break
            }
        }
        guard let pp = parentPath, let reader = LineReader(path: pp, startOffset: 0) else { return nil }
        var seq: [[Int]] = []
        while let raw = reader.nextRaw() {
            if !raw.terminated || !raw.contains(LineNeedle.tokenCount) { continue }   // byte-level prefilter
            guard let obj = jsonObject(raw.string),
                  let payload = obj.dict("payload"), payload.str("type") == "token_count",
                  let last = payload.dict("info")?.dict("last_token_usage") else { continue }
            seq.append([last.int("input_tokens"), last.int("cached_input_tokens"), last.int("output_tokens")])
        }
        return seq
    }
}

/// Stateful matcher: skips the fork's leading token_count events that replay the
/// parent's value-sequence, in order, and stops at the first divergence (the
/// fork's genuinely new usage). Feed EVERY token_count event in file order
/// (including excluded-model ones) so it stays aligned with the parent sequence.
struct CodexPrefixSkipper {
    private let parent: [[Int]]
    private var idx = 0
    private var active = true

    /// nil when the file is not a fork (or the parent can't be found) → no skipping.
    init?(forkPath: String, roots: [String]) {
        guard let pid = CodexFork.forkedFromId(forkPath),
              let seq = CodexFork.parentTokenSeq(forkedFromId: pid, roots: roots), !seq.isEmpty
        else { return nil }
        parent = seq
    }

    /// true → this event is part of the inherited replay; don't count it.
    mutating func shouldSkip(_ tuple: [Int]) -> Bool {
        guard active else { return false }
        if idx < parent.count && parent[idx] == tuple { idx += 1; return true }
        active = false
        return false
    }

    /// Still consuming the inherited replay — a scan caught the fork mid-replay
    /// (Codex hadn't flushed all replayed events yet). The caller must NOT
    /// advance the file cursor then: re-read from 0 next time with a fresh
    /// skipper. Nothing new was counted (we never diverged), so the re-read is
    /// free — and it stops the remaining replay from being counted as real usage.
    var stillSkipping: Bool { active && idx < parent.count }
}
