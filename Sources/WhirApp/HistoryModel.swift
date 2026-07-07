import SwiftUI
import WhirCore

struct LegendItem: Identifiable { var id: String { name }; let name: String; let color: Color }

@MainActor
@Observable
final class HistoryModel {
    /// One app-wide instance: pre-warmed at launch, observed by the window.
    static let shared = HistoryModel()

    var granularity: Granularity = .day
    var groupBy: GroupBy = .provider
    var points: [GroupedPoint] = []
    var selectedKey: String?
    var loading = true       // no data shown yet (first build)
    var building = false     // background scan in progress
    private(set) var colorMap: [String: Color] = [:]

    /// Menu-bar / popover headline: TODAY's spend (with provider split) for the
    /// glanceable number, plus the rolling last-30-days total for the ROI line.
    /// Independent of the granularity picker. nil until first built.
    struct Headline: Equatable { let today: Double; let codex: Double; let claude: Double; let last30: Double }
    private(set) var headline: Headline?
    var hasReadableRoot = true

    // Non-UI internals — excluded from observation. `snapshot` always mutates
    // alongside a tracked property (points/headline/loading), so views still update.
    @ObservationIgnored private let engine = HistoryEngine()
    @ObservationIgnored private var snapshot: HistorySnapshot?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?   // in-flight scan; nil = idle
    @ObservationIgnored private var autoTimer: Timer?
    @ObservationIgnored private let palette: [Color] = [.orange, .blue, .teal, .purple, .pink, .green, .indigo]

    /// Per-model + per-project breakdown of the selected bucket.
    var detail: BucketDetail? { selectedKey.flatMap { snapshot?.detail(for: $0, granularity) } }

    /// Called once at app launch (pre-warm) and again when the window opens.
    func start() {
        guard !started else { return }
        started = true
        if let s = engine.cachedSnapshot() {            // instant if we've built it before
            snapshot = s; recompute(); loading = points.isEmpty
        }
        refresh()
        // Keep the all-time history warm so opening the window is instant.
        autoTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { autoTimer?.invalidate() }

    func setGranularity(_ g: Granularity) { granularity = g; selectedKey = nil; recompute() }
    func setGroupBy(_ b: GroupBy) { groupBy = b; selectedKey = nil; recompute() }

    /// Coalesced: a no-op while a scan is in flight, so overlapping refreshes
    /// can't clobber the history.json byte offsets.
    func refresh() {
        guard scanTask == nil else { return }
        building = true
        scanTask = Task.detached(priority: .userInitiated) {
            let roots = FolderAccess.currentRoots()
            let (s, status) = FolderAccess.withAccess { () -> (HistorySnapshot, RootsStatus) in
                (HistoryEngine().refresh(claudeProjects: roots.claudeProjects, codexSessions: roots.codexSessions),
                 rootsStatus(claudeProjects: roots.claudeProjects, codexSessions: roots.codexSessions))
            }
            await MainActor.run {
                self.snapshot = s; self.hasReadableRoot = status.anyReadable
                self.recompute(); self.loading = false; self.building = false
                self.scanTask = nil
            }
        }
    }

    private func recompute() {
        points = snapshot?.grouped(granularity, by: groupBy) ?? []
        // Drop a selection whose bucket no longer exists (e.g. aged out after a
        // refresh), else the drilldown shows a stale header over empty tables.
        selectedKey = validSelection(selectedKey, in: points.map(\.key))
        // Stable colors: assign the palette to the highest-cost groups overall; rest gray.
        var totals: [String: Double] = [:]
        for p in points { for s in p.slices { totals[s.name, default: 0] += s.cost } }
        var map: [String: Color] = [:]
        for (i, e) in totals.sorted(by: { $0.value > $1.value }).enumerated() where i < palette.count {
            map[e.key] = palette[i]
        }
        colorMap = map
        recomputeHeadline()
    }

    /// Today's spend (+ provider split) and the last-30-days total, from the
    /// all-time daily buckets — fixed window, not affected by the picker.
    private func recomputeHeadline() {
        // An empty snapshot carries no information (pre-grant scan, fresh
        // install): keep the headline nil so the UI shows loading / no-logs
        // instead of a confident $0.
        guard let snap = snapshot, !snap.isEmpty else { headline = nil; return }
        let daily = snap.grouped(.day, by: .provider)
        let last30 = daily.suffix(30).reduce(0.0) { $0 + $1.total }
        var today = 0.0, cx = 0.0, cl = 0.0
        if let p = daily.last(where: { $0.key == Self.todayKey }) {
            today = p.total
            for s in p.slices { if s.name == "Codex" { cx += s.cost } else { cl += s.cost } }
        }
        headline = Headline(today: today, codex: cx, claude: cl, last30: last30)
    }

    /// Local "yyyy-MM-dd" — matches the History day-bucket keys.
    nonisolated static var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    func color(_ name: String) -> Color { colorMap[name] ?? .gray }

    /// Recent slice sized for readability per granularity.
    var recent: [GroupedPoint] {
        let cap: Int
        switch granularity {
        case .hour: cap = 24
        case .day: cap = 30
        case .week: cap = 16
        case .month: cap = 18
        }
        return Array(points.suffix(cap))
    }
    var rangeTotal: Double { recent.reduce(0) { $0 + $1.total } }
    var recentMax: Double { recent.map(\.total).max() ?? 0 }

    /// Groups present in the visible range, with their colors (for the compact legend).
    var legend: [LegendItem] {
        var totals: [String: Double] = [:]
        for p in recent { for s in p.slices { totals[s.name, default: 0] += s.cost } }
        return totals.sorted { $0.value > $1.value }.prefix(8).map { LegendItem(name: $0.key, color: color($0.key)) }
    }
}
