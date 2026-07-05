import XCTest
import SQLite3
@testable import AgentBabysitterCore

final class CursorAdapterTests: XCTestCase {

    private func makeAppSupport() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Cursor/User/globalStorage"),
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Writes a state.vscdb with the cursorDiskKV layout captured from a
    /// real install (schema `_v` 16, 2026-07).
    private func writeStateDB(at url: URL, rows: [(String, String)]) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB)",
                     nil, nil, nil)
        for (key, value) in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV VALUES (?, ?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    /// Composer JSON in the real record shape; used composers carry
    /// lastUpdatedAt, pristine defaults don't.
    private func composerJSON(id: String, name: String? = nil,
                              status: String = "none",
                              lastUpdatedAtMS: Double? = nil) -> String {
        var fields = [
            "\"_v\":16", "\"composerId\":\"\(id)\"", "\"richText\":\"\"",
            "\"hasLoaded\":true", "\"conversationMap\":{}", "\"status\":\"\(status)\"",
        ]
        if let name { fields.append("\"name\":\"\(name)\"") }
        if let lastUpdatedAtMS {
            fields.append("\"createdAt\":\(lastUpdatedAtMS - 60000)")
            fields.append("\"lastUpdatedAt\":\(lastUpdatedAtMS)")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    func testParsesUsedComposersAndSkipsPristineAndJunk() throws {
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        let updated = Date().timeIntervalSince1970 * 1000
        writeStateDB(at: adapter.stateDBURL, rows: [
            ("composerData:aaaa-1111", composerJSON(
                id: "aaaa-1111", name: "Fix login bug", status: "completed",
                lastUpdatedAtMS: updated)),
            // Pristine default composer: no lastUpdatedAt (real machines
            // carry a couple of these) — not a session.
            ("composerData:bbbb-2222", composerJSON(id: "bbbb-2222")),
            // Both seen on a real install: an empty-value draft row and a
            // key whose id doesn't match its record.
            ("composerData:empty-state-draft", ""),
            ("composerData:cccc-3333", composerJSON(
                id: "dddd-4444", lastUpdatedAtMS: updated)),
        ])

        let composers = CursorAdapter.composers(inStateDBAt: adapter.stateDBURL)
        XCTAssertEqual(composers.count, 1)
        XCTAssertEqual(composers[0].id, "aaaa-1111")
        XCTAssertEqual(composers[0].name, "Fix login bug")
        XCTAssertEqual(composers[0].status, "completed")
        XCTAssertEqual(composers[0].lastUpdatedAt.timeIntervalSince1970,
                       updated / 1000, accuracy: 0.01)
    }

    func testRecentTranscriptsUsesComposerIdentityAndMaxAge() throws {
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        let now = Date()
        writeStateDB(at: adapter.stateDBURL, rows: [
            ("composerData:fresh", composerJSON(
                id: "fresh", name: "Refactor",
                lastUpdatedAtMS: now.timeIntervalSince1970 * 1000 - 60_000)),
            ("composerData:stale", composerJSON(
                id: "stale",
                lastUpdatedAtMS: now.timeIntervalSince1970 * 1000 - 7_200_000)),
        ])

        let found = adapter.recentTranscripts(maxAge: 3600, now: now)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].sessionID, "fresh")
        XCTAssertEqual(found[0].projectDirName, "Refactor")
        XCTAssertEqual(found[0].url, adapter.stateDBURL)
        XCTAssertTrue(adapter.multiSessionFiles)
    }

    func testUnnamedComposerGetsShortIDLabel() throws {
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        let now = Date()
        writeStateDB(at: adapter.stateDBURL, rows: [
            ("composerData:0123456789abcdef", composerJSON(
                id: "0123456789abcdef",
                lastUpdatedAtMS: now.timeIntervalSince1970 * 1000)),
        ])
        let found = adapter.recentTranscripts(maxAge: 3600, now: now)
        XCTAssertEqual(found.first?.projectDirName, "#01234567")
    }

    func testWALPathsCanonicalizeToBaseDB() throws {
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        let base = adapter.stateDBURL.path
        XCTAssertTrue(adapter.isTranscript(path: base + "-wal"))
        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: base + "-wal").path, base)
        XCTAssertEqual(adapter.canonicalTranscriptURL(forPath: base + "-shm").path, base)
        XCTAssertFalse(adapter.isTranscript(path: "/tmp/other.vscdb"))
    }

    func testAgentPIDsMatchesMainBinaryNotHelpers() {
        let adapter = CursorAdapter()
        let comm = """
        100 /Applications/Cursor.app/Contents/MacOS/Cursor
        200 /Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)
        300 /Applications/Cursor.app/Contents/Frameworks/Cursor Helper (GPU).app/Contents/MacOS/Cursor Helper (GPU)
        400 vim
        """
        XCTAssertEqual(adapter.agentPIDs(psComm: comm, psArgs: ""), [100])
    }

    func testMatchSharesTheAppPidAcrossAllComposers() {
        let adapter = CursorAdapter()
        let now = Date()
        let candidates = [
            SessionMatchCandidate(sessionID: "a", projectDirName: "",
                                  lastKnownCWD: nil, lastModified: now),
            SessionMatchCandidate(sessionID: "b", projectDirName: "",
                                  lastKnownCWD: nil, lastModified: now.addingTimeInterval(-30)),
        ]
        let processes = [RunningProcess(pid: 42, cwd: "/")]
        let match = adapter.match(processes: processes, candidates: candidates)
        XCTAssertEqual(match["a"], 42)
        XCTAssertEqual(match["b"], 42)
    }

    func testReaderMidTurnWhileStatusActiveAndCompletedAtRest() throws {
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        let now = Date()
        writeStateDB(at: adapter.stateDBURL, rows: [
            ("composerData:live", composerJSON(
                id: "live", status: "generating",
                lastUpdatedAtMS: (now.timeIntervalSince1970 - 30) * 1000)),
            ("composerData:done", composerJSON(
                id: "done", status: "completed",
                lastUpdatedAtMS: (now.timeIntervalSince1970 - 30) * 1000)),
        ])

        let live = adapter.makeReader(url: adapter.stateDBURL, sessionID: "live")
        try live.refresh()
        XCTAssertEqual(live.turnPhase, .midTurn)

        let done = adapter.makeReader(url: adapter.stateDBURL, sessionID: "done")
        try done.refresh()
        XCTAssertEqual(done.turnPhase, .completed)
    }

    func testParseCacheReturnsFreshDataAfterDBChanges() throws {
        // The mtime-keyed parse cache must not serve stale composers after
        // the db is rewritten (a newer composer appears).
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        let now = Date().timeIntervalSince1970 * 1000
        writeStateDB(at: adapter.stateDBURL, rows: [
            ("composerData:one", composerJSON(id: "one", name: "First", lastUpdatedAtMS: now)),
        ])
        XCTAssertEqual(CursorAdapter.composers(inStateDBAt: adapter.stateDBURL).count, 1)

        // Rewrite with a second composer; bump mtime so the cache invalidates.
        try? FileManager.default.removeItem(at: adapter.stateDBURL)
        writeStateDB(at: adapter.stateDBURL, rows: [
            ("composerData:one", composerJSON(id: "one", name: "First", lastUpdatedAtMS: now)),
            ("composerData:two", composerJSON(id: "two", name: "Second", lastUpdatedAtMS: now)),
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: adapter.stateDBURL.path)
        let ids = Set(CursorAdapter.composers(inStateDBAt: adapter.stateDBURL).map(\.id))
        XCTAssertEqual(ids, ["one", "two"])
    }

    func testReaderTreatsStaleActiveStatusAsCompleted() throws {
        // A composer abandoned mid-turn (app crash) must not read Working
        // forever off its sticky status.
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        writeStateDB(at: adapter.stateDBURL, rows: [
            ("composerData:old", composerJSON(
                id: "old", status: "generating",
                lastUpdatedAtMS: (Date().timeIntervalSince1970 - 3600) * 1000)),
        ])
        let reader = adapter.makeReader(url: adapter.stateDBURL, sessionID: "old")
        try reader.refresh()
        XCTAssertEqual(reader.turnPhase, .completed)
    }
}

