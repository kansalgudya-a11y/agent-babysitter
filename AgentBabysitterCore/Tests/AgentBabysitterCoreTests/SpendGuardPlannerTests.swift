import XCTest
@testable import AgentBabysitterCore

final class SpendGuardPlannerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_783_158_000)

    private func row(_ id: String, _ state: SessionState, _ dollars: Double) -> SessionRow {
        SessionRow(id: id, projectName: "checkout", state: state,
                   turnStartedAt: nil, lastGrowthAt: nil, isUnreadable: false,
                   pid: 1, cwd: nil, cost: SessionCost(dollars: dollars))
    }

    func testBurningFastFiresOncePerEpisode() {
        var g = SpendGuardPlanner()
        // Anchor the window.
        XCTAssertEqual(g.evaluate(rows: [row("a", .working, 2)], now: base), [])
        // A full window later, $3 more = $3/min burn → fires once.
        let hits = g.evaluate(rows: [row("a", .working, 5)], now: base.addingTimeInterval(60))
        XCTAssertEqual(hits.map(\.id), ["a"])
        XCTAssertEqual(hits.first?.kind, .burningFast)
        XCTAssertEqual(hits.first?.burnRatePerMinute ?? 0, 3, accuracy: 0.001)
        // Still burning next window → no repeat (once per episode).
        XCTAssertEqual(g.evaluate(rows: [row("a", .working, 9)],
                                  now: base.addingTimeInterval(120)), [])
    }

    func testSlowBurnStaysQuiet() {
        var g = SpendGuardPlanner()
        _ = g.evaluate(rows: [row("a", .working, 2)], now: base)
        // Only $0.5 in a minute = $0.5/min < 1.5 threshold.
        XCTAssertEqual(g.evaluate(rows: [row("a", .working, 2.5)],
                                  now: base.addingTimeInterval(60)), [])
    }

    func testCheapSessionBelowFloorNeverBurnAlerts() {
        var g = SpendGuardPlanner()
        _ = g.evaluate(rows: [row("a", .working, 0.1)], now: base)
        // Burn is high ($1.4 in a min) but total is under the $2 floor.
        XCTAssertEqual(g.evaluate(rows: [row("a", .working, 1.5)],
                                  now: base.addingTimeInterval(60)), [])
    }

    func testCrossedBudgetFiresOnce() {
        var g = SpendGuardPlanner()
        XCTAssertEqual(g.evaluate(rows: [row("a", .working, 20)], now: base), [])
        let hits = g.evaluate(rows: [row("a", .working, 26)],
                              now: base.addingTimeInterval(1))
        XCTAssertEqual(hits.map(\.kind), [.crossedBudget])
        XCTAssertEqual(g.evaluate(rows: [row("a", .working, 40)],
                                  now: base.addingTimeInterval(2)), [])
    }

    func testNeverFiresOnDoneOrEndedSessions() {
        var g = SpendGuardPlanner()
        _ = g.evaluate(rows: [row("a", .done, 30)], now: base)
        XCTAssertEqual(g.evaluate(rows: [row("a", .done, 30)],
                                  now: base.addingTimeInterval(60)), [],
                       "a finished session that already spent $30 isn't a live nudge")
    }

    func testVanishedSessionResets() {
        var g = SpendGuardPlanner()
        _ = g.evaluate(rows: [row("a", .working, 2)], now: base)
        _ = g.evaluate(rows: [row("a", .working, 5)], now: base.addingTimeInterval(60)) // fires
        _ = g.evaluate(rows: [], now: base.addingTimeInterval(120))                      // gone
        // Returns later: fresh episode, needs a new window before it can fire.
        XCTAssertEqual(g.evaluate(rows: [row("a", .working, 5)],
                                  now: base.addingTimeInterval(200)), [])
        let hits = g.evaluate(rows: [row("a", .working, 9)],
                              now: base.addingTimeInterval(260))
        XCTAssertEqual(hits.map(\.kind), [.burningFast], "second episode earns its own nudge")
    }

    func testMessagesAreAdvisoryNotStopping() {
        let m = SpendGuardPlanner.message(.burningFast, project: "checkout", dollarsText: "$5", burnText: "$3")
        XCTAssertTrue(m.contains("checkout"))
        // Never tells the user we stopped/paused their work.
        for banned in ["stopped", "paused", "killed", "halted", "blocked"] {
            XCTAssertFalse(m.lowercased().contains(banned), "must not imply stopping work")
        }
    }
}
