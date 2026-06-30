import XCTest
@testable import WhirCore

final class CodexForkTests: XCTestCase {
    private func tc(_ ts: String, _ i: Int, _ c: Int, _ o: Int) -> String {
        "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(i),\"cached_input_tokens\":\(c),\"output_tokens\":\(o)}}}}"
    }
    private func write(_ dir: String, _ name: String, _ lines: [String]) {
        try! (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }
    private func sum(_ aggs: [String: FileAgg]) -> (Int, Int, Int) {
        var i = 0, c = 0, o = 0
        for fa in aggs.values { for t in fa.models.values { i += t.input; c += t.cachedInput; o += t.output } }
        return (i, c, o)
    }

    // A forked session replays the parent's token_count history; that inherited
    // prefix must not be double-counted.
    func testForkPrefixDeduped() {
        let dir = NSTemporaryDirectory() + "whir-fork-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let ctx = "{\"timestamp\":\"2026-06-01T00:00:01.000Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"cwd\":\"/x/proj\"}}"
        // parent: 100/50/10 + 200/100/20  → input 300, cached 150, output 30
        write(dir, "rollout-2026-06-01T00-00-00-parentaaa.jsonl", [
            "{\"timestamp\":\"2026-06-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"parentaaa\",\"cwd\":\"/x/proj\"}}",
            ctx,
            tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
            tc("2026-06-01T00:00:03.000Z", 200, 100, 20),
        ])
        // fork: replays the two parent events (re-stamped) + one new 500/0/50
        write(dir, "rollout-2026-06-30T00-00-00-forkbbbb.jsonl", [
            "{\"timestamp\":\"2026-06-30T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"forkbbbb\",\"forked_from_id\":\"parentaaa\",\"cwd\":\"/x/proj\"}}",
            ctx,
            tc("2026-06-30T00:00:00.101Z", 100, 50, 10),   // replay
            tc("2026-06-30T00:00:00.102Z", 200, 100, 20),  // replay
            tc("2026-06-30T00:00:05.000Z", 500, 0, 50),    // genuinely new
        ])

        var aggs: [String: FileAgg] = [:]
        CodexAdapter(root: dir).update(&aggs, window: .all)
        let (i, c, o) = sum(aggs)
        // deduped: parent 300/150/30 + fork's NEW 500/0/50 only (replay skipped).
        XCTAssertEqual(i, 800, "input should be 800 (1100 would mean the fork replay was double-counted)")
        XCTAssertEqual(c, 150)
        XCTAssertEqual(o, 80)
    }

    // Without a discoverable parent, nothing is skipped (no false dedup).
    func testNonForkNotSkipped() {
        let dir = NSTemporaryDirectory() + "whir-fork-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = "{\"timestamp\":\"2026-06-01T00:00:01.000Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"cwd\":\"/x/proj\"}}"
        write(dir, "rollout-2026-06-01T00-00-00-soloccccc.jsonl", [
            "{\"timestamp\":\"2026-06-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"soloccccc\",\"cwd\":\"/x/proj\"}}",
            ctx,
            tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
            tc("2026-06-01T00:00:03.000Z", 200, 100, 20),
        ])
        var aggs: [String: FileAgg] = [:]
        CodexAdapter(root: dir).update(&aggs, window: .all)
        let (i, c, o) = sum(aggs)
        XCTAssertEqual(i, 300); XCTAssertEqual(c, 150); XCTAssertEqual(o, 30)
    }
}
