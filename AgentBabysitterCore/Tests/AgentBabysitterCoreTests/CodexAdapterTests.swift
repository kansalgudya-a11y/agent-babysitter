import XCTest
@testable import AgentBabysitterCore

final class CodexAdapterTests: XCTestCase {

    private let adapter = CodexAdapter()

    private func tailerForFixture(_ name: String) throws -> TranscriptFileTailer {
        // Copy the fixture to a temp file so the tailer can read it by URL
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "rollout-2026-06-28T20-07-23-019f0ea9-e616-7680-a356-6ea85016501e.jsonl")
        try (try fixtureData(name)).write(to: url)
        // Use the adapter's reader factory so the stateful usage parser runs
        return adapter.makeReader(url: url) as! TranscriptFileTailer
    }

    // MARK: - Layout

    func testSessionIDComesFromRolloutFilename() {
        let url = URL(fileURLWithPath:
            "/x/2026/06/28/rollout-2026-06-28T20-07-23-019f0ea9-e616-7680-a356-6ea85016501e.jsonl")
        XCTAssertEqual(adapter.sessionID(forTranscript: url),
                       "019f0ea9-e616-7680-a356-6ea85016501e")
    }

    func testRecentTranscriptsWalksDateDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-scan-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/06/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-06-28T20-07-23-019f0ea9-e616-7680-a356-6ea85016501e.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let scoped = CodexAdapter(transcriptRoot: root)
        let found = scoped.recentTranscripts(maxAge: 24 * 3600, now: Date())
        XCTAssertEqual(found.map(\.sessionID), ["019f0ea9-e616-7680-a356-6ea85016501e"])
        // /var vs /private/var: compare symlink-resolved paths
        XCTAssertEqual(found[0].url?.resolvingSymlinksInPath(),
                       file.resolvingSymlinksInPath())
        XCTAssertTrue(scoped.isTranscript(path: file.path))
    }

    // MARK: - Rollout parsing through the normalized pipeline

    func testFixtureTurnEndsCompletedWithResolvedToolCall() throws {
        let tailer = try tailerForFixture("codex_turn")
        _ = try tailer.catchUp()

        XCTAssertEqual(tailer.reducer.turnPhase, .completed)
        XCTAssertTrue(tailer.reducer.pendingToolUseIDs.isEmpty)
        XCTAssertEqual(tailer.lastKnownCWD, "/Users/tester/demo-project")
        XCTAssertEqual(tailer.lastKnownEntrypoint, "Codex Desktop")
        XCTAssertFalse(tailer.isSidechain)

        // token_count usage priced via the model from turn_context (gpt-5.5:
        // $5/M input, $30/M output, $0.50/M cached input, no cache-write fees).
        // OpenAI nests cached (3000) INSIDE input_tokens (5000), so fresh input
        // is 2000; totalTokens = 2000 + 800 = 2800 (cached excluded), and
        // dollars = 2000·5 + 800·30 + 3000·0.5 per million = $0.0355. The cached
        // prefix is billed once (as cache-read), not twice.
        XCTAssertEqual(tailer.costAccumulator.cost.inputTokens, 2000)
        XCTAssertEqual(tailer.costAccumulator.cost.cacheReadTokens, 3000)
        XCTAssertEqual(tailer.costAccumulator.cost.outputTokens, 800)
        XCTAssertEqual(tailer.costAccumulator.cost.totalTokens, 2800)
        XCTAssertEqual(tailer.costAccumulator.cost.dollars, 0.0355, accuracy: 1e-9)
        XCTAssertFalse(tailer.costAccumulator.cost.hasUnknownPricing)
    }

    func testFunctionCallIsPendingUntilOutputArrives() throws {
        let lines = try String(decoding: fixtureData("codex_turn"), as: UTF8.self)
            .split(separator: "\n")
        var reducer = TranscriptReducer()
        for line in lines.prefix(6) {  // through function_call, before output
            if case .entry(let entry) = CodexRolloutParser.parse(Data(line.utf8), usageState: nil) {
                reducer.consume(entry)
            }
        }
        XCTAssertEqual(reducer.pendingToolUseIDs, ["call_abc123"])
        XCTAssertEqual(reducer.turnPhase, .midTurn)
    }

    func testTokenCountAfterTaskCompleteStaysCompleted() throws {
        // token_count arrives AFTER task_complete in real rollouts — it must
        // not reopen the turn.
        let tailer = try tailerForFixture("codex_turn")
        _ = try tailer.catchUp()
        XCTAssertEqual(tailer.reducer.turnPhase, .completed)
    }

    func testTurnAbortedClearsPending() {
        var reducer = TranscriptReducer()
        for line in [
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"exec_command\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}",
        ] {
            if case .entry(let entry) = CodexRolloutParser.parse(Data(line.utf8), usageState: nil) {
                reducer.consume(entry)
            }
        }
        XCTAssertEqual(reducer.turnPhase, .aborted)
        XCTAssertTrue(reducer.pendingToolUseIDs.isEmpty)
    }

    func testSubagentRolloutIsSidechain() throws {
        let tailer = try tailerForFixture("codex_subagent")
        _ = try tailer.catchUp()
        XCTAssertTrue(tailer.isSidechain)
    }

    func testCumulativeUsageCountsDeltasAndHandlesResets() {
        // total_token_usage is cumulative: 100 -> 150 means 150 total, not 250.
        // A drop (150 -> 40) means the counter reset; the new value is fresh.
        let state = CodexRolloutParser.UsageState()
        func tokens(_ total: Int) -> Int {
            let line = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"cached_input_tokens\":0,\"output_tokens\":0,\"total_tokens\":\(total)}}}}"
            guard case .entry(let entry) = CodexRolloutParser.parse(Data(line.utf8), usageState: state),
                  case .assistant(let payload) = entry.kind else { return -1 }
            return payload.usage?.inputTokens ?? -1
        }
        XCTAssertEqual(tokens(100), 100)
        XCTAssertEqual(tokens(150), 50, "cumulative counter -> delta")
        XCTAssertEqual(tokens(150), 0, "no growth -> nothing new (usage.totalTokens 0 is skipped by cost)")
        XCTAssertEqual(tokens(40), 40, "counter reset -> fresh count")
    }

    /// OpenAI nests cached inside input_tokens; the parser must subtract it so
    /// the cached prefix isn't billed at the full input rate AND as cache-read.
    private func codexUsage(_ state: CodexRolloutParser.UsageState,
                            input: Int, cached: Int, output: Int) -> TokenUsage? {
        let line = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output),\"total_tokens\":\(input + output)}}}}"
        guard case .entry(let entry) = CodexRolloutParser.parse(Data(line.utf8), usageState: state),
              case .assistant(let payload) = entry.kind else { return nil }
        return payload.usage
    }

    func testCachedInputIsSubtractedNotDoubleCounted() throws {
        let state = CodexRolloutParser.UsageState()
        let u = try XCTUnwrap(codexUsage(state, input: 100, cached: 60, output: 10))
        XCTAssertEqual(u.inputTokens, 40, "fresh input = input(100) - cached(60)")
        XCTAssertEqual(u.cacheReadInputTokens, 60, "cached counted once, as cache-read")
        XCTAssertEqual(u.outputTokens, 10)
    }

    /// A corrupt reading (all components 0 but a non-zero total) must NOT reset
    /// the cumulative baseline — doing so re-counts the whole preceding cumulative
    /// on the next real event (a spurious over-count).
    func testCorruptZeroReadingDoesNotResetTheBaseline() throws {
        let state = CodexRolloutParser.UsageState()
        let a = try XCTUnwrap(codexUsage(state, input: 100, cached: 0, output: 0))
        XCTAssertEqual(a.inputTokens, 100)
        // Corrupt: {0,0,0}. Skipped — contributes nothing, leaves baseline at 100.
        let corrupt = try XCTUnwrap(codexUsage(state, input: 0, cached: 0, output: 0))
        XCTAssertEqual(corrupt.inputTokens, 0)
        // Next real cumulative reading: delta is 250-100 = 150, NOT 250.
        let c = try XCTUnwrap(codexUsage(state, input: 250, cached: 0, output: 0))
        XCTAssertEqual(c.inputTokens, 150,
                       "baseline preserved: 250-100, not a reset-induced 250")
    }

    func testRateLimitSnapshotIsExtracted() throws {
        let tailer = try tailerForFixture("codex_turn")
        _ = try tailer.catchUp()
        let limit = try XCTUnwrap(tailer.lastUsageLimit)
        XCTAssertEqual(limit.usedPercent, 17.0)  // Double? unwrapped by ==
        XCTAssertEqual(limit.windowMinutes, 300, "primary is the 5-hour window")
        XCTAssertEqual(limit.plan, "plus")
        XCTAssertEqual(limit.resetsAt?.timeIntervalSince1970, 1_782_210_974)
    }

    func testGarbageLineIsMalformed() {
        guard case .malformed = CodexRolloutParser.parse(Data("not json".utf8), usageState: nil) else {
            return XCTFail("expected malformed")
        }
    }

    // MARK: - Processes

    func testAgentPIDsMatchCodexBinaries() {
        let psComm = """
        100 /usr/local/bin/codex
        200 /Applications/Codex.app/Contents/MacOS/Codex
        300 /Users/dev/Library/Application Support/Codex/engine/codex
        400 /Applications/Claude.app/Contents/MacOS/Claude
        """
        // The desktop app hosts sessions with no separate engine process
        // (verified 2026-07: a desktop session ran with only the Electron
        // shell alive), so the main binary must match - helpers must not.
        XCTAssertEqual(adapter.agentPIDs(psComm: psComm, psArgs: ""), [100, 200, 300])
    }

    func testMatchPairsProcessesBySessionCWD() {
        let candidates = [
            SessionMatchCandidate(sessionID: "old", projectDirName: "",
                                  lastKnownCWD: "/Users/dev/appA",
                                  lastModified: Date(timeIntervalSince1970: 1000)),
            SessionMatchCandidate(sessionID: "new", projectDirName: "",
                                  lastKnownCWD: "/Users/dev/appA",
                                  lastModified: Date(timeIntervalSince1970: 2000)),
            SessionMatchCandidate(sessionID: "other", projectDirName: "",
                                  lastKnownCWD: "/Users/dev/appB",
                                  lastModified: Date(timeIntervalSince1970: 1500)),
        ]
        let match = adapter.match(
            processes: [RunningProcess(pid: 7, cwd: "/Users/dev/appA")],
            candidates: candidates)
        XCTAssertEqual(match, ["new": 7], "most recent session with matching cwd wins")
    }

    // MARK: - Store integration

    func testStoreShowsCodexSessionWithAgentBadge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-store-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/06/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent(
            "rollout-2026-06-28T20-07-23-019f0ea9-e616-7680-a356-6ea85016501e.jsonl")
        try (try fixtureData("codex_turn")).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(configuration: .init(
            projectsRoot: root,  // unused: adapters override
            adapters: [CodexAdapter(transcriptRoot: root)]))
        await store.bootstrap()
        await store.processesUpdated(.init(
            processesByAdapter: ["codex": [RunningProcess(pid: 9, cwd: "/Users/tester/demo-project")]],
            degraded: false))

        let rows = await store.rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].agentID, "codex")
        XCTAssertEqual(rows[0].agentName, "Codex")
        XCTAssertEqual(rows[0].projectName, "demo-project")
        XCTAssertEqual(rows[0].pid, 9)
        XCTAssertTrue(rows[0].isDesktopApp)
        XCTAssertEqual(rows[0].state, .done, "fixture turn is complete")

        let limits = await store.usageLimits()
        XCTAssertEqual(limits["codex"]?.usedPercent, 17.0)
        XCTAssertNil(limits["claude-code"], "agents without local limit data have no entry")
    }
}

extension CodexAdapterTests {
    /// The desktop app's main binary is "Codex" (capital C) — it must match;
    /// its Electron helpers must not.
    func testDesktopAppProcessMatches() {
        let comm = """
        100 /Applications/Codex.app/Contents/MacOS/Codex
        200 /Applications/Codex.app/Contents/Frameworks/Codex Framework.framework/Versions/1/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)
        300 /Applications/Codex.app/Contents/Frameworks/Codex Framework.framework/Versions/1/Helpers/browser_crashpad_handler
        400 /opt/homebrew/bin/codex
        """
        XCTAssertEqual(CodexAdapter().agentPIDs(psComm: comm, psArgs: ""), [100, 400])
    }
}
