import Foundation

public enum Granularity: String, CaseIterable, Identifiable {
    case hour, day, week, month
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// One point in a usage time series (cost per bucket, split by provider).
public struct SeriesPoint: Identifiable {
    public var id: String { key }            // bucket keys are unique within a series
    public let key: String
    public let label: String
    public let claude: Double
    public let codex: Double
    public var total: Double { claude + codex }
}

/// Per-bucket breakdown for the history drilldown.
public struct BucketDetail {
    public struct ModelRow: Identifiable {
        public var id: String { provider.rawValue + "|" + model }
        public let provider: Provider
        public let model: String
        public let cost: Double
        public let priced: Bool   // false = model missing from the price table (render — not $0.00)
        public let tokens: ModelTokens
    }
    public struct ProjectRow: Identifiable {
        public var id: String { project }
        public let project: String
        public let cost: Double
        public let tokens: ModelTokens
    }
    public let total: Double
    public let models: [ModelRow]
    public let projects: [ProjectRow]
}

/// Per-project token sums, broken out by model — cost depends on which model
/// each token belongs to, so it's computed at read time and never stored here
/// (a pricing change is reflected immediately, with no rescan needed).
struct ProjectAgg: Codable {
    var models: [String: ModelTokens] = [:]
}

/// What we store for one bucket: model token sums + per-project cost/tokens.
struct BucketData: Codable {
    var models: [String: ModelTokens] = [:]
    var projects: [String: ProjectAgg] = [:]
}

/// Per-file, hour-bucketed aggregate (finest granularity; rolled up at report time).
struct HourAgg: Codable {
    var provider: Provider
    var inode = ""
    var mtime = 0.0
    var offset = 0
    var buckets: [String: BucketData] = [:]   // localHourKey -> bucket
    var seenRequestIDs: Set<String> = []
    var lastModel: String?
    var lastProject: String?
    var lastTokenFP: String?   // drop consecutive duplicate token_count snapshots
    init(provider: Provider) { self.provider = provider }
}

/// Parses an ISO-8601 UTC timestamp into a LOCAL "yyyy-MM-dd HH" bucket key.
/// Formatter parsing costs ~µs per call and log timestamps repeat heavily, so
/// results are memoized per UTC minute — minute (not hour) granularity so
/// half-hour timezones (+05:30, +05:45) still bucket correctly.
/// NOT thread-safe (mutable memo): each concurrent file-scan task creates its
/// own instance — never share one across tasks.
final class HourKeyer {
    private let isoFrac = ISO8601DateFormatter()
    private let iso = ISO8601DateFormatter()
    private let out = DateFormatter()
    private var memo: [String: String] = [:]   // UTC "yyyy-MM-ddTHH:mm" -> local key
    init() {
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.formatOptions = [.withInternetDateTime]
        out.dateFormat = "yyyy-MM-dd HH"
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = .current
    }
    func key(_ ts: String?) -> String {
        guard let ts else { return "unknown" }
        let minute = ts.count >= 16 ? String(ts.prefix(16)) : ""
        if !minute.isEmpty, let hit = memo[minute] { return hit }
        guard let d = isoFrac.date(from: ts) ?? iso.date(from: ts) else { return "unknown" }
        let k = out.string(from: d)
        if !minute.isEmpty {
            if memo.count >= 8192 { memo.removeAll(keepingCapacity: true) }   // bound the scan's footprint
            memo[minute] = k
        }
        return k
    }
}

private func projectName(_ cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "?" }
    return (cwd as NSString).lastPathComponent
}

private func add(_ agg: inout HourAgg, hour: String, model: String,
                 project: String, tokens t: ModelTokens) {
    var bd = agg.buckets[hour] ?? BucketData()
    bd.models[model] = (bd.models[model] ?? ModelTokens()) + t
    var pa = bd.projects[project] ?? ProjectAgg()
    pa.models[model] = (pa.models[model] ?? ModelTokens()) + t
    bd.projects[project] = pa
    agg.buckets[hour] = bd
}

// MARK: - all-time, hour-bucketed adapters (share the cursor/identity logic of the totals adapters)

