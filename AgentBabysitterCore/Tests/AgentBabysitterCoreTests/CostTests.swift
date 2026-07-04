import XCTest
@testable import AgentBabysitterCore

final class PriceTableTests: XCTestCase {

    func testBundledTableLoadsCurrentModels() {
        let table = PriceTable.bundled
        let opus = table.pricing(forModel: "claude-opus-4-8")
        XCTAssertEqual(opus?.inputPerMTok, 5.0)
        XCTAssertEqual(opus?.outputPerMTok, 25.0)
        XCTAssertEqual(opus?.cacheReadPerMTok, 0.5)
        XCTAssertEqual(opus?.cacheWrite5mPerMTok, 6.25)
        XCTAssertEqual(opus?.cacheWrite1hPerMTok, 10.0)

        XCTAssertEqual(table.pricing(forModel: "claude-fable-5")?.inputPerMTok, 10.0)
        XCTAssertEqual(table.pricing(forModel: "claude-haiku-4-5")?.outputPerMTok, 5.0)
    }

    func testDateSuffixedModelIDsResolveToBase() {
        // e.g. "claude-haiku-4-5-20251001" — full IDs carry a date suffix
        XCTAssertEqual(PriceTable.bundled.pricing(forModel: "claude-haiku-4-5-20251001")?.inputPerMTok, 1.0)
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(PriceTable.bundled.pricing(forModel: "claude-future-99"))
        XCTAssertNil(PriceTable.bundled.pricing(forModel: "<synthetic>"))
    }
}

final class CostAccumulatorTests: XCTestCase {

    private func assistantEntry(messageID: String, model: String?,
                                usage: TokenUsage?) -> TranscriptEntry {
        TranscriptEntry(kind: .assistant(AssistantPayload(
            messageID: messageID, model: model, stopReason: .endTurn, usage: usage,
            toolUses: [], hasText: true, hasThinking: false)),
            uuid: nil, timestamp: nil, sessionID: "s", cwd: nil, isSidechain: false)
    }

    func testComputesDollarsWithSeparateCacheRates() {
        var accumulator = CostAccumulator()
        // 1M of each bucket on opus-4-8 → 5 + 25 + 10 (1h write) + 0.5 (read)
        accumulator.consume(assistantEntry(
            messageID: "m1", model: "claude-opus-4-8",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000,
                              cacheCreationInputTokens: 1_000_000,
                              cacheReadInputTokens: 1_000_000,
                              cacheCreation5mTokens: 0,
                              cacheCreation1hTokens: 1_000_000)))
        XCTAssertEqual(accumulator.cost.dollars, 40.5, accuracy: 0.0001)
    }

    func testCacheWriteTTLsArePricedSeparately() {
        var accumulator = CostAccumulator()
        // Half the write tokens at 5m (6.25), half at 1h (10.0)
        accumulator.consume(assistantEntry(
            messageID: "m1", model: "claude-opus-4-8",
            usage: TokenUsage(inputTokens: 0, outputTokens: 0,
                              cacheCreationInputTokens: 2_000_000,
                              cacheReadInputTokens: 0,
                              cacheCreation5mTokens: 1_000_000,
                              cacheCreation1hTokens: 1_000_000)))
        XCTAssertEqual(accumulator.cost.dollars, 16.25, accuracy: 0.0001)
    }

    func testDeduplicatesRepeatedMessageIDs() {
        // One API message arrives as several block-lines with identical usage
        var accumulator = CostAccumulator()
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 0,
                               cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
        for _ in 0..<3 {
            accumulator.consume(assistantEntry(messageID: "m1",
                                               model: "claude-opus-4-8", usage: usage))
        }
        XCTAssertEqual(accumulator.cost.dollars, 5.0, accuracy: 0.0001,
                       "usage must count once per message id, not per line")
    }

    func testUnknownModelFlagsInsteadOfGuessing() {
        var accumulator = CostAccumulator()
        accumulator.consume(assistantEntry(
            messageID: "m1", model: "claude-future-99",
            usage: TokenUsage(inputTokens: 500, outputTokens: 100,
                              cacheCreationInputTokens: 0, cacheReadInputTokens: 0)))
        XCTAssertEqual(accumulator.cost.dollars, 0)
        XCTAssertEqual(accumulator.cost.unknownModels, ["claude-future-99"])
        XCTAssertTrue(accumulator.cost.hasUnknownPricing)
        XCTAssertEqual(accumulator.cost.totalTokens, 600)
    }

    func testSyntheticZeroUsageEntriesAreIgnored() {
        var accumulator = CostAccumulator()
        accumulator.consume(assistantEntry(
            messageID: "m1", model: "<synthetic>",
            usage: TokenUsage(inputTokens: 0, outputTokens: 0,
                              cacheCreationInputTokens: 0, cacheReadInputTokens: 0)))
        XCTAssertEqual(accumulator.cost.dollars, 0)
        XCTAssertFalse(accumulator.cost.hasUnknownPricing,
                       "zero-token synthetic notices should not raise the unknown flag")
    }

    func testNormalTurnFixtureCost() throws {
        // 5 unique claude-fable-5 messages ($10/$50, reads $1, 1h writes $20):
        // input 27,676; output 1,870; 1h cache writes 33,623; reads 176,163
        // = 0.27676 + 0.0935 + 0.67246 + 0.176163 = 1.218883
        let parser = TranscriptTailParser()
        var entries = parser.consume(try fixtureData("normal_turn"))
        if let last = parser.finalize() { entries.append(last) }

        var accumulator = CostAccumulator()
        for entry in entries { accumulator.consume(entry) }
        XCTAssertEqual(accumulator.cost.dollars, 1.218883, accuracy: 0.000001)
        XCTAssertFalse(accumulator.cost.hasUnknownPricing)
    }
}
