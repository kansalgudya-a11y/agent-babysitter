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

    // MARK: - Model recovered when token_count precedes turn_context

    func testTokenCountBeforeTurnContextIsStillPriced() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-latemodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(
            "rollout-2026-06-20T00-00-00-019ee4fa-8a68-7360-8592-756f272cbfae.jsonl")
        func tc(_ i: Int, _ o: Int) -> String {
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(i),\"cached_input_tokens\":0,\"output_tokens\":\(o),\"total_tokens\":\(i + o)}}}}"
        }
        // Sub-agent shape: cumulative token_count events, THEN turn_context.
        let lines = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"019ee4fa-8a68-7360-8592-756f272cbfae\",\"cwd\":\"/w\"}}",
            tc(100, 10), tc(300, 25),
            "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"cwd\":\"/w\"}}",
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)

        let reader = adapter.makeReader(url: url)
        try reader.refresh()
        XCTAssertFalse(reader.cost.hasUnknownPricing,
                       "early usage priced via the first turn_context model, not $0")
        XCTAssertEqual(reader.cost.inputTokens, 300)
        XCTAssertEqual(reader.cost.outputTokens, 25)
        // gpt-5.5: $5/M input, $30/M output.
        let expected = Double(300) * 5.0 / 1_000_000 + Double(25) * 30.0 / 1_000_000
        XCTAssertEqual(reader.cost.dollars, expected, accuracy: 1e-9)
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

// MARK: - Usage (quota buckets + the session-independent disk read)

