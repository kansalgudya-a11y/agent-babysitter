import XCTest
@testable import AgentBabysitterCore

final class QuietHoursTests: XCTestCase {
    private func at(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date())!
    }

    func testDaytimeWindowDoesNotWrap() {
        XCTAssertFalse(QuietHours.isQuiet(now: at(8), startHour: 9, endHour: 17))
        XCTAssertTrue(QuietHours.isQuiet(now: at(12), startHour: 9, endHour: 17))
        XCTAssertFalse(QuietHours.isQuiet(now: at(17), startHour: 9, endHour: 17)) // end exclusive
    }

    func testOvernightWindowWrapsMidnight() {
        // Quiet 22:00 → 08:00
        XCTAssertTrue(QuietHours.isQuiet(now: at(23), startHour: 22, endHour: 8))
        XCTAssertTrue(QuietHours.isQuiet(now: at(3), startHour: 22, endHour: 8))
        XCTAssertFalse(QuietHours.isQuiet(now: at(9), startHour: 22, endHour: 8))
        XCTAssertTrue(QuietHours.isQuiet(now: at(22), startHour: 22, endHour: 8)) // start inclusive
    }

    func testEqualHoursMeansNever() {
        XCTAssertFalse(QuietHours.isQuiet(now: at(5), startHour: 0, endHour: 0))
    }
}

final class AgentHealthTests: XCTestCase {
    func testFlagsOnlyWhenRunningWritingAndUnreadable() {
        XCTAssertEqual(AgentHealth.status(running: true, dataRecentlyModified: true,
                                          sessionsParsed: 0), .cannotRead)
        // Any one condition off → ok (no false alarms).
        XCTAssertEqual(AgentHealth.status(running: false, dataRecentlyModified: true,
                                          sessionsParsed: 0), .ok)
        XCTAssertEqual(AgentHealth.status(running: true, dataRecentlyModified: false,
                                          sessionsParsed: 0), .ok)
        XCTAssertEqual(AgentHealth.status(running: true, dataRecentlyModified: true,
                                          sessionsParsed: 2), .ok)
    }
}

final class CostBudgetPlannerTests: XCTestCase {
    func testFiresOncePerWindowWhenCrossed() {
        let first = CostBudgetPlanner.plan(
            todaySpent: 55, dailyBudget: 50, dayKey: "2026-07-06",
            weekSpent: 120, weeklyBudget: 300, weekKey: "2026-W27",
            alertedDayKey: nil, alertedWeekKey: nil)
        XCTAssertEqual(first.alerts, [.init(isWeekly: false, spent: 55, budget: 50)])
        XCTAssertEqual(first.alertedDayKey, "2026-07-06")

        // Same day, higher spend → no re-fire.
        let again = CostBudgetPlanner.plan(
            todaySpent: 70, dailyBudget: 50, dayKey: "2026-07-06",
            weekSpent: 120, weeklyBudget: 300, weekKey: "2026-W27",
            alertedDayKey: first.alertedDayKey, alertedWeekKey: first.alertedWeekKey)
        XCTAssertTrue(again.alerts.isEmpty)
    }

    func testNewDayReArms() {
        let next = CostBudgetPlanner.plan(
            todaySpent: 51, dailyBudget: 50, dayKey: "2026-07-07",
            weekSpent: 10, weeklyBudget: 300, weekKey: "2026-W28",
            alertedDayKey: "2026-07-06", alertedWeekKey: nil)
        XCTAssertEqual(next.alerts.map(\.isWeekly), [false])
    }

    func testZeroBudgetIsOff() {
        let out = CostBudgetPlanner.plan(
            todaySpent: 999, dailyBudget: 0, dayKey: "d",
            weekSpent: 999, weeklyBudget: 0, weekKey: "w",
            alertedDayKey: nil, alertedWeekKey: nil)
        XCTAssertTrue(out.alerts.isEmpty)
    }

    func testWeeklyFiresIndependently() {
        let out = CostBudgetPlanner.plan(
            todaySpent: 5, dailyBudget: 50, dayKey: "d",
            weekSpent: 305, weeklyBudget: 300, weekKey: "w",
            alertedDayKey: nil, alertedWeekKey: nil)
        XCTAssertEqual(out.alerts, [.init(isWeekly: true, spent: 305, budget: 300)])
    }
}

final class StatsLedgerSumTests: XCTestCase {
    func testCrossMachineSumsPerDay() {
        // Each machine's file holds its own totals; the household view sums.
        let macA = StatsLedger.Ledger(
            costByAgent: ["2026-07-06": ["claude-code": 50]],
            costByProject: ["2026-07-06": ["web": 30]],
            sessionCounts: ["2026-07-06": 3], activeMinutes: ["2026-07-06": 40])
        let macB = StatsLedger.Ledger(
            costByAgent: ["2026-07-06": ["claude-code": 30, "codex": 10]],
            costByProject: ["2026-07-06": ["web": 20]],
            sessionCounts: ["2026-07-06": 2], activeMinutes: ["2026-07-06": 25])
        let sum = StatsLedger.summed([macA, macB])
        XCTAssertEqual(sum.costByAgent["2026-07-06"], ["claude-code": 80, "codex": 10]) // sum, not max
        XCTAssertEqual(sum.costByProject["2026-07-06"], ["web": 50])
        XCTAssertEqual(sum.sessionCounts["2026-07-06"], 5)
        XCTAssertEqual(sum.activeMinutes["2026-07-06"], 65)
    }
}

