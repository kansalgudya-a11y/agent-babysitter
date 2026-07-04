import XCTest
@testable import AgentBabysitterCore

final class SessionStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures on disk

    @discardableResult
    private func writeTranscript(project: String, session: String,
                                 cwd: String, lines: [String],
                                 age: TimeInterval = 0) throws -> URL {
        let dir = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        if age > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        return url
    }

    private func userLine(_ text: String, cwd: String) -> String {
        "{\"type\":\"user\",\"cwd\":\"\(cwd)\",\"timestamp\":\"2026-07-04T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    private func iso(_ date: Date) -> String {
        date.ISO8601Format(.iso8601(timeZone: .current).year().month().day()
            .timeZone(separator: .omitted).time(includingFractionalSeconds: true))
    }

    private func usageLine(tokens: Int, at date: Date) -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(iso(date))\",\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_\(UUID().uuidString)\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":\(tokens),\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func endTurnLine() -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-04T10:00:30.000Z\",\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func store() -> SessionStore {
        SessionStore(configuration: .init(projectsRoot: root))
    }

    // MARK: - Tests

    func testBootstrapShowsOnlySessionsWithLiveProcess() async throws {
        try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                            cwd: "/Users/dev/appA", lines: [userLine("hi", cwd: "/Users/dev/appA")])
        try writeTranscript(project: "-Users-dev-appB", session: "bbb",
                            cwd: "/Users/dev/appB", lines: [userLine("hi", cwd: "/Users/dev/appB")],
                            age: 3600)

        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 10, cwd: "/Users/dev/appA")],
                                           degraded: false))

        let rows = await store.rows()
        XCTAssertEqual(rows.map(\.id), ["aaa"], "processless transcripts don't appear at launch")
        XCTAssertEqual(rows[0].pid, 10)
        XCTAssertEqual(rows[0].projectName, "appA")
        XCTAssertEqual(rows[0].state, .working, "mid-turn transcript that just grew")
    }

    func testProcessGoneMarksSessionEnded() async throws {
        try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                            cwd: "/Users/dev/appA", lines: [userLine("hi", cwd: "/Users/dev/appA")])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 10, cwd: "/Users/dev/appA")],
                                           degraded: false))
        await store.processesUpdated(.init(processes: [], degraded: false))

        let rows = await store.rows()
        XCTAssertEqual(rows.count, 1, "ended sessions stay listed for the rest of the app run")
        XCTAssertEqual(rows[0].state, .ended)
        XCTAssertNil(rows[0].pid)
    }

    func testTranscriptChangeUpdatesState() async throws {
        let url = try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                                      cwd: "/Users/dev/appA",
                                      lines: [userLine("hi", cwd: "/Users/dev/appA")])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 10, cwd: "/Users/dev/appA")],
                                           degraded: false))

        // Turn completes on disk
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((endTurnLine() + "\n").utf8))
        try handle.close()
        await store.transcriptsChanged(paths: [url.path])

        let rows = await store.rows()
        XCTAssertEqual(rows[0].state, .done)
    }

    func testNewTranscriptAfterLaunchIsTracked() async throws {
        let store = store()
        await store.bootstrap()

        let url = try writeTranscript(project: "-Users-dev-appC", session: "ccc",
                                      cwd: "/Users/dev/appC",
                                      lines: [userLine("go", cwd: "/Users/dev/appC")])
        await store.transcriptsChanged(paths: [url.path])
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 33, cwd: "/Users/dev/appC")],
                                           degraded: false))

        let rows = await store.rows()
        XCTAssertEqual(rows.map(\.id), ["ccc"])
        XCTAssertEqual(rows[0].pid, 33)
    }

    func testDegradedScanKeepsLastKnownLiveness() async throws {
        try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                            cwd: "/Users/dev/appA", lines: [userLine("hi", cwd: "/Users/dev/appA")])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 10, cwd: "/Users/dev/appA")],
                                           degraded: false))
        // ps/lsof broke: don't declare everything Ended
        await store.processesUpdated(.init(processes: [], degraded: true))

        let rows = await store.rows()
        XCTAssertEqual(rows[0].pid, 10)
        XCTAssertNotEqual(rows[0].state, .ended)
        let degraded = await store.isProcessDetectionDegraded
        XCTAssertTrue(degraded)
    }

    func testRowsSortedByAttentionPriority() async throws {
        // appA: done (completed turn); appB: working (mid-turn, fresh)
        try writeTranscript(project: "-Users-dev-appA", session: "aaa", cwd: "/Users/dev/appA",
                            lines: [userLine("hi", cwd: "/Users/dev/appA"), endTurnLine()])
        try writeTranscript(project: "-Users-dev-appB", session: "bbb", cwd: "/Users/dev/appB",
                            lines: [userLine("hi", cwd: "/Users/dev/appB")])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 1, cwd: "/Users/dev/appA"),
                                                       RunningProcess(pid: 2, cwd: "/Users/dev/appB")],
                                           degraded: false))
        let rows = await store.rows()
        XCTAssertEqual(rows.map(\.id), ["bbb", "aaa"], "working outranks done in the list")
    }

    func testTodayCostUsesEntryTimestampsNotFileMTime() async throws {
        // A session spanning midnight: yesterday's entry must not count today
        // even though the FILE was modified today.
        let yesterdayEvening = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(-3600)
        try writeTranscript(project: "-Users-dev-appA", session: "spanning",
                            cwd: "/Users/dev/appA",
                            lines: [usageLine(tokens: 1_000_000, at: yesterdayEvening),
                                    usageLine(tokens: 200_000, at: Date())])

        let store = store()
        await store.bootstrap()
        let today = await store.todayCost()
        // Only today's 200k input on opus-4-8 = $1; yesterday's $5 excluded
        XCTAssertEqual(today.dollars, 1.0, accuracy: 0.0001)
    }

    func testPruneDropsProcesslessSessionsOutsideActiveWindow() async throws {
        try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                            cwd: "/Users/dev/appA",
                            lines: [userLine("hi", cwd: "/Users/dev/appA")])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 10, cwd: "/Users/dev/appA")],
                                           degraded: false))
        await store.processesUpdated(.init(processes: [], degraded: false))
        let before = await store.rows().count
        XCTAssertEqual(before, 1, "recently active: kept as Ended")

        // Evaluate a day-plus later: processless + stale -> gone
        let later = Date().addingTimeInterval(25 * 3600)
        let after = await store.rows(at: later).count
        XCTAssertEqual(after, 0)
    }

    func testDismissHidesRowUntilNewActivity() async throws {
        let url = try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                                      cwd: "/Users/dev/appA",
                                      lines: [userLine("hi", cwd: "/Users/dev/appA")])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 10, cwd: "/Users/dev/appA")],
                                           degraded: false))
        let visible = await store.rows().count
        XCTAssertEqual(visible, 1)

        await store.dismissSession(id: "aaa", agentID: "claude-code")
        let afterDismiss = await store.rows().count
        XCTAssertEqual(afterDismiss, 0, "dismissed rows are hidden")

        // New growth on disk brings it back
        try? await Task.sleep(for: .seconds(1.1))  // mtime granularity
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((endTurnLine() + "\n").utf8))
        try handle.close()
        await store.transcriptsChanged(paths: [url.path])
        let revived = await store.rows().count
        XCTAssertEqual(revived, 1, "activity clears the dismissal")
    }

    func testHookSignalBeforeTrackingIsBuffered() async throws {
        let store = store()
        // The transcript grew a while ago; the Notification hook fires now,
        // but reaches the store before FSEvents delivers the file path.
        let url = try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                                      cwd: "/Users/dev/appA",
                                      lines: [userLine("hi", cwd: "/Users/dev/appA")],
                                      age: 120)
        await store.hookSignalReceived(sessionID: "aaa",
                                       HookSignal(kind: .waitingForInput, timestamp: Date()))
        await store.transcriptsChanged(paths: [url.path])
        await store.updateConfiguration(.init(projectsRoot: root, precisionModeEnabled: true))
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 10, cwd: "/Users/dev/appA")],
                                           degraded: false))
        let rows = await store.rows()
        XCTAssertEqual(rows[0].state, .waitingForInput,
                       "buffered hook signal applies once the session is tracked")
    }

    func testRowCarriesSessionCost() async throws {
        let usage = "{\"type\":\"assistant\",\"timestamp\":\"\(iso(Date()))\",\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_c1\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":200000,\"output_tokens\":40000,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
        try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                            cwd: "/Users/dev/appA",
                            lines: [userLine("hi", cwd: "/Users/dev/appA"), usage])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 1, cwd: "/Users/dev/appA")],
                                           degraded: false))
        let rows = await store.rows()
        // 200k in ($1.00) + 40k out ($1.00) = $2.00
        XCTAssertEqual(rows[0].cost.dollars, 2.0, accuracy: 0.0001)
    }

    func testRowMarksDesktopAppSessions() async throws {
        let desktopLine = "{\"type\":\"user\",\"cwd\":\"/Users/dev/appA\",\"entrypoint\":\"claude-desktop\",\"timestamp\":\"2026-07-04T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"
        try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                            cwd: "/Users/dev/appA", lines: [desktopLine])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 1, cwd: "/Users/dev/appA")],
                                           degraded: false))
        let rows = await store.rows()
        XCTAssertEqual(rows[0].entrypoint, "claude-desktop")
        XCTAssertTrue(rows[0].isDesktopApp)
    }

    func testMenuBarSummaryAggregatesWorstState() async throws {
        try writeTranscript(project: "-Users-dev-appA", session: "aaa", cwd: "/Users/dev/appA",
                            lines: [userLine("hi", cwd: "/Users/dev/appA")])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 1, cwd: "/Users/dev/appA")],
                                           degraded: false))
        let summary = await store.menuBarSummary()
        XCTAssertEqual(summary.worstState, .working)
        XCTAssertEqual(summary.activeCount, 1)
    }
}
