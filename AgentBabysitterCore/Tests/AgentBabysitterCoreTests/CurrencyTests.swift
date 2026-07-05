import XCTest
@testable import AgentBabysitterCore

final class CurrencyTests: XCTestCase {

    func testUSDNeedsNoRateAndKeepsDollarSign() {
        // USD ignores the rate entirely (offline default).
        XCTAssertEqual(CurrencyFormatter.string(usd: 1.22, currency: .usd, rate: 999),
                       "~$1.22")
        XCTAssertEqual(CurrencyFormatter.string(usd: 1.22, currency: .usd, rate: 1,
                                                approximate: false), "$1.22")
    }

    func testConvertsWithRateAndSymbol() {
        let inr = Currency.byCode("INR")!
        // 1.22 USD × 83.2 = 101.504 → "~₹101.50"
        XCTAssertEqual(CurrencyFormatter.string(usd: 1.22, currency: inr, rate: 83.2),
                       "~₹101.50")
    }

    func testZeroFractionDigitCurrencyRoundsWhole() {
        let jpy = Currency.byCode("JPY")!
        XCTAssertEqual(jpy.fractionDigits, 0)
        // 10 USD × 156.3 = 1563 → "~¥1,563"
        XCTAssertEqual(CurrencyFormatter.string(usd: 10, currency: jpy, rate: 156.3),
                       "~¥1,563")
    }

    func testGroupingSeparatorForLargeAmounts() {
        let inr = Currency.byCode("INR")!
        // 100 USD × 83 = 8300 → "~₹8,300.00"
        XCTAssertEqual(CurrencyFormatter.string(usd: 100, currency: inr, rate: 83),
                       "~₹8,300.00")
    }

    func testCompactForMenuBar() {
        let usd = Currency.usd
        XCTAssertEqual(CurrencyFormatter.compact(usd: 581, currency: usd, rate: 1), "$581")
        let inr = Currency.byCode("INR")!
        // 581 × 95.3 = 55369 → "₹55.4k"
        XCTAssertEqual(CurrencyFormatter.compact(usd: 581, currency: inr, rate: 95.3), "₹55.4k")
        // Millions roll to M.
        XCTAssertEqual(CurrencyFormatter.compact(usd: 20000, currency: inr, rate: 95.3),
                       "₹1.9M")
    }

    func testCatalogIsUSDFirstAndLookupWorks() {
        XCTAssertEqual(Currency.catalog.first, .usd)
        XCTAssertEqual(Currency.byCode("INR")?.symbol, "₹")
        XCTAssertNil(Currency.byCode("XYZ"))
    }

    // MARK: - Rate feed parsing (real open.er-api.com shape)

    func testParsesRateFeed() {
        let json = Data(#"""
        {"result":"success","base_code":"USD","time_last_update_unix":1783200000,
         "rates":{"USD":1,"INR":95.31,"EUR":0.874,"JPY":156.3}}
        """#.utf8)
        let rates = CurrencyRateParsing.parse(json)
        XCTAssertEqual(rates?.base, "USD")
        XCTAssertEqual(rates?.rate(for: "INR"), 95.31)
        XCTAssertEqual(rates?.rate(for: "USD"), 1)         // base always 1
        XCTAssertNil(rates?.rate(for: "XYZ"))
        XCTAssertEqual(rates?.updatedAt, Date(timeIntervalSince1970: 1783200000))
    }

    func testRejectsFailureAndGarbage() {
        XCTAssertNil(CurrencyRateParsing.parse(Data(#"{"result":"error"}"#.utf8)))
        XCTAssertNil(CurrencyRateParsing.parse(Data("not json".utf8)))
        XCTAssertNil(CurrencyRateParsing.parse(Data(#"{"result":"success","rates":{}}"#.utf8)))
    }
}

final class UsageLimitExpiryTests: XCTestCase {
    private func snap(resetsAt: Date?) -> UsageLimitSnapshot {
        UsageLimitSnapshot(usedPercent: 50, windowMinutes: 300, resetsAt: resetsAt,
                           capturedAt: Date(), plan: "pro")
    }

    func testExpiredWhenResetInPast() {
        let now = Date()
        XCTAssertTrue(snap(resetsAt: now.addingTimeInterval(-60)).isExpired(at: now))
    }

    func testNotExpiredWhenResetInFuture() {
        let now = Date()
        XCTAssertFalse(snap(resetsAt: now.addingTimeInterval(60)).isExpired(at: now))
    }

    func testNotExpiredWhenNoResetTime() {
        // Plan-only / no-reading snapshots have no reset — never "reset".
        XCTAssertFalse(snap(resetsAt: nil).isExpired())
    }
}
