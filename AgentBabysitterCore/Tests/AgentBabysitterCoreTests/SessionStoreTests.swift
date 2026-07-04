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

    func testTodayCostSumsOnlyTranscriptsModifiedToday() async throws {
        let usageLine = "{\"type\":\"assistant\",\"timestamp\":\"2026-07-04T10:00:30.000Z\",\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_c1\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
        // Today: 1M input on opus-4-8 = $5. Yesterday's session must not count.
        // Pin the old file's mtime to 23:00 local yesterday — always before
        // midnight regardless of when the test runs.
        let yesterdayEvening = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(-3600)
        try writeTranscript(project: "-Users-dev-appA", session: "today",
                            cwd: "/Users/dev/appA", lines: [usageLine])
        try writeTranscript(project: "-Users-dev-appB", session: "yesterday",
                            cwd: "/Users/dev/appB", lines: [usageLine],
                            age: Date().timeIntervalSince(yesterdayEvening))

        let store = store()
        await store.bootstrap()
        let today = await store.todayCost()
        XCTAssertEqual(today.dollars, 5.0, accuracy: 0.0001)
    }

    func testRowCarriesSessionCost() async throws {
        let usageLine = "{\"type\":\"assistant\",\"timestamp\":\"2026-07-04T10:00:30.000Z\",\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_c1\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":200000,\"output_tokens\":40000,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
        try writeTranscript(project: "-Users-dev-appA", session: "aaa",
                            cwd: "/Users/dev/appA",
                            lines: [userLine("hi", cwd: "/Users/dev/appA"), usageLine])
        let store = store()
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 1, cwd: "/Users/dev/appA")],
                                           degraded: false))
        let rows = await store.rows()
        // 200k in ($1.00) + 40k out ($1.00) = $2.00
        XCTAssertEqual(rows[0].cost.dollars, 2.0, accuracy: 0.0001)
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
