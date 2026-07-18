import XCTest
@testable import AgentBabysitterCore

final class UsageAlertPlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_783_200_000)

    private func snapshot(used: Double?, resets: Date?,
                          weekly: Double? = nil, weeklyResets: Date? = nil) -> UsageLimitSnapshot {
        UsageLimitSnapshot(usedPercent: used, windowMinutes: 300, resetsAt: resets,
                           capturedAt: now, plan: "pro",
                           weeklyUsedPercent: weekly, weeklyResetsAt: weeklyResets)
    }

    func testAlertsOncePerWindow() {
        let limits = ["claude-code": snapshot(used: 85, resets: now.addingTimeInterval(3600))]
        let first = UsageAlertPlanner.plan(limits: limits, threshold: 80,
                                           alertedFiveHour: [:], alertedWeekly: [:], now: now)
        XCTAssertEqual(first.alerts, [.init(agentID: "claude-code", isWeekly: false,
                                            usedPercent: 85,
                                            resetsAt: now.addingTimeInterval(3600))])
        let second = UsageAlertPlanner.plan(limits: limits, threshold: 80,
                                            alertedFiveHour: first.alertedFiveHour,
                                            alertedWeekly: first.alertedWeekly, now: now)
        XCTAssertTrue(second.alerts.isEmpty, "same window must not re-alert")
    }

    func testRearmsWhenWindowRollsOver() {
        let firstWindow = now.addingTimeInterval(600)
        let alerted = ["codex": firstWindow]
        let limits = ["codex": snapshot(used: 92, resets: now.addingTimeInterval(17_000))]
        let outcome = UsageAlertPlanner.plan(limits: limits, threshold: 80,
                                             alertedFiveHour: alerted, alertedWeekly: [:], now: now)
        XCTAssertEqual(outcome.alerts.count, 1, "a new window is a new alert")
    }

    func testStaleReadingNeverAlerts() {
        // The window this reading belongs to has already reset.
        let limits = ["codex": snapshot(used: 95, resets: now.addingTimeInterval(-60))]
        let outcome = UsageAlertPlanner.plan(limits: limits, threshold: 80,
                                             alertedFiveHour: [:], alertedWeekly: [:], now: now)
        XCTAssertTrue(outcome.alerts.isEmpty)
    }

    func testWeeklyWindowAlertsIndependently() {
        let limits = ["claude-code": snapshot(used: 10, resets: now.addingTimeInterval(3600),
                                              weekly: 88,
                                              weeklyResets: now.addingTimeInterval(86_400))]
        let outcome = UsageAlertPlanner.plan(limits: limits, threshold: 80,
                                             alertedFiveHour: [:], alertedWeekly: [:], now: now)
        XCTAssertEqual(outcome.alerts, [.init(agentID: "claude-code", isWeekly: true,
                                              usedPercent: 88,
                                              resetsAt: now.addingTimeInterval(86_400))])
    }

    func testBelowThresholdIsQuiet() {
        let limits = ["codex": snapshot(used: 79.9, resets: now.addingTimeInterval(3600))]
        let outcome = UsageAlertPlanner.plan(limits: limits, threshold: 80,
                                             alertedFiveHour: [:], alertedWeekly: [:], now: now)
        XCTAssertTrue(outcome.alerts.isEmpty)
    }
}

final class DailyCostHistoryTests: XCTestCase {

    func testAccumulatesTodayWithMaxGuard() {
        let now = Date()
        let key = DailyCostHistory.key(for: now)
        var history = DailyCostHistory.updated([:], now: now, dollars: 10)
        history = DailyCostHistory.updated(history, now: now, dollars: 7)  // prune dip
        XCTAssertEqual(history[key], 10)
        history = DailyCostHistory.updated(history, now: now, dollars: 12)
        XCTAssertEqual(history[key], 12)
    }

    func testDropsEntriesPastKeepWindow() {
        let now = Date()
        let old = DailyCostHistory.key(for: now.addingTimeInterval(-9 * 86_400))
        let history = DailyCostHistory.updated([old: 99, "garbage": 1], now: now, dollars: 5)
        XCTAssertNil(history[old])
        XCTAssertNil(history["garbage"])
        XCTAssertEqual(history.count, 1)
    }

    func testSeriesSortedOldestFirst() {
        let now = Date()
        let history = [
            DailyCostHistory.key(for: now): 3.0,
            DailyCostHistory.key(for: now.addingTimeInterval(-86_400)): 8.0,
        ]
        let series = DailyCostHistory.series(history)
        XCTAssertEqual(series.map(\.dollars), [8.0, 3.0])
    }
}

final class UsageLimitLayeringTests: XCTestCase {

