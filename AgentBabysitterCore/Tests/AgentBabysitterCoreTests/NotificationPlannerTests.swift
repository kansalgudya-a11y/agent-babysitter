import XCTest
@testable import AgentBabysitterCore

final class NotificationPlannerTests: XCTestCase {

    private func row(_ id: String, _ state: SessionState) -> SessionRow {
        SessionRow(id: id, projectName: id, state: state, turnStartedAt: nil,
                   lastGrowthAt: nil, isUnreadable: false, pid: 1, cwd: nil)
    }

    func testFirstObservationFiresOnlyForAlreadyWaiting() {
        var planner = NotificationPlanner()
        // Launch scan: already-done/already-stalled stay quiet (the user just
        // opened the app and can see them). An already-WAITING session does
        // fire — you open the app precisely when you suspect an agent is
        // blocked, and that was the one case that used to stay silent forever.
        let events = planner.events(for: [row("a", .waitingForInput),
                                          row("b", .stalled),
                                          row("c", .done)])
        XCTAssertEqual(events, [NotificationEvent(sessionID: "a", kind: .waitingForInput)])
    }

    func testWaitingFiresOncePerEpisode() {
        var planner = NotificationPlanner()
        _ = planner.events(for: [row("a", .working)])

        let first = planner.events(for: [row("a", .waitingForInput)])
        XCTAssertEqual(first, [NotificationEvent(sessionID: "a", kind: .waitingForInput)])

        // Still waiting: no re-fire
        XCTAssertTrue(planner.events(for: [row("a", .waitingForInput)]).isEmpty)

        // Episode ends, next waiting episode fires again
        _ = planner.events(for: [row("a", .working)])
        let second = planner.events(for: [row("a", .waitingForInput)])
        XCTAssertEqual(second, [NotificationEvent(sessionID: "a", kind: .waitingForInput)])
    }

    func testTurnCompletionFiresOnlyAfterActivity() {
        var planner = NotificationPlanner()
        _ = planner.events(for: [row("a", .working)])
        let events = planner.events(for: [row("a", .done)])
        XCTAssertEqual(events, [NotificationEvent(sessionID: "a", kind: .turnCompleted)])

        // done -> done: nothing new
        XCTAssertTrue(planner.events(for: [row("a", .done)]).isEmpty)
    }

    func testDoneAfterWaitingAlsoCounts() {
        var planner = NotificationPlanner()
        _ = planner.events(for: [row("a", .working)])
        _ = planner.events(for: [row("a", .waitingForInput)])
        let events = planner.events(for: [row("a", .done)])
        XCTAssertEqual(events, [NotificationEvent(sessionID: "a", kind: .turnCompleted)])
    }

    func testStallFiresOnceThenIsRateLimitedAcrossFlapping() {
        var planner = NotificationPlanner()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = planner.events(for: [row("a", .working)], now: t0)

        XCTAssertEqual(planner.events(for: [row("a", .stalled)], now: t0),
                       [NotificationEvent(sessionID: "a", kind: .stalled)])
        XCTAssertTrue(planner.events(for: [row("a", .stalled)], now: t0).isEmpty)

        // Resume + re-stall INSIDE the cooldown: silent. A session flapping
        // stalled<->working through a chain of slow tool calls used to ding on
        // every cycle.
        _ = planner.events(for: [row("a", .working)], now: t0.addingTimeInterval(10))
        XCTAssertTrue(planner.events(for: [row("a", .stalled)],
                                     now: t0.addingTimeInterval(20)).isEmpty)

        // Past the cooldown it is a genuinely new stall, so it fires again.
        _ = planner.events(for: [row("a", .working)], now: t0.addingTimeInterval(700))
        XCTAssertEqual(planner.events(for: [row("a", .stalled)],
                                      now: t0.addingTimeInterval(701)),
                       [NotificationEvent(sessionID: "a", kind: .stalled)])
    }

    func testEndedSessionIsForgotten() {
        var planner = NotificationPlanner()
        _ = planner.events(for: [row("a", .working)])
        _ = planner.events(for: [row("a", .ended)])
        // Session comes back (same id re-observed): treated like first sight,
        // so a session that returns BLOCKED alerts rather than sitting silent.
        XCTAssertEqual(planner.events(for: [row("a", .waitingForInput)]),
                       [NotificationEvent(sessionID: "a", kind: .waitingForInput)])
    }

    func testMultipleSessionsAreIndependent() {
        var planner = NotificationPlanner()
        _ = planner.events(for: [row("a", .working), row("b", .working)])
        let events = planner.events(for: [row("a", .waitingForInput), row("b", .done)])
        XCTAssertEqual(Set(events), [NotificationEvent(sessionID: "a", kind: .waitingForInput),
                                     NotificationEvent(sessionID: "b", kind: .turnCompleted)])
    }

    func testWorkingToDoneWithoutEverWaitingOrStallingStillFires() {
        var planner = NotificationPlanner()
        _ = planner.events(for: [row("a", .working)])
        XCTAssertEqual(planner.events(for: [row("a", .done)]),
                       [NotificationEvent(sessionID: "a", kind: .turnCompleted)])
    }
}

final class ProcessAncestryTests: XCTestCase {

    func testAncestorsOfCurrentProcessIncludeParentAndTerminate() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ancestors = ProcessAncestry.ancestorPIDs(of: pid)
        XCTAssertFalse(ancestors.isEmpty)
        XCTAssertEqual(ancestors.first, getppid())
        XCTAssertEqual(ancestors.last, 1, "chain should reach launchd")
        XCTAssertLessThan(ancestors.count, 30)
    }

    func testUnknownPIDReturnsEmpty() {
        XCTAssertTrue(ProcessAncestry.ancestorPIDs(of: 99_999_999).isEmpty)
    }
}
