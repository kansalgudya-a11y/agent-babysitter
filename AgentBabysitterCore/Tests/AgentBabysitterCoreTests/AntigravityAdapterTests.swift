import XCTest
@testable import AgentBabysitterCore

final class FileActivityReaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testFreshWritesReadAsMidTurnAndQuietReadsAsCompleted() throws {
        let db = dir.appendingPathComponent("abc.db")
        try Data("x".utf8).write(to: db)

        // Injected clock: start "now" at the file's mtime
        let mtime = (try FileManager.default.attributesOfItem(atPath: db.path))[.modificationDate] as! Date
        nonisolated(unsafe) var fakeNow = mtime.addingTimeInterval(5)
        let reader = FileActivityReader(url: db, sessionID: "abc", entrypoint: "Antigravity",
                                        idleCutoff: 60, now: { fakeNow })
        try reader.refresh()

        XCTAssertEqual(reader.turnPhase, .midTurn, "5s after last write: active")
        XCTAssertEqual(reader.lastGrowthAt!.timeIntervalSince1970,
                       mtime.timeIntervalSince1970, accuracy: 1)

        fakeNow = mtime.addingTimeInterval(120)
        XCTAssertEqual(reader.turnPhase, .completed, "2min quiet: turn over")
    }

    func testWALSiblingCountsAsGrowth() throws {
        let db = dir.appendingPathComponent("abc.db")
        try Data("x".utf8).write(to: db)
        // Backdate the main db; only the -wal is fresh (normal during writes)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: db.path)
        try Data("y".utf8).write(to: URL(fileURLWithPath: db.path + "-wal"))

        let reader = FileActivityReader(url: db, sessionID: "abc", entrypoint: nil)
        try reader.refresh()
        XCTAssertLessThan(abs(reader.lastGrowthAt!.timeIntervalSinceNow), 5,
                          "wal mtime should win over the stale main db")
    }

    func testNewBurstAfterQuietStartsNewTurn() throws {
        let db = dir.appendingPathComponent("abc.db")
        try Data("x".utf8).write(to: db)
        let first = (try FileManager.default.attributesOfItem(atPath: db.path))[.modificationDate] as! Date

        nonisolated(unsafe) var fakeNow = first.addingTimeInterval(1)
        let reader = FileActivityReader(url: db, sessionID: "abc", entrypoint: nil,
                                        idleCutoff: 60, now: { fakeNow })
        try reader.refresh()
        XCTAssertEqual(reader.currentTurnStartedAt, first)

        // Long quiet, then a new write
        fakeNow = first.addingTimeInterval(600)
        let second = first.addingTimeInterval(590)
        try FileManager.default.setAttributes([.modificationDate: second], ofItemAtPath: db.path)
        try reader.refresh()
        XCTAssertEqual(try XCTUnwrap(reader.currentTurnStartedAt).timeIntervalSince1970,
                       second.timeIntervalSince1970, accuracy: 1, "new burst = new turn")
    }
}

final class AntigravityAdapterTests: XCTestCase {

    private let adapter = AntigravityAdapter(surface: .cli)

    func testSurfaceRootsAndIdentity() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(adapter.id, "antigravity-cli")
        XCTAssertEqual(adapter.transcriptRoot.path,
                       "\(home)/.gemini/antigravity-cli/conversations")
        XCTAssertEqual(AntigravityAdapter(surface: .desktop).displayName, "Antigravity")
        XCTAssertEqual(AntigravityAdapter.allSurfaces().count, 3)
    }

    func testWALAndSHMPathsCanonicalizeToTheDB() {
        let base = adapter.transcriptRoot.appendingPathComponent("abc.db").path
        XCTAssertTrue(adapter.isTranscript(path: base))
        XCTAssertTrue(adapter.isTranscript(path: base + "-wal"))
        XCTAssertTrue(adapter.isTranscript(path: base + "-shm"))
        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: base + "-wal").path, base)
        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: base + "-shm").path, base)
        XCTAssertFalse(adapter.isTranscript(path: base + ".journal"))
    }

    func testAgentPIDsMatchOnlyMainBinaries() {
        let psComm = """
        100 /Users/dev/.local/bin/agy
        150 agy
        200 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        201 /Applications/Antigravity.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper
        300 /Applications/Antigravity IDE.app/Contents/MacOS/Electron
        400 /usr/bin/grep
        """
        // Go reports the running CLI as bare "agy" (observed live) — both forms match
        XCTAssertEqual(AntigravityAdapter(surface: .cli).agentPIDs(psComm: psComm, psArgs: ""), [100, 150])
        XCTAssertEqual(AntigravityAdapter(surface: .desktop).agentPIDs(psComm: psComm, psArgs: ""), [200])
        XCTAssertEqual(AntigravityAdapter(surface: .ide).agentPIDs(psComm: psComm, psArgs: ""), [300])
    }

    func testMatchPairsNewestSessionsFirst() {
        let candidates = [
            SessionMatchCandidate(sessionID: "old", projectDirName: "", lastKnownCWD: nil,
                                  lastModified: Date(timeIntervalSince1970: 1000)),
            SessionMatchCandidate(sessionID: "new", projectDirName: "", lastKnownCWD: nil,
                                  lastModified: Date(timeIntervalSince1970: 2000)),
        ]
        let match = adapter.match(processes: [RunningProcess(pid: 5, cwd: "/")],
                                  candidates: candidates)
        XCTAssertEqual(match, ["new": 5])
    }

    func testStoreShowsAntigravitySessionFromActivity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-store-\(UUID().uuidString)")
        let scoped = AntigravityAdapter(surface: .cli, geminiRoot: root)
        try FileManager.default.createDirectory(at: scoped.transcriptRoot,
                                                withIntermediateDirectories: true)
        let db = scoped.transcriptRoot.appendingPathComponent(
            "463fa2d4-6415-4945-bbd9-767695929f24.db")
        try Data("sqlite".utf8).write(to: db)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(configuration: .init(projectsRoot: root,
                                                      adapters: [scoped]))
        await store.bootstrap()
        await store.processesUpdated(.init(
            processesByAdapter: ["antigravity-cli": [RunningProcess(pid: 5, cwd: "/x")]],
            degraded: false))

        let rows = await store.rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "463fa2d4-6415-4945-bbd9-767695929f24")
        XCTAssertEqual(rows[0].agentName, "Antigravity CLI")
        XCTAssertEqual(rows[0].projectName, "#463fa2d4", "short conversation id keeps rows distinguishable")
        XCTAssertEqual(rows[0].state, .working, "db written moments ago")
        XCTAssertEqual(rows[0].cost, SessionCost(), "usage is unreadable — never invented")
    }
}
