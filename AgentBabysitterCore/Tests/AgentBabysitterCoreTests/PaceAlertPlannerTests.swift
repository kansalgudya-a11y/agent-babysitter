import XCTest
@testable import AgentBabysitterCore

final class PaceAlertPlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_783_200_000)

    /// 60% used with 150m elapsed in a 300m window: pace hits 100% at 250m,
    /// 50m before the reset — the canonical "warn me now" shape.
    private func onPace(used: Double = 60, capturedMinutesAgo: Double = 0,
                        resetsInMinutes: Double = 150,
                        weeklyUsed: Double? = nil,
                        weeklyResetsInDays: Double? = nil) -> UsageLimitSnapshot {
        UsageLimitSnapshot(usedPercent: used, windowMinutes: 300,
                           resetsAt: now.addingTimeInterval(resetsInMinutes * 60),
                           capturedAt: now.addingTimeInterval(-capturedMinutesAgo * 60),
                           plan: "plus",
                           weeklyUsedPercent: weeklyUsed,
                           weeklyResetsAt: weeklyResetsInDays.map {
                               now.addingTimeInterval($0 * 86_400)
                           })
    }

    private func plan(_ limits: [String: UsageLimitSnapshot],
                      threshold: Double = 80,
                      alertedFiveHour: [String: Date] = [:],
                      alertedWeekly: [String: Date] = [:]) -> PaceAlertPlanner.Outcome {
        PaceAlertPlanner.plan(limits: limits, threshold: threshold,
                              alertedFiveHour: alertedFiveHour,
                              alertedWeekly: alertedWeekly, now: now)
    }

    func testWarnsWhenPaceExhaustsWellBeforeReset() {
        let outcome = plan(["claude-code": onPace()])
        XCTAssertEqual(outcome.alerts.count, 1)
        let alert = outcome.alerts[0]
        XCTAssertEqual(alert.agentID, "claude-code")
        XCTAssertFalse(alert.isWeekly)
        // Exhaustion at 250m of 300m => 100m from now, 50m before reset.
        XCTAssertEqual(alert.exhaustionAt.timeIntervalSince(now), 100 * 60, accuracy: 1)
        XCTAssertEqual(alert.resetsAt.timeIntervalSince(alert.exhaustionAt), 50 * 60, accuracy: 1)
    }

    func testComfortablePaceStaysQuiet() {
        // 40% at 150m: 100% would land at 375m — after the 300m reset.
        let outcome = plan(["claude-code": onPace(used: 40)])
        XCTAssertTrue(outcome.alerts.isEmpty)
    }

    func testEarlyWindowNoiseIsSuppressed() {
        // A burst to 25% still under the 30% floor: alarming pace, no signal.
        let outcome = plan(["claude-code": onPace(used: 25, resetsInMinutes: 260)])
        XCTAssertTrue(outcome.alerts.isEmpty)
    }

    func testHandsOffAboveTheReactiveThreshold() {
        // At 85% the threshold alert owns the banner; pace must not stack.
        let outcome = plan(["claude-code": onPace(used: 85)])
        XCTAssertTrue(outcome.alerts.isEmpty)
    }

    func testTinyShortfallIsNotWorthABanner() {
        // 51% at 150m: exhaustion at ~294m, only ~6m before the 300m reset.
        let outcome = plan(["claude-code": onPace(used: 51)])
        XCTAssertTrue(outcome.alerts.isEmpty)
    }

    func testOneWarningPerWindow() {
        let limit = onPace()
        let first = plan(["claude-code": limit])
        XCTAssertEqual(first.alerts.count, 1)
        let second = plan(["claude-code": limit],
                          alertedFiveHour: first.alertedFiveHour)
        XCTAssertTrue(second.alerts.isEmpty)
        // The next window (fresh resetsAt) re-arms the warning.
        let later = now.addingTimeInterval(300 * 60)
        let nextWindow = UsageLimitSnapshot(usedPercent: 60, windowMinutes: 300,
                                            resetsAt: later.addingTimeInterval(150 * 60),
                                            capturedAt: later, plan: "plus")
        let third = PaceAlertPlanner.plan(limits: ["claude-code": nextWindow],
                                          threshold: 80,
                                          alertedFiveHour: first.alertedFiveHour,
                                          alertedWeekly: [:], now: later)
        XCTAssertEqual(third.alerts.count, 1)
    }

    func testWeeklyPaceWarnsIndependently() {
        // Weekly: 50% used, resets in 2 days => window started 5 days ago;
        // pace hits 100% at day 10 of 7 — comfortable. 80%... over threshold.
        // Use 60%: exhaustion at 5/0.6 = 8.33 days — still after reset. 75%:
        // 5/0.75 = 6.67 days => 0.33 days (~8h) before reset. Fires.
        let outcome = plan(["claude-code": onPace(used: 40,
                                                  weeklyUsed: 75,
                                                  weeklyResetsInDays: 2)])
        XCTAssertEqual(outcome.alerts.count, 1)
        XCTAssertTrue(outcome.alerts[0].isWeekly)
        XCTAssertGreaterThan(outcome.alerts[0].resetsAt
            .timeIntervalSince(outcome.alerts[0].exhaustionAt), 3600)
    }

    func testExpiredWindowNeverWarns() {
        let outcome = plan(["claude-code": onPace(resetsInMinutes: -5)])
        XCTAssertTrue(outcome.alerts.isEmpty)
    }

    /// The planner must receive RAW snapshots — this pins the exhaustion math
    /// for a stale reading so a pace-corrected percent sneaking in (which
    /// would double-count the pace) fails the assertion.
    func testStaleReadingProjectsFromTheRawPace() {
        // Window 300m, resets in 150m => started 150m ago. Captured 30m ago
        // (elapsed 120m) at 60%: pace exhausts at 200m => 100m before reset.
        let outcome = plan(["claude-code": onPace(used: 60, capturedMinutesAgo: 30,
                                                  resetsInMinutes: 150)])
        XCTAssertEqual(outcome.alerts.count, 1)
        XCTAssertEqual(outcome.alerts[0].resetsAt
            .timeIntervalSince(outcome.alerts[0].exhaustionAt), 100 * 60, accuracy: 1)
        // The banner's percent is the pace-corrected estimate (150/120 · 60).
        XCTAssertEqual(outcome.alerts[0].usedPercent, 75, accuracy: 0.01)
    }

    func testReadingsOlderThanTheCeilingStayQuiet() {
        // Same alarming pace, but the reading is 2h old — the pace is stale
        // news, not a live warning. (Weekly windows especially: without this
        // a Friday reading could fire on Monday.)
        let outcome = plan(["claude-code": onPace(used: 60, capturedMinutesAgo: 120,
                                                  resetsInMinutes: 30)])
        XCTAssertTrue(outcome.alerts.isEmpty)
    }

    func testBandOpensAboveThresholdWhenAskedTo() {
        // AppModel passes threshold 101 when the reactive alert is off: 85%
        // on a bad pace must then still warn — nobody else will.
        let limit = onPace(used: 85)
        XCTAssertTrue(plan(["claude-code": limit]).alerts.isEmpty)   // handoff
        XCTAssertEqual(plan(["claude-code": limit], threshold: 101).alerts.count, 1)
    }
}
