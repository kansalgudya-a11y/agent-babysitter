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

    func testFirstClaimWinsAndSecondIsRefused() {
        let claims = MessageIDClaims()
        XCTAssertTrue(claims.claim("msg_1", owner: "sessionA"))
        XCTAssertFalse(claims.claim("msg_1", owner: "sessionB"), "already counted by A")
        XCTAssertFalse(claims.claim("msg_1", owner: "sessionA"), "not even twice by its owner")
        XCTAssertEqual(claims.count, 1)
    }

    func testReleaseLetsTheOwnerCountItsMessagesAgain() {
        let claims = MessageIDClaims()
        XCTAssertTrue(claims.claim("msg_1", owner: "sessionA"))
        claims.release(owner: "sessionA")     // its file shrank → re-read from scratch
        XCTAssertTrue(claims.claim("msg_1", owner: "sessionA"))
        XCTAssertEqual(claims.count, 1)
    }

    func testReleaseOnlyDropsThatOwnersClaims() {
        let claims = MessageIDClaims()
        _ = claims.claim("a", owner: "s1")
        _ = claims.claim("b", owner: "s2")
        claims.release(owner: "s1")
        XCTAssertTrue(claims.claim("a", owner: "s1"), "s1's id is free again")
        XCTAssertFalse(claims.claim("b", owner: "s1"), "s2 still owns b")
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

    func testWithoutSharedClaimsPerFileDedupeStillWorks() {
        var a = CostAccumulator()   // stand-alone (existing behaviour)
        a.consume(assistant("m"))
        a.consume(assistant("m"))   // same id twice in one file → once
        XCTAssertEqual(a.cost.totalTokens, 1_000_000)
    }
}