enum ClaudeHistory {
    /// Returns whether anything changed (files pruned/reset or bytes consumed) —
    /// the engine skips the cache write when a rescan found nothing new.
    /// Files needing a read are scanned concurrently (ScanConfig kill switch).
    @discardableResult
    static func update(_ aggs: inout [String: HourAgg], root: String) async -> Bool {
        guard let found = files(under: root, suffix: ".jsonl") else { return false }   // unreadable → keep cache
        let present = Set(found)
        var changed = false
        for (path, a) in aggs where a.provider == .claude && !present.contains(path) {
            aggs[path] = nil; changed = true
        }
        var jobs: [(path: String, fa: HourAgg, mtime: Double)] = []
        for path in present {
            guard let id = fileIdentity(path) else { continue }
            var fa = aggs[path]
            let reset = fa == nil || fa!.provider != .claude
                || fa!.inode != id.inode || id.size < fa!.offset
                || (id.size == fa!.offset && fa!.mtime != id.mtime)
            if reset { fa = HourAgg(provider: .claude); fa!.inode = id.inode; changed = true }
            if !reset && id.size == fa!.offset { aggs[path] = fa; continue }
            jobs.append((path, fa!, id.mtime))
        }
        let results = await scanConcurrently(jobs) { j in
            await scanFile(path: j.path, fa: j.fa, mtime: j.mtime)
        }
        for (path, fa, fileChanged) in results {
            aggs[path] = fa
            changed = changed || fileChanged
        }
        return changed
    }

    private static func scanFile(path: String, fa faIn: HourAgg,
                                 mtime: Double) async -> (String, HourAgg, Bool) {
        var fa = faIn
        let startOffset = fa.offset
        guard let reader = LineReader(path: path, startOffset: fa.offset) else { return (path, fa, false) }
        let keyer = HourKeyer()   // per task — HourKeyer is not thread-safe
        var lineCount = 0
        while let raw = reader.nextRaw() {
            if !raw.terminated { continue }
            if !raw.contains(LineNeedle.assistant) { continue }
            autoreleasepool {
                guard let obj = jsonObject(raw.string), obj.str("type") == "assistant" else { return }
                if let rid = obj.str("requestId") {
                    if fa.seenRequestIDs.contains(rid) { return }
                    fa.seenRequestIDs.insert(rid)
                }
                guard let message = obj.dict("message"), let usage = message.dict("usage") else { return }
                let model = message.str("model") ?? "unknown"
                if Pricing.excludedModels.contains(model) { return }
                add(&fa, hour: keyer.key(obj.str("timestamp")), model: model,
                    project: projectName(obj.str("cwd")), tokens: claudeTokens(usage))
            }
            lineCount += 1
            if lineCount % ScanYield.every == 0 { await Task.yield() }
        }
        let fileChanged = reader.safeOffset != startOffset
        fa.offset = reader.safeOffset; fa.mtime = mtime
        return (path, fa, fileChanged)
    }
}

enum CodexHistory {
    /// Returns whether anything changed — see ClaudeHistory.update.
    /// Files needing a read are scanned concurrently (ScanConfig kill switch).
    @discardableResult
    static func update(_ aggs: inout [String: HourAgg], root: String) async -> Bool {
        var roots = [root]
        let archived = (root as NSString).deletingLastPathComponent + "/archived_sessions"
        if FileManager.default.fileExists(atPath: archived) { roots.append(archived) }
        var present = Set<String>()
        var allReadable = true
        for r in roots {
            guard let found = files(under: r, suffix: ".jsonl") else { allReadable = false; continue }
            for p in found { present.insert(p) }
        }
        var changed = false
        if allReadable {   // unreadable root → keep cache instead of wiping it
            for (path, a) in aggs where a.provider == .codex && !present.contains(path) {
                aggs[path] = nil; changed = true
            }
        }

        var jobs: [(path: String, fa: HourAgg, mtime: Double)] = []
        for path in present {
            guard let id = fileIdentity(path) else { continue }
            var fa = aggs[path]
            let reset = fa == nil || fa!.provider != .codex
                || fa!.inode != id.inode || id.size < fa!.offset
                || (id.size == fa!.offset && fa!.mtime != id.mtime)
            if reset { fa = HourAgg(provider: .codex); fa!.inode = id.inode; changed = true }
            if !reset && id.size == fa!.offset { aggs[path] = fa; continue }
            jobs.append((path, fa!, id.mtime))
        }
        let scanRoots = roots
        let results = await scanConcurrently(jobs) { j in
            await scanFile(path: j.path, fa: j.fa, mtime: j.mtime, roots: scanRoots)
        }
        for (path, fa, fileChanged) in results {
            aggs[path] = fa   // nil = caught mid-replay; re-read from 0 next scan
            changed = changed || fileChanged
        }
        return changed
    }

