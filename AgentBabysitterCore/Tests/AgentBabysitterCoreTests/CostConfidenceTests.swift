import XCTest
@testable import AgentBabysitterCore

final class CostConfidenceTests: XCTestCase {

    func testFullyPricedIsEstimated() {
        let c = SessionCost(dollars: 12.5)
        XCTAssertEqual(CostConfidence.level(for: c), .estimated)
        XCTAssertEqual(CostConfidence.amountPrefix(.estimated), "~")
    }

    func testMixedPricingIsPartialUndercount() {
        // Priced dollars plus a model we can't price → the total is a floor.
        let c = SessionCost(dollars: 12.5, totalTokens: 100, unknownModels: ["mystery-model"])
        XCTAssertEqual(CostConfidence.level(for: c), .partial)
        XCTAssertEqual(CostConfidence.amountPrefix(.partial), "≥")
        XCTAssertTrue(CostConfidence.detail(.partial, unknownModels: ["mystery-model"]).contains("mystery-model"))
    }

    func testOnlyUnknownModelIsUnpriced() {
        let c = SessionCost(dollars: 0, totalTokens: 5000, unknownModels: ["mystery-model"])
        XCTAssertEqual(CostConfidence.level(for: c), .unpriced)
        XCTAssertEqual(CostConfidence.amountPrefix(.unpriced), "")
    }

    func testEmptyCostIsEstimatedNotUnpriced() {
        XCTAssertEqual(CostConfidence.level(for: SessionCost()), .estimated)
    }
}
