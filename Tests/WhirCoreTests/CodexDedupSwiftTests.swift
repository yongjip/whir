import Testing
import Foundation
@testable import WhirCore

// Swift Testing suite locking in the Codex token accounting invariants that
// recent fixes established: a forked session replays its parent's token_count
// history (must not be double-counted), and Codex sometimes re-emits the exact
// same snapshot back-to-back (must be counted once). Parameterized so each
// scenario is an independent, named case. The XCTest suite (CodexForkTests)
// stays as-is; this is the additive Swift Testing coverage.

// MARK: - line builders

private func tc(_ ts: String, _ i: Int, _ c: Int, _ o: Int) -> String {
    "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(i),\"cached_input_tokens\":\(c),\"output_tokens\":\(o)}}}}"
}
private func meta(_ id: String, forkedFrom: String? = nil) -> String {
    let fk = forkedFrom.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
    return "{\"timestamp\":\"2026-06-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"\(id)\"\(fk),\"cwd\":\"/x/proj\"}}"
}
private let ctx = "{\"timestamp\":\"2026-06-01T00:00:01.000Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"cwd\":\"/x/proj\"}}"

// MARK: - scenario model

struct RolloutFile: Sendable { let name: String; let lines: [String] }

struct CodexScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let files: [RolloutFile]
    let input: Int, cached: Int, output: Int
    var testDescription: String { name }

    static let all: [CodexScenario] = [
        // A forked session replays the parent's two events (re-stamped to fork time)
        // and adds one genuinely new turn. Only parent + the new turn should count.
        CodexScenario(
            name: "fork replay is not double-counted",
            files: [
                RolloutFile(name: "rollout-2026-06-01T00-00-00-parentaaa.jsonl", lines: [
                    meta("parentaaa"), ctx,
                    tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
                    tc("2026-06-01T00:00:03.000Z", 200, 100, 20),
                ]),
                RolloutFile(name: "rollout-2026-06-30T00-00-00-forkbbbb.jsonl", lines: [
                    meta("forkbbbb", forkedFrom: "parentaaa"), ctx,
                    tc("2026-06-30T00:00:00.101Z", 100, 50, 10),   // replay
                    tc("2026-06-30T00:00:00.102Z", 200, 100, 20),  // replay
                    tc("2026-06-30T00:00:05.000Z", 500, 0, 50),    // new
                ]),
            ],
            input: 800, cached: 150, output: 80
        ),
        // No discoverable parent → nothing is skipped (no false dedup).
        CodexScenario(
            name: "non-fork session is counted in full",
            files: [
                RolloutFile(name: "rollout-2026-06-01T00-00-00-soloccccc.jsonl", lines: [
                    meta("soloccccc"), ctx,
                    tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
                    tc("2026-06-01T00:00:03.000Z", 200, 100, 20),
                ]),
            ],
            input: 300, cached: 150, output: 30
        ),
        // A consecutive duplicate snapshot drops; a later identical-valued snapshot
        // with a NEW timestamp is a real turn and is kept.
        CodexScenario(
            name: "consecutive duplicate drops, same-value new-timestamp kept",
            files: [
                RolloutFile(name: "rollout-2026-06-01T00-00-00-dupzzzzzz.jsonl", lines: [
                    meta("dupzzzzzz"), ctx,
                    tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
                    tc("2026-06-01T00:00:02.000Z", 100, 50, 10),   // exact consecutive dup → drop
                    tc("2026-06-01T00:00:03.000Z", 200, 100, 20),
                    tc("2026-06-01T00:00:04.000Z", 100, 50, 10),   // same values, new ts → keep
                ]),
            ],
            input: 400, cached: 200, output: 40
        ),
        // Three identical back-to-back snapshots collapse to one.
        CodexScenario(
            name: "triple consecutive identical collapses to one",
            files: [
                RolloutFile(name: "rollout-2026-06-01T00-00-00-tripleeee.jsonl", lines: [
                    meta("tripleeee"), ctx,
                    tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
                    tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
                    tc("2026-06-01T00:00:02.000Z", 100, 50, 10),
                    tc("2026-06-01T00:00:03.000Z", 200, 100, 20),
                ]),
            ],
            input: 300, cached: 150, output: 30
        ),
    ]
}

@Suite("Codex dedup & fork invariants")
struct CodexDedupSwiftTests {
    @Test("aggregated tokens match expected", arguments: CodexScenario.all)
    func aggregates(_ s: CodexScenario) async throws {
        let dir = NSTemporaryDirectory() + "whir-swifttest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for f in s.files {
            try (f.lines.joined(separator: "\n") + "\n").write(toFile: dir + "/" + f.name, atomically: true, encoding: .utf8)
        }

        var aggs: [String: FileAgg] = [:]
        await CodexAdapter(root: dir).update(&aggs, window: .all)

        var i = 0, c = 0, o = 0
        for fa in aggs.values { for t in fa.models.values { i += t.input; c += t.cachedInput; o += t.output } }
        #expect(i == s.input, "input tokens")
        #expect(c == s.cached, "cached tokens")
        #expect(o == s.output, "output tokens")
    }
}
