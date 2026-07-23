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

// MARK: - Disk usage fallbacks (the wiring, not the adapters' parsing)

/// Minimal adapter for exercising the store's usage plumbing without dragging
/// in SQLite: its "quota file" is a text file holding a percentage, and it
/// counts how often the store actually reads it.
private struct StubUsageAdapter: AgentAdapter {
    /// Reference type so the count survives the struct being copied into (and
    /// out of) the store's configuration.
    final class Probe: @unchecked Sendable {
        var diskReads = 0
        /// How often the store asked WHERE the quota lives — the directory
        /// descent Codex pays for, separate from the parse.
        var sourceResolutions = 0
        /// Lets a test rotate the source the way Codex's newest rollout
        /// rotates with every new session.
        var source: URL?
    }

    let id: String
    let displayName = "Stub"
    let transcriptRoot: URL
    let focusBundleIdentifiers: [String] = []
    let source: URL?
    let probe: Probe
    var publishesUsageLimit: Bool = true

    func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: transcriptRoot, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "jsonl" }.map {
            SessionFileInfo(sessionID: sessionID(forTranscript: $0), projectDirName: "stub",
                            lastModified: Date(), url: $0)
        }
    }

    func isTranscript(path: String) -> Bool {
        path.hasPrefix(transcriptRoot.path) && path.hasSuffix(".jsonl")
    }

    func sessionID(forTranscript url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Codex format — the only transcript shape that carries a rate_limits
    /// reading, so it's what a stub needs to produce a non-nil `usageLimit`.
    func parseLine(_ line: Data) -> LineParseResult {
        CodexRolloutParser.parse(line, usageState: nil)
    }

    func agentPIDs(psComm: String, psArgs: String) -> [Int32] { [] }

    func match(processes: [RunningProcess],
               candidates: [SessionMatchCandidate]) -> [String: Int32] { [:] }

    func usageSourceFile() -> URL? {
        probe.sourceResolutions += 1
        return probe.source ?? source
    }

    func usageFromDisk() -> UsageLimitSnapshot? {
        probe.diskReads += 1
        guard let source = probe.source ?? source, let data = try? Data(contentsOf: source),
              let percent = Double(String(decoding: data, as: UTF8.self)
                  .trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return UsageLimitSnapshot(usedPercent: percent, windowMinutes: 10080,
                                  resetsAt: Date().addingTimeInterval(86_400),
                                  capturedAt: Date(), plan: "stub")
    }
}

final class SessionStoreUsageFallbackTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSource(_ name: String, percent: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try percent.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func setMTime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: url.path)
    }

    /// The 2s refresh tick must cost one `stat`, not one parse — including
    /// when the parse produced nothing, or a missing source re-scans forever.
    func testDiskUsageIsCachedByPathAndMtime() async throws {
        let source = try writeSource("quota.txt", percent: "24")
        // A whole-second mtime, so the filesystem's nanosecond field is zero
        // and every read-back compares exactly equal to what was written.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try setMTime(source, pinned)
        let probe = StubUsageAdapter.Probe()
        let adapter = StubUsageAdapter(id: "stub", transcriptRoot: root,
                                       source: source, probe: probe)
        let store = SessionStore(configuration: .init(projectsRoot: root, adapters: [adapter]))

        for _ in 0..<3 { _ = await store.usageLimits() }
        XCTAssertEqual(probe.diskReads, 1, "unchanged mtime re-reads nothing")

        // Content changes but the mtime is restored: the gate must hold, and
        // the cached value must still be the one served.
        try "77".write(to: source, atomically: false, encoding: .utf8)
        try setMTime(source, pinned)
        let cached = await store.usageLimits()["stub"]
        XCTAssertEqual(cached?.usedPercent, 24.0)
        XCTAssertEqual(probe.diskReads, 1)

        try setMTime(source, pinned.addingTimeInterval(5))
        let refreshed = await store.usageLimits()["stub"]
        XCTAssertEqual(refreshed?.usedPercent, 77.0)
        XCTAssertEqual(probe.diskReads, 2, "a moved mtime re-reads exactly once")

        // Negative caching: an unparseable source must not re-parse every tick.
        try "not a number".write(to: source, atomically: false, encoding: .utf8)
        try setMTime(source, pinned.addingTimeInterval(9))
        for _ in 0..<3 {
            let unreadable = await store.usageLimits()["stub"]
            XCTAssertNil(unreadable)
        }
        XCTAssertEqual(probe.diskReads, 3, "a nil result is cached too")
    }

    /// Resolving the source is a directory descent for Codex, and it used to
    /// run on every 2s tick for as long as the agent was closed — the exact
    /// state the disk fallback exists to serve. It is throttled now; the
    /// `stat` that notices a CHANGED file is not, so freshness is unaffected.
    func testSourceResolutionIsThrottledButFreshnessIsNot() async throws {
        let source = try writeSource("quota.txt", percent: "24")
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try setMTime(source, pinned)
        let probe = StubUsageAdapter.Probe()
        let adapter = StubUsageAdapter(id: "stub", transcriptRoot: root,
                                       source: source, probe: probe)
        let store = SessionStore(configuration: .init(projectsRoot: root, adapters: [adapter]))

        for _ in 0..<5 { _ = await store.usageLimits() }
        XCTAssertEqual(probe.sourceResolutions, 1, "one descent, not one per tick")

        // A file that changes under an already-resolved path is still seen on
        // the very next call — the throttle covers WHERE, never WHAT.
        try "77".write(to: source, atomically: false, encoding: .utf8)
        try setMTime(source, pinned.addingTimeInterval(5))
        let refreshed = await store.usageLimits()["stub"]
        XCTAssertEqual(refreshed?.usedPercent, 77.0)
        XCTAssertEqual(probe.sourceResolutions, 1)
    }

    /// An mtime gate wedges permanently if the mtime can never change again —
    /// a file dated in the future stays "newest" forever, and a restored or
    /// synced copy can carry a frozen timestamp. The re-read ceiling is the
    /// only thing standing between that and a stale number pinned on screen
    /// with no error and no way out.
    func testCachedReadingIsRereadOnceTheCeilingPasses() async throws {
        let source = try writeSource("quota.txt", percent: "24")
        // Dated well into the future, exactly like the case this guards.
        try setMTime(source, Date().addingTimeInterval(365 * 86_400))
        let probe = StubUsageAdapter.Probe()
        let adapter = StubUsageAdapter(id: "stub", transcriptRoot: root,
                                       source: source, probe: probe)
        let store = SessionStore(configuration: .init(projectsRoot: root, adapters: [adapter],
                                                      usageRereadInterval: 0))

        for _ in 0..<3 { _ = await store.usageLimits() }
        XCTAssertEqual(probe.diskReads, 3, "an unchangeable mtime must not freeze the reading")

        // Default ceiling: the same unchanged mtime is served from cache.
        let cachedStore = SessionStore(configuration: .init(projectsRoot: root,
                                                            adapters: [adapter]))
        let before = probe.diskReads
        for _ in 0..<3 { _ = await cachedStore.usageLimits() }
        XCTAssertEqual(probe.diskReads, before + 1, "still one read per tick-storm normally")
    }

    /// Codex's source path is whichever rollout is newest, so it rotates with
    /// every new session. A path-keyed cache that never evicts would grow one
    /// dead entry per session for the life of a process that runs for weeks.
    func testDiskUsageCacheDoesNotRetainRotatedSources() async throws {
        let first = try writeSource("first.txt", percent: "10")
        let second = try writeSource("second.txt", percent: "20")
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try setMTime(first, pinned)
        try setMTime(second, pinned)
        let probe = StubUsageAdapter.Probe()
        probe.source = first
        let adapter = StubUsageAdapter(id: "stub", transcriptRoot: root,
                                       source: first, probe: probe)
        // No source throttling here: the point under test is the cache, and
        // the rotation a real Codex install spreads over hours has to happen
        // inside one test.
        let store = SessionStore(configuration: .init(projectsRoot: root, adapters: [adapter],
                                                      usageSourceRecheck: 0))

        let onFirst = await store.usageLimits()["stub"]
        XCTAssertEqual(onFirst?.usedPercent, 10.0)
        probe.source = second
        let onSecond = await store.usageLimits()["stub"]
        XCTAssertEqual(onSecond?.usedPercent, 20.0)
        XCTAssertEqual(probe.diskReads, 2)

        // Back to the first path, unchanged mtime. A retained entry would
        // serve it from cache; an evicted one costs exactly one re-read.
        probe.source = first
        let backOnFirst = await store.usageLimits()["stub"]
        XCTAssertEqual(backOnFirst?.usedPercent, 10.0)
        XCTAssertEqual(probe.diskReads, 3, "the superseded path was evicted, not kept forever")
    }

    /// Antigravity's three surfaces all resolve the same shared state.vscdb.
    /// The old bespoke loop parsed it once and fanned the reading out; a cache
    /// keyed by adapter id instead of source path would triple that cost.
    func testAdaptersSharingASourceFileParseOnce() async throws {
        let source = try writeSource("shared.txt", percent: "5")
        let probe = StubUsageAdapter.Probe()
        let adapters = ["one", "two", "three"].map {
            StubUsageAdapter(id: $0, transcriptRoot: root, source: source, probe: probe)
        }
        let store = SessionStore(configuration: .init(projectsRoot: root, adapters: adapters))

        let limits = await store.usageLimits()
        XCTAssertEqual(limits.count, 3)
        XCTAssertEqual(limits["one"]?.usedPercent, 5.0)
        XCTAssertEqual(limits["three"]?.usedPercent, 5.0)
        XCTAssertEqual(probe.diskReads, 1, "one parse fills every id sharing the source")
    }

    /// The Hermes/OpenClaw invariant, declared rather than incidental: a
    /// reading from an agent that doesn't publish one never reaches the
    /// dictionary — so the alert planners, `limitDanger`, `hottestLimitPercent`
    /// and babysitter-debug inherit the rule, not just the menu.
    func testNonPublishingAgentIsOmittedFromUsageLimits() async throws {
        let resets = Date().addingTimeInterval(86_400).timeIntervalSince1970
        try ("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":61.0,\"window_minutes\":300,\"resets_at\":\(resets)},\"plan_type\":\"plus\"}}}\n")
            .write(to: root.appendingPathComponent("s1.jsonl"), atomically: false, encoding: .utf8)
        let source = try writeSource("quota.txt", percent: "24")
        let probe = StubUsageAdapter.Probe()

        let loud = StubUsageAdapter(id: "loud", transcriptRoot: root,
                                    source: source, probe: probe)
        let quiet = StubUsageAdapter(id: "quiet", transcriptRoot: root,
                                     source: source, probe: probe,
                                     publishesUsageLimit: false)
        let store = SessionStore(configuration: .init(projectsRoot: root,
                                                      adapters: [loud, quiet]))
        await store.bootstrap()

        let limits = await store.usageLimits()
        XCTAssertEqual(limits["loud"]?.usedPercent, 61.0,
                       "the session reading reaches a publishing agent")
        XCTAssertNil(limits["quiet"], "neither its session reading nor its disk source")
    }

    /// The flags themselves. Hermes and both OpenClaw surfaces are muted;
    /// every agent that can produce a reading stays in.
    func testUsageLimitPublishingFlags() {
        XCTAssertFalse(HermesAdapter().publishesUsageLimit)
        for surface in OpenClawAdapter.allSurfaces() {
            XCTAssertFalse(surface.publishesUsageLimit, "\(surface.id) records no quota")
        }
        let publishing: [any AgentAdapter] =
            [ClaudeCodeAdapter(), CodexAdapter(), CursorAdapter(), ManusAdapter()]
            + AntigravityAdapter.allSurfaces() + GeminiAdapter.allSurfaces()
        for adapter in publishing {
            XCTAssertTrue(adapter.publishesUsageLimit, "\(adapter.id) must stay in the list")
        }
    }
}
