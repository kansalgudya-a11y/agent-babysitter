import XCTest
@testable import AgentBabysitterCore

/// Resuming a Claude Code session copies the whole prior conversation — same
/// `message.id`s, same `usage` — into a NEW transcript. Deduping per file bills
/// those API messages twice. These pin the store-wide fix.
final class MessageIDClaimsTests: XCTestCase {

    private func assistant(_ id: String, model: String = "claude-opus-4-8",
                           output: Int = 1_000_000) -> TranscriptEntry {
        let usage = TokenUsage(inputTokens: 0, outputTokens: output,
                               cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
        return TranscriptEntry(kind: .assistant(AssistantPayload(
            messageID: id, model: model, stopReason: .endTurn, usage: usage,
            toolUses: [], hasText: true, hasThinking: false)),
            uuid: nil, timestamp: nil, sessionID: "s", cwd: nil, isSidechain: false)
    }

    func testFirstClaimWinsAndAForeignCopyIsRefused() {
        let claims = MessageIDClaims()
        XCTAssertEqual(claims.claim("msg_1", owner: "sessionA"), .granted)
        XCTAssertEqual(claims.claim("msg_1", owner: "sessionB"), .ownedByOther,
                       "a resumed session's copy must never be billed again")
        XCTAssertEqual(claims.claim("msg_1", owner: "sessionA"), .alreadyOwned,
                       "its owner may revise it (later streaming line), not re-bill it")
        XCTAssertEqual(claims.count, 1)
    }

    func testReleaseLetsTheOwnerCountItsMessagesAgain() {
        let claims = MessageIDClaims()
        XCTAssertEqual(claims.claim("msg_1", owner: "sessionA"), .granted)
        claims.release(owner: "sessionA")     // its file shrank → re-read from scratch
        XCTAssertEqual(claims.claim("msg_1", owner: "sessionA"), .granted)
        XCTAssertEqual(claims.count, 1)
    }

    func testReleaseOnlyDropsThatOwnersClaims() {
        let claims = MessageIDClaims()
        _ = claims.claim("a", owner: "s1")
        _ = claims.claim("b", owner: "s2")
        claims.release(owner: "s1")
        XCTAssertEqual(claims.claim("a", owner: "s1"), .granted, "s1's id is free again")
        XCTAssertEqual(claims.claim("b", owner: "s1"), .ownedByOther, "s2 still owns b")
    }

    /// The real bug: a resumed session's transcript repeats the original's
    /// messages. Two accumulators sharing a registry must bill them once.
    func testResumedSessionDoesNotDoubleBillCopiedConversation() {
        let claims = MessageIDClaims()
        var original = CostAccumulator(claims: claims, owner: "original")
        var resumed = CostAccumulator(claims: claims, owner: "resumed")

        let shared = assistant("msg_copied")
        original.consume(shared)          // original made the API call
        resumed.consume(shared)           // the resume copied it verbatim
        resumed.consume(assistant("msg_new"))

        XCTAssertGreaterThan(original.cost.dollars, 0)
        XCTAssertEqual(resumed.cost.totalTokens, 1_000_000,
                       "resumed counts only its own new message, not the copy")
        let total = original.cost.dollars + resumed.cost.dollars
        // 2M output tokens @ $25/Mtok = $50 — NOT $75 (which is what per-file
        // dedupe produced: the copied message billed to both files).
        XCTAssertEqual(total, 50, accuracy: 0.01)
    }

    /// An entry with no timestamp can't be attributed to a day; charging it to
    /// "now" would move an old session's spend into today.
    func testUndatedEntryCountsInTheSessionTotalButNotInAnyDay() {
        var acc = CostAccumulator()
        acc.consume(assistant("m"))            // fixture carries timestamp: nil
        XCTAssertGreaterThan(acc.cost.dollars, 0, "still part of the session's total")
        XCTAssertTrue(acc.dailyCosts.isEmpty, "must not be charged to today")
        XCTAssertTrue(acc.dailyDollarsByModel.isEmpty)
    }

    func testWithoutSharedClaimsPerFileDedupeStillWorks() {
        var a = CostAccumulator()   // stand-alone (existing behaviour)
        a.consume(assistant("m"))
        a.consume(assistant("m"))   // identical repeat of one message → billed once
        XCTAssertEqual(a.cost.totalTokens, 1_000_000)
    }

    /// Claude Code streams one assistant message as several lines whose usage
    /// GROWS (`output_tokens: 1` … then the real figure). The last line is the
    /// bill; keeping the first under-counted every streamed message.
    func testLaterStreamingLineRevisesTheMessageUpward() {
        var a = CostAccumulator()
        a.consume(assistant("m", output: 1))
        a.consume(assistant("m", output: 1_000_000))
        XCTAssertEqual(a.cost.outputTokens, 1_000_000, "final usage, not the first snapshot")
        XCTAssertEqual(a.cost.dollars, 25, accuracy: 0.01, "billed once, at the final figure")
    }

    func testARevisionNeverShrinksTheBill() {
        var a = CostAccumulator()
        a.consume(assistant("m", output: 1_000_000))
        a.consume(assistant("m", output: 1))     // a stale/smaller line must not reduce it
        XCTAssertEqual(a.cost.outputTokens, 1_000_000)
    }

    /// A foreign copy must not revise ours either — it's the same final usage.
    func testResumedCopyCannotReviseTheOriginal() {
        let claims = MessageIDClaims()
        var original = CostAccumulator(claims: claims, owner: "original")
        var resumed = CostAccumulator(claims: claims, owner: "resumed")
        original.consume(assistant("m", output: 1_000_000))
        resumed.consume(assistant("m", output: 1_000_000))
        XCTAssertEqual(resumed.cost.totalTokens, 0)
        XCTAssertEqual(original.cost.dollars + resumed.cost.dollars, 25, accuracy: 0.01)
    }
}
