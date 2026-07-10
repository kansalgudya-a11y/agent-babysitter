import XCTest
@testable import AgentBabysitterCore

/// Tokens have two honest meanings and the UI must not confuse them:
/// `totalTokens` = NEW WORK (input + output + cache writes) — tokens that
/// existed once, and what a user means by "tokens used". `allTokens` adds
/// cache re-reads: billed volume, but it counts one cached prefix again on
/// every call, so a 400k context over 4,500 calls reads as ~1.8B. Cost counts
/// cache reads; the headline token figure must not.
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

    func testNewWorkExcludesCacheReadsWhileBilledVolumeIncludesThem() {
        var acc = CostAccumulator()
        acc.consume(entry("m", input: 10, output: 20, cacheWrite: 30, cacheRead: 1_000))
        XCTAssertEqual(acc.cost.totalTokens, 60, "new work only")
        XCTAssertEqual(acc.cost.cacheReadTokens, 1_000)
        XCTAssertEqual(acc.cost.allTokens, 1_060, "billed volume, incl. cache re-reads")
        XCTAssertEqual(acc.cost.formattedTokens, "60", "the UI's 'tok' = new work only")
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