/// Codex publishes several quota buckets under `rate_limits`, keyed by
/// `limit_id`, and its weekly quota outlives the session that recorded it.
/// Shapes here are the ones verified on a real install 2026-07-22: a plan-wide
/// bucket (`limit_name` absent/null) at 24% and a model-scoped
/// "GPT-5.3-Codex-Spark" bucket at 0%, both on a 10080-minute primary window
/// with a null secondary.
final class CodexUsageTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// One `token_count` line carrying a rate_limits bucket. `limitName` nil
    /// omits the key entirely (the fixture's shape); "" writes an explicit
    /// JSON null (the shape on disk today).
    private func usageLine(percent: Double, limitID: String = "codex",
                           limitName: String? = nil,
                           windowMinutes: Int = 10080,
                           resetsIn: TimeInterval = 6 * 86_400,
                           plan: String = "prolite",
                           at timestamp: Date? = Date(),
                           tokens: Int = 1000) -> String {
        let name = limitName.map { $0.isEmpty ? "null" : "\"\($0)\"" } ?? "null"
        let resets = Date().addingTimeInterval(resetsIn).timeIntervalSince1970
        let stamp = timestamp.map {
            "\"timestamp\":\"\($0.ISO8601Format(.iso8601(timeZone: .gmt).year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: true)))\","
        } ?? ""
        return """
        {\(stamp)"type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":\(tokens),"cached_input_tokens":0,\
        "output_tokens":10,"total_tokens":\(tokens + 10)}},\
        "rate_limits":{"limit_id":"\(limitID)","limit_name":\(name),\
        "primary":{"used_percent":\(percent),"window_minutes":\(windowMinutes),\
        "resets_at":\(resets)},"secondary":null,"plan_type":"\(plan)"}}}
        """
    }

    @discardableResult
    private func writeRollout(in root: URL, day: String = "2026/07/22",
                              stem: String = "rollout-2026-07-22T12-15-56",
                              lines: [String], age: TimeInterval = 0) throws -> URL {
        let dir = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "\(stem)-\(UUID().uuidString.lowercased()).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false,
                                                         encoding: .utf8)
        if age > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Bucket selection

    /// The currently-SHIPPING bug in the live reader path: the tailer keeps the
    /// last reading it sees, and on real rollouts the session switches models
    /// mid-file, so a trailing Spark 0% discards the plan's own 24%.
    func testPlanWideBucketBeatsModelScopedWithinAFile() throws {
        let root = try makeRoot()
        let url = try writeRollout(in: root, lines: [
            usageLine(percent: 24),
            usageLine(percent: 0, limitID: "codex_bengalfox",
                      limitName: "GPT-5.3-Codex-Spark"),
        ])
        let reader = CodexAdapter(transcriptRoot: root).makeReader(url: url)
        try reader.refresh()
        XCTAssertEqual(reader.usageLimit?.usedPercent, 24.0,
                       "the model-scoped bucket must not mask the plan-wide one")
        XCTAssertEqual(reader.usageLimit?.windowMinutes, 10080)
    }

    /// A rollout with nothing but model-scoped readings has no plan-wide quota
    /// to report — and rejecting the limit must not disturb token accounting,
    /// which rides on the same lines.
    func testModelScopedOnlyYieldsNoSnapshot() throws {
        let root = try makeRoot()
        let url = try writeRollout(in: root, lines: [
            "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"cwd\":\"/w\"}}",
            usageLine(percent: 7, limitID: "codex_bengalfox",
                      limitName: "GPT-5.3-Codex-Spark", tokens: 4000),
        ])
        let reader = CodexAdapter(transcriptRoot: root).makeReader(url: url)
        try reader.refresh()
        XCTAssertNil(reader.usageLimit)
        XCTAssertEqual(reader.cost.inputTokens, 4000, "tokens are unaffected by the limit filter")
        XCTAssertEqual(reader.cost.outputTokens, 10)
    }

    /// Back-compat for the new predicate: both an ABSENT `limit_name` (the
    /// shape in Fixtures/codex_turn.jsonl) and an explicit JSON null (the shape
    /// on disk today, which bridges to NSNull) mean plan-wide.
    func testMissingOrNullLimitNameStillParses() throws {
        let root = try makeRoot()
        let absent = try writeRollout(in: root, lines: [
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":31.0,\"window_minutes\":10080,\"resets_at\":\(Date().addingTimeInterval(86_400).timeIntervalSince1970)},\"plan_type\":\"plus\"}}}",
        ])
        let explicitNull = try writeRollout(in: root, lines: [usageLine(percent: 12)])
        let adapter = CodexAdapter(transcriptRoot: root)

        let absentReader = adapter.makeReader(url: absent)
        try absentReader.refresh()
        XCTAssertEqual(absentReader.usageLimit?.usedPercent, 31.0)

        let nullReader = adapter.makeReader(url: explicitNull)
        try nullReader.refresh()
        XCTAssertEqual(nullReader.usageLimit?.usedPercent, 12.0)
    }

    /// A genuine 0% is a reading, not a gap. Nothing in this path may gate on
    /// truthiness — the menu branches on nil, not on falsiness, and collapsing
    /// the two would render an untouched quota as "no recent reading".
    func testZeroPercentIsARealReading() throws {
        let root = try makeRoot()
        let url = try writeRollout(in: root, lines: [usageLine(percent: 0)])
        let adapter = CodexAdapter(transcriptRoot: root)

        let reader = adapter.makeReader(url: url)
        try reader.refresh()
        XCTAssertEqual(reader.usageLimit?.usedPercent, 0)
        XCTAssertNotNil(reader.usageLimit?.usedPercent)

        let fromDisk = adapter.usageFromDisk()
        XCTAssertEqual(fromDisk?.usedPercent, 0)
        XCTAssertNotNil(fromDisk?.usedPercent)
    }

    // MARK: - The disk read

    /// Today's disk, reproduced: the NEWER file ends on a Spark 0% and the
    /// plan's real 24% lives in the file written 16 seconds earlier. Stopping
    /// at the newest file — or at the first file with any reading — renders a
    /// confident, wrong 0%.
    func testUsageFromDiskPrefersPlanWideAcrossFiles() throws {
        let root = try makeRoot()
        try writeRollout(in: root, stem: "rollout-2026-07-22T12-15-30",
                         lines: [usageLine(percent: 24)], age: 16)
        try writeRollout(in: root, stem: "rollout-2026-07-22T12-15-56",
                         lines: [usageLine(percent: 0, limitID: "codex_bengalfox",
                                           limitName: "GPT-5.3-Codex-Spark")])

        let usage = CodexAdapter(transcriptRoot: root).usageFromDisk()
        XCTAssertEqual(usage?.usedPercent, 24.0)
        XCTAssertEqual(usage?.windowMinutes, 10080)
        XCTAssertEqual(usage?.plan, "prolite")
    }

    /// THE reported bug. The rollout is older than the store's active window,
    /// so its session is correctly gone — but the weekly quota it recorded is
    /// valid for days yet, and must still reach the menu. Also the first test
    /// anywhere covering the store's disk-fallback WIRING for any agent.
    func testCodexUsageSurvivesSessionAgingOutOfActiveWindow() async throws {
        let root = try makeRoot()
        try writeRollout(in: root, lines: [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"019f8892-e6cc-7643-a1ff-cdb7bcda6b26\",\"cwd\":\"/w\"}}",
            usageLine(percent: 24),
        ], age: 25 * 3600)

        let store = SessionStore(configuration: .init(
            projectsRoot: root,  // unused: adapters override
            adapters: [CodexAdapter(transcriptRoot: root)]))
        await store.bootstrap()

        let rows = await store.rows()
        XCTAssertTrue(rows.isEmpty, "the session itself correctly aged out")
        let limits = await store.usageLimits()
        XCTAssertEqual(limits["codex"]?.usedPercent, 24.0, "the quota outlives the session")
        XCTAssertEqual(limits["codex"]?.windowMinutes, 10080)
    }

    /// Fill-the-hole, matching the Cursor precedent: a live session's reading
    /// always wins, and the guard runs before the adapter is ever asked for its
    /// source file, so a running Codex never pays for the scan.
    func testLiveSessionReadingWinsOverDiskFallback() async throws {
        let root = try makeRoot()
        try writeRollout(in: root, stem: "rollout-2026-07-21T09-00-00",
                         lines: [usageLine(percent: 24)], age: 25 * 3600)
        try writeRollout(in: root, stem: "rollout-2026-07-23T09-00-00",
                         lines: [usageLine(percent: 40)])

        let store = SessionStore(configuration: .init(
            projectsRoot: root, adapters: [CodexAdapter(transcriptRoot: root)]))
        await store.bootstrap()
        let limits = await store.usageLimits()
        XCTAssertEqual(limits["codex"]?.usedPercent, 40.0)
    }

    /// `capturedAt` drives both `UsageLimitLayering` precedence and
    /// `UsageForecast`'s 1h staleness ceiling, so it must be the event's own
    /// timestamp — never `Date()` — and never ahead of the file that holds it.
    func testCapturedAtIsEventTimestampClampedToFileMTime() throws {
        let root = try makeRoot()
        let stamp = Date().addingTimeInterval(-26 * 3600)
        try writeRollout(in: root, lines: [usageLine(percent: 24, at: stamp)],
                         age: 25 * 3600)
        let dated = try XCTUnwrap(CodexAdapter(transcriptRoot: root).usageFromDisk())
        XCTAssertEqual(dated.capturedAt.timeIntervalSince1970,
                       stamp.timeIntervalSince1970, accuracy: 1,
                       "the line's own timestamp, not the file mtime and not now")
        XCTAssertNil(UsageForecast.estimatedCurrentPercent(dated),
                     "a day-old reading must not extrapolate to a false ~100%")

        // No timestamp on the line: fall back to the file's mtime, which is
        // still honestly old — not to now, which would revive the forecast.
        let bare = try makeRoot()
        try writeRollout(in: bare, lines: [usageLine(percent: 24, at: nil)],
                         age: 25 * 3600)
        let undated = try XCTUnwrap(CodexAdapter(transcriptRoot: bare).usageFromDisk())
        XCTAssertEqual(undated.capturedAt.timeIntervalSinceNow, -25 * 3600, accuracy: 60)
        XCTAssertNil(UsageForecast.estimatedCurrentPercent(undated))
    }

    /// Rollouts are read from their tail because whole-file parsing is
    /// impossible at this size — so the tail logic has to survive the giant
    /// lines that make it necessary.
    func testTailReadFindsAReadingBehindHugeLines() throws {
        let junk = String(repeating: "x", count: 200_000)
        func junkLine(_ size: Int) -> String {
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(String(repeating: "y", count: size))\"}]}}"
        }

        // (a) a multi-megabyte line BEFORE the reading is simply skipped.
        let a = try makeRoot()
        try writeRollout(in: a, lines: [junkLine(2_000_000), usageLine(percent: 24)])
        XCTAssertEqual(CodexAdapter(transcriptRoot: a).usageFromDisk()?.usedPercent, 24.0)

        // (b) the reading sits behind a line longer than the 64 KB window, so
        // the first slice lands entirely inside it — the 4 MB escalation finds it.
        let b = try makeRoot()
        try writeRollout(in: b, lines: [usageLine(percent: 24), junkLine(400_000)])
        XCTAssertEqual(CodexAdapter(transcriptRoot: b).usageFromDisk()?.usedPercent, 24.0)

        // (c) a truncated trailing fragment must not make the leading-fragment
        // discard swallow the valid line before it.
        let c = try makeRoot()
        let cURL = try writeRollout(in: c, lines: [junk, usageLine(percent: 24)])
        let handle = try FileHandle(forWritingTo: cURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payl".utf8))
        try handle.close()
        XCTAssertEqual(CodexAdapter(transcriptRoot: c).usageFromDisk()?.usedPercent, 24.0)

        // (d) a reading further than the escalation window from EOF simply
        // contributes nothing — an older reading, never a wrong one.
        let d = try makeRoot()
        try writeRollout(in: d, lines: [usageLine(percent: 24), junkLine(5_000_000)])
        XCTAssertNil(CodexAdapter(transcriptRoot: d).usageFromDisk())

        // (e) the case the old "did we parse ANY line" escalation missed: the
        // 64 KB slice parses perfectly and is full of model-scoped buckets,
        // while the plan's own reading sits a few hundred KB back behind
        // ordinary-sized lines. Escalation has to be driven by "no plan-wide
        // reading", not by "no lines".
        let e = try makeRoot()
        try writeRollout(in: e, lines: [usageLine(percent: 24)]
            + (0..<40).map { _ in junkLine(20_000) }
            + (0..<8).map { _ in usageLine(percent: 0, limitID: "codex_bengalfox",
                                           limitName: "GPT-5.3-Codex-Spark") })
        XCTAssertEqual(CodexAdapter(transcriptRoot: e).usageFromDisk()?.usedPercent, 24.0,
                       "a plan-wide reading past the 64 KB window must not be dropped "
                       + "just because the window itself parsed cleanly")
    }

    /// The shape of the author's real archive 2026-07-22: the newest rollouts
    /// spent their final hours on a model-scoped allowance, so their tails
    /// carry no plan-wide reading at all. Recall across rollouts — not a wider
    /// window, which would have to reach 300 MB back — is what keeps the row
    /// from going blank.
    func testRecallSurvivesManyModelScopedOnlyRollouts() throws {
        let root = try makeRoot()
        // Oldest file (highest age) holds the only plan-wide reading.
        try writeRollout(in: root, stem: "rollout-2026-07-22T00-00-00",
                         lines: [usageLine(percent: 24)], age: 20 * 3600)
        for index in 1...15 {
            try writeRollout(in: root, stem: "rollout-2026-07-22T\(index)-00-00",
                             lines: [usageLine(percent: 0, limitID: "codex_bengalfox",
                                               limitName: "GPT-5.3-Codex-Spark")],
                             age: Double(20 * 3600 - index * 600))
        }
        let usage = CodexAdapter(transcriptRoot: root).usageFromDisk()
        XCTAssertEqual(usage?.usedPercent, 24.0,
                       "15 model-scoped-only rollouts must not bury the plan's reading")
    }

    /// An unrecognized layout (no YYYY directories) must still find rollouts:
    /// a future Codex layout change has to degrade to "slower and
    /// approximate", never to "silently nothing".
    func testUnrecognizedLayoutStillFindsRollouts() throws {
        let root = try makeRoot()
        try writeRollout(in: root, day: "archive/old", lines: [usageLine(percent: 33)])
        let adapter = CodexAdapter(transcriptRoot: root)
        XCTAssertEqual(adapter.usageFromDisk()?.usedPercent, 33.0)
        XCTAssertNotNil(adapter.usageSourceFile())
    }

    /// …and must do it under a cap. `days.isEmpty` is true on EVERY call in
    /// that state and Codex never prunes, so an uncapped rescue walk would be
    /// a full archive traversal on every refresh. The previous version of this
    /// test wrote ONE rollout and asserted it was found, which the cap cannot
    /// fail; the budget is injected here so the break is actually taken
    /// without materializing thousands of files.
    func testRescueScanStopsAtItsEntryBudget() throws {
        let root = try makeRoot()
        for index in 0..<40 {
            try writeRollout(in: root, day: "archive/old",
                             stem: "rollout-unrecognized-\(index)",
                             lines: [usageLine(percent: 33)])
        }
        let adapter = CodexAdapter(transcriptRoot: root)
        // 40 rollouts on disk, a budget of 6 entries: the walk must stop
        // partway rather than collect them all. (The budget counts every
        // filesystem entry the enumerator yields, directories included, so
        // "at most 6 files" is the loosest true bound.)
        let capped = adapter.newestRollouts(rescueEntryBudget: 6)
        XCTAssertFalse(capped.isEmpty, "a partial result, not nothing")
        XCTAssertLessThanOrEqual(capped.count, 6)
        // Same tree, budget lifted: the cap — not the tree — is what limited
        // the result above.
        XCTAssertEqual(adapter.newestRollouts(limit: 100,
                                              rescueEntryBudget: 10_000).count, 40)
    }

    func testUsageFromDiskExpiryHandling() throws {
        // A rolled-over window loses to a live one regardless of which is newer.
        let mixed = try makeRoot()
        try writeRollout(in: mixed, stem: "rollout-2026-07-22T08-00-00",
                         lines: [usageLine(percent: 24, resetsIn: 5 * 86_400)], age: 60)
        try writeRollout(in: mixed, stem: "rollout-2026-07-22T09-00-00",
                         lines: [usageLine(percent: 88, resetsIn: -3600)])
        XCTAssertEqual(CodexAdapter(transcriptRoot: mixed).usageFromDisk()?.usedPercent, 24.0)

        // Everything rolled over: hand back the newest truth anyway so the menu
        // renders its honest "reset" state instead of "no recent reading".
        let allExpired = try makeRoot()
        try writeRollout(in: allExpired, lines: [usageLine(percent: 88, resetsIn: -3600)])
        let usage = CodexAdapter(transcriptRoot: allExpired).usageFromDisk()
        XCTAssertEqual(usage?.usedPercent, 88.0)
        XCTAssertTrue(usage?.isExpired() ?? false)
    }

    /// Fail-soft everywhere, matching the Cursor/Antigravity disk readers:
    /// nothing throws, nothing logs, a bad file is skipped rather than fatal.
    func testUsageFromDiskFailsSoft() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-absent-\(UUID().uuidString)")
        XCTAssertNil(CodexAdapter(transcriptRoot: missing).usageFromDisk())
        XCTAssertNil(CodexAdapter(transcriptRoot: missing).usageSourceFile())

        let garbage = try makeRoot()
        try writeRollout(in: garbage, lines: ["not json at all", "{\"type\":", ""])
        XCTAssertNil(CodexAdapter(transcriptRoot: garbage).usageFromDisk())

        let empty = try makeRoot()
        let emptyDir = empty.appendingPathComponent("2026/07/22")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try Data().write(to: emptyDir.appendingPathComponent("rollout-empty.jsonl"))
        XCTAssertNil(CodexAdapter(transcriptRoot: empty).usageFromDisk())

        // used_percent of the wrong type is not a reading.
        let wrongType = try makeRoot()
        try writeRollout(in: wrongType, lines: [
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":\"24\",\"window_minutes\":10080},\"plan_type\":\"plus\"}}}",
        ])
        XCTAssertNil(CodexAdapter(transcriptRoot: wrongType).usageFromDisk())
    }

    /// The support diagnostic behind the one silent failure this design has:
    /// if OpenAI ever labels the plan-wide bucket, `usageFromDisk()` honestly
    /// returns nil, and only a bucket listing distinguishes that from a
    /// parser regression.
    func testRecentUsageBucketsListsBothBucketsDistinctly() throws {
        let root = try makeRoot()
        try writeRollout(in: root, lines: [
            usageLine(percent: 24),
            usageLine(percent: 24),  // repeat of the same bucket: listed once
            usageLine(percent: 0, limitID: "codex_bengalfox",
                      limitName: "GPT-5.3-Codex-Spark"),
        ])
        let buckets = CodexAdapter(transcriptRoot: root).recentUsageBuckets()
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(Set(buckets.map { $0.limitID }), ["codex", "codex_bengalfox"])
        let planWide = try XCTUnwrap(buckets.first { $0.limitName == nil })
        XCTAssertEqual(planWide.limitID, "codex")
        XCTAssertEqual(planWide.usedPercent, 24.0)
        XCTAssertEqual(planWide.windowMinutes, 10080)
    }

    /// Codex never prunes its archive, so discovery must cost the same on a
    /// three-year-old install as on a fresh one — and must still step back
    /// through empty day-directories to find the newest actual rollout.
    ///
    /// This test owns the "old history changes NOTHING" half: the same
    /// rollouts are found on a three-year archive as on a one-year one. It
    /// deliberately makes NO boundedness claim, because it cannot support one:
    /// this fixture gives each month a single day-directory, and the year and
    /// month prefixes alone hold the result to at most a handful of files
    /// whatever `dayDirs` is set to — so any "not too many were found"
    /// assertion here would pass by construction, including after someone
    /// retuned the cap 4 -> 30. The cap is exercised where it can actually
    /// fail, in `testNewestRolloutsStopsAtItsDayDirectoryCap` below.
    func testNewestRolloutsIgnoresOldHistoryAndIsNewestFirst() throws {
        /// One rollout per month at day 15, plus an empty newest day-directory
        /// that discovery must step back past. Ages are absolute (derived from
        /// year/month), so the two archives agree on ordering.
        func buildArchive(years: [String]) throws -> URL {
            let root = try makeRoot()
            for year in years {
                for month in 1...12 {
                    let day = String(format: "%@/%02d/15", year, month)
                    try writeRollout(in: root, day: day, stem: "rollout-\(year)-\(month)",
                                     lines: [usageLine(percent: 5)],
                                     age: Double(12 * (2026 - Int(year)!) + (12 - month)) * 86_400)
                }
            }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("2026/12/31"), withIntermediateDirectories: true)
            return root
        }
        /// "2026/12/15" — the identity that survives across two archives, whose
        /// rollout filenames carry different random UUIDs.
        func dayPaths(_ found: [(url: URL, mtime: Date)]) -> [String] {
            found.map {
                $0.url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/")
            }
        }

        let deep = CodexAdapter(transcriptRoot: try buildArchive(years: ["2024", "2025", "2026"]))
        let shallow = CodexAdapter(transcriptRoot: try buildArchive(years: ["2025", "2026"]))
        let found = deep.newestRollouts()

        XCTAssertFalse(found.isEmpty)
        XCTAssertEqual(found.map(\.mtime), found.map(\.mtime).sorted(by: >))
        XCTAssertEqual(dayPaths(found).first, "2026/12/15",
                       "newest month first, stepping back past the empty day")
        XCTAssertEqual(dayPaths(found), dayPaths(shallow.newestRollouts()),
                       "a third year of history must change nothing about what is found")
        XCTAssertEqual(deep.newestRollouts(limit: 1).count, 1)
        XCTAssertEqual(deep.usageSourceFile(), found.first?.url)
    }

    /// The day-directory cap is the thing standing between a busy month and a
    /// full walk of an archive Codex never prunes, so it gets the same
    /// two-sided proof as the rescue budget: the SAME tree scanned twice with
    /// different caps must return different amounts of history. Without the
    /// second scan an "it found few files" assertion only proves the fixture
    /// was small — which is how a 7x discovery regression (dayDirs 4 -> 30)
    /// could have been retuned in with every test still green.
    func testNewestRolloutsStopsAtItsDayDirectoryCap() throws {
        let root = try makeRoot()
        // Twelve day-directories inside ONE month, three rollouts each, ages
        // descending with the date so "newest first" is unambiguous.
        for day in 1...12 {
            for index in 0..<3 {
                try writeRollout(in: root, day: String(format: "2026/12/%02d", day),
                                 stem: "rollout-\(day)-\(index)",
                                 lines: [usageLine(percent: 5)],
                                 age: Double(12 - day) * 86_400 + Double(index) * 60)
            }
        }
        func dayNumbers(_ found: [(url: URL, mtime: Date)]) -> [String] {
            Array(Set(found.map { $0.url.deletingLastPathComponent().lastPathComponent })).sorted()
        }
        let adapter = CodexAdapter(transcriptRoot: root)

        let capped = adapter.newestRollouts(dayDirs: 3)
        XCTAssertEqual(dayNumbers(capped), ["10", "11", "12"],
                       "three day-directories, and the NEWEST three")
        XCTAssertEqual(capped.count, 9, "3 days x 3 rollouts")
        // Same tree, cap lifted: the cap — not the tree — bounded the scan
        // above. This is the assertion that fails if the cap stops capping.
        XCTAssertEqual(adapter.newestRollouts(limit: 100, dayDirs: 12).count, 36)
    }
}
