import XCTest
@testable import AgentBabysitterCore

final class ModelNamesTests: XCTestCase {

    func testClaudeIdsPrettified() {
        XCTAssertEqual(ModelNames.pretty("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelNames.pretty("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelNames.pretty("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelNames.pretty("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
    }

    func testOpenAIIdsPrettified() {
        XCTAssertEqual(ModelNames.pretty("gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(ModelNames.pretty("gpt-5.2-codex"), "GPT-5.2 Codex")
        XCTAssertEqual(ModelNames.pretty("gpt-5.1-codex-mini"), "GPT-5.1 Codex Mini")
    }

    func testForeignIdsPassThroughUntouched() {
        XCTAssertEqual(ModelNames.pretty("mistral-large"), "mistral-large")
        XCTAssertEqual(ModelNames.pretty("unknown"), "unknown")
    }
}

final class ModelCostSplitTests: XCTestCase {

    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    private let table = PriceTable(prices: [
        "claude-opus-4-8": ModelPricing(inputPerMTok: 5, outputPerMTok: 25,
                                        cacheReadPerMTok: 0.5,
                                        cacheWrite5mPerMTok: 6.25, cacheWrite1hPerMTok: 10),
        "claude-haiku-4-5": ModelPricing(inputPerMTok: 1, outputPerMTok: 5,
                                         cacheReadPerMTok: 0.1,
                                         cacheWrite5mPerMTok: 1.25, cacheWrite1hPerMTok: 2),
    ])

    private func assistant(model: String, id: String, output: Int,
                           at timestamp: Date) -> TranscriptEntry {
        TranscriptEntry(
            kind: .assistant(AssistantPayload(
                messageID: id, model: model, stopReason: nil,
                usage: TokenUsage(inputTokens: 0, outputTokens: output,
                                  cacheCreationInputTokens: 0, cacheReadInputTokens: 0),
                toolUses: [], hasText: true, hasThinking: false)),
            uuid: nil, timestamp: timestamp, sessionID: nil, cwd: nil, isSidechain: false)
    }

    func testDollarsSplitPerModelPerDay() {
        var accumulator = CostAccumulator(table: table, timeZone: kolkata)
        let noon = Date(timeIntervalSince1970: 1_783_158_000)
        accumulator.consume(assistant(model: "claude-opus-4-8", id: "m1",
                                      output: 1_000_000, at: noon))
        accumulator.consume(assistant(model: "claude-haiku-4-5", id: "m2",
                                      output: 1_000_000, at: noon))
        // Same message id repeated (multi-line write) must not double-count
        accumulator.consume(assistant(model: "claude-opus-4-8", id: "m1",
                                      output: 1_000_000, at: noon))

        let day = LocalDay.start(of: noon, timeZone: kolkata)
        let split = accumulator.dailyDollarsByModel[day] ?? [:]
        XCTAssertEqual(split["claude-opus-4-8"] ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(split["claude-haiku-4-5"] ?? 0, 5, accuracy: 1e-9)
    }

    func testUnknownModelsExcludedFromSplit() {
        var accumulator = CostAccumulator(table: table, timeZone: kolkata)
        let noon = Date(timeIntervalSince1970: 1_783_158_000)
        accumulator.consume(assistant(model: "gpt-5.1-codex", id: "m1",
                                      output: 1_000_000, at: noon))
        XCTAssertTrue(accumulator.dailyDollarsByModel.isEmpty)
        XCTAssertTrue(accumulator.cost.hasUnknownPricing)
    }

    func testLedgerTicksAndSumsModelSplit() {
        var ledger = StatsLedger.ticked(
            .init(), todayKey: "2026-07-06",
            todayCostByAgent: ["claude-code": 30],
            todayCostByModel: ["claude-opus-4-8": 25, "claude-haiku-4-5": 5],
            visibleSessionIDs: ["s1"], anyWorking: false, secondsSinceLastTick: 30)
        XCTAssertEqual(ledger.costByModel["2026-07-06"]?["claude-opus-4-8"], 25)
        // Max-merge within the day: a dip must not shrink the recorded value
        ledger = StatsLedger.ticked(
            ledger, todayKey: "2026-07-06",
            todayCostByAgent: [:], todayCostByModel: ["claude-opus-4-8": 20],
            visibleSessionIDs: [], anyWorking: false, secondsSinceLastTick: 30)
        XCTAssertEqual(ledger.costByModel["2026-07-06"]?["claude-opus-4-8"], 25)

        let summed = StatsLedger.summed([ledger, ledger])
        XCTAssertEqual(summed.costByModel["2026-07-06"]?["claude-opus-4-8"], 50)
    }
}