    private func snapshot(used: Double?, at capturedAt: Date) -> UsageLimitSnapshot {
        UsageLimitSnapshot(usedPercent: used, windowMinutes: 300, resetsAt: nil,
                           capturedAt: capturedAt, plan: nil)
    }

    func testNewerOverlayWins() {
        let base = ["codex": snapshot(used: 10, at: Date(timeIntervalSince1970: 100))]
        let overlay = ["codex": snapshot(used: 20, at: Date(timeIntervalSince1970: 200))]
        let merged = UsageLimitLayering.merged(base: base, overlays: [overlay])
        XCTAssertEqual(merged["codex"]?.usedPercent, 20)
    }

    func testOlderOverlayNeverDisplacesRealPercent() {
        let base = ["codex": snapshot(used: 10, at: Date(timeIntervalSince1970: 300))]
        let overlay = ["codex": snapshot(used: 99, at: Date(timeIntervalSince1970: 200))]
        let merged = UsageLimitLayering.merged(base: base, overlays: [overlay])
        XCTAssertEqual(merged["codex"]?.usedPercent, 10)
    }

    func testOverlayFillsPlanOnlyBase() {
        // Plan-only base (no %) yields to any overlay with data.
        let base = ["antigravity": snapshot(used: nil, at: Date(timeIntervalSince1970: 300))]
        let overlay = ["antigravity": snapshot(used: 5, at: Date(timeIntervalSince1970: 200))]
        let merged = UsageLimitLayering.merged(base: base, overlays: [overlay])
        XCTAssertEqual(merged["antigravity"]?.usedPercent, 5)
    }

    func testLaterOverlaysLayerOverEarlier() {
        let overlay1 = ["claude-code": snapshot(used: 30, at: Date(timeIntervalSince1970: 100))]
        let overlay2 = ["claude-code": snapshot(used: 40, at: Date(timeIntervalSince1970: 200))]
        let merged = UsageLimitLayering.merged(base: [:], overlays: [overlay1, overlay2])
        XCTAssertEqual(merged["claude-code"]?.usedPercent, 40)
    }
}

final class SelfLimitingCommandTests: XCTestCase {

    /// The size guard must live in the shell command itself so an orphaned
    /// install can't grow the log unbounded.
    func testHookCommandGuardsLogSize() throws {
        let settings = try HooksInstaller.settingsWithHooksInstalled(nil, eventLogPath: "/tmp/e.jsonl")
        let text = String(data: settings, encoding: .utf8)!
        XCTAssertTrue(text.contains("stat -f%z"))
        XCTAssertTrue(text.contains("5242880"))
        XCTAssertTrue(text.contains("cat >\\/dev\\/null") || text.contains("cat >/dev/null"),
                      "stdin must always be drained")
    }

    func testStatusLineCommandGuardsLogSize() throws {
        let result = try StatusLineInstaller.settingsWithStatusLineInstalled(
            nil, eventLogPath: "/tmp/e.jsonl", originalCommandPath: "/tmp/orig.sh")
        let text = String(data: result.settings, encoding: .utf8)!
        XCTAssertTrue(text.contains("stat -f%z"))
        XCTAssertTrue(text.contains("5242880"))
    }

    func testStatusLineUpgradesStaleCommandPreservingPassthrough() throws {
        let staleCommand = "old-wrapper; printf x | /bin/sh '/tmp/orig.sh' #\(StatusLineInstaller.marker)"
        let root: [String: Any] = ["statusLine": ["type": "command", "command": staleCommand]]
        let data = try JSONSerialization.data(withJSONObject: root)

        let result = try StatusLineInstaller.settingsWithStatusLineInstalled(
            data, eventLogPath: "/tmp/e.jsonl", originalCommandPath: "/tmp/orig.sh")
        let updated = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: result.settings) as? [String: Any]))
        let command = try XCTUnwrap(
            (updated["statusLine"] as? [String: Any])?["command"] as? String)
        XCTAssertFalse(command.contains("old-wrapper"), "stale template must upgrade")
        XCTAssertTrue(command.contains("stat -f%z"))
        XCTAssertTrue(command.contains("/tmp/orig.sh"), "passthrough must be preserved")
        XCTAssertNil(result.backup, "upgrade must not create a new backup")
    }

    /// Behavioral check: run the real command against a fixture at and over
    /// the cap; the append must stop but stdin still be consumed.
    func testHookCommandBehavesAtCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("events.jsonl")

        let settings = try HooksInstaller.settingsWithHooksInstalled(nil, eventLogPath: log.path)
        let root = try JSONSerialization.jsonObject(with: settings) as! [String: Any]
        let hooks = ((root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]])
        let command = ((hooks[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)

        func run(_ input: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        try run("{\"a\":1}")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "{\"a\":1}\n")

        // Inflate past the cap; the next append must be skipped.
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        handle.write(Data(repeating: 0x78, count: 5 * 1024 * 1024))
        try handle.close()
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as! UInt64
        try run("{\"b\":2}")
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as! UInt64
        XCTAssertEqual(sizeBefore, sizeAfter, "append past the cap must be skipped")
    }
}

