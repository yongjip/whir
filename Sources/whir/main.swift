import Foundation
import WhirCore

let args = CommandLine.arguments

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("-h") || args.contains("--help") {
    print("""
    usage: whir [--month YYYY-MM | --all]
           whir --history [--by hour|day|week|month] [--last N]
    Incremental cache: first run is a full scan, later runs read only new bytes.
    """)
    exit(0)
}

// ---- system stats ----
if args.contains("--system") {
    let s = SystemSampler()
    _ = s.cpu(); usleep(500_000)            // prime, then measure a 0.5s window
    let snap = s.sample()
    func gb(_ b: Double) -> String { String(format: "%.1f GB", b / 1e9) }
    print(String(format: "CPU   %5.1f%%", snap.cpu * 100))
    print("RAM   \(gb(Double(snap.ramUsed))) / \(gb(Double(snap.ramTotal)))  (\(Int((snap.ramFraction * 100).rounded()))%)")
    print("Disk  \(gb(Double(snap.diskUsed))) / \(gb(Double(snap.diskTotal)))  (\(Int((snap.diskFraction * 100).rounded()))%)")
    exit(0)
}

// ---- history mode ----
if args.contains("--history") {
    let g = Granularity(rawValue: flagValue("--by") ?? "day") ?? .day
    let last = flagValue("--last").flatMap { Int($0) }
    func money(_ v: Double) -> String { String(format: "$%8.2f", v) }
    let snapshot = HistoryEngine().refresh()

    // Drilldown for one bucket: --detail <key>
    if let key = flagValue("--detail") {
        let d = snapshot.detail(for: key, g)
        func tkf(_ n: Int) -> String {
            if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
            if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
            return "\(n)"
        }
        func rj(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        func lj(_ s: String, _ w: Int) -> String { s.padding(toLength: w, withPad: " ", startingAt: 0) }
        func header(_ name: String) {
            print("  \(lj(name, 28))\(rj("Input", 9))\(rj("Cache", 9))\(rj("Output", 9))\(rj("Total", 9))\(rj("Cost", 11))")
        }
        func row(_ name: String, _ t: ModelTokens, _ c: Double) {
            print("  \(lj(name, 28))\(rj(tkf(t.input), 9))\(rj(tkf(t.cacheAll), 9))\(rj(tkf(t.output), 9))\(rj(tkf(t.total), 9))\(rj(String(format: "$%.2f", c), 11))")
        }
        print("================ \(key) — drilldown (\(g.rawValue)) ================")
        print("By model:"); header("model")
        for m in d.models { row("\(m.model) \(m.provider == .codex ? "(X)" : "(C)")", m.tokens, m.cost) }
        print("By project:"); header("project")
        for p in d.projects { row(p.project, p.tokens, p.cost) }
        print("  total: \(money(d.total))")
        exit(0)
    }

    var points = snapshot.series(g)
    if let n = last, points.count > n { points = Array(points.suffix(n)) }
    let maxTotal = points.map(\.total).max() ?? 1
    print("================ usage by \(g.rawValue) (estimated value) ================")
    for p in points {
        let bars = Int((p.total / maxTotal * 28).rounded())
        let bar = String(repeating: "█", count: max(bars, p.total > 0 ? 1 : 0))
        print("  \(p.label.padding(toLength: 13, withPad: " ", startingAt: 0)) \(money(p.total))  \(bar)")
    }
    print("  prices as of \(Pricing.asOf) · local logs only, no credentials")
    print("  range total: \(money(points.reduce(0) { $0 + $1.total }))")
    exit(0)
}

// ---- totals mode (menu-bar number) ----
var window: Window = .month(currentMonthKey())
var label = "This month (\(currentMonthKey()))"
if args.contains("--all") { window = .all; label = "All time" }
if let m = flagValue("--month") { window = .month(m); label = m }

print(UsageEngine().refresh(window: window).render(windowLabel: label))