// MARK: - Usage (plan tier on disk; live JSON shapes captured 2026-07)

final class CursorUsageTests: XCTestCase {

    private func makeAppSupport() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Cursor/User/globalStorage"),
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeItemTable(at url: URL, rows: [(String, String)]) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)",
                     nil, nil, nil)
        for (key, value) in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES (?, ?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    func testPlanTierFromDisk() throws {
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        writeItemTable(at: adapter.stateDBURL, rows: [
            ("cursorAuth/stripeMembershipType", "free"),
            ("cursorAuth/accessToken", "tok"),
        ])
        let usage = adapter.usageFromDisk()
        XCTAssertEqual(usage?.plan, "Free")
        XCTAssertNil(usage?.usedPercent)
        XCTAssertFalse(usage?.isLive ?? true)
        XCTAssertEqual(adapter.storedAccessToken(), "tok")
    }

    func testNoPlanKeyMeansNoSnapshot() throws {
        let appSupport = try makeAppSupport()
        let adapter = CursorAdapter(appSupport: appSupport)
        writeItemTable(at: adapter.stateDBURL, rows: [])
        XCTAssertNil(adapter.usageFromDisk())
        XCTAssertNil(adapter.storedAccessToken())
    }

    func testUserIDFromSessionJWT() {
        // Same claim layout as the real token: sub = "<provider>|user_…".
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let jwt = [b64url(#"{"alg":"HS256"}"#),
                   b64url(#"{"sub":"google-oauth2|user_01ABC","type":"session"}"#),
                   "sig"].joined(separator: ".")
        XCTAssertEqual(CursorUsageParsing.userID(fromSessionJWT: jwt), "user_01ABC")
        XCTAssertNil(CursorUsageParsing.userID(fromSessionJWT: "not-a-jwt"))
        let noUser = [b64url("{}"), b64url(#"{"sub":"auth0|other"}"#), "s"]
            .joined(separator: ".")
        XCTAssertNil(CursorUsageParsing.userID(fromSessionJWT: noUser))
    }

    func testSummaryGivesIncludedUsagePercentAndCycleReset() {
        // Verbatim live response shape from a real free account.
        let json = Data(#"""
        {"billingCycleStart":"2026-06-12T16:31:12.692Z",
         "billingCycleEnd":"2026-07-12T16:31:12.692Z",
         "membershipType":"free","isUnlimited":false,
         "individualUsage":{"plan":{"enabled":true,"autoPercentUsed":10,
           "apiPercentUsed":0,"totalPercentUsed":5}}}
        """#.utf8)
        let snapshot = CursorUsageParsing.snapshot(fromSummaryJSON: json)
        XCTAssertEqual(snapshot?.usedPercent ?? -1, 5, accuracy: 0.01)
        XCTAssertEqual(snapshot?.plan, "Free")
        XCTAssertTrue(snapshot?.isLive ?? false)
        let resets = snapshot?.resetsAt
        XCTAssertEqual(resets.map { Calendar.current.component(.month, from: $0) }, 7)
        // Window spans the ~30-day billing cycle, not a 5-hour default.
        XCTAssertGreaterThan(snapshot?.windowMinutes ?? 0, 20 * 24 * 60)
    }

    func testSummaryFullyUsedClampsTo100() {
        let json = Data(#"""
        {"membershipType":"pro","billingCycleStart":"2026-06-12T16:31:12.692Z",
         "billingCycleEnd":"2026-07-12T16:31:12.692Z",
         "individualUsage":{"plan":{"totalPercentUsed":143}}}
        """#.utf8)
        XCTAssertEqual(CursorUsageParsing.snapshot(fromSummaryJSON: json)?.usedPercent, 100)
    }

    func testMalformedSummaryJSONIsRejected() {
        XCTAssertNil(CursorUsageParsing.snapshot(fromSummaryJSON: Data("[]".utf8)))
        XCTAssertNil(CursorUsageParsing.snapshot(fromSummaryJSON: Data("{}".utf8)))
        // Missing the plan percentage → nil, never a fake 0.
        XCTAssertNil(CursorUsageParsing.snapshot(
            fromSummaryJSON: Data(#"{"individualUsage":{"plan":{}}}"#.utf8)))
    }
}
