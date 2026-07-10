import XCTest
@testable import AgentBabysitterCore

final class ImpactLedgerTests: XCTestCase {

    func testRecordedAddsDeltasPerDay() {
        var l = ImpactLedger.Ledger()
        l = ImpactLedger.recorded(l, todayKey: "2026-07-08", stalls: 2, waits: 3, suggestions: 1, dollarsFlagged: 40)
        l = ImpactLedger.recorded(l, todayKey: "2026-07-08", stalls: 1, dollarsFlagged: 12)
        XCTAssertEqual(l.stallsCaught["2026-07-08"], 3)
        XCTAssertEqual(l.waitingPings["2026-07-08"], 3)
        XCTAssertEqual(l.suggestions["2026-07-08"], 1)
        XCTAssertEqual(l.dollarsFlagged["2026-07-08"] ?? 0, 52, accuracy: 0.001)
    }

    func testZeroDeltasDontCreateNoiseKeys() {
        let l = ImpactLedger.recorded(ImpactLedger.Ledger(), todayKey: "d", stalls: 0)
        XCTAssertNil(l.stallsCaught["d"], "a no-op tick shouldn't write an empty key")
    }

    func testSummaryRollsUpAcrossDays() {
        var l = ImpactLedger.Ledger()
        l = ImpactLedger.recorded(l, todayKey: "d1", stalls: 5, waits: 2, dollarsFlagged: 100)
        l = ImpactLedger.recorded(l, todayKey: "d2", stalls: 3, suggestions: 4, dollarsFlagged: 50)
        let s = ImpactLedger.summary(l, days: ["d1", "d2"])
        XCTAssertEqual(s.stalls, 8)
        XCTAssertEqual(s.waits, 2)
        XCTAssertEqual(s.suggestions, 4)
        XCTAssertEqual(s.dollarsFlagged, 150, accuracy: 0.001)
        XCTAssertTrue(s.hasContent)
        // A day outside the range is excluded.
        XCTAssertEqual(ImpactLedger.summary(l, days: ["d1"]).stalls, 5)
        XCTAssertFalse(ImpactLedger.Summary().hasContent)
    }

    func testPrunedDropsOldKeys() {
        var l = ImpactLedger.Ledger()
        l = ImpactLedger.recorded(l, todayKey: "2026-05-01", stalls: 3, dollarsFlagged: 10)
        l = ImpactLedger.recorded(l, todayKey: "2026-07-08", stalls: 5, dollarsFlagged: 20)
        let p = ImpactLedger.pruned(l, keepingFrom: "2026-07-01")
        XCTAssertNil(p.stallsCaught["2026-05-01"])
        XCTAssertNil(p.dollarsFlagged["2026-05-01"])
        XCTAssertEqual(p.stallsCaught["2026-07-08"], 5)
        XCTAssertEqual(p.dollarsFlagged["2026-07-08"] ?? 0, 20, accuracy: 0.001)
    }

    func testSummedAcrossMachines() {
        let a = ImpactLedger.recorded(.init(), todayKey: "d", stalls: 2, dollarsFlagged: 10)
        let b = ImpactLedger.recorded(.init(), todayKey: "d", stalls: 4, dollarsFlagged: 25)
        let out = ImpactLedger.summed([a, b])
        XCTAssertEqual(out.stallsCaught["d"], 6)
        XCTAssertEqual(out.dollarsFlagged["d"] ?? 0, 35, accuracy: 0.001)
    }
}
