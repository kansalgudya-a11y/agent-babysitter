import XCTest
@testable import AgentBabysitterCore

final class UsageForecastTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_783_200_000)

    private func snapshot(used: Double, capturedMinutesAgo: Double,
                          resetsInMinutes: Double) -> UsageLimitSnapshot {
        UsageLimitSnapshot(usedPercent: used, windowMinutes: 300,
                           resetsAt: now.addingTimeInterval(resetsInMinutes * 60),
                           capturedAt: now.addingTimeInterval(-capturedMinutesAgo * 60),
                           plan: "plus")
    }

    /// The real-world case that prompted this: 7% captured with 81m left in
    /// the window, read an hour later — the vendor app showed 9%.
    func testExtrapolatesTheStaleCodexReading() {
        // Window: 300m. resets in 21m => window start 279m ago.
        // Captured 60m ago => 219m elapsed at capture, 7% used.
        let s = snapshot(used: 7, capturedMinutesAgo: 60, resetsInMinutes: 21)
        let estimate = try! XCTUnwrap(UsageForecast.estimatedCurrentPercent(s, now: now))
        XCTAssertEqual(estimate, 7 * 279 / 219, accuracy: 0.01)   // ≈ 8.9
    }

    func testFreshReadingIsNotSecondGuessed() {
        let s = snapshot(used: 40, capturedMinutesAgo: 2, resetsInMinutes: 100)
        XCTAssertNil(UsageForecast.estimatedCurrentPercent(s, now: now))
    }

    func testTinyReadingsAndYoungWindowsAreLeftAlone() {
        XCTAssertNil(UsageForecast.estimatedCurrentPercent(
            snapshot(used: 1, capturedMinutesAgo: 60, resetsInMinutes: 60), now: now))
        // Captured 5m into the window: elapsedAtCapture below the floor.
        XCTAssertNil(UsageForecast.estimatedCurrentPercent(
            snapshot(used: 50, capturedMinutesAgo: 15, resetsInMinutes: 290), now: now))
    }

    func testEstimateNeverExceedsFullOrDropsBelowRaw() {
        let s = snapshot(used: 80, capturedMinutesAgo: 200, resetsInMinutes: 10)
        XCTAssertEqual(UsageForecast.estimatedCurrentPercent(s, now: now), 100)
    }

    func testProjectsExhaustionBeforeReset() {
        // 60% used with 150m elapsed => 100% at 250m; window runs 300m.
        let s = snapshot(used: 60, capturedMinutesAgo: 0.01, resetsInMinutes: 150)
        let exhaustion = try! XCTUnwrap(UsageForecast.projectedExhaustion(s, now: now))
        let windowStart = s.resetsAt!.addingTimeInterval(-300 * 60)
        XCTAssertEqual(exhaustion.timeIntervalSince(windowStart), 250 * 60, accuracy: 60)
    }

    func testNoExhaustionWarningWhenPaceOutlastsReset() {
        // 10% at 150m elapsed => 100% at 1500m, way past the window.
        let s = snapshot(used: 10, capturedMinutesAgo: 0.01, resetsInMinutes: 150)
        XCTAssertNil(UsageForecast.projectedExhaustion(s, now: now))
    }

    func testExpiredWindowNeverForecasts() {
        let s = snapshot(used: 90, capturedMinutesAgo: 30, resetsInMinutes: -5)
        XCTAssertNil(UsageForecast.estimatedCurrentPercent(s, now: now))
        XCTAssertNil(UsageForecast.projectedExhaustion(s, now: now))
        XCTAssertNil(UsageForecast.projectedPercentAtReset(s, now: now))
    }

    func testProjectsPercentAtResetForAComfortablePace() {
        // 40% at 150m of a 300m window => on pace for 80% at reset.
        let s = snapshot(used: 40, capturedMinutesAgo: 0.01, resetsInMinutes: 150)
        let projected = try! XCTUnwrap(UsageForecast.projectedPercentAtReset(s, now: now))
        XCTAssertEqual(projected, 80, accuracy: 0.5)
        // A pace headed over 100% reports as such — callers hide it and let
        // the exhaustion warning speak instead.
        let hot = snapshot(used: 60, capturedMinutesAgo: 0.01, resetsInMinutes: 150)
        XCTAssertEqual(try! XCTUnwrap(UsageForecast.projectedPercentAtReset(hot, now: now)),
                       120, accuracy: 0.5)
        // Too young to measure: same floor as the exhaustion path.
        XCTAssertNil(UsageForecast.projectedPercentAtReset(
            snapshot(used: 50, capturedMinutesAgo: 15, resetsInMinutes: 290), now: now))
    }
}