final class TokenFormattingTests: XCTestCase {
    func testRollsUnitsAtEachThousand() {
        XCTAssertEqual(SessionCost.abbreviatedCount(812), "812")
        XCTAssertEqual(SessionCost.abbreviatedCount(1_000), "1k")
        XCTAssertEqual(SessionCost.abbreviatedCount(1_900), "1.9k", "must NOT floor to 1k")
        XCTAssertEqual(SessionCost.abbreviatedCount(999_999), "1M", "rounds up, rolls to the next unit")
        XCTAssertEqual(SessionCost.abbreviatedCount(1_000_000), "1M")
        // The reported bug: 264,924k must read as millions.
        XCTAssertEqual(SessionCost.abbreviatedCount(264_924_000), "264.9M")
        XCTAssertEqual(SessionCost.abbreviatedCount(1_540_000_000), "1.5B")
    }
}

final class DoneAutoHideTests: XCTestCase {

    /// A done session older than the hide window disappears from rows;
    /// a fresh one stays; nil keeps everything.
    func testDoneRowsHideAfterConfiguredQuietTime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autohide-\(UUID().uuidString)/projects/-tmp-demo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // One Claude transcript whose last write was 20 minutes ago.
        let transcript = root.appendingPathComponent("11111111-aaaa-bbbb-cccc-000000000001.jsonl")
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20 * 60))
        try #"{"type":"user","timestamp":"__TS__","sessionId":"s1","cwd":"/tmp/demo","message":{"role":"user","content":"hi"}}"#
            .replacingOccurrences(of: "__TS__", with: ts)
            .write(to: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-20 * 60)],
            ofItemAtPath: transcript.path)

        func rows(hideAfter: TimeInterval?) async -> [SessionRow] {
            let store = SessionStore(configuration: .init(
                projectsRoot: root.deletingLastPathComponent(),
                adapters: [ClaudeCodeAdapter(transcriptRoot: root.deletingLastPathComponent())],
                doneAutoHide: hideAfter))
            await store.bootstrap()
            // Give the session a (dead) process history so the row qualifies.
            await store.processesUpdated(.init(processes: [
                RunningProcess(pid: 1, cwd: "/tmp/demo"),
            ], degraded: false))
            await store.processesUpdated(.init(processes: [], degraded: false))
            return await store.rows()
        }

        let hidden = await rows(hideAfter: 10 * 60)
        XCTAssertTrue(hidden.isEmpty, "20m-quiet finished session must hide at 10m setting")

        let kept = await rows(hideAfter: nil)
        XCTAssertEqual(kept.count, 1, "Never (nil) keeps finished sessions listed")

        let generous = await rows(hideAfter: 60 * 60)
        XCTAssertEqual(generous.count, 1, "still inside a 1h window")
    }
}

final class StatsLedgerTests: XCTestCase {

    func testMaxMergeAndSessionCounting() {
        var ledger = StatsLedger.Ledger()
        ledger = StatsLedger.ticked(ledger, todayKey: "2026-07-05",
                                    todayCostByAgent: ["claude-code": 10],
                                    visibleSessionIDs: ["a", "b"],
                                    anyWorking: true, secondsSinceLastTick: 2)
        ledger = StatsLedger.ticked(ledger, todayKey: "2026-07-05",
                                    todayCostByAgent: ["claude-code": 7],  // prune dip
                                    visibleSessionIDs: ["b", "c"],
                                    anyWorking: false, secondsSinceLastTick: 2)
        XCTAssertEqual(ledger.costByAgent["2026-07-05"]?["claude-code"], 10)
        XCTAssertEqual(ledger.sessionCounts["2026-07-05"], 3)
        XCTAssertEqual(ledger.activeMinutes["2026-07-05"] ?? 0, 2.0 / 60, accuracy: 0.001)
    }

    func testSleepWakeGapIsCapped() {
        let ledger = StatsLedger.ticked(.init(), todayKey: "d",
                                        todayCostByAgent: [:],
                                        visibleSessionIDs: [],
                                        anyWorking: true,
                                        secondsSinceLastTick: 8 * 3600)
        XCTAssertEqual(ledger.activeMinutes["d"], 1, "an 8h gap credits at most one minute")
    }
}
