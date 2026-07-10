import XCTest
@testable import AgentBabysitterCore

/// The displayed token figure must be every token the API processed. Cache
/// reads are ~90%+ of real volume, so omitting them under-reports by an order
/// of magnitude against `/cost` and the usage console.
final class TokenAccuracyTests: XCTestCase {

    private func entry(_ id: String, input: Int = 0, output: Int = 0,
                       cacheWrite: Int = 0, cacheRead: Int = 0) -> TranscriptEntry {
        let usage = TokenUsage(inputTokens: input, outputTokens: output,
                               cacheCreationInputTokens: cacheWrite,
                               cacheReadInputTokens: cacheRead)
        return TranscriptEntry(kind: .assistant(AssistantPayload(
            messageID: id, model: "claude-opus-4-8", stopReason: .endTurn, usage: usage,
            toolUses: [], hasText: true, hasThinking: false)),
            uuid: nil, timestamp: nil, sessionID: "s", cwd: nil, isSidechain: false)
    }

    func testAllTokensIncludesCacheReads() {
        var acc = CostAccumulator()
        acc.consume(entry("m", input: 10, output: 20, cacheWrite: 30, cacheRead: 1_000))
        XCTAssertEqual(acc.cost.totalTokens, 60, "new work only")
        XCTAssertEqual(acc.cost.cacheReadTokens, 1_000)
        XCTAssertEqual(acc.cost.allTokens, 1_060, "what the UI shows as 'tok'")
        XCTAssertEqual(acc.cost.formattedAllTokens, "1k")
    }

    /// A message that is nothing but cache reads still costs money; the old
    /// `totalTokens > 0` guard threw it away entirely.
    func testPureCacheReadMessageIsBilledNotDropped() {
        var acc = CostAccumulator()
        acc.consume(entry("m", cacheRead: 10_000_000))   // 10M @ $0.50/Mtok = $5
        XCTAssertEqual(acc.cost.cacheReadTokens, 10_000_000)
        XCTAssertEqual(acc.cost.dollars, 5, accuracy: 0.001, "cache reads are billed")
        XCTAssertEqual(acc.cost.allTokens, 10_000_000)
    }

    func testTrulyEmptyUsageIsStillIgnored() {
        var acc = CostAccumulator()
        acc.consume(entry("m"))   // all zeros — a <synthetic> no-op
        XCTAssertEqual(acc.cost.allTokens, 0)
        XCTAssertEqual(acc.cost.dollars, 0)
    }

    /// Sub-agent spend must land in the same totals as the main agent's.
    func testSubAgentEntriesAreCountedLikeAnyOther() {
        var acc = CostAccumulator()
        let sub = TranscriptEntry(kind: .assistant(AssistantPayload(
            messageID: "sub", model: "claude-opus-4-8", stopReason: .endTurn,
            usage: TokenUsage(inputTokens: 0, outputTokens: 1_000_000,
                              cacheCreationInputTokens: 0, cacheReadInputTokens: 0),
            toolUses: [], hasText: true, hasThinking: false)),
            uuid: nil, timestamp: nil, sessionID: "s", cwd: nil, isSidechain: true)
        acc.consume(sub)
        XCTAssertEqual(acc.cost.dollars, 25, accuracy: 0.01,
                       "a parallel sub-agent's tokens cost real money")
    }
}
