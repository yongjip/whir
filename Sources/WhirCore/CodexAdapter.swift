import Foundation

/// Reads Codex rollout logs from $CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl
/// (default ~/.codex), plus archived_sessions/. Aggregates info.last_token_usage
/// per token_count event, attributing each to the model from the most recent
/// turn_context — which is persisted (`lastModel`) so a resumed scan keeps the
/// right model even when no turn_context appears in the new bytes.
public struct CodexAdapter {
    public var root: String
    public init(root: String? = nil) {
        if let r = root { self.root = r }
        else if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            self.root = (env as NSString).appendingPathComponent("sessions")
        } else {
            self.root = homePath(".codex/sessions")
        }
    }

    /// Files needing a read are scanned concurrently (see ScanConfig for the
    /// kill switch) — each file's aggregate is independent (the fork skipper
    /// only READS other files), so results merge deterministically by path.
    /// Returns whether anything changed (files pruned/reset or bytes consumed).
    @discardableResult
    public func update(_ aggs: inout [String: FileAgg], window: Window) async -> Bool {
        var roots = [root]
        let archived = (root as NSString).deletingLastPathComponent + "/archived_sessions"
        if FileManager.default.fileExists(atPath: archived) { roots.append(archived) }

        let needle: String? = {
            if case .month(let m) = window { return "/" + m.replacingOccurrences(of: "-", with: "/") + "/" }
            return nil
        }()

        var present = Set<String>()
        var allReadable = true
        for r in roots {
            guard let found = files(under: r, suffix: ".jsonl") else { allReadable = false; continue }
            for path in found {
                if let n = needle, !path.contains(n) { continue }
                present.insert(path)
            }
        }
        var changed = false
        // Only prune when every root was readable — a transient access failure
        // must not wipe cached aggregates and force a multi-GB rescan on recovery.
        if allReadable {
            for (path, fa) in aggs where fa.provider == .codex && !present.contains(path) {
                aggs[path] = nil; changed = true
            }
        }

        // Classify sequentially (cheap stats); collect the files that need reads.
        var jobs: [(path: String, fa: FileAgg, mtime: Double)] = []
        for path in present {
            guard let id = fileIdentity(path) else { continue }
            var fa = aggs[path]
            let reset = fa == nil || fa!.provider != .codex
                || fa!.inode != id.inode || id.size < fa!.offset
                || (id.size == fa!.offset && fa!.mtime != id.mtime)   // in-place same-length edit
            if reset {
                fa = FileAgg(provider: .codex)
                fa!.inode = id.inode
                changed = true
            }
            if !reset && id.size == fa!.offset { aggs[path] = fa; continue }
            jobs.append((path, fa!, id.mtime))
        }

        let scanRoots = roots
        let results = await scanConcurrently(jobs) { j in
            await Self.scanFile(path: j.path, fa: j.fa, mtime: j.mtime, roots: scanRoots)
        }
        for (path, fa, fileChanged) in results {
            aggs[path] = fa   // nil = caught mid-replay; re-read from 0 next scan
            changed = changed || fileChanged
        }
        return changed
    }

    private static func scanFile(path: String, fa faIn: FileAgg, mtime: Double,
                                 roots: [String]) async -> (String, FileAgg?, Bool) {
        var fa = faIn
        let startOffset = fa.offset
        guard let reader = LineReader(path: path, startOffset: fa.offset) else { return (path, fa, false) }
        var curModel = fa.lastModel    // carry model across the resume boundary
        // On a from-scratch read of a forked session, skip the replayed parent prefix.
        var skipper = fa.offset == 0 ? CodexPrefixSkipper(forkPath: path, roots: roots) : nil
        var lastFP = fa.lastTokenFP    // drop consecutive duplicate token_count snapshots
        var lineCount = 0
        while let raw = reader.nextRaw() {
            if !raw.terminated { continue }                      // mid-write tail: re-read when completed
            let isCtx = raw.contains(LineNeedle.turnContext)
            let isTok = raw.contains(LineNeedle.tokenCount)
            if !isCtx && !isTok { continue }
            // Drain the per-line JSONSerialization garbage each iteration — the
            // periodic yield below drains the task's own pool, but this one
            // keeps each line's garbage from surviving to the next yield point.
            autoreleasepool {
                guard let obj = jsonObject(raw.string) else { return }

                if obj.str("type") == "turn_context" {
                    if let m = obj.dict("payload")?.str("model") { curModel = m }
                    return
                }
                guard let payload = obj.dict("payload"), payload.str("type") == "token_count",
                      let last = payload.dict("info")?.dict("last_token_usage") else { return }

                let tup = [last.int("input_tokens"), last.int("cached_input_tokens"), last.int("output_tokens")]
                if skipper?.shouldSkip(tup) == true { return }   // inherited fork replay — counted in the parent

                let total = payload.dict("info")?.dict("total_token_usage")
                let fp = "\(obj.str("timestamp") ?? "")|\(tup[0])|\(tup[1])|\(tup[2])|\(total?.int("input_tokens") ?? -1)|\(total?.int("output_tokens") ?? -1)"
                if fp == lastFP { return }   // consecutive duplicate token_count snapshot (Codex re-emit)
                lastFP = fp

                let model = curModel ?? "unknown"
                if Pricing.excludedModels.contains(model) { return }

                var t = ModelTokens()
                t.input = tup[0]; t.cachedInput = tup[1]; t.output = tup[2]
                fa.models[model] = (fa.models[model] ?? ModelTokens()) + t
            }
            lineCount += 1
            if lineCount % ScanYield.every == 0 { await Task.yield() }
        }
        // Caught the fork mid-replay: leave the cursor at 0 (drop the partial
        // agg) so the next scan re-reads with a fresh skipper. Nothing new was
        // counted, so it costs nothing and avoids double-counting the rest.
        if skipper?.stillSkipping == true { return (path, nil, false) }
        let fileChanged = reader.safeOffset != startOffset
        fa.lastModel = curModel
        fa.lastTokenFP = lastFP
        fa.offset = reader.safeOffset
        fa.mtime = mtime
        return (path, fa, fileChanged)
    }
}
