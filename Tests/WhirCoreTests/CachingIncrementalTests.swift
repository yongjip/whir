import XCTest
@testable import WhirCore

// Closes the caching-correctness coverage gaps: the existing IncrementalTests
// only prove incremental == full for the Claude TOTALS path. These prove it for
// the Codex totals path (incl. a fork resumed across the boundary) and for the
// all-time hour-bucketed HISTORY path (ClaudeHistory / CodexHistory), which have
// their own copies of the cursor logic.
final class CachingIncrementalTests: XCTestCase {

    private func tmpDir() -> String {
        let d = NSTemporaryDirectory() + "whir-cache-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private func mkdir(_ p: String) { try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
    private func write(_ s: String, to path: String) { try! (s).write(toFile: path, atomically: true, encoding: .utf8) }
    private func append(_ s: String, to path: String) {
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile(); fh.write(Data(s.utf8)); try? fh.close()
    }
    private func jsonLine(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) + "\n"
    }
    private func claude(_ ts: String, req: String, model: String, input: Int, output: Int) -> String {
        jsonLine(["type": "assistant", "timestamp": ts, "requestId": req, "cwd": "/x/proj",
                  "message": ["model": model, "usage": ["input_tokens": input, "output_tokens": output]]])
    }
    private func ctx(_ model: String) -> String {
        jsonLine(["type": "turn_context", "payload": ["type": "turn_context", "model": model, "cwd": "/x/proj"]])
    }
    private func tok(_ ts: String, _ input: Int, _ cached: Int, _ output: Int) -> String {
        jsonLine(["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count",
                  "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]]]])
    }
    private func meta(_ id: String, forkedFrom: String? = nil) -> String {
        var payload: [String: Any] = ["session_id": id, "cwd": "/x/proj"]
        if let f = forkedFrom { payload["forked_from_id"] = f }
        return jsonLine(["type": "session_meta", "timestamp": "2026-06-15T00:00:00Z", "payload": payload])
    }

    private func sumFiles(_ aggs: [String: FileAgg]) -> (Int, Int, Int) {
        var i = 0, c = 0, o = 0
        for fa in aggs.values { for t in fa.models.values { i += t.input; c += t.cachedInput; o += t.output } }
        return (i, c, o)
    }
    private func sumHours(_ aggs: [String: HourAgg]) -> (Int, Int, Int) {
        var i = 0, c = 0, o = 0
        for a in aggs.values { for bd in a.buckets.values { for t in bd.models.values { i += t.input; c += t.cachedInput; o += t.output } } }
        return (i, c, o)
    }

    // MARK: - Codex totals: incremental == full

    func testCodexIncrementalEqualsFull() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = root + "/2026/06/15"; mkdir(dir)
        let file = dir + "/rollout-2026-06-15-aaa.jsonl"
        write(ctx("gpt-5.5") + tok("2026-06-15T00:00:02Z", 1000, 200, 50), to: file)

        var inc: [String: FileAgg] = [:]
        let ad = CodexAdapter(root: root)
        await ad.update(&inc, window: .all)
        append(tok("2026-06-15T00:00:03Z", 2000, 500, 80), to: file)
        await ad.update(&inc, window: .all)

        var full: [String: FileAgg] = [:]
        await CodexAdapter(root: root).update(&full, window: .all)

        XCTAssertEqual(sumFiles(inc).0, sumFiles(full).0)
        XCTAssertEqual(sumFiles(inc).0, 3000, "codex incremental should total 3000 input")
        XCTAssertEqual(sumFiles(inc).1, 700)
        XCTAssertEqual(sumFiles(inc).2, 130)
    }

    // MARK: - Codex fork resumed across the boundary: incremental == full

    // The fork's replayed parent prefix is skipped only on the offset-0 scan; a
    // post-fork turn appended later (offset>0, no skipper) must still be counted,
    // and match a from-scratch scan of the final file.
    func testCodexForkIncrementalEqualsFull() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let pDir = root + "/2026/06/15"; mkdir(pDir)
        let fDir = root + "/2026/06/16"; mkdir(fDir)
        let parent = pDir + "/rollout-2026-06-15-parentaaa.jsonl"
        let fork = fDir + "/rollout-2026-06-16-forkbbbb.jsonl"
        // parent: 100/50/10 + 200/100/20  → 300/150/30
        write(meta("parentaaa") + ctx("gpt-5.5")
              + tok("2026-06-15T00:00:02Z", 100, 50, 10)
              + tok("2026-06-15T00:00:03Z", 200, 100, 20), to: parent)
        // fork: replays the two parent events (re-stamped), no new turn yet
        write(meta("forkbbbb", forkedFrom: "parentaaa") + ctx("gpt-5.5")
              + tok("2026-06-16T00:00:00.1Z", 100, 50, 10)
              + tok("2026-06-16T00:00:00.2Z", 200, 100, 20), to: fork)

        var inc: [String: FileAgg] = [:]
        let ad = CodexAdapter(root: root)
        await ad.update(&inc, window: .all)                 // fork replay skipped → only parent counts
        append(tok("2026-06-16T00:00:05Z", 500, 0, 50), to: fork)   // genuinely new post-fork turn
        await ad.update(&inc, window: .all)

        var full: [String: FileAgg] = [:]
        await CodexAdapter(root: root).update(&full, window: .all)

        // parent 300/150/30 + fork's NEW 500/0/50 (replay skipped both times)
        XCTAssertEqual(sumFiles(inc).0, 800, "1100 would mean the fork replay was double-counted")
        XCTAssertEqual(sumFiles(inc).1, 150)
        XCTAssertEqual(sumFiles(inc).2, 80)
        XCTAssertEqual(sumFiles(inc).0, sumFiles(full).0, "codex fork incremental must equal a full scan")
        XCTAssertEqual(sumFiles(inc).1, sumFiles(full).1)
        XCTAssertEqual(sumFiles(inc).2, sumFiles(full).2)
    }

