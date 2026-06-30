import XCTest
@testable import WhirCore

final class HistoryTests: XCTestCase {

    private func tok(input: Int) -> ModelTokens { var t = ModelTokens(); t.input = input; return t }
    private func bd(_ models: [String: ModelTokens], _ projects: [String: Double] = [:]) -> BucketData {
        BucketData(models: models, projects: projects.mapValues { ProjectAgg(cost: $0, tokens: ModelTokens()) })
    }

    // Rollup: hour buckets collapse correctly to hour / day / month.
    func testRollupGranularities() {
        var a = HourAgg(provider: .claude)
        a.buckets["2026-06-15 09"] = bd(["claude-opus-4-8": tok(input: 1_000_000)])   // $5
        a.buckets["2026-06-15 10"] = bd(["claude-opus-4-8": tok(input: 2_000_000)])   // $10
        a.buckets["2026-06-16 11"] = bd(["claude-opus-4-8": tok(input: 1_000_000)])   // $5
        let aggs = ["f": a]

        XCTAssertEqual(buildSeries(aggs, .hour).count, 3)

        let day = buildSeries(aggs, .day)
        XCTAssertEqual(day.count, 2)
        XCTAssertEqual(day.first { $0.key == "2026-06-15" }?.claude ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(day.first { $0.key == "2026-06-16" }?.claude ?? 0, 5, accuracy: 1e-9)

        let month = buildSeries(aggs, .month)
        XCTAssertEqual(month.count, 1)
        XCTAssertEqual(month[0].claude, 20, accuracy: 1e-9)
        XCTAssertEqual(month[0].key, "2026-06")
    }

    // Provider split is kept per bucket; series sorted ascending.
    func testProviderSplitAndSort() {
        var c = HourAgg(provider: .claude)
        c.buckets["2026-06-15 09"] = bd(["claude-opus-4-8": tok(input: 1_000_000)])   // $5
        var x = HourAgg(provider: .codex)
        x.buckets["2026-06-15 09"] = bd(["gpt-5.5": tok(input: 1_000_000)])            // $5
        x.buckets["2026-06-14 09"] = bd(["gpt-5.5": tok(input: 1_000_000)])

        let day = buildSeries(["c": c, "x": x], .day)
        XCTAssertEqual(day.map(\.key), ["2026-06-14", "2026-06-15"])                  // ascending
        let d15 = day.first { $0.key == "2026-06-15" }!
        XCTAssertEqual(d15.claude, 5, accuracy: 1e-9)
        XCTAssertEqual(d15.codex, 5, accuracy: 1e-9)
        XCTAssertEqual(d15.total, 10, accuracy: 1e-9)
    }

    // ISO week rollup groups days in the same week.
    func testWeekRollup() {
        var a = HourAgg(provider: .claude)
        a.buckets["2026-06-15 09"] = bd(["claude-opus-4-8": tok(input: 1_000_000)])   // Mon
        a.buckets["2026-06-17 09"] = bd(["claude-opus-4-8": tok(input: 1_000_000)])   // Wed, same week
        a.buckets["2026-06-22 09"] = bd(["claude-opus-4-8": tok(input: 1_000_000)])   // next Mon
        XCTAssertEqual(buildSeries(["f": a], .week).count, 2)
    }

    // Drilldown: a rolled-up bucket reports per-model and per-project breakdown,
    // merging projects across providers.
    func testBucketDetail() {
        var c = HourAgg(provider: .claude)
        c.buckets["2026-06-15 09"] = bd(["claude-opus-4-8": tok(input: 1_000_000)], ["backend": 5])
        var x = HourAgg(provider: .codex)
        x.buckets["2026-06-15 14"] = bd(["gpt-5.5": tok(input: 1_000_000)], ["backend": 5]) // same day, diff hour

        let detail = buildDetail(["c": c, "x": x], "2026-06-15", .day)
        XCTAssertEqual(detail.models.count, 2)
        XCTAssertEqual(detail.models.map(\.cost).reduce(0, +), 10, accuracy: 1e-9)
        XCTAssertEqual(detail.models.first { $0.model == "claude-opus-4-8" }?.tokens.input, 1_000_000)
        XCTAssertEqual(detail.projects.count, 1, "same project merged across providers")
        XCTAssertEqual(detail.projects[0].project, "backend")
        XCTAssertEqual(detail.projects[0].cost, 10, accuracy: 1e-9)
        XCTAssertEqual(detail.total, 10, accuracy: 1e-9)
    }

    // Grouped series: same buckets, split by provider vs by model.
    func testGroupedSeries() {
        var c = HourAgg(provider: .claude)
        c.buckets["2026-06-15 09"] = bd(["claude-opus-4-8": tok(input: 1_000_000)])   // $5
        var x = HourAgg(provider: .codex)
        x.buckets["2026-06-15 14"] = bd(["gpt-5.5": tok(input: 1_000_000)])            // $5
        x.buckets["2026-06-15 16"] = bd(["gpt-5.4": tok(input: 1_000_000)])            // $2.50
        let aggs = ["c": c, "x": x]

        let byProvider = buildGroupedSeries(aggs, .day, .provider)
        XCTAssertEqual(byProvider.count, 1)
        XCTAssertEqual(Set(byProvider[0].slices.map(\.name)), ["Claude Code", "Codex"])
        XCTAssertEqual(byProvider[0].total, 12.5, accuracy: 1e-9)

        let byModel = buildGroupedSeries(aggs, .day, .model)
        XCTAssertEqual(byModel.count, 1)
        XCTAssertEqual(Set(byModel[0].slices.map(\.name)), ["claude-opus-4-8", "gpt-5.5", "gpt-5.4"])
        XCTAssertEqual(byModel[0].slices.last?.name, "gpt-5.4", "slices sorted by cost desc")
        XCTAssertEqual(byModel[0].total, 12.5, accuracy: 1e-9)
    }

    // End-to-end: two Claude events in different hours bucket into two hour points.
    func testClaudeAdapterBucketsByHour() {
        let root = NSTemporaryDirectory() + "urhist-" + UUID().uuidString
        let proj = root + "/proj"
        try! FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = proj + "/a.jsonl"
        func line(ts: String, req: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: [
                "type": "assistant", "timestamp": ts, "requestId": req, "cwd": "/x/p",
                "message": ["model": "claude-opus-4-8", "usage": ["input_tokens": 1_000_000]],
            ]), as: UTF8.self)
        }
        try! (line(ts: "2026-06-15T01:00:00.000Z", req: "r1") + "\n"
            + line(ts: "2026-06-15T05:00:00.000Z", req: "r2") + "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)

        var aggs: [String: HourAgg] = [:]
        ClaudeHistory.update(&aggs, root: root, keyer: HourKeyer())
        XCTAssertEqual(buildSeries(aggs, .hour).count, 2)
        XCTAssertEqual(buildSeries(aggs, .day).count, 1)
        // and the day's drilldown attributes to the project "p"
        let d = buildDetail(aggs, buildSeries(aggs, .day)[0].key, .day)
        XCTAssertEqual(d.projects.first?.project, "p")
    }
}
