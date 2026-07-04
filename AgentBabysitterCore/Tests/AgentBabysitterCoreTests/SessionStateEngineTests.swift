import XCTest
@testable import AgentBabysitterCore

final class SessionStateEngineTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_783_158_000)
    private let stall: TimeInterval = 300
    private let window: TimeInterval = 10

    private func signals(alive: Bool = true,
                         growthAge: TimeInterval? = 5,
                         phase: TurnPhase = .midTurn,
                         pending: Bool = false,
                         hook: HookSignal? = nil,
                         precision: Bool = false) -> SessionSignals {
        SessionSignals(processAlive: alive,
                       lastGrowthAt: growthAge.map { base.addingTimeInterval(-$0) },
                       turnPhase: phase,
                       hasPendingToolUses: pending,
                       latestHookEvent: hook,
                       precisionModeEnabled: precision)
    }

    private func evaluate(_ s: SessionSignals) -> SessionState {
        SessionStateEngine.evaluate(s, at: base, stallThreshold: stall, workingWindow: window)
    }

    // MARK: - Transition table: every (phase, pending, growth-age, alive) combination

    func testTransitionTable() {
        // (phase, pending, growthAge, alive) -> expected
        let table: [(TurnPhase, Bool, TimeInterval?, Bool, SessionState)] = [
            // Dead process wins over everything
            (.idle,      false, 5,    false, .ended),
            (.idle,      false, nil,  false, .ended),
            (.midTurn,   false, 5,    false, .ended),
            (.midTurn,   true,  60,   false, .ended),
            (.midTurn,   true,  400,  false, .ended),
            (.completed, false, 5,    false, .ended),
            (.aborted,   false, 400,  false, .ended),

            // Idle: session open, nothing asked yet
            (.idle,      false, 5,    true,  .done),
            (.idle,      false, 400,  true,  .done),
            (.idle,      false, nil,  true,  .done),

            // Completed / aborted turns are done regardless of growth recency
            // (meta lines keep appending after end_turn; that isn't "working")
            (.completed, false, 5,    true,  .done),
            (.completed, false, 60,   true,  .done),
            (.completed, false, 400,  true,  .done),
            (.aborted,   false, 5,    true,  .done),
            (.aborted,   false, 400,  true,  .done),

            // Mid-turn, no pending tool_use: streaming or thinking
            (.midTurn,   false, 5,    true,  .working),   // fresh growth
            (.midTurn,   false, 60,   true,  .working),   // quiet but under stall threshold
            (.midTurn,   false, 299,  true,  .working),
            (.midTurn,   false, 300,  true,  .stalled),   // at threshold
            (.midTurn,   false, 400,  true,  .stalled),
            (.midTurn,   false, nil,  true,  .stalled),   // no growth ever observed

            // Mid-turn with pending tool_use: permission prompt once quiet
            (.midTurn,   true,  5,    true,  .working),   // results still flowing
            (.midTurn,   true,  9.9,  true,  .working),
            (.midTurn,   true,  10,   true,  .waitingForInput),  // window boundary
            (.midTurn,   true,  60,   true,  .waitingForInput),
            (.midTurn,   true,  400,  true,  .waitingForInput),  // waiting outranks stalled
            (.midTurn,   true,  nil,  true,  .waitingForInput),
        ]

        for (phase, pending, age, alive, expected) in table {
            let state = evaluate(signals(alive: alive, growthAge: age,
                                         phase: phase, pending: pending))
            XCTAssertEqual(state, expected,
                           "phase=\(phase) pending=\(pending) age=\(String(describing: age)) alive=\(alive)")
        }
    }

    // MARK: - Precision mode hook overrides

    func testNotificationHookNewerThanGrowthForcesWaiting() {
        // Hook fired after the last transcript growth -> it knows better
        let hook = HookSignal(kind: .waitingForInput, timestamp: base.addingTimeInterval(-2))
        let s = signals(growthAge: 60, phase: .midTurn, pending: false, hook: hook, precision: true)
        XCTAssertEqual(evaluate(s), .waitingForInput)
    }

    func testStopHookNewerThanGrowthForcesDone() {
        let hook = HookSignal(kind: .turnCompleted, timestamp: base.addingTimeInterval(-2))
        let s = signals(growthAge: 60, phase: .midTurn, pending: true, hook: hook, precision: true)
        XCTAssertEqual(evaluate(s), .done)
    }

    func testHookOlderThanGrowthIsSuperseded() {
        // Transcript grew after the hook event: the session moved on
        let hook = HookSignal(kind: .waitingForInput, timestamp: base.addingTimeInterval(-60))
        let s = signals(growthAge: 5, phase: .midTurn, pending: false, hook: hook, precision: true)
        XCTAssertEqual(evaluate(s), .working)
    }

    func testHookIgnoredWhenPrecisionModeOff() {
        let hook = HookSignal(kind: .waitingForInput, timestamp: base.addingTimeInterval(-2))
        let s = signals(growthAge: 5, phase: .midTurn, pending: false, hook: hook, precision: false)
        XCTAssertEqual(evaluate(s), .working)
    }

    func testDeadProcessOutranksHookEvents() {
        let hook = HookSignal(kind: .waitingForInput, timestamp: base.addingTimeInterval(-2))
        let s = signals(alive: false, growthAge: 60, hook: hook, precision: true)
        XCTAssertEqual(evaluate(s), .ended)
    }

    func testHookWithNoGrowthObservedStillApplies() {
        let hook = HookSignal(kind: .turnCompleted, timestamp: base.addingTimeInterval(-2))
        let s = signals(growthAge: nil, phase: .midTurn, pending: false, hook: hook, precision: true)
        XCTAssertEqual(evaluate(s), .done)
    }

    // MARK: - Menu bar aggregation (worst state wins: 🟡 > 🔴 > 🟢 > 🔵)

    func testWorstStatePriority() {
        XCTAssertEqual(SessionState.worst(of: [.working, .done]), .working)
        XCTAssertEqual(SessionState.worst(of: [.working, .stalled, .done]), .stalled)
        XCTAssertEqual(SessionState.worst(of: [.stalled, .waitingForInput, .working]), .waitingForInput)
        XCTAssertEqual(SessionState.worst(of: [.done, .done]), .done)
        XCTAssertNil(SessionState.worst(of: []))
        // Ended sessions never drive the menu bar dot
        XCTAssertNil(SessionState.worst(of: [.ended, .ended]))
    }
}
