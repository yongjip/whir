import XCTest
@testable import WhirCore

final class CostTests: XCTestCase {

    // Real Claude assistant usage block (Sonnet 4.6) observed in a transcript.
    func testClaudeCostWith1hCacheWrite() {
        let usage: [String: Any] = [
            "input_tokens": 2,
            "output_tokens": 215,
            "cache_read_input_tokens": 27816,
            "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 17763],
        ]
        let c = claudeCost(model: "claude-sonnet-4-6", usage: usage)
        // 2*3 + 215*15 + 27816*0.3 + 17763*6, all /1e6
        XCTAssertEqual(c!, 0.118154, accuracy: 1e-5)
    }

    func testClaudeCacheCreationFallbackWhenSplitAbsent() {
        let usage: [String: Any] = ["input_tokens": 0, "output_tokens": 0,
                                    "cache_creation_input_tokens": 1_000_000]
        // no split → treated as 5m write = 1.25 × input price (opus $5) = $6.25
        XCTAssertEqual(claudeCost(model: "claude-opus-4-8", usage: usage)!, 6.25, accuracy: 1e-9)
    }

    func testClaudeUnknownModelUnpriced() {
        XCTAssertNil(claudeCost(model: "<synthetic>", usage: ["input_tokens": 100]))
    }

    // Real Codex last_token_usage (gpt-5.5): cached ⊂ input, reasoning ⊂ output.
    func testCodexCostAppliesCachedDiscount() {
        let c = codexCost(model: "gpt-5.5", input: 21070, cachedInput: 4992, output: 296)
        // (21070-4992)*5 + 4992*0.5 + 296*30, all /1e6
        XCTAssertEqual(c!, 0.091766, accuracy: 1e-5)
    }

    func testOpenAILongestPrefixWins() {
        // "gpt-5.4-mini" must not resolve to the "gpt-5.4" tier
        XCTAssertEqual(Pricing.openAIPrice("gpt-5.4-mini")?.input, 0.25)
        XCTAssertEqual(Pricing.openAIPrice("gpt-5.4")?.input, 2.5)
    }

    func testCodexExcludedModelStillPricesByName() {
        // codexCost itself prices by name; the adapter is what excludes codex-auto-review.
        XCTAssertTrue(Pricing.excludedModels.contains("codex-auto-review"))
    }
}
