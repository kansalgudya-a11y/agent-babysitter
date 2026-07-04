import XCTest
@testable import AgentBabysitterCore

final class GeminiAdapterTests: XCTestCase {

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    // MARK: - CLI surface (layout captured from a real 0.49.0 run)

    func testCLIFindsRealLayoutSessions() throws {
        let home = try makeHome()
        let chats = home.appendingPathComponent(".gemini/tmp/scratchpad/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-2026-07-04T23-29-6268f132.jsonl")
        // Real header shape from disk.
        try #"{"sessionId":"fd848c42-bd9c-48b9-bea5-3fb336f4ff44","projectHash":"f7c9","startTime":"2026-07-04T23:29:38.186Z","lastUpdated":"2026-07-04T23:29:38.186Z","kind":"main"}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiAdapter(surface: .cli, home: home)
        let found = adapter.recentTranscripts(maxAge: 3600, now: Date())
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].sessionID, "2026-07-04T23-29-6268f132")
        XCTAssertEqual(found[0].projectDirName, "scratchpad")
        XCTAssertTrue(adapter.isTranscript(path: file.path))
        XCTAssertFalse(adapter.isTranscript(path: home.appendingPathComponent(
            ".gemini/tmp/scratchpad/logs.json").path))
    }

    func testCLIProcessMatchesNodeHostedInvocations() {
        let adapter = GeminiAdapter(surface: .cli)
        let args = """
        123 node /Users/x/.local/bin/gemini -p hi
        456 node /usr/lib/node_modules/@google/gemini-cli/dist/index.js
        789 vim notes.txt
        """
        XCTAssertEqual(adapter.agentPIDs(psComm: "", psArgs: args), [123, 456])
    }

    // MARK: - Desktop surface (layout captured from the live app via lsof)

    func testDesktopFindsChatStorePerProfile() throws {
        let home = try makeHome()
        let user1 = home.appendingPathComponent(
            "Library/Caches/com.google.GeminiMacOS/Gemini/user1")
        try FileManager.default.createDirectory(at: user1, withIntermediateDirectories: true)
        let store = user1.appendingPathComponent("ChatInfo2.store")
        try Data("sqlite".utf8).write(to: store)
        // Activity arrives via the WAL, not the main file.
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))

        let adapter = GeminiAdapter(surface: .desktop, home: home)
        let found = adapter.recentTranscripts(maxAge: 3600, now: Date())
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].sessionID, "user1")
        XCTAssertEqual(found[0].projectDirName, "Gemini chat")

        XCTAssertTrue(adapter.isTranscript(path: store.path + "-wal"))
        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: store.path + "-wal"), store)
    }

    func testDesktopWALActivityCountsAsRecent() throws {
        let home = try makeHome()
        let user1 = home.appendingPathComponent(
            "Library/Caches/com.google.GeminiMacOS/Gemini/user1")
        try FileManager.default.createDirectory(at: user1, withIntermediateDirectories: true)
        let store = user1.appendingPathComponent("ChatInfo2.store")
        try Data("sqlite".utf8).write(to: store)
        // Main file is old; WAL is fresh — the session must still be found.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: store.path)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))

        let adapter = GeminiAdapter(surface: .desktop, home: home)
        XCTAssertEqual(adapter.recentTranscripts(maxAge: 3600, now: Date()).count, 1)
    }

    func testDesktopProcessMatchExcludesTheAlwaysRunningLauncher() {
        let adapter = GeminiAdapter(surface: .desktop)
        let comm = """
        100 /Applications/Gemini.app/Contents/MacOS/Gemini
        200 /Applications/Gemini.app/Contents/Helpers/GeminiAppLauncher.app/Contents/MacOS/GeminiAppLauncher
        300 /Applications/Gemini.app/Contents/Helpers/crashpad_handler
        """
        XCTAssertEqual(adapter.agentPIDs(psComm: comm, psArgs: ""), [100])
    }

    /// Integration: only on a machine with real Gemini data.
    func testRealLayoutsIfPresent() throws {
        let cli = GeminiAdapter(surface: .cli)
        guard FileManager.default.fileExists(atPath: cli.transcriptRoot.path) else {
            throw XCTSkip("gemini CLI has no tmp dir")
        }
        // Must not crash and must not misclassify antigravity's dirs, which
        // share ~/.gemini.
        for info in cli.recentTranscripts(maxAge: 365 * 86_400, now: Date()) {
            XCTAssertTrue(info.url?.path.contains("/chats/session-") == true)
        }
    }
}
