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

    public func update(_ aggs: inout [String: FileAgg], window: Window) {
        var roots = [root]
        let archived = (root as NSString).deletingLastPathComponent + "/archived_sessions"
        if FileManager.default.fileExists(atPath: archived) { roots.append(archived) }

        let needle: String? = {
            if case .month(let m) = window { return "/" + m.replacingOccurrences(of: "-", with: "/") + "/" }
            return nil
        }()

        var present = Set<String>()
        for r in roots {
            for path in files(under: r, suffix: ".jsonl") {
                if let n = needle, !path.contains(n) { continue }
                present.insert(path)
            }
        }
        for (path, fa) in aggs where fa.provider == .codex && !present.contains(path) {
            aggs[path] = nil
        }

        for path in present {
            guard let id = fileIdentity(path) else { continue }
            var fa = aggs[path]
            let reset = fa == nil || fa!.provider != .codex
                || fa!.inode != id.inode || id.size < fa!.offset
                || (id.size == fa!.offset && fa!.mtime != id.mtime)   // in-place same-length edit
            if reset {
                fa = FileAgg(provider: .codex)
                fa!.inode = id.inode
            }
            if !reset && id.size == fa!.offset { aggs[path] = fa; continue }

            guard let reader = LineReader(path: path, startOffset: fa!.offset) else {
                aggs[path] = fa; continue
            }
            var curModel = fa!.lastModel    // carry model across the resume boundary
            // On a from-scratch read of a forked session, skip the replayed parent prefix.
            var skipper = fa!.offset == 0 ? CodexPrefixSkipper(forkPath: path, roots: roots) : nil
            var lastFP = fa!.lastTokenFP    // drop consecutive duplicate token_count snapshots
            while let (line, terminated) = reader.next() {
                if !terminated { continue }                          // mid-write tail: re-read when completed
                let isCtx = line.contains("\"turn_context\"")
                let isTok = line.contains("\"token_count\"")
                if !isCtx && !isTok { continue }
                guard let obj = jsonObject(line) else { continue }

                if obj.str("type") == "turn_context" {
                    if let m = obj.dict("payload")?.str("model") { curModel = m }
                    continue
                }
                guard let payload = obj.dict("payload"), payload.str("type") == "token_count",
                      let last = payload.dict("info")?.dict("last_token_usage") else { continue }

                let tup = [last.int("input_tokens"), last.int("cached_input_tokens"), last.int("output_tokens")]
                if skipper?.shouldSkip(tup) == true { continue }   // inherited fork replay — counted in the parent

                let total = payload.dict("info")?.dict("total_token_usage")
                let fp = "\(obj.str("timestamp") ?? "")|\(tup[0])|\(tup[1])|\(tup[2])|\(total?.int("input_tokens") ?? -1)|\(total?.int("output_tokens") ?? -1)"
                if fp == lastFP { continue }   // consecutive duplicate token_count snapshot (Codex re-emit)
                lastFP = fp

                let model = curModel ?? "unknown"
                if Pricing.excludedModels.contains(model) { continue }

                var t = ModelTokens()
                t.input = tup[0]; t.cachedInput = tup[1]; t.output = tup[2]
                fa!.models[model] = (fa!.models[model] ?? ModelTokens()) + t
            }
            fa!.lastModel = curModel
            fa!.lastTokenFP = lastFP
            fa!.offset = reader.safeOffset
            fa!.size = id.size
            fa!.mtime = id.mtime
            aggs[path] = fa
        }
    }
}
