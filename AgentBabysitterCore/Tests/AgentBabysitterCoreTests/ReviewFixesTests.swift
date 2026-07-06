import XCTest
@testable import AgentBabysitterCore

final class HookCommandUpgradeTests: XCTestCase {

    /// An install over settings holding an OLD version of our command (same
    /// marker, different template) must upgrade the command in place.
    func testUpgradesStaleCommandInPlace() throws {
        let stale = Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command",
        "command":"old-template #\(HooksInstaller.marker)"}]}]}}
        """.utf8)
        let updated = try HooksInstaller.settingsWithHooksInstalled(stale, eventLogPath: "/tmp/e.jsonl")
        let text = String(data: updated, encoding: .utf8)!
        XCTAssertFalse(text.contains("old-template"))
        XCTAssertTrue(text.contains("umask 077"))
        // Still exactly one of ours per event (Notification/Stop/PreToolUse).
        XCTAssertEqual(text.components(separatedBy: HooksInstaller.marker).count - 1, 3)
    }

    func testForeignHooksSurviveUpgrade() throws {
        let mixed = Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-own-hook.sh"}]},
        {"hooks":[{"type":"command","command":"old #\(HooksInstaller.marker)"}]}]}}
        """.utf8)
        let updated = try HooksInstaller.settingsWithHooksInstalled(mixed, eventLogPath: "/tmp/e.jsonl")
        let text = String(data: updated, encoding: .utf8)!
        XCTAssertTrue(text.contains("my-own-hook.sh"))
        XCTAssertFalse(text.contains("\"old #"))
    }

    func testHookCommandKeepsLogPrivate() throws {
        let updated = try HooksInstaller.settingsWithHooksInstalled(nil, eventLogPath: "/tmp/e.jsonl")
        XCTAssertTrue(String(data: updated, encoding: .utf8)!.contains("umask 077"))
    }
}

final class ClaudeLiveParsingTests: XCTestCase {

    func testParsesUnifiedHeaders() {
        let snapshot = ClaudeLiveParsing.snapshot(fromHeaders: [
            "Anthropic-Ratelimit-Unified-5h-Utilization": "0.43",
            "anthropic-ratelimit-unified-5h-reset": "1783195800",
            "anthropic-ratelimit-unified-7d-utilization": "0.23",
            "anthropic-ratelimit-unified-7d-reset": "1783573200",
        ], plan: "pro")
        XCTAssertEqual(snapshot?.usedPercent ?? -1, 43, accuracy: 0.01)
        XCTAssertEqual(snapshot?.resetsAt, Date(timeIntervalSince1970: 1_783_195_800))
        XCTAssertEqual(snapshot?.weeklyUsedPercent ?? -1, 23, accuracy: 0.01)
        XCTAssertEqual(snapshot?.weeklyResetsAt, Date(timeIntervalSince1970: 1_783_573_200))
        XCTAssertEqual(snapshot?.plan, "pro")
        XCTAssertEqual(snapshot?.isLive, true)
    }

    func testMissingUtilizationYieldsNil() {
        XCTAssertNil(ClaudeLiveParsing.snapshot(fromHeaders: ["content-type": "application/json"],
                                                plan: nil))
    }

    func testFractionClamped() {
        let snapshot = ClaudeLiveParsing.snapshot(
            fromHeaders: ["anthropic-ratelimit-unified-5h-utilization": "1.7"], plan: nil)
        XCTAssertEqual(snapshot?.usedPercent, 100)
    }

    func testEnvValueExtraction() {
        let ps = "/path/to/claude --flag CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abcdef "
               + "CLAUDE_CODE_SUBSCRIPTION_TYPE=pro HOME=/Users/x"
        XCTAssertEqual(ClaudeLiveParsing.envValue("CLAUDE_CODE_OAUTH_TOKEN", inProcessEnv: ps),
                       "sk-ant-oat01-abcdef")
        XCTAssertEqual(ClaudeLiveParsing.envValue("CLAUDE_CODE_SUBSCRIPTION_TYPE", inProcessEnv: ps),
                       "pro")
        XCTAssertNil(ClaudeLiveParsing.envValue("MISSING_VAR", inProcessEnv: ps))
    }
}

final class LicenseParsingTests: XCTestCase {