final class AgentHealthExclusionTests: XCTestCase {
    // Documents the invariant the app-layer relies on: activity-based agents
    // are excluded from the check (0 parsed is normal for them), and hidden
    // sessions still count (tracked, not visible-row, is the input).
    func testHealthOnlyFlagsGenuinelyUnreadable() {
        // A file-based agent running + writing + zero tracked sessions.
        XCTAssertEqual(AgentHealth.status(running: true, dataRecentlyModified: true,
                                          sessionsParsed: 0), .cannotRead)
        // Same agent but with a tracked (possibly hidden) session → ok.
        XCTAssertEqual(AgentHealth.status(running: true, dataRecentlyModified: true,
                                          sessionsParsed: 1), .ok)
    }
}

final class StatsLedgerMergeTests: XCTestCase {
    func testMergesByMaxPerDay() {
        let a = StatsLedger.Ledger(
            costByAgent: ["2026-07-06": ["claude-code": 10]],
            costByProject: ["2026-07-06": ["web": 6]],
            sessionCounts: ["2026-07-06": 3],
            todaySessionIDs: ["a"], activeMinutes: ["2026-07-06": 30])
        let b = StatsLedger.Ledger(
            costByAgent: ["2026-07-06": ["claude-code": 8, "codex": 4],
                          "2026-07-05": ["codex": 2]],
            costByProject: ["2026-07-06": ["web": 9]],
            sessionCounts: ["2026-07-06": 5],
            todaySessionIDs: ["b"], activeMinutes: ["2026-07-06": 20])
        let m = StatsLedger.merged(a, b)
        XCTAssertEqual(m.costByAgent["2026-07-06"], ["claude-code": 10, "codex": 4])
        XCTAssertEqual(m.costByAgent["2026-07-05"], ["codex": 2])
        XCTAssertEqual(m.costByProject["2026-07-06"], ["web": 9])   // max
        XCTAssertEqual(m.sessionCounts["2026-07-06"], 5)            // max
        XCTAssertEqual(m.activeMinutes["2026-07-06"], 30)           // max
        XCTAssertEqual(m.todaySessionIDs, ["a", "b"])               // union
    }
}

final class SessionHistoryLedgerTests: XCTestCase {
    private func entry(_ id: String, endedAt: Date, dollars: Double = 1) -> SessionHistoryEntry {
        SessionHistoryEntry(id: id, sessionID: id, agentID: "claude-code",
                            agentName: "Claude Code", project: "p", cwd: nil,
                            startedAt: nil, endedAt: endedAt, dollars: dollars,
                            totalTokens: 100, transcriptPath: nil)
    }

    func testNewestFirstAndDedupesByID() {
        let now = Date()
        var h = SessionHistoryLedger.record(entry("a", endedAt: now.addingTimeInterval(-100)), into: [])
        h = SessionHistoryLedger.record(entry("b", endedAt: now), into: h)
        XCTAssertEqual(h.map(\.id), ["b", "a"])   // newest first
        // Re-record "a" with a fresh time + updated cost → moves up, no dup.
        h = SessionHistoryLedger.record(entry("a", endedAt: now.addingTimeInterval(10), dollars: 9), into: h)
        XCTAssertEqual(h.map(\.id), ["a", "b"])
        XCTAssertEqual(h.first?.dollars, 9)
    }

    func testPrunesToCap() {
        var h: [SessionHistoryEntry] = []
        for i in 0..<10 { h = SessionHistoryLedger.record(entry("\(i)", endedAt: Date().addingTimeInterval(Double(i))), into: h, keep: 3) }
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.map(\.id), ["9", "8", "7"])
    }
}

final class TokenSplitTests: XCTestCase {
    func testAccumulatorTracksTokenSplit() {
        var acc = CostAccumulator()
        acc.consume(TranscriptEntry(kind: .assistant(AssistantPayload(
            messageID: "m1", model: "claude-opus-4-8", stopReason: .endTurn,
            usage: TokenUsage(inputTokens: 100, outputTokens: 200,
                              cacheCreationInputTokens: 300, cacheReadInputTokens: 400),
            toolUses: [], hasText: true, hasThinking: false)),
            uuid: nil, timestamp: Date(), sessionID: "s", cwd: nil, isSidechain: false))
        XCTAssertEqual(acc.cost.inputTokens, 100)
        XCTAssertEqual(acc.cost.outputTokens, 200)
        XCTAssertEqual(acc.cost.cacheWriteTokens, 300)
        XCTAssertEqual(acc.cost.cacheReadTokens, 400)
        // totalTokens excludes cache reads by design: 100+200+300.
        XCTAssertEqual(acc.cost.totalTokens, 600)
    }
}
