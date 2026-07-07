import Foundation

/// Reads Claude Code transcripts from ~/.claude/projects/**/*.jsonl.
/// Only message.usage / model / timestamp / requestId / cwd are touched — never
/// prompt text, generated code, or tool output.
public struct ClaudeAdapter {
    public var root: String
    public init(root: String = homePath(".claude/projects")) { self.root = root }

    /// Incrementally update `aggs` in place: reads only bytes appended since the
    /// last scan, resets a file's aggregate if its identity changed or it shrank.
    public func update(_ aggs: inout [String: FileAgg], window: Window) {
        // Unreadable root (missing / access lost) → leave cached aggs untouched
        // rather than wiping them (which would force a full rescan on recovery).
        guard let found = files(under: root, suffix: ".jsonl") else { return }
        let present = Set(found)
        // Drop Claude files that vanished.
        for (path, fa) in aggs where fa.provider == .claude && !present.contains(path) {
            aggs[path] = nil
        }

        for path in present {
            guard let id = fileIdentity(path) else { continue }
            var fa = aggs[path]
            let reset = fa == nil || fa!.provider != .claude
                || fa!.inode != id.inode || id.size < fa!.offset
                || (id.size == fa!.offset && fa!.mtime != id.mtime)   // in-place same-length edit
            if reset {
                fa = FileAgg(provider: .claude)
                fa!.inode = id.inode
            }
            if !reset && id.size == fa!.offset { aggs[path] = fa; continue }   // unchanged → keep cached

            guard let reader = LineReader(path: path, startOffset: fa!.offset) else {
                aggs[path] = fa; continue
            }
            while let raw = reader.nextRaw() {
                if !raw.terminated { continue }                      // mid-write tail: re-read when completed
                if !raw.contains(LineNeedle.assistant) { continue }
                // Drain per-line JSON garbage (assistant lines are large).
                autoreleasepool {
                    guard let obj = jsonObject(raw.string), obj.str("type") == "assistant" else { return }
                    if case .month(let m) = window,
                       !(obj.str("timestamp")?.hasPrefix(m) ?? false) { return }

                    if let rid = obj.str("requestId") {
                        if fa!.seenRequestIDs.contains(rid) { return }   // dedup retried requests
                        fa!.seenRequestIDs.insert(rid)
                    }
                    guard let message = obj.dict("message"), let usage = message.dict("usage") else { return }
                    let model = message.str("model") ?? "unknown"
                    if Pricing.excludedModels.contains(model) { return }

                    let t = claudeTokens(usage)
                    fa!.models[model] = (fa!.models[model] ?? ModelTokens()) + t
                    let proj = (obj.str("cwd").map { ($0 as NSString).lastPathComponent }) ?? "?"
                    fa!.costByProject[proj, default: 0] += cost(provider: .claude, model: model, tokens: t).usd
                }
            }
            fa!.offset = reader.safeOffset
            fa!.mtime = id.mtime
            aggs[path] = fa
        }
    }
}
