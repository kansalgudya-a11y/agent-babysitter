import XCTest
@testable import AgentBabysitterCore

final class TranscriptFileTailerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func transcript(_ name: String = "session.jsonl") -> URL {
        tempDir.appendingPathComponent(name)
    }

    private func userLine(_ text: String) -> String {
        "{\"type\":\"user\",\"cwd\":\"/Users/dev/appA\",\"timestamp\":\"2026-07-04T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}\n"
    }

    private let endTurnLine = """
    {"type":"assistant","timestamp":"2026-07-04T10:00:30.000Z","message":{"model":"claude-opus-4-8",\
    "id":"msg_1","role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn",\
    "usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

    """

    func testCatchUpReadsWholeFileThenOnlyAppendedBytes() throws {
        let url = transcript()
        try userLine("first").write(to: url, atomically: false, encoding: .utf8)

        let tailer = TranscriptFileTailer(url: url)
        XCTAssertEqual(try tailer.catchUp().count, 1)
        XCTAssertEqual(tailer.reducer.turnPhase, .midTurn)

        // No growth -> nothing new
        XCTAssertEqual(try tailer.catchUp().count, 0)

        // Append and catch up again: only the new line is parsed
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(endTurnLine.utf8))
        try handle.close()

        let newEntries = try tailer.catchUp()
        XCTAssertEqual(newEntries.count, 1)
        XCTAssertEqual(tailer.reducer.turnPhase, .completed)
    }

    func testPartialLineAcrossCatchUpsIsNotLost() throws {
        let url = transcript()
        let full = userLine("hello")
        let half = full.index(full.startIndex, offsetBy: full.count / 2)

        try String(full[..<half]).write(to: url, atomically: false, encoding: .utf8)
        let tailer = TranscriptFileTailer(url: url)
        XCTAssertEqual(try tailer.catchUp().count, 0, "half a line is not an entry")

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(String(full[half...]).utf8))
        try handle.close()
        XCTAssertEqual(try tailer.catchUp().count, 1)
    }

    func testLastGrowthAtTracksFileModificationTime() throws {
        let url = transcript()
        try userLine("hello").write(to: url, atomically: false, encoding: .utf8)
        // Backdate the file: launch-scanning an old transcript must not look
        // like fresh growth or every session would boot as Working.
        let past = Date(timeIntervalSinceNow: -600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)

        let tailer = TranscriptFileTailer(url: url)
        _ = try tailer.catchUp()
        let growth = try XCTUnwrap(tailer.lastGrowthAt)
        XCTAssertEqual(growth.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 2)
    }

    func testTruncatedFileResetsAndReparses() throws {
        let url = transcript()
        try (userLine("one") + endTurnLine).write(to: url, atomically: false, encoding: .utf8)
        let tailer = TranscriptFileTailer(url: url)
        XCTAssertEqual(try tailer.catchUp().count, 2)

        // Shrink the file (shouldn't happen in practice; don't crash or misread)
        try userLine("fresh").write(to: url, atomically: false, encoding: .utf8)
        let entries = try tailer.catchUp()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(tailer.reducer.turnPhase, .midTurn)
    }

    func testCWDIsCapturedFromEntries() throws {
        let url = transcript()
        try userLine("hello").write(to: url, atomically: false, encoding: .utf8)
        let tailer = TranscriptFileTailer(url: url)
        _ = try tailer.catchUp()
        XCTAssertEqual(tailer.lastKnownCWD, "/Users/dev/appA")
    }

    func testUnreadableAfterManyMalformedLines() throws {
        let url = transcript()
        var content = userLine("ok")
        for i in 0..<51 { content += "garbage line \(i)\n" }
        try content.write(to: url, atomically: false, encoding: .utf8)

        let tailer = TranscriptFileTailer(url: url)
        _ = try tailer.catchUp()
        XCTAssertTrue(tailer.isUnreadable)
    }

    func testSessionIDComesFromFilename() {
        let tailer = TranscriptFileTailer(url: transcript("d51bb435-50c0-4fdd-96b4-385367309534.jsonl"))
        XCTAssertEqual(tailer.sessionID, "d51bb435-50c0-4fdd-96b4-385367309534")
    }
}

final class SessionDirectoryScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTranscript(dir: String, name: String, age: TimeInterval) throws {
        let dirURL = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let url = dirURL.appendingPathComponent(name)
        try "{}\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    func testFindsRecentTranscriptsAndSkipsOldOnes() throws {
        try makeTranscript(dir: "-Users-dev-appA", name: "aaa.jsonl", age: 60)
        try makeTranscript(dir: "-Users-dev-appA", name: "old.jsonl", age: 25 * 3600)
        try makeTranscript(dir: "-Users-dev-appB", name: "bbb.jsonl", age: 3600)

        let found = SessionDirectoryScanner.recentTranscripts(under: root, maxAge: 24 * 3600)
        XCTAssertEqual(Set(found.map(\.sessionID)), ["aaa", "bbb"])
        let aaa = found.first { $0.sessionID == "aaa" }
        XCTAssertEqual(aaa?.projectDirName, "-Users-dev-appA")
    }

    func testIgnoresNonJSONLFiles() throws {
        try makeTranscript(dir: "-Users-dev-appA", name: "notes.txt", age: 60)
        let found = SessionDirectoryScanner.recentTranscripts(under: root, maxAge: 24 * 3600)
        XCTAssertTrue(found.isEmpty)
    }

    func testMissingRootReturnsEmpty() {
        let found = SessionDirectoryScanner.recentTranscripts(
            under: root.appendingPathComponent("nope"), maxAge: 24 * 3600)
        XCTAssertTrue(found.isEmpty)
    }
}
