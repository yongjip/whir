import Testing
import Foundation
@testable import WhirCore

/// Locks in the pricing.json override contract: defensive parsing, provider-safe
/// lookup, newer-asOf-wins, and built-in coverage of the current model lineup.
/// These tests stay on the pure PricingTable layer (plus a rejected apply) so
/// they can't perturb the global table other suites price against.
@Suite struct PricingTableTests {
    private func table(_ json: String) -> PricingTable? { PricingTable.parse(Data(json.utf8)) }

    @Test func parsesValidTable() throws {
        let t = try #require(table("""
        {"version": 1, "asOf": "2026-07-02",
         "claude": [{"prefix": "claude-sonnet-5", "input": 3, "output": 15}],
         "openai": [{"prefix": "gpt-9", "input": 1, "cachedInput": 0.1, "output": 4, "estimate": true}]}
        """))
        #expect(t.asOf == "2026-07-02")
        #expect(t.claudePrice("claude-sonnet-5")?.input == 3)
        #expect(t.claudePrice("claude-sonnet-5")?.output == 15)
        #expect(t.openAIPrice("gpt-9")?.output == 4)
        #expect(t.openAIPrice("gpt-9-mini") == nil)             // distinct model id
        #expect(t.claudePrice("claude-opus-4-8") == nil)        // not in this table
    }

    @Test func rejectsUnusableTables() {
        #expect(table("not json") == nil)
        #expect(table(#"{"version": 2, "asOf": "2026-07-02", "claude": [{"prefix": "c", "input": 1, "output": 2}]}"#) == nil)
        #expect(table(#"{"version": 1, "asOf": "soon", "claude": [{"prefix": "c", "input": 1, "output": 2}]}"#) == nil)
        // all Claude rows malformed → no usable table
        #expect(table(#"{"version": 1, "asOf": "2026-07-02", "claude": [{"prefix": "c", "input": 1}]}"#) == nil)
    }

    @Test func skipsMalformedRowsKeepsGoodOnes() throws {
        let t = try #require(table("""
        {"version": 1, "asOf": "2026-07-02", "claude": [
            {"prefix": "claude-good", "input": 2, "output": 4},
            {"prefix": "", "input": 1, "output": 1},
            {"prefix": "claude-bad", "output": 9}
        ]}
        """))
        #expect(t.claudePrice("claude-good-1")?.input == 2)
        #expect(t.claudePrice("claude-bad-1") == nil)
    }

    @Test func longestPrefixWins() throws {
        let t = try #require(table("""
        {"version": 1, "asOf": "2026-07-02", "claude": [
            {"prefix": "claude-opus-4", "input": 5, "output": 25},
            {"prefix": "claude-opus-4-9", "input": 7, "output": 35}
        ]}
        """))
        #expect(t.claudePrice("claude-opus-4-9")?.input == 7)
        #expect(t.claudePrice("claude-opus-4-8")?.input == 5)
    }

    @Test func openAIUsesExactIDsAndDatedSnapshotFallback() throws {
        let t = try #require(table("""
        {"version": 1, "asOf": "2026-07-12",
         "claude": [{"prefix": "claude-sonnet-5", "input": 3, "output": 15}],
         "openai": [
            {"prefix": "gpt-5", "input": 1.25, "cachedInput": 0.125, "output": 10},
            {"prefix": "gpt-5.6", "input": 5, "cachedInput": 0.5, "output": 30},
            {"prefix": "gpt-5.6-luna", "input": 1, "cachedInput": 0.1, "output": 6}
         ]}
        """))
        #expect(t.openAIPrice("gpt-5.6")?.input == 5)
        #expect(t.openAIPrice("gpt-5.6-luna")?.input == 1)
        #expect(t.openAIPrice("gpt-5.7") == nil)
        #expect(t.openAIPrice("gpt-5.6-2026-07-12")?.input == 5)
        #expect(t.openAIPrice("gpt-5.6-20260712")?.input == 5)
    }

    @Test func builtInCoversCurrentModels() {
        // The screenshot bug: sonnet-5 / fable-5 silently priced at $0.
        #expect(Pricing.builtIn.claudePrice("claude-opus-4-8")?.input == 5)
        #expect(Pricing.builtIn.claudePrice("claude-sonnet-5")?.input == 3)
        #expect(Pricing.builtIn.claudePrice("claude-fable-5")?.input == 10)
        #expect(Pricing.builtIn.claudePrice("claude-haiku-4-5")?.input == 1)
    }

    @Test func olderOverrideIsRejected() throws {
        // Safe to run against the global: a rejected apply never mutates it.
        let old = try #require(table(
            #"{"version": 1, "asOf": "2020-01-01", "claude": [{"prefix": "claude-x", "input": 1, "output": 1}]}"#))
        #expect(Pricing.apply(old) == false)
        #expect(Pricing.claudePrice("claude-x-1") == nil)
    }

    @Test func shippedPricingJSONCoversBuiltInModels() throws {
        // The repo-root pricing.json is what the app fetches. CI auto-syncs it
        // from LiteLLM (scripts/sync_pricing.py), so it may run ahead of the
        // compiled-in table — but it must stay parseable, never be older, and
        // still price every model family the built-in table knows about.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("pricing.json")
        let t = try #require(PricingTable.parse(Data(contentsOf: url)))
        #expect(t.asOf >= Pricing.builtIn.asOf)
        for (prefix, _) in Pricing.builtIn.claude {
            #expect(t.claudePrice(prefix) != nil, "claude \(prefix) unpriced")
        }
        for (prefix, _) in Pricing.builtIn.openai {
            #expect(t.openAIPrice(prefix) != nil, "openai \(prefix) unpriced")
        }
        #expect(t.openAIPrice("gpt-5.6")?.input == 5)
        #expect(t.openAIPrice("gpt-5.6-sol")?.output == 30)
        #expect(t.openAIPrice("gpt-5.6-terra")?.input == 2.5)
        #expect(t.openAIPrice("gpt-5.6-luna")?.output == 6)
    }
}