    private let success = Data("""
    {"activated":true,"error":null,
     "license_key":{"id":1,"status":"active","key":"ABC-123-DEF","activation_limit":3},
     "instance":{"id":"inst-uuid-1","name":"My Mac"},
     "meta":{"store_id":111,"product_id":222,"customer_email":"x@y.z"}}
    """.utf8)

    func testActivateSuccess() {
        let result = LicenseParsing.activation(from: success,
            expecting: .init(storeID: nil, productID: nil))
        XCTAssertEqual(try? result.get(),
                       LicenseParsing.Activation(licenseKey: "ABC-123-DEF",
                                                 instanceID: "inst-uuid-1", status: "active"))
    }

    func testActivatePinnedToRightProduct() {
        let result = LicenseParsing.activation(from: success,
            expecting: .init(storeID: 111, productID: 222))
        XCTAssertNotNil(try? result.get())
    }

    func testForeignKeyRejectedWhenPinned() {
        let result = LicenseParsing.activation(from: success,
            expecting: .init(storeID: 999, productID: nil))
        XCTAssertEqual(result, .failure(.wrongProduct))
    }

    func testAPIErrorSurfaced() {
        let rejected = Data(#"{"activated":false,"error":"license_key not found"}"#.utf8)
        let result = LicenseParsing.activation(from: rejected,
            expecting: .init(storeID: nil, productID: nil))
        XCTAssertEqual(result, .failure(.rejected(message: "license_key not found")))
    }

    func testGarbageIsMalformed() {
        let result = LicenseParsing.activation(from: Data("nope".utf8),
            expecting: .init(storeID: nil, productID: nil))
        XCTAssertEqual(result, .failure(.malformed))
        XCTAssertFalse(LicenseParsing.isValid(validateResponse: Data("nope".utf8)))
    }

    func testValidate() {
        XCTAssertTrue(LicenseParsing.isValid(
            validateResponse: Data(#"{"valid":true,"error":null}"#.utf8)))
        XCTAssertFalse(LicenseParsing.isValid(
            validateResponse: Data(#"{"valid":false,"error":"expired"}"#.utf8)))
    }
}

final class BudgetInputTests: XCTestCase {

    func testPlainNumbers() {
        XCTAssertEqual(BudgetInput.parse("150"), 150)
        XCTAssertEqual(BudgetInput.parse("12.50"), 12.5, accuracy: 1e-9)
        XCTAssertEqual(BudgetInput.parse("0"), 0)
    }

    func testEmptyAndJunkAreOff() {
        XCTAssertEqual(BudgetInput.parse(""), 0)
        XCTAssertEqual(BudgetInput.parse("   "), 0)
        XCTAssertEqual(BudgetInput.parse("abc"), 0)
    }

    func testCurrencySymbolsAndSpacesStripped() {
        XCTAssertEqual(BudgetInput.parse("$150"), 150)
        XCTAssertEqual(BudgetInput.parse("£ 42"), 42)
        XCTAssertEqual(BudgetInput.parse("20 USD"), 20)
    }

    func testCommaDecimalAccepted() {
        XCTAssertEqual(BudgetInput.parse("12,50"), 12.5, accuracy: 1e-9)
    }

    /// A second separator must NOT make the whole thing unparseable (the old
    /// code turned "1.2.3" into 0, silently switching the budget OFF). The
    /// first dot is the decimal point; later dots drop but their digits stay.
    func testMultipleSeparatorsStayParseable() {
        XCTAssertEqual(BudgetInput.parse("1.2.3"), 1.23, accuracy: 1e-9)
        XCTAssertEqual(BudgetInput.parse("1.234.56"), 1.23456, accuracy: 1e-9)
        XCTAssertEqual(BudgetInput.parse("12..50"), 12.5, accuracy: 1e-9)   // fat-finger double dot
    }

    func testNeverNegative() {
        XCTAssertEqual(BudgetInput.parse("-30"), 30)  // stray minus is dropped, not negated
    }

    func testFormatRoundTrips() {
        XCTAssertEqual(BudgetInput.format(0), "")        // off shows empty
        XCTAssertEqual(BudgetInput.format(150), "150")   // whole number, no decimals
        XCTAssertEqual(BudgetInput.format(12.5), "12.50")
    }

    func testFormatParseIsStable() {
        for value: Double in [0, 5, 42, 150, 12.5, 99.99] {
            XCTAssertEqual(BudgetInput.parse(BudgetInput.format(value)), value, accuracy: 1e-9)
        }
    }
}
