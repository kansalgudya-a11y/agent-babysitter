import XCTest
@testable import AgentBabysitterCore

final class AntigravityStateReaderTests: XCTestCase {

    // MARK: - Protobuf builders (mirror the real UserStatus shapes)

    private func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        while v >= 0x80 { bytes.append(UInt8(v & 0x7f | 0x80)); v >>= 7 }
        bytes.append(UInt8(v))
        return bytes
    }

    private func tag(_ field: Int, _ wire: UInt64) -> [UInt8] {
        varint(UInt64(field) << 3 | wire)
    }

    private func lengthDelimited(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    private func str(_ field: Int, _ text: String) -> [UInt8] {
        lengthDelimited(field, Array(text.utf8))
    }

    private func doubleField(_ field: Int, _ value: Double) -> [UInt8] {
        var bytes = tag(field, 1)
        var raw = value.bitPattern.littleEndian
        withUnsafeBytes(of: &raw) { bytes.append(contentsOf: $0) }
        return bytes
    }

    private func varintField(_ field: Int, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    private func planProtobuf(tierID: String, display: String) -> Data {
        Data(str(1, tierID) + str(2, display))
    }

    private func floatField(_ field: Int, _ value: Float) -> [UInt8] {
        var bytes = tag(field, 5)
        var raw = value.bitPattern.littleEndian
        withUnsafeBytes(of: &raw) { bytes.append(contentsOf: $0) }
        return bytes
    }

    /// A model quota entry as stored: 1: name, 15: {1: remaining, 2: {1: reset}}.
    /// The real payload uses a float32 fraction; `asDouble` covers the wider
    /// encoding for robustness.
    private func quotaEntry(name: String, remaining: Double, reset: UInt64,
                            asDouble: Bool = false) -> [UInt8] {
        let resetMsg = varintField(1, reset)
        let fraction = asDouble ? doubleField(1, remaining)
                                : floatField(1, Float(remaining))
        let quota = fraction + lengthDelimited(2, resetMsg)
        return str(1, name) + lengthDelimited(15, quota)
    }

    // MARK: - Plan

    func testExtractsDisplayNameAfterTierID() {
        let pb = planProtobuf(tierID: "g1-pro-tier", display: "Google AI Pro")
        XCTAssertEqual(AntigravityStateReader.accountStatus(fromProtobuf: pb).plan, "Google AI Pro")
    }

    func testExtractsUltraTier() {
        let pb = planProtobuf(tierID: "g1-ultra-tier", display: "Google AI Ultra")
        XCTAssertEqual(AntigravityStateReader.accountStatus(fromProtobuf: pb).plan, "Google AI Ultra")
    }

    func testNoTierYieldsNilPlan() {
        XCTAssertNil(AntigravityStateReader.accountStatus(
            fromProtobuf: Data("no plan here".utf8)).plan)
    }

    func testGarbageDoesNotCrash() {
        let garbage = AntigravityStateReader.accountStatus(fromProtobuf: Data([0x12, 0xff, 0x00]))
        XCTAssertNil(garbage.plan)
        XCTAssertNil(garbage.fiveHourUsedPercent)
        XCTAssertNil(AntigravityStateReader.planName(inStateDB: Data("not a sqlite db".utf8)))
    }

    // MARK: - Five-hour quota

    func testExtractsMostUsedModelQuota() {
        // Gemini group 94.5% remaining (5.5% used), Claude group untouched —
        // the most-consumed entry governs, as it's the binding limit.
        let entries = lengthDelimited(1, quotaEntry(name: "Gemini 3.5 Flash (Medium)",
                                                    remaining: 0.945, reset: 1_783_205_351))
                    + lengthDelimited(1, quotaEntry(name: "Claude Sonnet 4.6 (Thinking)",
                                                    remaining: 1.0, reset: 1_783_214_680))
        let pb = Data(lengthDelimited(33, entries))
        let status = AntigravityStateReader.accountStatus(fromProtobuf: pb)
        XCTAssertEqual(status.fiveHourUsedPercent ?? -1, 5.5, accuracy: 0.01)
        XCTAssertEqual(status.fiveHourResetsAt,
                       Date(timeIntervalSince1970: 1_783_205_351))
    }

    func testUntouchedQuotaReadsZeroUsed() {
        let pb = Data(lengthDelimited(33, lengthDelimited(1, quotaEntry(
            name: "Claude Opus 4.6 (Thinking)", remaining: 1.0, reset: 1_783_214_680))))
        let status = AntigravityStateReader.accountStatus(fromProtobuf: pb)
        XCTAssertEqual(status.fiveHourUsedPercent, 0)
    }

    func testAcceptsDoubleEncodedFraction() {
        let pb = Data(lengthDelimited(33, lengthDelimited(1, quotaEntry(
            name: "Gemini 3.5 Flash (Medium)", remaining: 0.5,
            reset: 1_783_205_351, asDouble: true))))
        let status = AntigravityStateReader.accountStatus(fromProtobuf: pb)
        XCTAssertEqual(status.fiveHourUsedPercent ?? -1, 50, accuracy: 0.01)
    }

    func testOutOfRangeFractionIgnored() {
        let pb = Data(lengthDelimited(33, lengthDelimited(1, quotaEntry(
            name: "Weird", remaining: 42.0, reset: 1_783_205_351))))
        XCTAssertNil(AntigravityStateReader.accountStatus(fromProtobuf: pb).fiveHourUsedPercent)
    }

    func testPlanAndQuotaTogether() {
        let bytes = lengthDelimited(20, str(1, "g1-pro-tier") + str(2, "Google AI Pro"))
                  + lengthDelimited(33, lengthDelimited(1, quotaEntry(
                        name: "Gemini 3.1 Pro (High)", remaining: 0.25, reset: 1_783_205_351)))
        let status = AntigravityStateReader.accountStatus(fromProtobuf: Data(bytes))
        XCTAssertEqual(status.plan, "Google AI Pro")
        XCTAssertEqual(status.fiveHourUsedPercent ?? -1, 75, accuracy: 0.01)
    }

    /// Integration: only runs on a machine with the IDE installed. Confirms
    /// the SQLite + double-base64 + walker pipeline against the real file.
    func testRealStateDBIfPresent() throws {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb")
        guard let data = try? Data(contentsOf: db) else {
            throw XCTSkip("Antigravity IDE not installed")
        }
        guard let status = AntigravityStateReader.accountStatus(inStateDB: data) else {
            throw XCTSkip("no userStatus in state db")
        }
        if let plan = status.plan {
            XCTAssertTrue(plan.contains("AI"), "unexpected plan string: \(plan)")
        }
        if let used = status.fiveHourUsedPercent {
            XCTAssertTrue((0...100).contains(used), "used % out of range: \(used)")
        }
    }
}