    // MARK: - History (hour-bucketed) path: incremental == full

    func testClaudeHistoryIncrementalEqualsFull() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let proj = root + "/proj"; mkdir(proj)
        let file = proj + "/a.jsonl"
        write(claude("2026-06-15T01:00:00Z", req: "r1", model: "claude-opus-4-8", input: 100, output: 50), to: file)

        var inc: [String: HourAgg] = [:]
        await ClaudeHistory.update(&inc, root: root, keyer: HourKeyer())
        append(claude("2026-06-15T02:00:00Z", req: "r2", model: "claude-opus-4-8", input: 200, output: 60), to: file)
        await ClaudeHistory.update(&inc, root: root, keyer: HourKeyer())

        var full: [String: HourAgg] = [:]
        await ClaudeHistory.update(&full, root: root, keyer: HourKeyer())

        XCTAssertEqual(sumHours(inc).0, 300, "claude history incremental input")
        XCTAssertEqual(sumHours(inc).2, 110)
        XCTAssertEqual(sumHours(inc).0, sumHours(full).0, "claude history incremental must equal full")
        XCTAssertEqual(sumHours(inc).2, sumHours(full).2)
    }

    func testCodexHistoryIncrementalEqualsFull() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = root + "/2026/06/15"; mkdir(dir)
        let file = dir + "/rollout-2026-06-15-aaa.jsonl"
        write(ctx("gpt-5.5") + tok("2026-06-15T01:00:02Z", 1000, 200, 50), to: file)

        var inc: [String: HourAgg] = [:]
        await CodexHistory.update(&inc, root: root, keyer: HourKeyer())
        append(tok("2026-06-15T02:00:03Z", 2000, 500, 80), to: file)   // no new turn_context
        await CodexHistory.update(&inc, root: root, keyer: HourKeyer())

        var full: [String: HourAgg] = [:]
        await CodexHistory.update(&full, root: root, keyer: HourKeyer())

        XCTAssertEqual(sumHours(inc).0, 3000, "codex history incremental input (model must carry across resume)")
        XCTAssertEqual(sumHours(inc).0, sumHours(full).0, "codex history incremental must equal full")
        XCTAssertEqual(sumHours(inc).1, sumHours(full).1)
        XCTAssertEqual(sumHours(inc).2, sumHours(full).2)
        XCTAssertNil(inc.values.first(where: { $0.buckets.values.contains { $0.models["unknown"] != nil } }),
                     "model must carry across the resume boundary in the history path too")
    }

    // A scan that catches a fork mid-replay (parent history not fully flushed
    // yet) must not advance the cursor — else the rest of the replay is counted
    // as real usage on the next scan (ccusage #897 class of double-count).
    func testForkMidReplayNotDoubleCounted() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let pDir = root + "/2026/06/15"; mkdir(pDir)
        let fDir = root + "/2026/06/16"; mkdir(fDir)
        let parent = pDir + "/rollout-2026-06-15-parentaaa.jsonl"
        let fork = fDir + "/rollout-2026-06-16-forkbbbb.jsonl"
        // parent: three turns → 600/150/60
        write(meta("parentaaa") + ctx("gpt-5.5")
              + tok("2026-06-15T00:00:02Z", 100, 50, 10)
              + tok("2026-06-15T00:00:03Z", 200, 100, 20)
              + tok("2026-06-15T00:00:04Z", 300, 0, 30), to: parent)
        // fork so far replayed ONLY the first parent event (mid-replay)
        write(meta("forkbbbb", forkedFrom: "parentaaa") + ctx("gpt-5.5")
              + tok("2026-06-16T00:00:00.1Z", 100, 50, 10), to: fork)

        var inc: [String: FileAgg] = [:]
        let ad = CodexAdapter(root: root)
        await ad.update(&inc, window: .all)                      // parent counted; fork left at 0 (mid-replay)
        XCTAssertEqual(sumFiles(inc).0, 600, "only the parent should count while the fork is mid-replay")

        // Codex flushes the rest of the replay + one genuinely new turn.
        append(tok("2026-06-16T00:00:00.2Z", 200, 100, 20)
             + tok("2026-06-16T00:00:00.3Z", 300, 0, 30)
             + tok("2026-06-16T00:00:05Z", 500, 0, 50), to: fork)
        await ad.update(&inc, window: .all)

        var full: [String: FileAgg] = [:]
        await CodexAdapter(root: root).update(&full, window: .all)

        // parent 600/150/60 + fork's ONE new turn 500/0/50 = 1100/150/110
        XCTAssertEqual(sumFiles(inc).0, 1100, "1600 would mean the mid-replay remainder was double-counted")
        XCTAssertEqual(sumFiles(inc).1, 150)
        XCTAssertEqual(sumFiles(inc).2, 110)
        XCTAssertEqual(sumFiles(inc).0, sumFiles(full).0, "incremental must equal a full scan")
    }

    // A granted root that becomes unreadable (moved / access lost) must NOT wipe
    // the cached aggregates — that would force a multi-GB rescan on recovery.
    func testUnreadableRootPreservesCache() async {
        let root = tmpDir()
        let dir = root + "/2026/06/15"; mkdir(dir)
        write(ctx("gpt-5.5") + tok("2026-06-15T00:00:02Z", 1000, 200, 50),
              to: dir + "/rollout-2026-06-15-aaa.jsonl")
        var aggs: [String: FileAgg] = [:]
        let ad = CodexAdapter(root: root)
        await ad.update(&aggs, window: .all)
        XCTAssertEqual(sumFiles(aggs).0, 1000)

        try? FileManager.default.removeItem(atPath: root)   // root now unreadable
        await ad.update(&aggs, window: .all)
        XCTAssertEqual(sumFiles(aggs).0, 1000, "unreadable root must preserve the cache, not wipe it")

        // Same guarantee on the single-root Claude path.
        let croot = tmpDir()
        let proj = croot + "/proj"; mkdir(proj)
        write(claude("2026-06-15T01:00:00Z", req: "r1", model: "claude-opus-4-8", input: 100, output: 50),
              to: proj + "/a.jsonl")
        var cggs: [String: FileAgg] = [:]
        let cad = ClaudeAdapter(root: croot)
        await cad.update(&cggs, window: .all)
        XCTAssertEqual(sumFiles(cggs).0, 100)
        try? FileManager.default.removeItem(atPath: croot)
        await cad.update(&cggs, window: .all)
        XCTAssertEqual(sumFiles(cggs).0, 100, "unreadable Claude root must preserve the cache")
    }
}
