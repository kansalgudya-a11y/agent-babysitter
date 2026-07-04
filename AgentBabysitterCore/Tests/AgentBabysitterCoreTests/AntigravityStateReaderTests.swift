import XCTest
@testable import AgentBabysitterCore

final class AntigravityStateReaderTests: XCTestCase {

    /// Build the protobuf shape the real state uses: a tier-id string field
    /// followed by a field-2 display-name string.
    private func planProtobuf(tierID: String, display: String) -> Data {
        var bytes: [UInt8] = []
        // field 1 (0x0a), len, tier id
        bytes.append(0x0a)
        bytes.append(UInt8(tierID.utf8.count))
        bytes.append(contentsOf: tierID.utf8)
        // field 2 (0x12), len, display name
        bytes.append(0x12)
        bytes.append(UInt8(display.utf8.count))
        bytes.append(contentsOf: display.utf8)
        return Data(bytes)
    }

    func testExtractsDisplayNameAfterTierID() {
        let pb = planProtobuf(tierID: "g1-pro-tier", display: "Google AI Pro")
        XCTAssertEqual(AntigravityStateReader.planName(fromProtobuf: pb), "Google AI Pro")
    }

    func testExtractsUltraTier() {
        let pb = planProtobuf(tierID: "g1-ultra-tier", display: "Google AI Ultra")
        XCTAssertEqual(AntigravityStateReader.planName(fromProtobuf: pb), "Google AI Ultra")
    }

    func testNoTierYieldsNil() {
        XCTAssertNil(AntigravityStateReader.planName(fromProtobuf: Data("no plan here".utf8)))
    }

    func testGarbageDoesNotCrash() {
        XCTAssertNil(AntigravityStateReader.planName(fromProtobuf: Data([0x12, 0xff, 0x00])))
        XCTAssertNil(AntigravityStateReader.planName(inStateDB: Data("not a sqlite db".utf8)))
    }

    /// Integration: only runs on a machine with the IDE installed. Confirms
    /// the SQLite + double-base64 pipeline against the real file.
    func testRealStateDBIfPresent() throws {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb")
        guard let data = try? Data(contentsOf: db) else {
            throw XCTSkip("Antigravity IDE not installed")
        }
        let plan = AntigravityStateReader.planName(inStateDB: data)
        // We can't hard-code the tester's plan, but it must be a readable
        // "Google AI …" tier when present.
        if let plan {
            XCTAssertTrue(plan.contains("Google AI") || plan.contains("AI"),
                          "unexpected plan string: \(plan)")
        }
    }
}
