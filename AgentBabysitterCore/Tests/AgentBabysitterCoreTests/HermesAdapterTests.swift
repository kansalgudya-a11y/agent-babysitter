import XCTest
import SQLite3
@testable import AgentBabysitterCore

final class HermesAdapterTests: XCTestCase {

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// A `~/.hermes` root with an empty schema-only state.db already created.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private struct SessionInput {
        var id = "20260708_093658_8ac090"
        var model: String? = "deepseek-v4-pro"
        var modelConfig: String? = nil
        var cwd: String? = "/Users/x/proj"
        var gitRepoRoot: String? = nil
        var parentSessionID: String? = nil
        var title: String? = "Safe use of OAuth"
        var startedAt: Double = 1_000
        var endedAt: Double? = nil
        var endReason: String? = nil
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var reasoning = 0
        var actualCost: Double? = nil
        var estimatedCost: Double? = nil
        var archived: Int = 0
    }

    /// (role, content, finish_reason, timestamp)
    private typealias MessageInput = (String, String?, String?, Double)

    /// Writes a real SQLite state.db with the two tables and the given rows.
    /// Plain rollback-journal mode (no WAL) so the read-only copy opens cleanly.
    @discardableResult
    private func writeStateDB(root: URL,
                             sessions: [SessionInput],
                             messages: [MessageInput] = []) -> URL {
        let url = root.appendingPathComponent("state.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, source TEXT, model TEXT, model_config TEXT, cwd TEXT,
              git_repo_root TEXT, parent_session_id TEXT, title TEXT,
              started_at REAL, ended_at REAL, end_reason TEXT,
              input_tokens INTEGER, output_tokens INTEGER,
              cache_read_tokens INTEGER, cache_write_tokens INTEGER,
              reasoning_tokens INTEGER, actual_cost_usd REAL,
              estimated_cost_usd REAL, archived INTEGER
            )
            """, nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT,
              content TEXT, finish_reason TEXT, timestamp REAL
            )
            """, nil, nil, nil)

        for s in sessions {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, """
                INSERT INTO sessions (id, source, model, model_config, cwd, git_repo_root,
                  parent_session_id, title, started_at, ended_at, end_reason,
                  input_tokens, output_tokens,
                  cache_read_tokens, cache_write_tokens, reasoning_tokens,
                  actual_cost_usd, estimated_cost_usd, archived)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, -1, &stmt, nil)
            bindText(stmt, 1, s.id)
            bindText(stmt, 2, "tui")
            bindText(stmt, 3, s.model)
            bindText(stmt, 4, s.modelConfig)
            bindText(stmt, 5, s.cwd)
            bindText(stmt, 6, s.gitRepoRoot)
            bindText(stmt, 7, s.parentSessionID)
            bindText(stmt, 8, s.title)
            sqlite3_bind_double(stmt, 9, s.startedAt)
            bindDouble(stmt, 10, s.endedAt)
            bindText(stmt, 11, s.endReason)
            sqlite3_bind_int64(stmt, 12, Int64(s.input))
            sqlite3_bind_int64(stmt, 13, Int64(s.output))
            sqlite3_bind_int64(stmt, 14, Int64(s.cacheRead))
            sqlite3_bind_int64(stmt, 15, Int64(s.cacheWrite))
            sqlite3_bind_int64(stmt, 16, Int64(s.reasoning))
            bindDouble(stmt, 17, s.actualCost)
            bindDouble(stmt, 18, s.estimatedCost)
            sqlite3_bind_int64(stmt, 19, Int64(s.archived))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }

        for m in messages {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db,
                "INSERT INTO messages (session_id, role, content, finish_reason, timestamp) VALUES (?,?,?,?,?)",
                -1, &stmt, nil)
            bindText(stmt, 1, sessions.first?.id ?? "s")
            bindText(stmt, 2, m.0)
            bindText(stmt, 3, m.1)
            bindText(stmt, 4, m.2)
            sqlite3_bind_double(stmt, 5, m.3)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        return url
    }

    private func bindText(_ stmt: OpaquePointer?, _ i: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, i, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, i)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ i: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, i, value) } else { sqlite3_bind_null(stmt, i) }
    }

    private func reader(_ adapter: HermesAdapter, _ id: String) throws -> any SessionReading {
        let r = adapter.makeReader(url: adapter.stateDBURL, sessionID: id)
        try r.refresh()
        return r
    }

    // MARK: - 1. Transcript identity

    func testIsTranscriptAndCanonicalURL() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        let base = adapter.stateDBURL.path
        XCTAssertTrue(adapter.isTranscript(path: base))
        XCTAssertTrue(adapter.isTranscript(path: base + "-wal"))
        XCTAssertTrue(adapter.isTranscript(path: base + "-shm"))
        XCTAssertFalse(adapter.isTranscript(path: root.appendingPathComponent("kanban.db").path))
        XCTAssertFalse(adapter.isTranscript(path: "/tmp/state.db"))

        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: base).path, base)
        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: base + "-wal").path, base)
        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: base + "-shm").path, base)
        XCTAssertTrue(adapter.multiSessionFiles)
        XCTAssertFalse(adapter.isActivityBased)
        XCTAssertTrue(adapter.sessionsAreParsed)
    }

    // MARK: - 2. recentTranscripts

    func testRecentTranscriptsOneRowPerSessionWithNewestMessageTS() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        let now = Date()
        let fresh = now.timeIntervalSince1970
        writeStateDB(root: root,
            sessions: [
                SessionInput(id: "fresh", cwd: "/Users/x/alpha", startedAt: fresh - 500),
                SessionInput(id: "stale", cwd: "/Users/x/beta", startedAt: fresh - 10_000),
                SessionInput(id: "archived", cwd: "/Users/x/gamma",
                             startedAt: fresh - 100, archived: 1),
            ],
            messages: [
                ("user", "hi", nil, fresh - 400),
                ("assistant", "yo", "stop", fresh - 300),  // newest for "fresh"
            ])
        // Messages above all reference "fresh" (writeStateDB attributes them to
        // the first session); "stale" has none so it falls back to started_at.

        let found = adapter.recentTranscripts(maxAge: 3600, now: now)
        // "fresh" is in-window, "stale" is 10k s old, "archived" is skipped.
        XCTAssertEqual(found.map(\.sessionID), ["fresh"])
        let row = try XCTUnwrap(found.first)
        XCTAssertEqual(row.sessionID, "fresh")
        XCTAssertEqual(row.projectDirName, "alpha")
        XCTAssertEqual(row.url, adapter.stateDBURL)
        // lastModified is the newest message timestamp, not started_at.
        XCTAssertEqual(row.lastModified.timeIntervalSince1970, fresh - 300, accuracy: 0.001)
    }

    func testRecentTranscriptsProjectFallbacks() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        let now = Date().timeIntervalSince1970
        writeStateDB(root: root, sessions: [
            SessionInput(id: "repo", cwd: "", gitRepoRoot: "/Users/x/myrepo", startedAt: now - 10),
            SessionInput(id: "bare", cwd: "", gitRepoRoot: nil, startedAt: now - 10),
        ])
        let found = adapter.recentTranscripts(maxAge: 3600, now: Date())
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.sessionID, $0.projectDirName) })
        XCTAssertEqual(byID["repo"], "myrepo")   // cwd empty → git repo basename
        XCTAssertEqual(byID["bare"], "hermes")   // nothing → agent id
    }

    // MARK: - 3. Turn-phase mapping

    private func phase(_ messages: [MessageInput]) throws -> TurnPhase {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(id: "s")], messages: messages)
        return try reader(adapter, "s").turnPhase
    }

    func testTurnPhaseMapping() throws {
        // assistant + tool_calls → mid-turn
        XCTAssertEqual(try phase([("user", "q", nil, 1), ("assistant", nil, "tool_calls", 2)]),
                       .midTurn)
        // assistant + terminal reason → completed
        XCTAssertEqual(try phase([("user", "q", nil, 1), ("assistant", "a", "stop", 2)]),
                       .completed)
        // trailing tool row → mid-turn
        XCTAssertEqual(try phase([("user", "q", nil, 1), ("assistant", nil, "tool_calls", 2),
                                  ("tool", "out", nil, 3)]), .midTurn)
        // trailing user → mid-turn (agent owes a reply)
        XCTAssertEqual(try phase([("assistant", "a", "stop", 1), ("user", "again", nil, 2)]),
                       .midTurn)
        // no messages → idle
        XCTAssertEqual(try phase([]), .idle)
        // trailing system row is skipped: the assistant stop before it governs.
        XCTAssertEqual(try phase([("user", "q", nil, 1), ("assistant", "a", "stop", 2),
                                  ("system", "note", nil, 3)]), .completed)
    }

    func testPendingToolUsesAndTurnStart() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(id: "s")], messages: [
            ("user", "do it", nil, 100),
            ("assistant", nil, "tool_calls", 200),
        ])
        let r = try reader(adapter, "s")
        XCTAssertTrue(r.hasPendingToolUses)
        XCTAssertEqual(r.currentTurnStartedAt?.timeIntervalSince1970, 100)  // the prompt
        XCTAssertEqual(r.lastGrowthAt?.timeIntervalSince1970, 200)          // newest msg
    }

    func testCompletedTurnHasNoPendingToolsOrTurnStart() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(id: "s")], messages: [
            ("user", "q", nil, 100), ("assistant", "a", "stop", 200),
        ])
        let r = try reader(adapter, "s")
        XCTAssertFalse(r.hasPendingToolUses)
        XCTAssertNil(r.currentTurnStartedAt)
    }

    // MARK: - 4. Cost sourcing (Hermes prices itself)

    func testActualCostBeatsEstimated() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", actualCost: 0.25, estimatedCost: 0.10)],
            messages: [("assistant", "a", "stop", 100)])
        let r = try reader(adapter, "s")
        XCTAssertEqual(r.cost.dollars, 0.25, accuracy: 1e-9)
        XCTAssertFalse(r.cost.hasUnknownPricing)
    }

    func testBothCostsNullFlagsUnknownPricing() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", model: "nvidia/nemotron", actualCost: nil, estimatedCost: nil)],
            messages: [("assistant", "a", "stop", 100)])
        let r = try reader(adapter, "s")
        XCTAssertEqual(r.cost.dollars, 0)
        XCTAssertTrue(r.cost.hasUnknownPricing)
        XCTAssertTrue(r.cost.unknownModels.contains("nvidia/nemotron"))
    }

    func testFreeModelZeroEstimateIsNotUnknownPricing() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", model: "nvidia/nemotron:free", actualCost: nil, estimatedCost: 0.0)],
            messages: [("assistant", "a", "stop", 100)])
        let r = try reader(adapter, "s")
        XCTAssertEqual(r.cost.dollars, 0)
        XCTAssertFalse(r.cost.hasUnknownPricing, "a real 0.0 estimate is a known price")
    }

    // MARK: - 5. Token mapping

    /// `reasoning_tokens` is a SUBSET of `output_tokens` — hermes-agent prints it
    /// as "↳ Reasoning (subset)". Adding the two bills thinking twice.
    func testReasoningTokensAreASubsetOfOutputNotAddedToIt() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", input: 1000, output: 200, cacheRead: 5000, cacheWrite: 300,
            reasoning: 50, estimatedCost: 0.5)],
            messages: [("assistant", "a", "stop", 100)])
        let c = try reader(adapter, "s").cost
        XCTAssertEqual(c.inputTokens, 1000)
        XCTAssertEqual(c.outputTokens, 200, "reasoning (50) is already inside output (200)")
        XCTAssertEqual(c.cacheReadTokens, 5000)
        XCTAssertEqual(c.cacheWriteTokens, 300)
        // totalTokens = input + output + cacheWrite; cache reads excluded.
        XCTAssertEqual(c.totalTokens, 1000 + 200 + 300)
    }

    // MARK: - 6. Daily bucketing (pinned timezone)

    func testSingleDaySessionBucketsAllCostOnThatDay() throws {
        let root = try makeRoot()
        let tz = TimeZone(identifier: "America/New_York")!
        let adapter = HermesAdapter(transcriptRoot: root, timeZone: tz)
        // 2026-07-08 09:36:58 UTC → still 2026-07-08 in New York (-04:00 → 05:36).
        let ts = 1_783_669_018.0
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", model: "deepseek-v4-pro", startedAt: ts, estimatedCost: 0.1029)],
            messages: [("assistant", "a", "stop", ts)])
        let r = try reader(adapter, "s")

        let expectedDay = LocalDay.start(of: Date(timeIntervalSince1970: ts), timeZone: tz)
        XCTAssertEqual(Set(r.dailyCosts.keys), [expectedDay])
        XCTAssertEqual(r.dailyCosts[expectedDay]?.dollars ?? -1, 0.1029, accuracy: 1e-9)
        XCTAssertEqual(r.dailyDollarsByModel[expectedDay]?["deepseek-v4-pro"] ?? -1,
                       0.1029, accuracy: 1e-9)
    }

    /// A session spanning midnight splits its cost across days by message count —
    /// stable (no day migrates), non-zero for the current day, total reconciles.
    func testOvernightSessionSplitsCostByMessageDayAndReconciles() throws {
        let root = try makeRoot()
        let tz = TimeZone(identifier: "America/New_York")!
        let adapter = HermesAdapter(transcriptRoot: root, timeZone: tz)
        // 3 messages on 2026-07-08, 1 message after midnight on 2026-07-09 ET.
        let day1 = 1_783_669_018.0                // 2026-07-08 05:36 ET
        let day2 = day1 + 86_400                   // ~2026-07-09
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", startedAt: day1, estimatedCost: 8.0)],
            messages: [("user", "a", nil, day1), ("assistant", "b", "stop", day1 + 10),
                       ("user", "c", nil, day1 + 20), ("assistant", "d", "stop", day2)])
        let r = try reader(adapter, "s")

        let d1 = LocalDay.start(of: Date(timeIntervalSince1970: day1), timeZone: tz)
        let d2 = LocalDay.start(of: Date(timeIntervalSince1970: day2), timeZone: tz)
        XCTAssertEqual(Set(r.dailyCosts.keys), [d1, d2], "cost lands on both days, not one")
        let sum = (r.dailyCosts[d1]?.dollars ?? 0) + (r.dailyCosts[d2]?.dollars ?? 0)
        XCTAssertEqual(sum, 8.0, accuracy: 1e-9, "the per-day parts reconcile to the total")
        XCTAssertGreaterThan(r.dailyCosts[d2]?.dollars ?? 0, 0, "the current day is not zeroed")
        XCTAssertEqual(r.dailyCosts[d1]?.dollars ?? 0, 6.0, accuracy: 1e-9, "3 of 4 messages")
    }

    // MARK: - 7. Process attribution

    func testAgentPIDsMatchesHermesButNotBundledNode() {
        let adapter = HermesAdapter()
        let psComm = """
        100 /Users/x/.local/bin/hermes
        200 /Users/x/.hermes/hermes-agent/venv/bin/python
        300 /Users/x/.hermes/node/bin/node
        """
        let psArgs = """
        100 /Users/x/.local/bin/hermes tui
        200 /Users/x/.hermes/hermes-agent/venv/bin/python /Users/x/.hermes/hermes-agent/venv/bin/hermes gateway
        300 /Users/x/.hermes/node/bin/node /Users/x/Library/claude-mem/mcp-server.cjs
        """
        // 100: hermes wrapper (comm). 200: hermes as a python argv token.
        // 300: bundled Node running claude-mem — explicitly rejected.
        XCTAssertEqual(adapter.agentPIDs(psComm: psComm, psArgs: psArgs), [100, 200])
    }

    // MARK: - 8. Store integration

    func testStoreShowsHermesSessionWithAgentBadge() async throws {
        let root = try makeRoot()
        let now = Date().timeIntervalSince1970
        writeStateDB(root: root,
            sessions: [SessionInput(id: "20260708_093658_8ac090",
                                    cwd: "/Users/x/agent-babysitter",
                                    startedAt: now - 120, estimatedCost: 0.1029)],
            messages: [("user", "help", nil, now - 90),
                       ("assistant", "done", "stop", now - 60)])

        let store = SessionStore(configuration: .init(
            projectsRoot: root,
            adapters: [HermesAdapter(transcriptRoot: root)]))
        await store.bootstrap()
        await store.processesUpdated(.init(
            processesByAdapter: ["hermes": [RunningProcess(pid: 42, cwd: "/Users/x/agent-babysitter")]],
            degraded: false))

        let rows = await store.rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].agentID, "hermes")
        XCTAssertEqual(rows[0].agentName, "Hermes")
        XCTAssertEqual(rows[0].projectName, "agent-babysitter")
        XCTAssertEqual(rows[0].pid, 42)
        XCTAssertEqual(rows[0].state, .done, "trailing assistant stop is a finished turn")
    }

    // MARK: - 9. Which children are user-facing

    /// hermes-agent's own picker (hermes_state.py) lists roots + /branch children,
    /// and hides subagent runs and compression continuations. A bare
    /// `parent_session_id != NULL` test would wrongly hide a branch.
    func testRootSessionIsNotASidechain() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(id: "s")],
                     messages: [("assistant", "a", "stop", 100)])
        XCTAssertFalse(try reader(adapter, "s").isSidechain)
    }

    func testCompressionContinuationIsASidechain() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [
            SessionInput(id: "parent", startedAt: 10, endedAt: 20, endReason: "compression"),
            SessionInput(id: "child", parentSessionID: "parent", startedAt: 30),
        ], messages: [])
        XCTAssertTrue(try reader(adapter, "child").isSidechain,
                      "a compression continuation is not a session the user picks")
    }

    func testBranchChildIsNotASidechain() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [
            SessionInput(id: "parent", startedAt: 10, endedAt: 20, endReason: "branched"),
            SessionInput(id: "child", modelConfig: #"{"_branched_from":"parent"}"#,
                         parentSessionID: "parent", startedAt: 30),
        ], messages: [])
        XCTAssertFalse(try reader(adapter, "child").isSidechain,
                       "a /branch stays visible even though it has a parent")
    }

    // MARK: - 10. A failed read must never look like a $0 session

    func testCorruptDBKeepsLastGoodCostAndStaysUnreadable() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", input: 1000, output: 200, estimatedCost: 4.2)],
            messages: [("assistant", "a", "stop", 100)])
        let r = adapter.makeReader(url: adapter.stateDBURL, sessionID: "s")
        try r.refresh()
        XCTAssertEqual(r.cost.dollars, 4.2, accuracy: 0.0001)
        XCTAssertFalse(r.isUnreadable)

        // Corrupt the db in place, changing its size so the signature moves.
        try Data(repeating: 0x41, count: 4096).write(to: adapter.stateDBURL)
        try r.refresh()
        XCTAssertTrue(r.isUnreadable, "a torn/corrupt db is unreadable")
        XCTAssertEqual(r.cost.dollars, 4.2, accuracy: 0.0001,
                       "a failed read must not overwrite real spend with $0")
    }

    /// The disk signature must only advance after a SUCCESSFUL read, or a single
    /// bad copy latches the reader until state.db happens to change again.
    func testFailedReadRetriesOnNextTickWithUnchangedSignature() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        let dbURL = adapter.stateDBURL
        try Data(repeating: 0x41, count: 4096).write(to: dbURL)
        let r = adapter.makeReader(url: dbURL, sessionID: "s")
        try r.refresh()
        XCTAssertTrue(r.isUnreadable)

        // Same path, same size/mtime signature is irrelevant: replace with a good
        // db of the SAME byte length so only a genuine retry can recover.
        try FileManager.default.removeItem(at: dbURL)
        writeStateDB(root: root, sessions: [SessionInput(id: "s", estimatedCost: 1.5)],
                     messages: [("assistant", "a", "stop", 100)])
        try r.refresh()
        XCTAssertFalse(r.isUnreadable, "reader retried instead of latching on the failure")
        XCTAssertEqual(r.cost.dollars, 1.5, accuracy: 0.0001)
    }

    // MARK: - 11. Malformed model_config must not brick the read

    /// json_extract raises on non-JSON model_config; an empty string is non-NULL
    /// so COALESCE didn't guard it. The session must stay readable, not vanish.
    func testEmptyOrGarbageModelConfigStaysReadable() throws {
        let root = try makeRoot()
        let adapter = HermesAdapter(transcriptRoot: root)
        writeStateDB(root: root, sessions: [SessionInput(
            id: "s", modelConfig: "", estimatedCost: 2.5)],
            messages: [("assistant", "a", "stop", 100)])
        let r = try reader(adapter, "s")
        XCTAssertFalse(r.isUnreadable, "empty model_config must not error the whole read")
        XCTAssertEqual(r.cost.dollars, 2.5, accuracy: 0.0001)

        writeStateDB(root: root, sessions: [SessionInput(
            id: "g", modelConfig: "not json", estimatedCost: 3.0)],
            messages: [("assistant", "a", "stop", 100)])
        let r2 = try reader(adapter, "g")
        XCTAssertFalse(r2.isUnreadable)
        XCTAssertEqual(r2.cost.dollars, 3.0, accuracy: 0.0001)
    }

    // Cost-day stability across midnight is now covered by
    // testOvernightSessionSplitsCostByMessageDayAndReconciles (proportional split),
    // which supersedes the old start-day approach that zeroed today's activity.

    // MARK: - 13. A single TUI pid must not be shared with old sessions

    func testMatchDoesNotFanOutAPidToStaleSessions() {
        let adapter = HermesAdapter()
        let now = Date()
        let active = SessionMatchCandidate(sessionID: "active", projectDirName: "hermes",
                                           lastKnownCWD: nil, lastModified: now)
        let stale = SessionMatchCandidate(sessionID: "stale", projectDirName: "hermes",
                                          lastKnownCWD: nil,
                                          lastModified: now.addingTimeInterval(-7200))
        let match = adapter.match(processes: [RunningProcess(pid: 5, cwd: "/")],
                                  candidates: [active, stale])
        XCTAssertEqual(match["active"], 5)
        XCTAssertNil(match["stale"], "an abandoned session must read Ended, not borrow a live pid")
    }
}
