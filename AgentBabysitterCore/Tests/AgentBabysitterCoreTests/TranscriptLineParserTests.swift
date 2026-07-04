import XCTest
@testable import AgentBabysitterCore

final class TranscriptLineParserTests: XCTestCase {

    // MARK: - Inline lines

    func testParsesUserPlainStringEntry() throws {
        let line = """
        {"type":"user","uuid":"u-1","sessionId":"s-1","cwd":"/tmp/x","isSidechain":false,\
        "timestamp":"2026-07-04T09:45:52.675Z","message":{"role":"user","content":"hello there"}}
        """
        guard case .entry(let entry) = TranscriptLineParser.parse(line) else {
            return XCTFail("expected entry")
        }
        guard case .user(let payload) = entry.kind else {
            return XCTFail("expected user kind")
        }
        XCTAssertEqual(payload.text, "hello there")
        XCTAssertTrue(payload.toolResults.isEmpty)
        XCTAssertEqual(entry.uuid, "u-1")
        XCTAssertEqual(entry.sessionID, "s-1")
        XCTAssertEqual(entry.cwd, "/tmp/x")
        XCTAssertFalse(entry.isSidechain)
        let expected = Date(timeIntervalSince1970: 1_783_158_352.675)  // 2026-07-04T09:45:52.675Z
        XCTAssertEqual(entry.timestamp!.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testParsesUserTextBlockArray() throws {
        let line = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"part one"},\
        {"type":"text","text":"part two"}]}}
        """
        guard case .entry(let entry) = TranscriptLineParser.parse(line),
              case .user(let payload) = entry.kind else {
            return XCTFail("expected user entry")
        }
        XCTAssertEqual(payload.text, "part one\npart two")
    }

    func testParsesToolResultEntry() throws {
        let line = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"toolu_abc","is_error":false,"content":"ok"}]},"toolUseResult":"ok"}
        """
        guard case .entry(let entry) = TranscriptLineParser.parse(line),
              case .user(let payload) = entry.kind else {
            return XCTFail("expected user entry")
        }
        XCTAssertNil(payload.text)
        XCTAssertEqual(payload.toolResults, [ToolResultRef(toolUseID: "toolu_abc", isError: false)])
    }

    func testParsesAssistantToolUseEntry() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-07-04T09:45:57.119Z","sessionId":"s-1",\
        "message":{"model":"claude-opus-4-8","id":"msg_123","role":"assistant",\
        "content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}],\
        "stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":20,\
        "cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}
        """
        guard case .entry(let entry) = TranscriptLineParser.parse(line),
              case .assistant(let payload) = entry.kind else {
            return XCTFail("expected assistant entry")
        }
        XCTAssertEqual(payload.messageID, "msg_123")
        XCTAssertEqual(payload.model, "claude-opus-4-8")
        XCTAssertEqual(payload.stopReason, .toolUse)
        XCTAssertEqual(payload.toolUses, [ToolUseRef(id: "toolu_1", name: "Bash")])
        XCTAssertFalse(payload.hasText)
        XCTAssertFalse(payload.hasThinking)
        XCTAssertEqual(payload.usage, TokenUsage(inputTokens: 10, outputTokens: 20,
                                                 cacheCreationInputTokens: 30,
                                                 cacheReadInputTokens: 40))
    }

    func testParsesAssistantWithNullStopReasonAndMissingUsage() throws {
        let line = """
        {"type":"assistant","message":{"model":"claude-opus-4-8","id":"msg_9",\
        "role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":null}}
        """
        guard case .entry(let entry) = TranscriptLineParser.parse(line),
              case .assistant(let payload) = entry.kind else {
            return XCTFail("expected assistant entry")
        }
        XCTAssertNil(payload.stopReason)
        XCTAssertNil(payload.usage)
        XCTAssertTrue(payload.hasText)
    }

    func testUnknownStopReasonIsPreserved() throws {
        let line = """
        {"type":"assistant","message":{"model":"m","id":"msg_1","role":"assistant",\
        "content":[],"stop_reason":"brand_new_reason"}}
        """
        guard case .entry(let entry) = TranscriptLineParser.parse(line),
              case .assistant(let payload) = entry.kind else {
            return XCTFail("expected assistant entry")
        }
        XCTAssertEqual(payload.stopReason, .other("brand_new_reason"))
    }

    func testParsesMetaEntryTypes() throws {
        for raw in ["queue-operation", "ai-title", "last-prompt", "mode",
                    "custom-title", "attachment", "system"] {
            let line = "{\"type\":\"\(raw)\",\"sessionId\":\"s-1\"}"
            guard case .entry(let entry) = TranscriptLineParser.parse(line),
                  case .meta(let rawType) = entry.kind else {
                return XCTFail("expected meta entry for \(raw)")
            }
            XCTAssertEqual(rawType, raw)
        }
    }

    func testTimestampWithoutFractionalSecondsParses() throws {
        let line = """
        {"type":"user","timestamp":"2026-07-04T09:45:52Z","message":{"role":"user","content":"x"}}
        """
        guard case .entry(let entry) = TranscriptLineParser.parse(line) else {
            return XCTFail("expected entry")
        }
        XCTAssertNotNil(entry.timestamp)
    }

    func testMalformedAndEmptyLines() {
        // Malformed: truncated JSON, plain text, JSON fragment, object without type
        for bad in ["{\"type\":\"assistant\",\"message\":{\"model\":\"m",
                    "this is not json at all",
                    "42",
                    "{\"noType\":true}",
                    "[1,2,3]"] {
            guard case .malformed = TranscriptLineParser.parse(bad) else {
                return XCTFail("expected malformed for: \(bad)")
            }
        }
        // Empty / whitespace-only: skipped without counting as malformed
        for empty in ["", "   ", "\t"] {
            guard case .empty = TranscriptLineParser.parse(empty) else {
                return XCTFail("expected empty for whitespace line")
            }
        }
    }

    // MARK: - Fixtures (sanitized slices of real transcripts)

    func testNormalTurnFixture() throws {
        let entries = try parseFixture("normal_turn")
        XCTAssertEqual(entries.count, 26)

        var users = 0, assistants = 0, metas = 0
        for entry in entries {
            switch entry.kind {
            case .user: users += 1
            case .assistant: assistants += 1
            case .meta: metas += 1
            }
        }
        XCTAssertEqual(users, 5)        // 1 prompt + 4 tool results
        XCTAssertEqual(assistants, 12)  // 5 API messages split into block-lines
        XCTAssertEqual(metas, 9)        // queue-operation ×2, attachment ×5, last-prompt, ai-title

        // The real user prompt
        guard case .user(let prompt) = entries[2].kind else { return XCTFail("line 3 should be user") }
        XCTAssertNotNil(prompt.text)
        XCTAssertTrue(prompt.toolResults.isEmpty)
        XCTAssertEqual(entries[2].sessionID, "d51bb435-50c0-4fdd-96b4-385367309534")

        // First assistant block-line: thinking, full usage
        guard case .assistant(let first) = entries[9].kind else { return XCTFail("line 10 should be assistant") }
        XCTAssertEqual(first.messageID, "msg_01ELo2YuPr98Sxdj6GH5MftS")
        XCTAssertEqual(first.model, "claude-fable-5")
        XCTAssertEqual(first.stopReason, .toolUse)
        XCTAssertTrue(first.hasThinking)
        XCTAssertEqual(first.usage, TokenUsage(inputTokens: 26870, outputTokens: 156,
                                               cacheCreationInputTokens: 4207,
                                               cacheReadInputTokens: 15148,
                                               cacheCreation5mTokens: 0,
                                               cacheCreation1hTokens: 4207))

        // Second block-line of the SAME message: same id, same usage (dedupe hazard)
        guard case .assistant(let second) = entries[10].kind else { return XCTFail("line 11 should be assistant") }
        XCTAssertEqual(second.messageID, first.messageID)
        XCTAssertEqual(second.usage, first.usage)
        XCTAssertEqual(second.toolUses, [ToolUseRef(id: "toolu_01PzC9qBUww5PrQm1cCd6P1x", name: "Read")])

        // Tool result matches the tool_use id (and errors are flagged)
        guard case .user(let result) = entries[11].kind else { return XCTFail("line 12 should be user") }
        XCTAssertEqual(result.toolResults, [ToolResultRef(toolUseID: "toolu_01PzC9qBUww5PrQm1cCd6P1x",
                                                          isError: true)])

        // Turn completes: final line is assistant text with end_turn and no tool_use
        guard case .assistant(let last) = entries[25].kind else { return XCTFail("line 26 should be assistant") }
        XCTAssertEqual(last.stopReason, .endTurn)
        XCTAssertTrue(last.hasText)
        XCTAssertTrue(last.toolUses.isEmpty)

        // Every tool_use in this fixture is resolved by a tool_result
        XCTAssertTrue(pendingToolUseIDs(entries).isEmpty)
    }

    func testAwaitingPermissionFixtureEndsWithPendingToolUse() throws {
        let entries = try parseFixture("awaiting_permission")
        XCTAssertEqual(entries.count, 10)

        // Last non-meta entry is an assistant tool_use…
        let stateEntries = entries.filter { if case .meta = $0.kind { return false }; return true }
        guard case .assistant(let last) = stateEntries.last?.kind else {
            return XCTFail("expected trailing assistant entry")
        }
        XCTAssertEqual(last.toolUses.count, 1)

        // …and that tool_use has no matching tool_result: the waiting-for-permission signature.
        XCTAssertEqual(pendingToolUseIDs(entries), Set(last.toolUses.map(\.id)))
    }

    func testAbortedTurnFixture() throws {
        let entries = try parseFixture("aborted_turn")
        XCTAssertEqual(entries.count, 9)

        // Parallel tool calls: two tool_use block-lines sharing one message id
        var toolUsesByMessage: [String: Int] = [:]
        for entry in entries {
            if case .assistant(let a) = entry.kind, !a.toolUses.isEmpty, let id = a.messageID {
                toolUsesByMessage[id, default: 0] += a.toolUses.count
            }
        }
        XCTAssertTrue(toolUsesByMessage.values.contains(2), "expected a message with 2 parallel tool_use blocks")

        // The user interruption marker survives sanitization and is exposed as text
        let interrupted = entries.contains { entry in
            if case .user(let u) = entry.kind, let text = u.text {
                return text.hasPrefix("[Request interrupted")
            }
            return false
        }
        XCTAssertTrue(interrupted)
    }

    func testSyntheticAbortFixture() throws {
        let entries = try parseFixture("synthetic_abort")
        let synthetic = entries.compactMap { entry -> AssistantPayload? in
            if case .assistant(let a) = entry.kind, a.model == "<synthetic>" { return a }
            return nil
        }
        XCTAssertEqual(synthetic.count, 1)
        XCTAssertEqual(synthetic[0].stopReason, .stopSequence)
        XCTAssertEqual(synthetic[0].usage, TokenUsage(inputTokens: 0, outputTokens: 0,
                                                      cacheCreationInputTokens: 0,
                                                      cacheReadInputTokens: 0))
    }

    func testMetadataTypesFixture() throws {
        let entries = try parseFixture("metadata_types")
        XCTAssertEqual(entries.count, 7)
        let rawTypes = entries.compactMap { entry -> String? in
            if case .meta(let raw) = entry.kind { return raw }
            return nil
        }
        XCTAssertEqual(Set(rawTypes), ["queue-operation", "ai-title", "last-prompt",
                                       "mode", "custom-title", "attachment", "system"])
    }

    func testUnknownModelIsPreservedVerbatim() throws {
        let entries = try parseFixture("unknown_model")
        let models = entries.compactMap { entry -> String? in
            if case .assistant(let a) = entry.kind { return a.model }
            return nil
        }
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy { $0 == "claude-future-99" })
    }

    // MARK: - Helpers

    private func parseFixture(_ name: String) throws -> [TranscriptEntry] {
        let data = try fixtureData(name)
        let parser = TranscriptTailParser()
        var entries = parser.consume(data)
        if let last = parser.finalize() { entries.append(last) }
        XCTAssertEqual(parser.malformedLineCount, 0, "fixture \(name) should have no malformed lines")
        return entries
    }
}

func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "jsonl",
                                subdirectory: "Fixtures")
    return try Data(contentsOf: XCTUnwrap(url))
}

/// tool_use ids with no matching tool_result — the "waiting on permission" signal.
func pendingToolUseIDs(_ entries: [TranscriptEntry]) -> Set<String> {
    var pending = Set<String>()
    for entry in entries {
        switch entry.kind {
        case .assistant(let a):
            for use in a.toolUses { pending.insert(use.id) }
        case .user(let u):
            for result in u.toolResults { pending.remove(result.toolUseID) }
        case .meta:
            break
        }
    }
    return pending
}
