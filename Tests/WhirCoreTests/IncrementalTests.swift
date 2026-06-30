import XCTest
@testable import WhirCore

final class IncrementalTests: XCTestCase {

    private func tmpDir() -> String {
        let d = NSTemporaryDirectory() + "urtest-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private func append(_ s: String, to path: String) {
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile(); fh.write(Data((s + "\n").utf8)); try? fh.close()
    }
    private func jsonLine(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
    private func claude(req: String, model: String, input: Int, output: Int) -> String {
        jsonLine(["type": "assistant", "timestamp": "2026-06-15T00:00:00Z", "requestId": req, "cwd": "/x/proj",
                  "message": ["model": model, "usage": ["input_tokens": input, "output_tokens": output]]])
    }
    private func codexCtx(_ model: String) -> String {
        jsonLine(["type": "turn_context", "payload": ["type": "turn_context", "model": model]])
    }
    private func codexTok(input: Int, cached: Int, output: Int) -> String {
        jsonLine(["type": "event_msg", "payload": ["type": "token_count",
                  "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]]]])
    }

    // Incremental (read 1 line, append 1, read again) must equal a from-scratch scan.
    func testClaudeIncrementalEqualsFull() {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let proj = root + "/proj"; try! FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        let file = proj + "/a.jsonl"
        try! (claude(req: "r1", model: "claude-opus-4-8", input: 100, output: 50) + "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)

        var aggs: [String: FileAgg] = [:]
        let ad = ClaudeAdapter(root: root)
        ad.update(&aggs, window: .all)
        append(claude(req: "r2", model: "claude-opus-4-8", input: 200, output: 60), to: file)
        ad.update(&aggs, window: .all)
        let incremental = UsageReport.build(from: aggs)

        var fresh: [String: FileAgg] = [:]
        ClaudeAdapter(root: root).update(&fresh, window: .all)
        let full = UsageReport.build(from: fresh)

        XCTAssertEqual(incremental.totalCost, full.totalCost, accuracy: 1e-9)
        let line = incremental.models.first { $0.provider == .claude }!
        XCTAssertEqual(line.tokens.input, 300)
        XCTAssertEqual(line.tokens.output, 110)
    }

    // A retried requestId split across the resume boundary is counted once.
    func testClaudeDedupAcrossResume() {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let proj = root + "/proj"; try! FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        let file = proj + "/a.jsonl"
        let dup = claude(req: "rDUP", model: "claude-opus-4-8", input: 100, output: 50)
        try! (dup + "\n").write(toFile: file, atomically: true, encoding: .utf8)

        var aggs: [String: FileAgg] = [:]
        let ad = ClaudeAdapter(root: root)
        ad.update(&aggs, window: .all)
        append(dup, to: file)            // same requestId again
        ad.update(&aggs, window: .all)

        let line = UsageReport.build(from: aggs).models.first { $0.provider == .claude }!
        XCTAssertEqual(line.tokens.input, 100, "duplicate requestId must not double-count")
    }

    // Codex model from turn_context must carry over when the resumed bytes have none.
    func testCodexModelCarriesAcrossResume() {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sessions = root + "/sessions"
        let dateDir = sessions + "/2026/06/15"
        try! FileManager.default.createDirectory(atPath: dateDir, withIntermediateDirectories: true)
        let file = dateDir + "/rollout-x.jsonl"
        try! (codexCtx("gpt-5.5") + "\n" + codexTok(input: 1000, cached: 200, output: 50) + "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)

        var aggs: [String: FileAgg] = [:]
        let ad = CodexAdapter(root: sessions)
        ad.update(&aggs, window: .all)
        append(codexTok(input: 2000, cached: 500, output: 80), to: file)   // no new turn_context
        ad.update(&aggs, window: .all)

        let r = UsageReport.build(from: aggs)
        XCTAssertNil(r.models.first { $0.model == "unknown" }, "model must carry across resume")
        let line = r.models.first { $0.model == "gpt-5.5" }
        XCTAssertEqual(line?.tokens.input, 3000)
    }

    // A complete record without its trailing newline yet (mid-write) must not be
    // counted now and again once the newline arrives. (Codex has no requestId dedup.)
    func testUnterminatedLineNotDoubleCounted() {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sessions = root + "/sessions"
        let dateDir = sessions + "/2026/06/15"
        try! FileManager.default.createDirectory(atPath: dateDir, withIntermediateDirectories: true)
        let file = dateDir + "/rollout-x.jsonl"
        // turn_context terminated; token_count NOT yet newline-terminated
        try! (codexCtx("gpt-5.5") + "\n" + codexTok(input: 1000, cached: 0, output: 0))
            .write(toFile: file, atomically: true, encoding: .utf8)

        var aggs: [String: FileAgg] = [:]
        let ad = CodexAdapter(root: sessions)
        ad.update(&aggs, window: .all)
        // the unterminated token_count must not have been counted yet
        XCTAssertNil(UsageReport.build(from: aggs).models.first { $0.model == "gpt-5.5" })

        // complete it (add newline) and append a new unterminated record
        append("", to: file)                                  // adds the missing "\n"
        let fh = FileHandle(forWritingAtPath: file)!
        fh.seekToEndOfFile(); fh.write(Data(codexTok(input: 2000, cached: 0, output: 0).utf8)); try? fh.close()
        ad.update(&aggs, window: .all)

        let line = UsageReport.build(from: aggs).models.first { $0.model == "gpt-5.5" }
        XCTAssertEqual(line?.tokens.input, 1000, "completed record counted exactly once; pending one not yet")
    }

    // In-place edit preserving byte length (same inode, same size, new mtime) must re-read.
    func testInPlaceSameLengthEditReread() {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let proj = root + "/proj"; try! FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        let file = proj + "/a.jsonl"
        let a = claude(req: "rA", model: "claude-opus-4-8", input: 100, output: 50)
        let b = claude(req: "rB", model: "claude-opus-4-8", input: 200, output: 50)  // same byte length
        XCTAssertEqual(a.utf8.count, b.utf8.count, "fixture must be equal length")
        try! (a + "\n").write(toFile: file, atomically: true, encoding: .utf8)

        var aggs: [String: FileAgg] = [:]
        ClaudeAdapter(root: root).update(&aggs, window: .all)
        // overwrite in place (same inode, same size, newer mtime)
        let fh = FileHandle(forWritingAtPath: file)!
        fh.seek(toFileOffset: 0); fh.write(Data((b + "\n").utf8)); try? fh.close()
        ClaudeAdapter(root: root).update(&aggs, window: .all)

        let line = UsageReport.build(from: aggs).models.first { $0.provider == .claude }!
        XCTAssertEqual(line.tokens.input, 200, "in-place same-length edit must reset, not keep stale or double")
    }

    // Truncation/rotation (smaller file, new identity) re-reads from 0 without double-counting.
    func testRewriteResetsFile() {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let proj = root + "/proj"; try! FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        let file = proj + "/a.jsonl"
        try! (claude(req: "r1", model: "claude-opus-4-8", input: 999, output: 1) + "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)
        var aggs: [String: FileAgg] = [:]
        ClaudeAdapter(root: root).update(&aggs, window: .all)
        // overwrite with a smaller, different file
        try! (claude(req: "r9", model: "claude-opus-4-8", input: 5, output: 5) + "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)
        ClaudeAdapter(root: root).update(&aggs, window: .all)
        let line = UsageReport.build(from: aggs).models.first { $0.provider == .claude }!
        XCTAssertEqual(line.tokens.input, 5, "rewritten file must reset, not accumulate")
    }
}