    private static func scanFile(path: String, fa faIn: HourAgg, mtime: Double,
                                 roots: [String]) async -> (String, HourAgg?, Bool) {
        var fa = faIn
        let startOffset = fa.offset
        guard let reader = LineReader(path: path, startOffset: fa.offset) else { return (path, fa, false) }
        let keyer = HourKeyer()   // per task — HourKeyer is not thread-safe
        var curModel = fa.lastModel
        var curProject = fa.lastProject
        var skipper = fa.offset == 0 ? CodexPrefixSkipper(forkPath: path, roots: roots) : nil
        var lastFP = fa.lastTokenFP
        var lineCount = 0
        while let raw = reader.nextRaw() {
            if !raw.terminated { continue }
            let isCtx = raw.contains(LineNeedle.turnContext)
            let isTok = raw.contains(LineNeedle.tokenCount)
            if !isCtx && !isTok { continue }
            autoreleasepool {
                guard let obj = jsonObject(raw.string) else { return }
                if obj.str("type") == "turn_context" {
                    let p = obj.dict("payload")
                    if let m = p?.str("model") { curModel = m }
                    if let c = p?.str("cwd") { curProject = projectName(c) }
                    return
                }
                guard let payload = obj.dict("payload"), payload.str("type") == "token_count",
                      let last = payload.dict("info")?.dict("last_token_usage") else { return }
                let tup = [last.int("input_tokens"), last.int("cached_input_tokens"), last.int("output_tokens")]
                if skipper?.shouldSkip(tup) == true { return }   // inherited fork replay — counted in the parent
                let total = payload.dict("info")?.dict("total_token_usage")
                let fp = "\(obj.str("timestamp") ?? "")|\(tup[0])|\(tup[1])|\(tup[2])|\(total?.int("input_tokens") ?? -1)|\(total?.int("output_tokens") ?? -1)"
                if fp == lastFP { return }   // consecutive duplicate token_count snapshot
                lastFP = fp
                let model = curModel ?? "unknown"
                if Pricing.excludedModels.contains(model) { return }
                var t = ModelTokens()
                t.input = tup[0]; t.cachedInput = tup[1]; t.output = tup[2]
                add(&fa, hour: keyer.key(obj.str("timestamp")), model: model,
                    project: curProject ?? "?", tokens: t)
            }
            lineCount += 1
            if lineCount % ScanYield.every == 0 { await Task.yield() }
        }
        // Caught mid-replay: re-read from 0 next time with a fresh skipper.
        if skipper?.stillSkipping == true { return (path, nil, false) }
        let fileChanged = reader.safeOffset != startOffset
        fa.lastModel = curModel; fa.lastProject = curProject; fa.lastTokenFP = lastFP
        fa.offset = reader.safeOffset; fa.mtime = mtime
        return (path, fa, fileChanged)
    }
}

// MARK: - rollup hour buckets -> requested granularity

private let dayParser: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; return f
}()
private var isoCal: Calendar = { var c = Calendar(identifier: .iso8601); c.timeZone = .current; return c }()

func rollupKey(_ hourKey: String, _ g: Granularity, _ weekMemo: inout [String: (String, String)]) -> (key: String, label: String) {
    if hourKey == "unknown" { return ("unknown", "unknown") }
    switch g {
    case .hour:  return (hourKey, String(hourKey.dropFirst(5)) + ":00")        // MM-dd HH:00
    case .day:   let d = String(hourKey.prefix(10)); return (d, d)
    case .month: let m = String(hourKey.prefix(7)); return (m, m)
    case .week:
        let day = String(hourKey.prefix(10))
        if let cached = weekMemo[day] { return cached }
        var out = (day, day)
        if let date = dayParser.date(from: day) {
            let c = isoCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            if let y = c.yearForWeekOfYear, let w = c.weekOfYear {
                let k = String(format: "%04d-W%02d", y, w); out = (k, k)
            }
        }
        weekMemo[day] = out
        return out
    }
}

