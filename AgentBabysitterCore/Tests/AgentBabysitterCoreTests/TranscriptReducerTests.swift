import XCTest
@testable import AgentBabysitterCore

final class TranscriptReducerTests: XCTestCase {

    private func entry(_ kind: TranscriptEntry.Kind, at seconds: TimeInterval = 0) -> TranscriptEntry {
        TranscriptEntry(kind: kind, uuid: nil,
                        timestamp: Date(timeIntervalSince1970: 1_783_158_000 + seconds),
                        sessionID: "s", cwd: nil, isSidechain: false)
    }

    private func userPrompt(_ text: String = "do the thing", at seconds: TimeInterval = 0) -> TranscriptEntry {
        entry(.user(UserPayload(text: text, toolResults: [])), at: seconds)
    }

    private func assistant(stop: StopReason?, toolUses: [ToolUseRef] = [],
                           hasText: Bool = false, at seconds: TimeInterval = 0) -> TranscriptEntry {
        entry(.assistant(AssistantPayload(messageID: "m", model: "claude-opus-4-8",
                                          stopReason: stop, usage: nil, toolUses: toolUses,
                                          hasText: hasText, hasThinking: false)), at: seconds)
    }

    private func toolResult(_ id: String, at seconds: TimeInterval = 0) -> TranscriptEntry {
        entry(.user(UserPayload(text: nil, toolResults: [ToolResultRef(toolUseID: id, isError: false)])), at: seconds)
    }

    func testStartsIdle() {
        let reducer = TranscriptReducer()
        XCTAssertEqual(reducer.turnPhase, .idle)
        XCTAssertTrue(reducer.pendingToolUseIDs.isEmpty)
        XCTAssertNil(reducer.currentTurnStartedAt)
    }

    func testUserPromptStartsTurn() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt(at: 5))
        XCTAssertEqual(reducer.turnPhase, .midTurn)
        XCTAssertEqual(reducer.currentTurnStartedAt, Date(timeIntervalSince1970: 1_783_158_005))
    }

    func testToolUseBecomesPendingAndResolvesOnResult() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt())
        reducer.consume(assistant(stop: .toolUse, toolUses: [ToolUseRef(id: "t1", name: "Bash")]))
        XCTAssertEqual(reducer.pendingToolUseIDs, ["t1"])
        XCTAssertEqual(reducer.turnPhase, .midTurn)

        reducer.consume(toolResult("t1"))
        XCTAssertTrue(reducer.pendingToolUseIDs.isEmpty)
        XCTAssertEqual(reducer.turnPhase, .midTurn)
    }

    func testParallelToolUsesAllPendingUntilEachResolves() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt())
        reducer.consume(assistant(stop: .toolUse, toolUses: [ToolUseRef(id: "t1", name: "Read")]))
        reducer.consume(assistant(stop: .toolUse, toolUses: [ToolUseRef(id: "t2", name: "Bash")]))
        XCTAssertEqual(reducer.pendingToolUseIDs, ["t1", "t2"])
        reducer.consume(toolResult("t1"))
        XCTAssertEqual(reducer.pendingToolUseIDs, ["t2"])
        reducer.consume(toolResult("t2"))
        XCTAssertTrue(reducer.pendingToolUseIDs.isEmpty)
    }

    func testEndTurnCompletesTurnAndKeepsTurnStart() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt(at: 0))
        reducer.consume(assistant(stop: .endTurn, hasText: true, at: 30))
        XCTAssertEqual(reducer.turnPhase, .completed)
        // Turn start is kept so the UI can show how long the finished turn took
        XCTAssertEqual(reducer.currentTurnStartedAt, Date(timeIntervalSince1970: 1_783_158_000))
    }

    func testNextPromptAfterCompletionStartsFreshTurn() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt(at: 0))
        reducer.consume(assistant(stop: .endTurn, hasText: true, at: 30))
        reducer.consume(userPrompt("again", at: 100))
        XCTAssertEqual(reducer.turnPhase, .midTurn)
        XCTAssertEqual(reducer.currentTurnStartedAt, Date(timeIntervalSince1970: 1_783_158_100))
    }

    func testInterruptionAbortsTurnAndClearsPendingToolUses() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt())
        reducer.consume(assistant(stop: .toolUse, toolUses: [ToolUseRef(id: "t1", name: "Bash")]))
        reducer.consume(entry(.user(UserPayload(text: "[Request interrupted by user for tool use]",
                                                toolResults: []))))
        XCTAssertEqual(reducer.turnPhase, .aborted)
        XCTAssertTrue(reducer.pendingToolUseIDs.isEmpty,
                      "an interrupt cancels pending tool_use or the session would wait forever")
    }

    func testStopSequenceSyntheticNoticeCompletesTurn() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt())
        reducer.consume(assistant(stop: .stopSequence, hasText: true))
        XCTAssertEqual(reducer.turnPhase, .completed)
    }

    func testMetaEntriesDoNotAffectState() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt())
        reducer.consume(assistant(stop: .toolUse, toolUses: [ToolUseRef(id: "t1", name: "Bash")]))
        let before = reducer
        reducer.consume(entry(.meta(rawType: "queue-operation")))
        reducer.consume(entry(.meta(rawType: "ai-title")))
        XCTAssertEqual(reducer.turnPhase, before.turnPhase)
        XCTAssertEqual(reducer.pendingToolUseIDs, before.pendingToolUseIDs)
    }

    func testStreamingAssistantWithNilStopReasonIsMidTurn() {
        var reducer = TranscriptReducer()
        reducer.consume(userPrompt())
        reducer.consume(assistant(stop: nil, hasText: true))
        XCTAssertEqual(reducer.turnPhase, .midTurn)
    }

    func testRealFixtureNormalTurnEndsCompleted() throws {
        var reducer = TranscriptReducer()
        for entry in try parseWholeFixture("normal_turn") { reducer.consume(entry) }
        XCTAssertEqual(reducer.turnPhase, .completed)
        XCTAssertTrue(reducer.pendingToolUseIDs.isEmpty)
    }

    func testRealFixtureAwaitingPermissionEndsMidTurnWithPending() throws {
        var reducer = TranscriptReducer()
        for entry in try parseWholeFixture("awaiting_permission") { reducer.consume(entry) }
        XCTAssertEqual(reducer.turnPhase, .midTurn)
        XCTAssertEqual(reducer.pendingToolUseIDs.count, 1)
    }

    func testRealFixtureAbortedTurnEndsAbortedWithNoPending() throws {
        var reducer = TranscriptReducer()
        for entry in try parseWholeFixture("aborted_turn") { reducer.consume(entry) }
        XCTAssertEqual(reducer.turnPhase, .aborted)
        XCTAssertTrue(reducer.pendingToolUseIDs.isEmpty)
    }

    private func parseWholeFixture(_ name: String) throws -> [TranscriptEntry] {
        let parser = TranscriptTailParser()
        var entries = parser.consume(try fixtureData(name))
        if let last = parser.finalize() { entries.append(last) }
        return entries
    }
}