/// Build a cost-per-bucket series at the requested granularity, sorted ascending by key.
func buildSeries(_ aggs: [String: HourAgg], _ g: Granularity) -> [SeriesPoint] {
    var claude: [String: Double] = [:]
    var codex: [String: Double] = [:]
    var labels: [String: String] = [:]
    var weekMemo: [String: (String, String)] = [:]
    for agg in aggs.values {
        for (hourKey, bd) in agg.buckets {
            var c = 0.0
            for (model, t) in bd.models { c += cost(provider: agg.provider, model: model, tokens: t).usd }
            if c == 0 { continue }
            let (k, l) = rollupKey(hourKey, g, &weekMemo)
            labels[k] = l
            if agg.provider == .claude { claude[k, default: 0] += c } else { codex[k, default: 0] += c }
        }
    }
    let keys = Set(claude.keys).union(codex.keys).sorted()
    return keys.map { SeriesPoint(key: $0, label: labels[$0] ?? $0,
                                  claude: claude[$0] ?? 0, codex: codex[$0] ?? 0) }
}

// MARK: - grouped series (split each bucket by provider or by model)

public enum GroupBy: String, CaseIterable, Identifiable {
    case provider, model
    public var id: String { rawValue }
    public var title: String { self == .provider ? "Provider" : "Model" }
}

public struct GroupSlice { public let name: String; public let cost: Double }

public struct GroupedPoint: Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let slices: [GroupSlice]          // sorted by cost desc
    public var total: Double { slices.reduce(0) { $0 + $1.cost } }
}

/// Cost per bucket, split into slices by provider or by model, sorted ascending by key.
func buildGroupedSeries(_ aggs: [String: HourAgg], _ g: Granularity, _ by: GroupBy) -> [GroupedPoint] {
    var byBucket: [String: [String: Double]] = [:]   // bucketKey -> group -> cost
    var labels: [String: String] = [:]
    var weekMemo: [String: (String, String)] = [:]
    for agg in aggs.values {
        for (hourKey, bd) in agg.buckets {
            let (k, l) = rollupKey(hourKey, g, &weekMemo)
            labels[k] = l
            for (model, t) in bd.models {
                let c = cost(provider: agg.provider, model: model, tokens: t).usd
                if c == 0 { continue }
                let group = (by == .provider) ? agg.provider.rawValue : model
                byBucket[k, default: [:]][group, default: 0] += c
            }
        }
    }
    return byBucket.keys.sorted().map { k in
        let slices = byBucket[k]!.map { GroupSlice(name: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
        return GroupedPoint(key: k, label: labels[k] ?? k, slices: slices)
    }
}

/// Per-bucket model + project breakdown for one rolled-up bucket key.
func buildDetail(_ aggs: [String: HourAgg], _ bucketKey: String, _ g: Granularity) -> BucketDetail {
    var modelTokens: [String: (provider: Provider, model: String, tokens: ModelTokens)] = [:]
    var projectCost: [String: Double] = [:]
    var projectTokens: [String: ModelTokens] = [:]
    var weekMemo: [String: (String, String)] = [:]
    for agg in aggs.values {
        for (hourKey, bd) in agg.buckets {
            if rollupKey(hourKey, g, &weekMemo).key != bucketKey { continue }
            for (model, t) in bd.models {
                let k = agg.provider.rawValue + "|" + model
                if let ex = modelTokens[k] { modelTokens[k] = (ex.provider, ex.model, ex.tokens + t) }
                else { modelTokens[k] = (agg.provider, model, t) }
            }
            // Project cost is recomputed here, per (project, model) pair, under
            // whatever price table is active right now — never stored.
            for (p, pa) in bd.projects {
                for (model, t) in pa.models {
                    projectCost[p, default: 0] += cost(provider: agg.provider, model: model, tokens: t).usd
                    projectTokens[p] = (projectTokens[p] ?? ModelTokens()) + t
                }
            }
        }
    }
    let modelRows = modelTokens.values.map {
        let c = cost(provider: $0.provider, model: $0.model, tokens: $0.tokens)
        return BucketDetail.ModelRow(provider: $0.provider, model: $0.model,
                                     cost: c.usd, priced: c.priced, tokens: $0.tokens)
    }.sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.tokens.total > $1.tokens.total }
    let projectRows = projectTokens.map {
        BucketDetail.ProjectRow(project: $0.key, cost: projectCost[$0.key] ?? 0, tokens: $0.value)
    }.sorted { $0.cost > $1.cost }
    return BucketDetail(total: modelRows.reduce(0) { $0 + $1.cost }, models: modelRows, projects: projectRows)
}
